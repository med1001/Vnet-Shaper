#!/usr/bin/env bash
# vshape_full_test.sh
# Comprehensive test-suite for vshape_mod kernel module.
# Usage: sudo ./vshape_full_test.sh [--module ./kernel/vshape_mod.ko] [--time 10] [--same-ns] [--keep-files]
set -euo pipefail

MODULE_PATH="./kernel/vshape_mod.ko"
TEST_TIME=8
SAME_NS=0
KEEP_FILES=0

NS1="ns1_vshape"
NS2="ns2_vshape"
TMPDIR="/tmp/vshape_test.$$"
PCAP="${TMPDIR}/vshape_pcap.pcap"
IPERF_SERVER_LOG="${TMPDIR}/vshape_iperf_server.log"
IPERF_CLIENT_LOG="${TMPDIR}/vshape_iperf_client.log"
SUMMARY="${TMPDIR}/summary.txt"

die(){ echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE_PATH="$2"; shift 2;;
    --time) TEST_TIME="$2"; shift 2;;
    --same-ns) SAME_NS=1; shift;;
    --keep-files) KEEP_FILES=1; shift;;
    --help) echo "Usage: $0 [--module path] [--time secs] [--same-ns] [--keep-files]"; exit 0;;
    *) warn "Unknown arg $1"; shift;;
  esac
done

if (( EUID != 0 )); then die "Run as root"; fi
mkdir -p "$TMPDIR"

cleanup_all() {
  info "cleanup: stopping background jobs and removing namespaces (best-effort)"
  pkill -f "iperf3 -s" || true
  pkill -f "tcpdump -i" || true
  sleep 0.4
  ip netns del "$NS1" 2>/dev/null || true
  ip netns del "$NS2" 2>/dev/null || true

  # remove any vshape* in root (if left)
  for d in $(ip -o link show | awk -F': ' '{print $2}' | grep '^vshape' || true); do
    info "deleting leftover $d"
    ip link del "$d" 2>/dev/null || true
  done

  modname="$(basename "${MODULE_PATH}" .ko)"
  if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
    info "unloading module ${modname} (best-effort)"
    rmmod "${modname}" || true
  fi
  if (( KEEP_FILES == 0 )); then
    rm -rf "$TMPDIR"
  else
    info "kept test files in $TMPDIR"
  fi
}
trap cleanup_all EXIT

# ensure required tools
for cmd in ip insmod rmmod tcpdump iperf3 ping awk grep sleep head tail; do
  command -v "$cmd" >/dev/null || die "Required tool '$cmd' not found"
done

# load module (best-effort)
modname="$(basename "${MODULE_PATH}" .ko)"
info "Loading (insmod) module ${MODULE_PATH} (best-effort)"
if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
  info "Module ${modname} already loaded; skipping insmod"
else
  if ! insmod "$MODULE_PATH" 2>/tmp/vshape_insmod.err; then
    cat /tmp/vshape_insmod.err >&2 || true; rm -f /tmp/vshape_insmod.err
    die "insmod failed"
  fi
  rm -f /tmp/vshape_insmod.err
fi

# helper to set module param
set_param() {
  local p=$1; local v=$2
  local path="/sys/module/${modname}/parameters/${p}"
  if [[ -w "$path" ]]; then
    echo "$v" > "$path" || warn "failed to write $v to $path"
  else
    warn "param $p not writable or not present"
  fi
}

# wait for devices
info "Waiting for vshapeA* and vshapeB* devices (timeout 12s)..."
DEV_A=""; DEV_B=""; WAIT=12
while (( WAIT-- > 0 )); do
  DEV_A="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeA' || true | head -n1)"
  DEV_B="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeB' || true | head -n1)"
  if [[ -n "$DEV_A" && -n "$DEV_B" ]]; then break; fi
  sleep 1
done
if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then die "vshape pair not found. Check dmesg"; fi
info "Found pair: $DEV_A <-> $DEV_B"

