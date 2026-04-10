#!/usr/bin/env bash
# vshape_test3_safe.sh
# Safe, minimal automated test for TEST-3 (rate limiting UDP)
# - loads module, configures vshape pair, runs iperf3 UDP (optional tcpdump)
#
# Usage: sudo ./tests/test_rate_limit_udp.sh [options]
#   --module PATH   --bw 5M  --rate 2000  --time 8
#   --no-netns      keep vshapeA/B in root namespace (avoids flaky ip netns exec in some VMs)
#   --no-tcpdump    skip capture (tcpdump + vbox can freeze the guest)
#   --quick         same as --no-netns --no-tcpdump
#
# Stuck on RTNL: IP_TIMEOUT=120; try stopping NetworkManager; ip netns del ns1_vshape ns2_vshape

set -euo pipefail

MODULE_PATH="./kernel/vshape_mod.ko"
OUTDIR="/tmp/vshape_test3_safe.$(date +%s)"
CLIENT_BW="5M"
RATE_KBPS=2000
DELAY_MS=0
JITTER_MS=0
DURATION=8
USE_NETNS=1
NO_TCPDUMP_OPT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --bw) CLIENT_BW="$2"; shift 2;;
    --rate) RATE_KBPS="$2"; shift 2;;
    --time) DURATION="$2"; shift 2;;
    --no-netns) USE_NETNS=0; shift;;
    --no-tcpdump) NO_TCPDUMP_OPT=1; shift;;
    --quick) USE_NETNS=0; NO_TCPDUMP_OPT=1; shift;;
    --help)
      echo "Usage: $0 [--module path] [--bw 5M] [--rate 2000] [--time 8] [--no-netns] [--no-tcpdump] [--quick]"
      exit 0
      ;;
    *) echo "Unknown $1"; shift;;
  esac
done

if (( EUID != 0 )); then
  echo "Run as root"; exit 1
fi

if ! command -v iperf3 >/dev/null 2>&1; then
  echo "[ERROR] iperf3 is not installed — this test needs it for UDP throughput."
  echo "Install (Debian/Ubuntu): sudo apt install iperf3"
  exit 1
fi

SKIP_TCPDUMP=
if [[ "$NO_TCPDUMP_OPT" -eq 1 ]]; then
  echo "[INFO] skipping tcpdump (--no-tcpdump / --quick)"
  SKIP_TCPDUMP=1
elif ! command -v tcpdump >/dev/null 2>&1; then
  echo "[WARN] tcpdump not found — PCAP will be skipped. Install: sudo apt install tcpdump"
  SKIP_TCPDUMP=1
fi

mkdir -p "$OUTDIR"
echo "outdir=$OUTDIR"
LOG="$OUTDIR/run.log"
if command -v stdbuf >/dev/null 2>&1; then
  exec > >(stdbuf -oL tee -a "$LOG") 2>&1
else
  exec > >(tee -a "$LOG") 2>&1
fi

IP_TIMEOUT="${IP_TIMEOUT:-45}"
# iperf runs longer than a single ip(8) call — do not reuse IP_TIMEOUT for the client
IPERF_WAIT=$((DURATION + 45))

step_tty() {
  if [[ -w /dev/tty ]]; then
    echo "$@" > /dev/tty
  fi
}

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

# Configure / stats: netns or root namespace
run_cfg() {
  local ns="$1"
  shift
  if [[ "$USE_NETNS" -eq 1 ]]; then
    run_ns "$ns" "$@"
    return
  fi
  step_tty "[RUN] (root) $*"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${IP_TIMEOUT}" "$@"; then
      echo "[ERROR] command failed: $*"
      exit 1
    fi
  else
    "$@" || exit 1
  fi
}

run_cfg_ignore() {
  local ns="$1"
  shift
  if [[ "$USE_NETNS" -eq 1 ]]; then
    run_ns_ignore "$ns" "$@"
    return
  fi
  step_tty "[RUN] (root) $* (non-fatal)"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${IP_TIMEOUT}" "$@" 2>/dev/null || true
  else
    "$@" 2>/dev/null || true
  fi
}

