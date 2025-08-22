#!/usr/bin/env bash
# vshape_pair_test.sh
# Usage:
#   sudo ./vshape_pair_test.sh [--module ./kernel/vshape_mod.ko] [--time 10] [--same-ns] [--cleanup]
#
# - By default the script creates two netns (ns1_vshape, ns2_vshape) and moves vshapeA -> ns1, vshapeB -> ns2.
# - Use --same-ns to keep both ends in the current root namespace (quick testing).
# - --cleanup performs teardown only.
set -euo pipefail

MODULE_PATH="./kernel/vshape_mod.ko"
TEST_TIME=10
CLEANUP=0
SAME_NS=0

NS1="ns1_vshape"
NS2="ns2_vshape"
DEV_A_PREFIX="vshapeA"
DEV_B_PREFIX="vshapeB"

TMPDIR="/tmp"
PCAP="${TMPDIR}/vshape_pcap.pcap"
IPERF_SERVER_LOG="${TMPDIR}/vshape_iperf_server.log"
IPERF_CLIENT_LOG="${TMPDIR}/vshape_iperf_client.log"

die() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }

# parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE_PATH="$2"; shift 2;;
        --time) TEST_TIME="$2"; shift 2;;
        --same-ns) SAME_NS=1; shift;;
        --cleanup) CLEANUP=1; shift;;
        --help) echo "Usage: $0 [--module path] [--time secs] [--same-ns] [--cleanup]"; exit 0;;
        *) warn "Unknown arg $1"; shift;;
    esac
done

if (( EUID != 0 )); then
    die "Run as root"
fi

cleanup() {
    info "Cleanup: stopping background jobs and removing namespaces/module (best-effort)..."
    pkill -f "iperf3 -s" || true
    pkill -f "tcpdump -i" || true
    sleep 0.5

    ip netns del "$NS1" 2>/dev/null || true
    ip netns del "$NS2" 2>/dev/null || true

    # remove any vshape* devices in root (if left)
    for d in $(ip -o link show | awk -F': ' '{print $2}' | grep '^vshape' || true); do
        info "Deleting leftover device $d"
        ip link del "$d" 2>/dev/null || true
    done

    modname="$(basename "${MODULE_PATH}" .ko)"
    if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
        info "Unloading module ${modname}..."
        rmmod "${modname}" || warn "rmmod failed"
    fi

    rm -f "$PCAP" "$IPERF_SERVER_LOG" "$IPERF_CLIENT_LOG"
    info "Cleanup done."
}

if (( CLEANUP )); then
    cleanup
    exit 0
fi

# ensure required tools
for cmd in ip insmod rmmod tcpdump iperf3 ping awk grep sleep; do
    command -v "$cmd" >/dev/null || die "Required tool '$cmd' not found"
done

# load module (best-effort update via sysfs if already loaded)
modname="$(basename "${MODULE_PATH}" .ko)"
info "Loading (insmod) module ${MODULE_PATH} (best-effort)"
if lsmod | awk '{print $1}' | grep -q "^${modname}$"; then
    info "Module ${modname} already loaded; skipping insmod"
else
    if ! insmod "$MODULE_PATH" 2>/tmp/vshape_insmod.err; then
        cat /tmp/vshape_insmod.err >&2 || true
        rm -f /tmp/vshape_insmod.err
        die "insmod failed"
    fi
    rm -f /tmp/vshape_insmod.err
fi

# write parameters to sysfs (best-effort)
for p in param_delay_ms param_jitter_ms param_loss_ppm param_rate_kbps param_passthrough; do
    if [[ -w "/sys/module/${modname}/parameters/${p}" ]]; then
        echo "$(cat /sys/module/${modname}/parameters/${p} 2>/dev/null || echo '')" >/dev/null 2>&1 || true
    fi
done