# create namespaces (unless same-ns)
if (( SAME_NS )); then
  info "--same-ns: keeping both ends in root namespace"
  NS1="root"; NS2="root"
else
  info "Creating namespaces $NS1 and $NS2"
  ip netns add "$NS1" 2>/dev/null || true
  ip netns add "$NS2" 2>/dev/null || true
fi

# Move endpoints if needed
if (( SAME_NS )); then
  info "Both ends remain in root"
else
  info "Moving $DEV_A -> $NS1 and $DEV_B -> $NS2"
  ip link set "$DEV_A" netns "$NS1" || die "failed to move $DEV_A to $NS1"
  ip link set "$DEV_B" netns "$NS2" || die "failed to move $DEV_B to $NS2"
fi

# bring up and assign IPs
if (( SAME_NS )); then
  ip link set dev "$DEV_A" up
  ip addr add 10.42.1.1/24 dev "$DEV_A" || true
  ip link set dev "$DEV_B" up
  ip addr add 10.42.1.2/24 dev "$DEV_B" || true
else
  ip netns exec "$NS1" ip link set lo up
  ip netns exec "$NS1" ip link set dev "$DEV_A" up
  ip netns exec "$NS1" ip addr add 10.42.1.1/24 dev "$DEV_A" || true

  ip netns exec "$NS2" ip link set lo up
  ip netns exec "$NS2" ip link set dev "$DEV_B" up
  ip netns exec "$NS2" ip addr add 10.42.1.2/24 dev "$DEV_B" || true
fi

# disable offloads best-effort
if command -v ethtool >/dev/null 2>&1; then
  info "Disabling offloads (best-effort)"
  if (( SAME_NS )); then
    ethtool -K "$DEV_A" tso off gso off gro off lro off 2>/dev/null || true
    ethtool -K "$DEV_B" tso off gso off gro off lro off 2>/dev/null || true
  else
    ip netns exec "$NS1" ethtool -K "$DEV_A" tso off gso off gro off lro off 2>/dev/null || true
    ip netns exec "$NS2" ethtool -K "$DEV_B" tso off gso off gro off lro off 2>/dev/null || true
  fi
fi

# helper to run commands in ns1 or ns2
run1(){ if (( SAME_NS )); then bash -c "$*"; else ip netns exec "$NS1" bash -c "$*"; fi }
run2(){ if (( SAME_NS )); then bash -c "$*"; else ip netns exec "$NS2" bash -c "$*"; fi }

# function: capture netdev stats
get_link_stats() {
  local ns=$1 dev=$2 out=$3
  if [[ "$ns" == "root" ]]; then ip -s link show "$dev" > "$out" 2>/dev/null || true
  else ip netns exec "$ns" ip -s link show "$dev" > "$out" 2>/dev/null || true; fi
}

# helper: run iperf tcp
iperf_tcp() {
  local dur=$1
  run2 "iperf3 -s > ${IPERF_SERVER_LOG} 2>&1 & echo \$! > ${TMPDIR}/iperf_srv.pid"
  sleep 0.5
  run1 "iperf3 -c 10.42.1.2 -t ${dur} -J > ${IPERF_CLIENT_LOG} 2>&1 || true"
  srvpid=$(cat ${TMPDIR}/iperf_srv.pid 2>/dev/null || echo "")
  [[ -n "$srvpid" ]] && run2 "kill $srvpid" || true
  sleep 0.2
  # parse
  if [[ -s "${IPERF_CLIENT_LOG}" ]]; then
    bps=$(grep -o '"bits_per_second":[^,]*' "${IPERF_CLIENT_LOG}" | head -n1 | cut -d: -f2 || true)
    echo "${bps:-0}"
  else echo "0"; fi
}

