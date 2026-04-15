#!/usr/bin/env bash
# Robust UDP packet loss test for vshape module.
# Primary validation: increase in TX dropped packets on sender interface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_PATH="${REPO_ROOT}/kernel/vshape_mod.ko"
OUTDIR="/tmp/vshape_loss_test.$(date +%s)"

LOSS_PPM=100000        # 10% packet loss target at enqueue
DELAY_MS=0
JITTER_MS=0
RATE_KBPS=100000       # keep rate high to avoid rate-limit side effects
CLIENT_BW="20M"
DURATION=10
MIN_TX_DROPS=1         # minimum expected delta in TX dropped counter

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --loss-ppm) LOSS_PPM="$2"; shift 2;;
    --delay) DELAY_MS="$2"; shift 2;;
    --jitter) JITTER_MS="$2"; shift 2;;
    --rate-kbps) RATE_KBPS="$2"; shift 2;;
    --bw) CLIENT_BW="$2"; shift 2;;
    --time) DURATION="$2"; shift 2;;
    --min-tx-drops) MIN_TX_DROPS="$2"; shift 2;;
    --help)
      echo "Usage: $0 [--module path] [--loss-ppm 100000] [--delay 0] [--jitter 0] [--rate-kbps 100000] [--bw 20M] [--time 10] [--min-tx-drops 1]"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; shift;;
  esac
done

if (( EUID != 0 )); then
  echo "Run as root: sudo $0 ..."
  exit 1
fi

mkdir -p "$OUTDIR"
echo "outdir=$OUTDIR"
LOG="$OUTDIR/run.log"
if command -v stdbuf >/dev/null 2>&1; then
  exec > >(stdbuf -oL tee -a "$LOG") 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi

echo "=== vshape PACKET LOSS TEST (KERNEL-LEVEL) ==="
echo "module: $MODULE_PATH"
echo "params: loss=${LOSS_PPM}ppm delay=${DELAY_MS}ms jitter=${JITTER_MS}ms rate=${RATE_KBPS}kbps bw=${CLIENT_BW} duration=${DURATION}s"
echo "pass criteria: TX dropped delta >= ${MIN_TX_DROPS}"

modname="$(basename "$MODULE_PATH" .ko)"
NS1="ns1_vshape"
NS2="ns2_vshape"
IFACE_TX="vshapeA0"
TARGET_IP="10.42.1.2"

cleanup() {
  echo "[CLEANUP] killing bg jobs..."
  pkill -P $$ 2>/dev/null || true
  pkill -f "iperf3 -s" 2>/dev/null || true
  echo "[CLEANUP] done."
}
trap cleanup EXIT

get_tx_dropped() {
  local ns="$1"
  local iface="$2"
  ip netns exec "$ns" ip -s link show "$iface" | awk '
    /^ *TX:/ { want=1; next }
    want==1 && $1 ~ /^[0-9]+$/ {
      # columns: bytes packets errors dropped carrier collsns
      print $4
      exit
    }
  '
}

if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
  echo "[INFO] module $modname already loaded -> trying to rmmod (best-effort)"
  rmmod "$modname" 2>/dev/null || true
fi

echo "[INFO] insmod with param_loss_ppm=${LOSS_PPM}, param_delay_ms=${DELAY_MS}, param_jitter_ms=${JITTER_MS}, param_rate_kbps=${RATE_KBPS}"
insmod "$MODULE_PATH" \
  param_loss_ppm="$LOSS_PPM" \
  param_delay_ms="$DELAY_MS" \
  param_jitter_ms="$JITTER_MS" \
  param_rate_kbps="$RATE_KBPS"

ip netns del "$NS1" 2>/dev/null || true
ip netns del "$NS2" 2>/dev/null || true
ip netns add "$NS1"
ip netns add "$NS2"