echo "=== vshape TEST3 SAFE ==="
echo "module: $MODULE_PATH"
echo "mode: netns=$USE_NETNS tcpdump=$([[ -z "${SKIP_TCPDUMP:-}" ]] && echo on || echo off)"
echo "requested client BW: $CLIENT_BW, module rate: ${RATE_KBPS} kbps, duration: ${DURATION}s"

modname="$(basename "$MODULE_PATH" .ko)"

cleanup() {
    echo "[CLEANUP] killing bg jobs..."
    pkill -P $$ 2>/dev/null || true
    sleep 0.3
    pkill -f "iperf3 -s" 2>/dev/null || true
    pkill -f "tcpdump -i" 2>/dev/null || true
    sleep 0.2
    echo "[CLEANUP] done."
}
trap cleanup EXIT

if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
    echo "[INFO] module $modname already loaded -> trying to rmmod (best-effort)"
    if ! rmmod "$modname" 2>/dev/null; then
        echo "[WARN] could not rmmod $modname; continuing (may have stale state)"
    else
        echo "[INFO] rmmod succeeded"
    fi
fi

echo "[INFO] inserting module with params rate=${RATE_KBPS}kbps delay=${DELAY_MS}ms jitter=${JITTER_MS}ms"
if ! insmod "$MODULE_PATH" param_rate_kbps="$RATE_KBPS" param_delay_ms="$DELAY_MS" param_jitter_ms="$JITTER_MS"; then
    echo "[ERROR] insmod failed"; exit 1
fi

sleep 0.5

WAIT=8
DEV_A=""
DEV_B=""
while (( WAIT-- > 0 )); do
    DEV_A="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeA' || true | head -n1)"
    DEV_B="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeB' || true | head -n1)"
    if [[ -n "$DEV_A" && -n "$DEV_B" ]]; then
        echo "[INFO] found pair in root ns: $DEV_A <-> $DEV_B"
        ROOT_MODE=1
        break
    fi
    sleep 1
done

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

if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then
    echo "[ERROR] cannot find vshape pair (vshapeA* and vshapeB*). Check dmesg. Exiting."
    dmesg | tail -n 40 | sed -n '1,200p'
    exit 1
fi

NS1="ns1_vshape"
NS2="ns2_vshape"

if [[ "${ROOT_MODE:-0}" -eq 1 ]]; then
    if [[ "$USE_NETNS" -eq 1 ]]; then
        echo "[INFO] creating netns $NS1 $NS2 (if missing) and moving devices"
        ip netns add "$NS1" 2>/dev/null || true
        ip netns add "$NS2" 2>/dev/null || true
        echo "[INFO] moving $DEV_A -> $NS1"
        ip link set "$DEV_A" netns "$NS1"
        echo "[INFO] moving $DEV_B -> $NS2"
        ip link set "$DEV_B" netns "$NS2"
    else
        echo "[INFO] keeping vshape pair in root namespace (--no-netns / --quick)"
    fi
else
    if [[ "$USE_NETNS" -eq 0 ]]; then
        echo "[ERROR] interfaces are inside netns but --no-netns was set. Run: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname; then reload module and retry."
        exit 1
    fi
    echo "[INFO] using existing netns layout"
fi

sleep 0.2

echo "[INFO] configuring interfaces and IPs"
run_cfg "$NS1" ip link set lo up
run_cfg_ignore "$NS1" ip link set dev vshapeA0 up
run_cfg "$NS1" ip addr replace 10.42.1.1/24 dev vshapeA0

run_cfg "$NS2" ip link set lo up
run_cfg_ignore "$NS2" ip link set dev vshapeB0 up
run_cfg "$NS2" ip addr replace 10.42.1.2/24 dev vshapeB0

if command -v ethtool >/dev/null 2>&1; then
    run_cfg_ignore "$NS1" ethtool -K vshapeA0 tso off gso off gro off lro off
    run_cfg_ignore "$NS2" ethtool -K vshapeB0 tso off gso off gro off lro off
fi

PCAP="$OUTDIR/test3.pcap"
TCPDUMP_LOG="$OUTDIR/tcpdump.err"
if [[ -n "$SKIP_TCPDUMP" ]]; then
    echo "[INFO] no tcpdump for this run"
    TCPDUMP_PID=""