# helper: run iperf udp (offered rate)
iperf_udp() {
  local dur=$1 offered=$2
  run2 "iperf3 -s > ${IPERF_SERVER_LOG} 2>&1 & echo \$! > ${TMPDIR}/iperf_srv.pid"
  sleep 0.5
  run1 "iperf3 -c 10.42.1.2 -u -b ${offered} -t ${dur} -J > ${IPERF_CLIENT_LOG} 2>&1 || true"
  srvpid=$(cat ${TMPDIR}/iperf_srv.pid 2>/dev/null || echo "")
  [[ -n "$srvpid" ]] && run2 "kill $srvpid" || true
  sleep 0.2
  if [[ -s "${IPERF_CLIENT_LOG}" ]]; then
    bps=$(grep -o '"bits_per_second":[^,]*' "${IPERF_CLIENT_LOG}" | head -n1 | cut -d: -f2 || true)
    echo "${bps:-0}"
  else echo "0"; fi
}

# baseline check: default params
echo "====== vshape full test run ======" | tee "$SUMMARY"
echo "module: $MODULE_PATH" | tee -a "$SUMMARY"
echo "pair: $DEV_A <-> $DEV_B" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# start tcpdump on peer side
info "Starting tcpdump on ${DEV_B} (30s capture) -> ${PCAP}"
rm -f "$PCAP"
if (( SAME_NS )); then
  tcpdump -i "$DEV_B" -s 0 -w "$PCAP" not vlan 2>/dev/null & TCPDUMP_PID=$!
else
  ip netns exec "$NS2" tcpdump -i "$DEV_B" -s 0 -w "$PCAP" not vlan 2>/dev/null & TCPDUMP_PID=$!
fi
sleep 0.5

# Save initial link stats
get_link_stats "$NS1" "$DEV_A" "${TMPDIR}/link_before_A.txt"
get_link_stats "$NS2" "$DEV_B" "${TMPDIR}/link_before_B.txt"

# Test 1 - baseline ping + TCP iperf
info "TEST1: baseline ping + TCP iperf (delay/jitter/rate default)"
echo "TEST1: baseline ping + TCP" | tee -a "$SUMMARY"
if (( SAME_NS )); then
  ping -c5 -i1 10.42.1.2 > "${TMPDIR}/ping_baseline.txt" 2>&1 || true
else
  ip netns exec "$NS1" ping -c5 -i1 10.42.1.2 > "${TMPDIR}/ping_baseline.txt" 2>&1 || true
fi
awk '/rtt/ {print;}' "${TMPDIR}/ping_baseline.txt" | tee -a "$SUMMARY"
tcp_bps=$(iperf_tcp "$TEST_TIME")
if [[ "$tcp_bps" =~ ^[0-9]+$ && "$tcp_bps" -gt 0 ]]; then
  tcp_mbps=$(awk "BEGIN{printf \"%.3f\", ${tcp_bps}/1000000}")
else tcp_mbps="0"; fi
echo "TCP throughput (baseline): ${tcp_mbps} Mbps" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# Test 2 - passthrough on/off (no shaping)
echo "TEST2: passthrough ON then OFF" | tee -a "$SUMMARY"
set_param param_passthrough 1
sleep 0.2
if (( SAME_NS )); then
  ping -c3 -i0.5 10.42.1.2 > "${TMPDIR}/ping_pt_on.txt" 2>&1 || true
else
  ip netns exec "$NS1" ping -c3 -i0.5 10.42.1.2 > "${TMPDIR}/ping_pt_on.txt" 2>&1 || true
fi
awk '/rtt/ {print "PT-ON: "$0}' "${TMPDIR}/ping_pt_on.txt" | tee -a "$SUMMARY"
# quick throughput (short)
tcp_bps_pt_on=$(iperf_tcp 3)
if [[ "$tcp_bps_pt_on" =~ ^[0-9]+$ && "$tcp_bps_pt_on" -gt 0 ]]; then
  echo "PT-ON TCP Mbps: $(awk "BEGIN{printf \"%.3f\", ${tcp_bps_pt_on}/1000000}")" | tee -a "$SUMMARY"
