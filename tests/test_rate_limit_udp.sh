#!/usr/bin/env bash
# vshape_test3_safe.sh
# Safe, minimal automated test for TEST-3 (rate limiting UDP)
# - loads module (or reloads it) with safe params
# - configures vshape pair in net namespaces (creates ns if needed)
# - starts tcpdump, iperf3 server, runs iperf3 client UDP (small BW)
# - gathers logs in /tmp and cleans up background processes
#
# Usage: sudo ./vshape_test3_safe.sh [--module path] [--bw 5M] [--rate 2000] [--time 8]
#
# Stuck after "configuring interfaces"? Usually `ip netns exec` is waiting on the kernel
# RTNL lock. Check: `ss -tp | grep -E '^\s*ip'`; try `systemctl stop NetworkManager` briefly;
# remove stale namespaces: `ip netns del ns1_vshape` / `ns2_vshape`. Increase wait: IP_TIMEOUT=120.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_PATH="${REPO_ROOT}/kernel/vshape_mod.ko"
OUTDIR="/tmp/vshape_test3_safe.$(date +%s)"
CLIENT_BW="5M"      # iperf client requested bandwidth
RATE_KBPS=2000      # module shaping target rate in kbps (2 Mbps)
DELAY_MS=0
JITTER_MS=0
DURATION=8
TOLERANCE_PCT=25    # acceptable +/- percentage around RATE_KBPS
MAX_LOSS_PCT=5      # acceptable UDP packet loss percentage

# parse args simple
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --bw) CLIENT_BW="$2"; shift 2;;
    --rate) RATE_KBPS="$2"; shift 2;;
    --time) DURATION="$2"; shift 2;;
    --tol) TOLERANCE_PCT="$2"; shift 2;;
    --max-loss) MAX_LOSS_PCT="$2"; shift 2;;
    --help) echo "Usage: $0 [--module path] [--bw 5M] [--rate 2000] [--time 8] [--tol 25] [--max-loss 5]"; exit 0;;
    *) echo "Unknown $1"; shift;;
  esac
done

if (( EUID != 0 )); then
  echo "Run as root"; exit 1
fi

mkdir -p "$OUTDIR"
echo "outdir=$OUTDIR"
LOG="$OUTDIR/run.log"
# Line-buffer tee when stdbuf exists (reduces oddities with long pipelines).
if command -v stdbuf >/dev/null 2>&1; then
  exec > >(stdbuf -oL tee -a "$LOG") 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi

# Seconds for each `ip netns exec ...` (not for iperf duration). Increase if needed.
IP_TIMEOUT="${IP_TIMEOUT:-45}"

step_tty() {
  if [[ -w /dev/tty ]]; then
    echo "$@" > /dev/tty
  fi
}

# Run a command inside a net namespace with an optional timeout (GNU coreutils).
run_ns() {
  local ns="$1"
  shift
  step_tty "[RUN] ip netns exec ${ns} $*"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${IP_TIMEOUT}" ip netns exec "$ns" "$@"; then
      echo "[ERROR] ip netns exec failed or exceeded ${IP_TIMEOUT}s: $ns -> $*"
      echo "[HINT] Another process may hold RTNL (see: ss -tp); try stopping NetworkManager, or delete stale netns."
      exit 1
    fi
  else
    ip netns exec "$ns" "$@"
  fi
}

# Same as run_ns but never aborts the script (for flush / ethtool / optional "link up").
run_ns_ignore() {
  local ns="$1"
  shift
  step_tty "[RUN] ip netns exec ${ns} $* (non-fatal)"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${IP_TIMEOUT}" ip netns exec "$ns" "$@" 2>/dev/null || true
  else
    ip netns exec "$ns" "$@" 2>/dev/null || true
  fi
}

echo "=== vshape TEST3 SAFE ==="
echo "module: $MODULE_PATH"
echo "requested client BW: $CLIENT_BW, module rate: ${RATE_KBPS} kbps, duration: ${DURATION}s"
echo "pass criteria: throughput within +/-${TOLERANCE_PCT}% of ${RATE_KBPS} kbps, loss <= ${MAX_LOSS_PCT}%"

modname="$(basename "$MODULE_PATH" .ko)"

cleanup() {
    echo "[CLEANUP] killing bg jobs..."
    pkill -P $$ 2>/dev/null || true
    sleep 0.3
    # try to stop iperf / tcpdump if still running
    pkill -f "iperf3 -s" 2>/dev/null || true
    pkill -f "tcpdump -i" 2>/dev/null || true
    sleep 0.2
    echo "[CLEANUP] done."
}
trap cleanup EXIT