else
    echo "[INFO] starting tcpdump (snaplen 128; lower load than -s 0)"
    TD_SEC=$((DURATION + 8))
    if [[ "$USE_NETNS" -eq 1 ]]; then
        if command -v timeout >/dev/null 2>&1; then
            ip netns exec "$NS2" timeout "$TD_SEC" tcpdump -i vshapeB0 -s 128 -w "$PCAP" -U not vlan >"$TCPDUMP_LOG" 2>&1 &
        else
            ip netns exec "$NS2" tcpdump -i vshapeB0 -s 128 -w "$PCAP" -U not vlan >"$TCPDUMP_LOG" 2>&1 &
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            timeout "$TD_SEC" tcpdump -i vshapeB0 -s 128 -w "$PCAP" -U not vlan >"$TCPDUMP_LOG" 2>&1 &
        else
            tcpdump -i vshapeB0 -s 128 -w "$PCAP" -U not vlan >"$TCPDUMP_LOG" 2>&1 &
        fi
    fi
    TCPDUMP_PID=$!
    echo "[INFO] tcpdump pid=$TCPDUMP_PID"
    sleep 0.5
    echo "[STEP] tcpdump started; continuing to iperf3"
fi

IPERF_SERVER_LOG="$OUTDIR/iperf_server.log"
echo "[INFO] starting iperf3 server (bind 10.42.1.2)"
if [[ "$USE_NETNS" -eq 1 ]]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout $((DURATION + 25)) ip netns exec "$NS2" iperf3 -s -1 -B 10.42.1.2 >"$IPERF_SERVER_LOG" 2>&1 &
    else
        ip netns exec "$NS2" iperf3 -s -1 -B 10.42.1.2 >"$IPERF_SERVER_LOG" 2>&1 &
    fi
else
    if command -v timeout >/dev/null 2>&1; then
        timeout $((DURATION + 25)) iperf3 -s -1 -B 10.42.1.2 >"$IPERF_SERVER_LOG" 2>&1 &
    else
        iperf3 -s -1 -B 10.42.1.2 >"$IPERF_SERVER_LOG" 2>&1 &
    fi
fi
IPERF_SERVER_PID=$!
sleep 0.6
if ! kill -0 "$IPERF_SERVER_PID" 2>/dev/null; then
    echo "[ERROR] iperf3 server failed to start"
    head -n 80 "$IPERF_SERVER_LOG" || true
    exit 1
fi
echo "[INFO] iperf3 server pid=$IPERF_SERVER_PID"

CLIENT_OUT="$OUTDIR/iperf_client.json"
echo "[INFO] running iperf3 client UDP -> 10.42.1.2, bind 10.42.1.1, bw=$CLIENT_BW, duration=${DURATION}s"
set +e
step_tty "[RUN] iperf3 client (${IPERF_WAIT}s max)"
if [[ "$USE_NETNS" -eq 1 ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "${IPERF_WAIT}" ip netns exec "$NS1" iperf3 -c 10.42.1.2 -B 10.42.1.1 -u -b "$CLIENT_BW" -t "$DURATION" -J > "$CLIENT_OUT" 2>&1
  else
    ip netns exec "$NS1" iperf3 -c 10.42.1.2 -B 10.42.1.1 -u -b "$CLIENT_BW" -t "$DURATION" -J > "$CLIENT_OUT" 2>&1
  fi
else
  if command -v timeout >/dev/null 2>&1; then
    timeout "${IPERF_WAIT}" iperf3 -c 10.42.1.2 -B 10.42.1.1 -u -b "$CLIENT_BW" -t "$DURATION" -J > "$CLIENT_OUT" 2>&1
  else
    iperf3 -c 10.42.1.2 -B 10.42.1.1 -u -b "$CLIENT_BW" -t "$DURATION" -J > "$CLIENT_OUT" 2>&1
  fi
fi
RC=$?
set -e
echo "[INFO] iperf3 client exited rc=$RC (saved to $CLIENT_OUT)"

sleep 1

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
run_cfg_ignore "$NS1" ip -s link show vshapeA0
run_cfg_ignore "$NS2" ip -s link show vshapeB0

echo "Logs saved under $OUTDIR"
if [[ "$USE_NETNS" -eq 1 ]]; then
  echo "Cleanup: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname"
else
  echo "Cleanup: sudo ip link set vshapeA0 down; sudo ip link set vshapeB0 down; sudo rmmod $modname"
fi

exit 0