# wait for devices
info "Waiting for vshapeA* and vshapeB* devices (timeout 10s)..."
DEV_A=""
DEV_B=""
WAIT=10
while (( WAIT-- > 0 )); do
    # pick first matching names
    DEV_A="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeA' || true | head -n1)"
    DEV_B="$(ip -o link show | awk -F': ' '{print $2}' | grep '^vshapeB' || true | head -n1)"
    if [[ -n "$DEV_A" && -n "$DEV_B" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$DEV_A" || -z "$DEV_B" ]]; then
    die "vshape pair not found in root namespace. Check dmesg and module output."
fi

info "Found pair: $DEV_A <-> $DEV_B"

# Prepare namespaces (unless same-ns)
if (( SAME_NS )); then
    info "--same-ns: keeping both ends in the current namespace"
    NS1="root"
    NS2="root"
else
    info "Creating namespaces ${NS1} and ${NS2}..."
    ip netns add "$NS1" 2>/dev/null || true
    ip netns add "$NS2" 2>/dev/null || true
fi

# Move endpoints
if (( SAME_NS )); then
    info "No move needed (both ends remain in root)."
else
    info "Moving $DEV_A -> $NS1 and $DEV_B -> $NS2..."
    ip link set "$DEV_A" netns "$NS1" || die "failed to move $DEV_A to $NS1"
    ip link set "$DEV_B" netns "$NS2" || die "failed to move $DEV_B to $NS2"
fi

# Bring up interfaces and assign simple IPs
if (( SAME_NS )); then
    ip link set dev "$DEV_A" up
    ip addr add 10.42.1.1/24 dev "$DEV_A"
    ip link set dev "$DEV_B" up
    ip addr add 10.42.1.2/24 dev "$DEV_B"
else
    ip netns exec "$NS1" ip link set lo up
    ip netns exec "$NS1" ip link set dev "$DEV_A" up
    ip netns exec "$NS1" ip addr add 10.42.1.1/24 dev "$DEV_A"

    ip netns exec "$NS2" ip link set lo up
    ip netns exec "$NS2" ip link set dev "$DEV_B" up
    ip netns exec "$NS2" ip addr add 10.42.1.2/24 dev "$DEV_B"
fi

# disable offloads to minimize host acceleration effects (best-effort)
if command -v ethtool >/dev/null 2>&1; then
    info "Disabling offloads where possible..."
    if (( SAME_NS )); then
        ethtool -K "$DEV_A" tso off gso off gro off lro off 2>/dev/null || true
        ethtool -K "$DEV_B" tso off gso off gro off lro off 2>/dev/null || true
    else
        ip netns exec "$NS1" ethtool -K "$DEV_A" tso off gso off gro off lro off 2>/dev/null || true
        ip netns exec "$NS2" ethtool -K "$DEV_B" tso off gso off gro off lro off 2>/dev/null || true
    fi
fi

# Start tcpdump on peer side to verify traversal
info "Starting tcpdump on $DEV_B (capture up to 200 pkts or 30s)..."
rm -f "$PCAP"
if (( SAME_NS )); then
    tcpdump -i "$DEV_B" -s 0 -w "$PCAP" not vlan 2>/dev/null & TCPDUMP_PID=$!
else
    ip netns exec "$NS2" tcpdump -i "$DEV_B" -s 0 -w "$PCAP" not vlan 2>/dev/null & TCPDUMP_PID=$!
fi
sleep 0.5
info "tcpdump pid=${TCPDUMP_PID}"

# Start iperf3 server on peer
info "Starting iperf3 server on peer..."
if (( SAME_NS )); then
    iperf3 -s > "$IPERF_SERVER_LOG" 2>&1 & IPERF_SRV_PID=$!
else
    ip netns exec "$NS2" iperf3 -s > "$IPERF_SERVER_LOG" 2>&1 & IPERF_SRV_PID=$!
fi
sleep 1
info "iperf3 server pid=${IPERF_SRV_PID} (logs: ${IPERF_SERVER_LOG})"

# Ping test
info "Ping test (5 packets)..."
if (( SAME_NS )); then
    ping -c5 -i1 10.42.1.2 || true
else
    ip netns exec "$NS1" ping -c5 -i1 10.42.1.2 || true
fi

# iperf3 client test
info "Running iperf3 client for ${TEST_TIME}s..."
if (( SAME_NS )); then
    iperf3 -c 10.42.1.2 -t "$TEST_TIME" -J > "$IPERF_CLIENT_LOG" 2>&1 || true
else
    ip netns exec "$NS1" iperf3 -c 10.42.1.2 -t "$TEST_TIME" -J > "$IPERF_CLIENT_LOG" 2>&1 || true
fi

# parse iperf3 JSON if present
if [[ -s "$IPERF_CLIENT_LOG" ]]; then
    bitrate=$(grep -o '"bits_per_second":[^,]*' "$IPERF_CLIENT_LOG" | head -n1 | cut -d: -f2)
    if [[ -n "$bitrate" ]]; then
        mbps=$(awk "BEGIN{print $bitrate/1000000}")
        info "Measured throughput: ${mbps} Mbps"
    else
        warn "iperf3 output did not contain bits_per_second"
    fi
else
    warn "iperf3 client log missing or empty: ${IPERF_CLIENT_LOG}"
fi

# stop iperf3 server
info "Stopping iperf3 server (pid ${IPERF_SRV_PID})..."
kill "${IPERF_SRV_PID}" 2>/dev/null || true

# stop tcpdump and wait for file
info "Stopping tcpdump (pid ${TCPDUMP_PID})..."
kill "${TCPDUMP_PID}" 2>/dev/null || true
sleep 0.5

# Summaries
info "Kernel dmesg (vnet_shape) tail:"
dmesg | grep -i vnet_shape | tail -n 40 || true

info "tcpdump summary (first 80 lines):"
if [[ -f "$PCAP" ]]; then
    tcpdump -r "$PCAP" -n -tttt | head -n 80 || true
else
    warn "pcap not found: $PCAP"
fi

info "Device stats (brief):"
if (( SAME_NS )); then
    ip -s link show "$DEV_A" || true
    ip -s link show "$DEV_B" || true
else
    ip netns exec "$NS1" ip -s link show "$DEV_A" || true
    ip netns exec "$NS2" ip -s link show "$DEV_B" || true
fi

info "Test finished. To cleanup run: sudo $0 --cleanup"
