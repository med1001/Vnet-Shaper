#!/usr/bin/env bash
# Robust ICMP delay test for vshape module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_PATH="${REPO_ROOT}/kernel/vshape_mod.ko"
OUTDIR="/tmp/vshape_delay_test.$(date +%s)"
DELAY_MS=50
JITTER_MS=0
LOSS_PPM=0
RATE_KBPS=100000
COUNT=10
RTT_TOL_PCT=30   # Acceptable +/- around expected RTT
MAX_LOSS_PCT=0   # No loss expected in a pure delay test

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --delay) DELAY_MS="$2"; shift 2;;
    --jitter) JITTER_MS="$2"; shift 2;;
    --loss-ppm) LOSS_PPM="$2"; shift 2;;
    --rate) RATE_KBPS="$2"; shift 2;;
    --count) COUNT="$2"; shift 2;;
    --rtt-tol) RTT_TOL_PCT="$2"; shift 2;;
    --max-loss) MAX_LOSS_PCT="$2"; shift 2;;
    --help)
      echo "Usage: $0 [--module path] [--delay 50] [--jitter 0] [--loss-ppm 0] [--rate 100000] [--count 10] [--rtt-tol 30] [--max-loss 0]"
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

echo "=== vshape DELAY TEST ==="
echo "module: $MODULE_PATH"
echo "params: delay=${DELAY_MS}ms jitter=${JITTER_MS}ms loss=${LOSS_PPM}ppm rate=${RATE_KBPS}kbps count=${COUNT}"
echo "pass criteria: RTT within +/-${RTT_TOL_PCT}% of expected, packet loss <= ${MAX_LOSS_PCT}%"

modname="$(basename "$MODULE_PATH" .ko)"
NS1="ns1_vshape"
NS2="ns2_vshape"

cleanup() {
  echo "[CLEANUP] stopping background jobs..."
  pkill -P $$ 2>/dev/null || true
  echo "[CLEANUP] done."
}
trap cleanup EXIT

# Reload module with the desired parameters.
if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
  echo "[INFO] module $modname already loaded -> trying to rmmod (best-effort)"
  rmmod "$modname" 2>/dev/null || true
fi

echo "[INFO] insmod with param_delay_ms=${DELAY_MS}, param_jitter_ms=${JITTER_MS}, param_loss_ppm=${LOSS_PPM}, param_rate_kbps=${RATE_KBPS}"
insmod "$MODULE_PATH" \
  param_delay_ms="$DELAY_MS" \
  param_jitter_ms="$JITTER_MS" \
  param_loss_ppm="$LOSS_PPM" \
  param_rate_kbps="$RATE_KBPS"

# Clean and re-create namespaces.
ip netns del "$NS1" 2>/dev/null || true
ip netns del "$NS2" 2>/dev/null || true
ip netns add "$NS1"
ip netns add "$NS2"

# Wait for pair in root namespace.
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
echo "[INFO] moving devices to namespaces"
ip link set "$DEV_A" netns "$NS1"
ip link set "$DEV_B" netns "$NS2"

echo "[INFO] configuring links"
ip netns exec "$NS1" ip link set lo up
ip netns exec "$NS2" ip link set lo up
ip netns exec "$NS1" ip addr flush dev "$DEV_A" 2>/dev/null || true
ip netns exec "$NS2" ip addr flush dev "$DEV_B" 2>/dev/null || true
ip netns exec "$NS1" ip addr add 10.42.1.1/24 dev "$DEV_A"
ip netns exec "$NS2" ip addr add 10.42.1.2/24 dev "$DEV_B"
ip netns exec "$NS1" ip link set dev "$DEV_A" up
ip netns exec "$NS2" ip link set dev "$DEV_B" up

if command -v ethtool >/dev/null 2>&1; then
  ip netns exec "$NS1" ethtool -K "$DEV_A" tso off gso off gro off lro off 2>/dev/null || true
  ip netns exec "$NS2" ethtool -K "$DEV_B" tso off gso off gro off lro off 2>/dev/null || true
fi

EXPECTED_RTT_MS=$((DELAY_MS * 2))
MIN_RTT_MS=$((EXPECTED_RTT_MS * (100 - RTT_TOL_PCT) / 100))
MAX_RTT_MS=$((EXPECTED_RTT_MS * (100 + RTT_TOL_PCT) / 100))

echo "[INFO] running ping with expected RTT ~= ${EXPECTED_RTT_MS} ms"
PING_LOG="$OUTDIR/ping.txt"
set +e
ip netns exec "$NS1" ping -c "$COUNT" -i 0.2 10.42.1.2 | tee "$PING_LOG"
PING_RC=${PIPESTATUS[0]}
set -e

echo "=== VERDICT ==="
FAIL=0
if [[ "$PING_RC" -ne 0 ]]; then
  echo "[FAIL] ping returned rc=$PING_RC"
  FAIL=1
fi

RTT_LINE="$(grep -m 1 'rtt min/avg/max' "$PING_LOG" || true)"
if [[ -z "$RTT_LINE" ]]; then
  echo "[FAIL] could not parse RTT summary from ping output"
  FAIL=1
else
  # Example: rtt min/avg/max/mdev = 100.772/101.633/102.590/0.486 ms
  AVG_RTT_MS="$(echo "$RTT_LINE" | awk -F'=' '{print $2}' | awk -F'/' '{gsub(/ /,"",$2); print $2}')"
  echo "[INFO] average RTT: ${AVG_RTT_MS} ms (expected ${EXPECTED_RTT_MS} ms, allowed ${MIN_RTT_MS}-${MAX_RTT_MS} ms)"
  if ! awk "BEGIN { exit !($AVG_RTT_MS >= $MIN_RTT_MS && $AVG_RTT_MS <= $MAX_RTT_MS) }"; then
    echo "[FAIL] average RTT outside tolerance"
    FAIL=1
  fi
fi

LOSS_LINE="$(grep -m 1 'packet loss' "$PING_LOG" || true)"
if [[ -n "$LOSS_LINE" ]]; then
  echo "[INFO] $LOSS_LINE"
  LOSS_PCT="$(echo "$LOSS_LINE" | awk -F',' '{print $3}' | awk '{gsub(/%/,"",$1); print $1}')"
  if [[ -n "$LOSS_PCT" ]]; then
    if ! awk "BEGIN { exit !($LOSS_PCT <= $MAX_LOSS_PCT) }"; then
      echo "[FAIL] packet loss ${LOSS_PCT}% exceeds maximum ${MAX_LOSS_PCT}%"
      FAIL=1
    fi
  fi
fi

echo "Logs saved under $OUTDIR"
echo "When done, you can cleanup: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname (if desired)"

if [[ "$FAIL" -eq 0 ]]; then
  echo "[PASS] delay test checks passed."
  exit 0
fi

echo "[FAIL] delay test checks failed."
exit 2