DEV_A=""
DEV_B=""
for _ in $(seq 1 10); do
  DEV_A="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeA' | head -n 1 || true)"
  DEV_B="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeB' | head -n 1 || true)"
  if [[ -n "$DEV_A" && -n "$DEV_B" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then
  echo "[FAIL] could not find vshapeA*/vshapeB* after module insert"
  dmesg | tail -n 60 || true
  exit 2
fi

echo "[INFO] found pair in root ns: $DEV_A <-> $DEV_B"
ip link set "$DEV_A" netns "$NS1"
ip link set "$DEV_B" netns "$NS2"

echo "[INFO] configuring interfaces"
ip netns exec "$NS1" ip link set lo up
ip netns exec "$NS2" ip link set lo up
ip netns exec "$NS1" ip addr flush dev vshapeA0 2>/dev/null || true
ip netns exec "$NS2" ip addr flush dev vshapeB0 2>/dev/null || true
ip netns exec "$NS1" ip addr add 10.42.1.1/24 dev vshapeA0
ip netns exec "$NS2" ip addr add 10.42.1.2/24 dev vshapeB0
ip netns exec "$NS1" ip link set dev vshapeA0 up
ip netns exec "$NS2" ip link set dev vshapeB0 up

if command -v ethtool >/dev/null 2>&1; then
  ip netns exec "$NS1" ethtool -K vshapeA0 tso off gso off gro off lro off 2>/dev/null || true
  ip netns exec "$NS2" ethtool -K vshapeB0 tso off gso off gro off lro off 2>/dev/null || true
fi

# Kill any leftover iperf3 from previous tests to free port 5201.
pkill -f "iperf3 -s" 2>/dev/null || true
sleep 0.5

echo "[INFO] starting iperf3 server in $NS2"
IPERF_SERVER_LOG="$OUTDIR/iperf_server.log"
ip netns exec "$NS2" iperf3 -s --one-off >"$IPERF_SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.7
echo "[INFO] iperf3 server pid=$SERVER_PID"

TX_DROP_BEFORE="$(get_tx_dropped "$NS1" "$IFACE_TX" || true)"
if [[ -z "$TX_DROP_BEFORE" ]]; then
  echo "[FAIL] could not parse TX dropped counter before test"
  exit 2
fi
echo "[INFO] TX dropped before: $TX_DROP_BEFORE"

CLIENT_OUT="$OUTDIR/iperf_client.json"
echo "[INFO] running UDP iperf client -> ${TARGET_IP}, bw=${CLIENT_BW}, duration=${DURATION}s"
set +e
ip netns exec "$NS1" iperf3 -u -c "$TARGET_IP" -b "$CLIENT_BW" -t "$DURATION" -J >"$CLIENT_OUT" 2>&1
RC=$?
set -e
echo "[INFO] iperf3 client rc=$RC (saved to $CLIENT_OUT)"

TX_DROP_AFTER="$(get_tx_dropped "$NS1" "$IFACE_TX" || true)"
if [[ -z "$TX_DROP_AFTER" ]]; then
  echo "[FAIL] could not parse TX dropped counter after test"
  exit 2
fi
echo "[INFO] TX dropped after: $TX_DROP_AFTER"

DELTA_DROPS=$((TX_DROP_AFTER - TX_DROP_BEFORE))
echo "[INFO] TX dropped delta: $DELTA_DROPS"

LOSS_PCT_IPERF=""
if command -v jq >/dev/null 2>&1; then
  LOSS_PCT_IPERF="$(jq -r '.end.sum.lost_percent // empty' "$CLIENT_OUT" 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  LOSS_PCT_IPERF="$(python3 - "$CLIENT_OUT" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(d.get("end", {}).get("sum", {}).get("lost_percent", ""))
except Exception:
    print("")
PY
)"
fi

echo "=== VERDICT ==="
FAIL=0
if [[ "$RC" -ne 0 ]]; then
  echo "[WARN] iperf3 client returned rc=$RC (non-fatal; primary metric is TX drops)"
fi

if (( DELTA_DROPS < MIN_TX_DROPS )); then
  echo "[FAIL] TX dropped delta (${DELTA_DROPS}) is below minimum expected (${MIN_TX_DROPS})"
  FAIL=1
else
  echo "[INFO] kernel TX drop check passed (${DELTA_DROPS} >= ${MIN_TX_DROPS})"
fi

if [[ -n "$LOSS_PCT_IPERF" ]]; then
  echo "[INFO] iperf reported lost_percent=${LOSS_PCT_IPERF}% (informational)"
else
  echo "[WARN] could not parse iperf lost_percent (informational only)"
fi

echo "Logs saved under $OUTDIR"
echo "When done, you can cleanup: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname (if desired)"

if [[ "$FAIL" -eq 0 ]]; then
  echo "[PASS] packet loss test checks passed."
  exit 0
fi

echo "[FAIL] packet loss test checks failed."
exit 2