else echo "PT-ON TCP Mbps: 0" | tee -a "$SUMMARY"; fi
set_param param_passthrough 0
sleep 0.2
if (( SAME_NS )); then
  ping -c3 -i0.5 10.42.1.2 > "${TMPDIR}/ping_pt_off.txt" 2>&1 || true
else
  ip netns exec "$NS1" ping -c3 -i0.5 10.42.1.2 > "${TMPDIR}/ping_pt_off.txt" 2>&1 || true
fi
awk '/rtt/ {print "PT-OFF: "$0}' "${TMPDIR}/ping_pt_off.txt" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# Test 3 - token-bucket / rate limiting (UDP)
echo "TEST3: rate limiting UDP (2 Mbps) with delay=0/jitter=0" | tee -a "$SUMMARY"
set_param param_delay_ms 0
set_param param_jitter_ms 0
set_param param_rate_kbps 2000   # 2 Mbps
set_param param_burst_ms 100
sleep 0.2
udp_bps=$(iperf_udp "$TEST_TIME" "50M")
if [[ "$udp_bps" =~ ^[0-9]+$ && "$udp_bps" -gt 0 ]]; then
  udp_mbps=$(awk "BEGIN{printf \"%.3f\", ${udp_bps}/1000000}")
else udp_mbps="0"; fi
echo "UDP measured (offer 50M, shaped to ~2M): ${udp_mbps} Mbps" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# Test 4 - packet loss
echo "TEST4: loss injection (10% ~ 100000 ppm)" | tee -a "$SUMMARY"
set_param param_loss_ppm 100000   # 10% loss
sleep 0.2
if (( SAME_NS )); then
  ping -c50 -i0.1 10.42.1.2 > "${TMPDIR}/ping_loss.txt" 2>&1 || true
else
  ip netns exec "$NS1" ping -c50 -i0.1 10.42.1.2 > "${TMPDIR}/ping_loss.txt" 2>&1 || true
fi
grep -E 'packets transmitted|packet loss|loss' "${TMPDIR}/ping_loss.txt" | tee -a "$SUMMARY"
set_param param_loss_ppm 0
echo "" | tee -a "$SUMMARY"

# Test 5 - delay & jitter effect
echo "TEST5: delay=50ms jitter=30ms" | tee -a "$SUMMARY"
set_param param_delay_ms 50
set_param param_jitter_ms 30
set_param param_rate_kbps 0   # unlimited for latency test
sleep 0.2
if (( SAME_NS )); then
  ping -c10 -i0.2 10.42.1.2 > "${TMPDIR}/ping_delay.txt" 2>&1 || true
else
  ip netns exec "$NS1" ping -c10 -i0.2 10.42.1.2 > "${TMPDIR}/ping_delay.txt" 2>&1 || true
fi
awk '/rtt/ {print;}' "${TMPDIR}/ping_delay.txt" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

# Test 6 - queue saturation (small max queue)
echo "TEST6: queue saturation (maxq=8) - run short UDP flood" | tee -a "$SUMMARY"
set_param param_max_queue 8
# restore some delay to hold packets in queue
set_param param_delay_ms 200
set_param param_rate_kbps 0
sleep 0.2
# capture link stats before
get_link_stats "$NS1" "$DEV_A" "${TMPDIR}/link_before_qtest_A.txt"
get_link_stats "$NS2" "$DEV_B" "${TMPDIR}/link_before_qtest_B.txt"
# run brief UDP flood (try to overflow queue). Use iperf from ns1.
udp_bps_q=$(iperf_udp 6 "100M")
sleep 0.5
# capture link stats after
get_link_stats "$NS1" "$DEV_A" "${TMPDIR}/link_after_qtest_A.txt"
get_link_stats "$NS2" "$DEV_B" "${TMPDIR}/link_after_qtest_B.txt"
# check dmesg for queue-full/warn
dmesg | tail -n 200 | grep -i -E 'queue full|dropping|queue full|queue overflow|queue full' > "${TMPDIR}/dmesg_qtest.txt" || true
echo "Queue saturation dmesg grep:" | tee -a "$SUMMARY"
cat "${TMPDIR}/dmesg_qtest.txt" | tee -a "$SUMMARY"
# restore defaults
set_param param_max_queue 100000
set_param param_delay_ms 50
sleep 0.2
echo "" | tee -a "$SUMMARY"