# unload module if already loaded (safer to reinsert with params)
if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
    echo "[INFO] module $modname already loaded -> trying to rmmod (best-effort)"
    if ! rmmod "$modname" 2>/dev/null; then
        echo "[WARN] could not rmmod $modname; continuing (may have stale state)"
    else
        echo "[INFO] rmmod succeeded"
    fi
fi

# insert module with params so per-end values are set at init
echo "[INFO] inserting module with params rate=${RATE_KBPS}kbps delay=${DELAY_MS}ms jitter=${JITTER_MS}ms"
if ! insmod "$MODULE_PATH" param_rate_kbps="$RATE_KBPS" param_delay_ms="$DELAY_MS" param_jitter_ms="$JITTER_MS"; then
    echo "[ERROR] insmod failed"; exit 1
fi

# Clean stale namespaces from previous runs before device discovery.
ip netns del ns1_vshape 2>/dev/null || true
ip netns del ns2_vshape 2>/dev/null || true

sleep 0.5

# wait for device pair (in root namespace initially)
WAIT=8
DEV_A=""
DEV_B=""
while (( WAIT-- > 0 )); do
    DEV_A="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeA' | head -n1 || true)"
    DEV_B="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeB' | head -n1 || true)"
    if [[ -n "$DEV_A" && -n "$DEV_B" ]]; then
        echo "[INFO] found pair in root ns: $DEV_A <-> $DEV_B"
        ROOT_MODE=1
        break
    fi
    sleep 1
done

# If not in root, check common ns names
if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then
    if ip netns list 2>/dev/null | grep -q '^ns1_vshape'; then
        echo "[INFO] checking in netns ns1_vshape/ns2_vshape"
        if ip netns exec ns1_vshape ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -q '^vshapeA'; then
            DEV_A="vshapeA0"
            DEV_B="vshapeB0"
            ROOT_MODE=0
            echo "[INFO] found vshapeA/B inside netns ns1_vshape/ns2_vshape"
        fi
    fi
fi

# If still not found: try to wait a little longer
if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then
    echo "[ERROR] cannot find vshape pair (vshapeA* and vshapeB*). Check dmesg. Exiting."
    dmesg | tail -n 40 | sed -n '1,200p'
    exit 1
fi

# If devices are in root, move them to netns ns1/ns2 (we create them)
if [[ "${ROOT_MODE:-0}" -eq 1 ]]; then
    NS1="ns1_vshape"
    NS2="ns2_vshape"
    echo "[INFO] creating netns $NS1 $NS2 (if missing) and moving devices"
    ip netns add "$NS1" 2>/dev/null || true
    ip netns add "$NS2" 2>/dev/null || true

    echo "[INFO] moving $DEV_A -> $NS1"
    ip link set "$DEV_A" netns "$NS1"
    echo "[INFO] moving $DEV_B -> $NS2"
    ip link set "$DEV_B" netns "$NS2"
else
    NS1="ns1_vshape"
    NS2="ns2_vshape"
fi

sleep 0.2

# configure devices inside namespaces
echo "[INFO] configuring interfaces and IPs"
run_ns "$NS1" ip link set lo up
run_ns_ignore "$NS1" ip link set dev vshapeA0 up
run_ns_ignore "$NS1" ip addr flush dev vshapeA0
run_ns "$NS1" ip addr add 10.42.1.1/24 dev vshapeA0

run_ns "$NS2" ip link set lo up
run_ns_ignore "$NS2" ip link set dev vshapeB0 up
run_ns_ignore "$NS2" ip addr flush dev vshapeB0
run_ns "$NS2" ip addr add 10.42.1.2/24 dev vshapeB0

# disable offloads best-effort (minimize host acceleration)
if command -v ethtool >/dev/null 2>&1; then
    run_ns_ignore "$NS1" ethtool -K vshapeA0 tso off gso off gro off lro off
    run_ns_ignore "$NS2" ethtool -K vshapeB0 tso off gso off gro off lro off
fi

# start background tcpdump on B (limited time via timeout if available)
PCAP="$OUTDIR/test3.pcap"
TCPDUMP_LOG="$OUTDIR/tcpdump.err"
echo "[INFO] starting tcpdump in $NS2 (writing $PCAP)"
if command -v timeout >/dev/null 2>&1; then
    ip netns exec "$NS2" timeout $((DURATION + 6)) tcpdump -i vshapeB0 -s 0 -w "$PCAP" not vlan >"$TCPDUMP_LOG" 2>&1 &
    TCPDUMP_PID=$!
else
    ip netns exec "$NS2" tcpdump -i vshapeB0 -s 0 -w "$PCAP" not vlan >"$TCPDUMP_LOG" 2>&1 &
    TCPDUMP_PID=$!
fi
echo "[INFO] tcpdump pid=$TCPDUMP_PID"
sleep 0.5

