#!/usr/bin/env bash
# Robust ICMP jitter test for vshape module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULE_PATH="${REPO_ROOT}/kernel/vshape_mod.ko"
OUTDIR="/tmp/vshape_jitter_test.$(date +%s)"

BASE_DELAY_MS=30
JITTER_MS=20
LOSS_PPM=0
RATE_KBPS=100000
COUNT=20
MIN_SWING_MS=15      # minimum expected (max-min) RTT variation
MAX_LOSS_PCT=2       # acceptable ICMP packet loss

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --delay) BASE_DELAY_MS="$2"; shift 2;;
    --jitter) JITTER_MS="$2"; shift 2;;
    --loss-ppm) LOSS_PPM="$2"; shift 2;;
    --rate) RATE_KBPS="$2"; shift 2;;
    --count) COUNT="$2"; shift 2;;
    --min-swing) MIN_SWING_MS="$2"; shift 2;;
    --max-loss) MAX_LOSS_PCT="$2"; shift 2;;
    --help)
      echo "Usage: $0 [--module path] [--delay 30] [--jitter 20] [--loss-ppm 0] [--rate 100000] [--count 20] [--min-swing 15] [--max-loss 2]"
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

echo "=== vshape JITTER TEST ==="
echo "module: $MODULE_PATH"
echo "params: delay=${BASE_DELAY_MS}ms jitter=${JITTER_MS}ms loss=${LOSS_PPM}ppm rate=${RATE_KBPS}kbps count=${COUNT}"
echo "pass criteria: RTT swing >= ${MIN_SWING_MS} ms, packet loss <= ${MAX_LOSS_PCT}%"

modname="$(basename "$MODULE_PATH" .ko)"
NS1="ns1_vshape"
NS2="ns2_vshape"

cleanup() {
  echo "[CLEANUP] stopping background jobs..."
  pkill -P $$ 2>/dev/null || true
  echo "[CLEANUP] done."
}
trap cleanup EXIT

if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
  echo "[INFO] module $modname already loaded -> trying to rmmod (best-effort)"
  rmmod "$modname" 2>/dev/null || true
fi

echo "[INFO] insmod with param_delay_ms=${BASE_DELAY_MS}, param_jitter_ms=${JITTER_MS}, param_loss_ppm=${LOSS_PPM}, param_rate_kbps=${RATE_KBPS}"
insmod "$MODULE_PATH" \
  param_delay_ms="$BASE_DELAY_MS" \
  param_jitter_ms="$JITTER_MS" \
  param_loss_ppm="$LOSS_PPM" \
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

echo "[INFO] measuring RTT variation using ICMP (${COUNT} packets)"
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
RTT_SERIES="$(awk '
  /time=/ {
    split($0, a, "time=");
    split(a[2], b, " ");
    print b[1];
  }
' "$PING_LOG")"

if [[ -z "$RTT_SERIES" ]]; then
  echo "[FAIL] could not parse RTT samples from ping output"
  FAIL=1
else
  # Ignore the first sample to reduce ARP/warm-up bias when possible.
  RTT_STATS="$(echo "$RTT_SERIES" | awk '
    NR==1 { first=$1; next }
    {
      n++;
      x=$1+0;
      sum+=x;
      sumsq+=x*x;
      if (n==1 || x<min) min=x;
      if (n==1 || x>max) max=x;
    }
    END {
      if (n==0) exit 1;
      avg=sum/n;
      var=(sumsq/n)-(avg*avg);
      if (var < 0) var=0;
      mdev=sqrt(var);
      printf "%.3f %.3f %.3f %.3f %d", min, avg, max, mdev, n;
    }
  ')" || RTT_STATS=""

  if [[ -z "$RTT_STATS" ]]; then
    # Fallback to ping summary line if sample-level parsing failed.
    if [[ -z "$RTT_LINE" ]]; then
      echo "[FAIL] could not compute RTT statistics"
      FAIL=1
    else
      RTT_VALUES="$(echo "$RTT_LINE" | awk -F'=' '{print $2}')"
      RTT_MIN_MS="$(echo "$RTT_VALUES" | awk -F'/' '{gsub(/ /,"",$1); print $1}')"
      RTT_AVG_MS="$(echo "$RTT_VALUES" | awk -F'/' '{gsub(/ /,"",$2); print $2}')"
      RTT_MAX_MS="$(echo "$RTT_VALUES" | awk -F'/' '{gsub(/ /,"",$3); print $3}')"
      RTT_MDEV_MS="$(echo "$RTT_VALUES" | awk -F'/' '{gsub(/ /,"",$4); gsub(/ ms/,"",$4); print $4}')"
      USED_SAMPLES="all"
    fi
  else
    RTT_MIN_MS="$(echo "$RTT_STATS" | awk '{print $1}')"
    RTT_AVG_MS="$(echo "$RTT_STATS" | awk '{print $2}')"
    RTT_MAX_MS="$(echo "$RTT_STATS" | awk '{print $3}')"
    RTT_MDEV_MS="$(echo "$RTT_STATS" | awk '{print $4}')"
    SAMPLE_COUNT_USED="$(echo "$RTT_STATS" | awk '{print $5}')"
    USED_SAMPLES="${SAMPLE_COUNT_USED} (first sample ignored)"
  fi

  RTT_SWING_MS="$(awk "BEGIN { printf \"%.3f\", $RTT_MAX_MS - $RTT_MIN_MS }")"
  EXPECTED_AVG_MS=$((2 * BASE_DELAY_MS))
  echo "[INFO] RTT min/avg/max/mdev = ${RTT_MIN_MS}/${RTT_AVG_MS}/${RTT_MAX_MS}/${RTT_MDEV_MS} ms"
  echo "[INFO] samples used for stats: ${USED_SAMPLES}"
  echo "[INFO] RTT swing = ${RTT_SWING_MS} ms (min expected ${MIN_SWING_MS} ms)"
  echo "[INFO] expected avg RTT near ${EXPECTED_AVG_MS} ms"

  if ! awk "BEGIN { exit !($RTT_SWING_MS >= $MIN_SWING_MS) }"; then
    echo "[FAIL] RTT variation is too small; jitter effect not clearly visible"
    FAIL=1
  fi
fi

LOSS_LINE="$(grep -m 1 'packet loss' "$PING_LOG" || true)"
if [[ -n "$LOSS_LINE" ]]; then
  echo "[INFO] $LOSS_LINE"
  LOSS_PCT="$(echo "$LOSS_LINE" | awk -F',' '{print $3}' | awk '{gsub(/%/,"",$1); print $1}')"
  if [[ -n "$LOSS_PCT" ]]; then
    if ! awk "BEGIN { exit !($LOSS_PCT <= $MAX_LOSS_PCT) }"; then
      echo "[FAIL] packet loss above threshold"
      FAIL=1
    fi
  fi
fi

echo "Logs saved under $OUTDIR"
echo "When done, you can cleanup: sudo ip netns del $NS1; sudo ip netns del $NS2; sudo rmmod $modname (if desired)"

if [[ "$FAIL" -eq 0 ]]; then
  echo "[PASS] jitter test checks passed."
  exit 0
fi

echo "[FAIL] jitter test checks failed."
exit 2