# Test 7 - burst & capacity (rate + burst)
echo "TEST7: rate 1 Mbps with small burst window (burst_ms=10)" | tee -a "$SUMMARY"
set_param param_rate_kbps 1000
set_param param_burst_ms 10
set_param param_delay_ms 0
set_param param_jitter_ms 0
sleep 0.2
udp_bps_burst=$(iperf_udp 8 "50M")
if [[ "$udp_bps_burst" =~ ^[0-9]+$ && "$udp_bps_burst" -gt 0 ]]; then
  echo "Measured UDP bps: $(awk "BEGIN{printf \"%.3f\", ${udp_bps_burst}/1000000}") Mbps" | tee -a "$SUMMARY"
else
  echo "Measured UDP bps: 0" | tee -a "$SUMMARY"
fi
# reset
set_param param_rate_kbps 0
set_param param_burst_ms 100
echo "" | tee -a "$SUMMARY"

# Gather final info
info "Stopping tcpdump (pid ${TCPDUMP_PID})"
kill "${TCPDUMP_PID}" 2>/dev/null || true
sleep 0.3

echo "===== final dmesg lines (module) =====" >> "$SUMMARY"
dmesg | grep -i vnet_shape | tail -n 80 >> "$SUMMARY" || true

echo "===== tcpdump sample (first 80 lines) =====" >> "$SUMMARY"
if [[ -f "$PCAP" ]]; then
  tcpdump -r "$PCAP" -n -tttt | head -n 80 >> "$SUMMARY" 2>/dev/null || true
else
  echo "pcap missing" >> "$SUMMARY"
fi

echo "===== link stats before/after tests =====" >> "$SUMMARY"
echo "A before:" >> "$SUMMARY"; cat "${TMPDIR}/link_before_A.txt" >> "$SUMMARY" || true
echo "A after:"  >> "$SUMMARY"; cat "${TMPDIR}/link_after_qtest_A.txt" >> "$SUMMARY" || true
echo "B before:" >> "$SUMMARY"; cat "${TMPDIR}/link_before_B.txt" >> "$SUMMARY" || true
echo "B after:"  >> "$SUMMARY"; cat "${TMPDIR}/link_after_qtest_B.txt" >> "$SUMMARY" || true

# Print a short human summary to stdout (copy-pasteable)
echo "" | tee -a "$SUMMARY"
echo "SUMMARY (short):" | tee -a "$SUMMARY"
echo "- Baseline TCP (Mbps): ${tcp_mbps}" | tee -a "$SUMMARY"
echo "- Passthrough ON TCP (Mbps): $(awk "BEGIN{printf \"%.3f\", ${tcp_bps_pt_on:-0}/1000000}")" | tee -a "$SUMMARY"
echo "- UDP (2Mbps shaped) measured (Mbps): ${udp_mbps}" | tee -a "$SUMMARY"
echo "- Loss test: see ping output in ${TMPDIR}/ping_loss.txt" | tee -a "$SUMMARY"
echo "- Delay/jitter test: see ${TMPDIR}/ping_delay.txt" | tee -a "$SUMMARY"
echo "- Queue saturation dmesg lines (if any):" | tee -a "$SUMMARY"
cat "${TMPDIR}/dmesg_qtest.txt" | tee -a "$SUMMARY" || true
echo "" | tee -a "$SUMMARY"

info "Full summary saved to: $SUMMARY"
info "If you want me to analyze results, copy-paste the contents of $SUMMARY here."

# keep files if requested
if (( KEEP_FILES == 1 )); then
  info "Kept $TMPDIR for inspection"
else
  info "Temporary files are left until script exit; they will be removed on exit (or set --keep-files to keep)"
fi

# end (EXIT trap will cleanup unless KEEP_FILES)