# start iperf3 server inside NS2
IPERF_SERVER_LOG="$OUTDIR/iperf_server.log"
echo "[INFO] starting iperf3 server in $NS2"
ip netns exec "$NS2" iperf3 -s >"$IPERF_SERVER_LOG" 2>&1 &
IPERF_SERVER_PID=$!
sleep 0.6
echo "[INFO] iperf3 server pid=$IPERF_SERVER_PID"

# run iperf3 client UDP from NS1
CLIENT_OUT="$OUTDIR/iperf_client.json"
echo "[INFO] running iperf3 client UDP -> 10.42.1.2, bw=$CLIENT_BW, duration=${DURATION}s"
set +e
ip netns exec "$NS1" iperf3 -c 10.42.1.2 -u -b "$CLIENT_BW" -t "$DURATION" -J > "$CLIENT_OUT" 2>&1
RC=$?
set -e
echo "[INFO] iperf3 client exited rc=$RC (saved to $CLIENT_OUT)"

# give tcpdump a moment to flush if still running
sleep 1

# collect results
echo "===== RESULTS ====="
echo "iperf client output (grep bits_per_second):"
grep -o '"bits_per_second":[^,]*' "$CLIENT_OUT" | head -n 5 || true
echo "------ full iperf client JSON head -----"
head -n 80 "$CLIENT_OUT" || true

echo "dmesg tail for module:"
dmesg | tail -n 80 | grep -i -E 'vnet_shape|vshape' || true

echo "tcpdump summary (first 40 lines):"
if [[ -f "$PCAP" ]]; then
    tcpdump -r "$PCAP" -n -tttt | head -n 40 || true
else
    echo "no pcap found at $PCAP"
fi

echo "link stats (brief):"
run_ns_ignore "$NS1" ip -s link show vshapeA0
run_ns_ignore "$NS2" ip -s link show vshapeB0

echo "Logs saved under $OUTDIR"
echo "When done, you can cleanup: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname (if desired)"

# Evaluate pass/fail based on iperf JSON metrics.
TARGET_BPS=$((RATE_KBPS * 1000))
MIN_BPS=$((TARGET_BPS * (100 - TOLERANCE_PCT) / 100))
MAX_BPS=$((TARGET_BPS * (100 + TOLERANCE_PCT) / 100))

AVG_BPS=""
LOSS_PCT=""
if command -v jq >/dev/null 2>&1; then
  AVG_BPS="$(jq -r '[.intervals[].sum.bits_per_second] | if length > 0 then (add/length) else empty end' "$CLIENT_OUT" 2>/dev/null || true)"
  LOSS_PCT="$(jq -r '.end.sum.lost_percent // empty' "$CLIENT_OUT" 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  AVG_BPS="$(python3 - "$CLIENT_OUT" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    vals = [x.get("sum", {}).get("bits_per_second") for x in d.get("intervals", [])]
    vals = [v for v in vals if isinstance(v, (int, float))]
    print((sum(vals)/len(vals)) if vals else "")
except Exception:
    print("")
PY
)"
  LOSS_PCT="$(python3 - "$CLIENT_OUT" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    v = d.get("end", {}).get("sum", {}).get("lost_percent", "")
    print(v)
except Exception:
    print("")
PY
)"
fi

echo "----- verdict -----"
FAIL=0

if [[ "$RC" -ne 0 ]]; then
  echo "[FAIL] iperf3 client returned rc=$RC"
  FAIL=1
fi

if [[ -z "$AVG_BPS" ]]; then
  echo "[FAIL] could not parse average throughput from $CLIENT_OUT"
  FAIL=1
else
  AVG_KBPS="$(awk "BEGIN { printf \"%.2f\", $AVG_BPS/1000 }")"
  echo "[INFO] average throughput: ${AVG_KBPS} kbps (target ${RATE_KBPS} kbps, allowed ${MIN_BPS}-${MAX_BPS} bps)"
  if ! awk "BEGIN { exit !($AVG_BPS >= $MIN_BPS && $AVG_BPS <= $MAX_BPS) }"; then
    echo "[FAIL] average throughput outside allowed tolerance band"
    FAIL=1
  fi
fi

if [[ -n "$LOSS_PCT" ]]; then
  echo "[INFO] UDP loss: ${LOSS_PCT}% (max ${MAX_LOSS_PCT}%)"
  if ! awk "BEGIN { exit !($LOSS_PCT <= $MAX_LOSS_PCT) }"; then
    echo "[FAIL] UDP loss above threshold"
    FAIL=1
  fi
else
  echo "[WARN] could not parse UDP loss percentage from $CLIENT_OUT"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "[PASS] test_rate_limit_udp checks passed."
  # final exit (trap will run cleanup)
  exit 0
fi

echo "[FAIL] test_rate_limit_udp checks failed."
# final exit (trap will run cleanup)
exit 2

