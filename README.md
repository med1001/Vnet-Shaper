# vnet-shape: Virtual NIC pair with Latency, Jitter, Loss & Rate-Limit Shaping

## Overview

**vnet-shape** is a Linux kernel module that registers **two** virtual Ethernet interfaces (**`vshapeA*`** and **`vshapeB*`**) wired together in software. Traffic sent on one interface is optionally delayed, jittered, dropped, and rate-limited before being delivered to the peer—similar to a **veth pair**, with **emulated network conditions** for education and demos. No physical hardware is involved.

For a deeper walkthrough of components and data flow, see **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Features

- **Paired virtual interfaces** using the Linux `net_device` API (`vshapeA0` / `vshapeB0` after load).
- Configurable **latency** with **jitter** via high-resolution timers (`hrtimer`).
- **Packet loss** emulation using kernel pseudo-random draws (PPM).
- **Bandwidth limiting** via a **token bucket** (refill at millisecond granularity).
- **User-space configuration** via **Generic Netlink** and the `vshape_ctl` tool.
- **Safe for lab use**: all logic is in RAM; no NIC programming.

---

## Build

Install **Linux kernel headers** for your running kernel (and the usual build tools). On many distributions:

```bash
# example (package names vary)
sudo apt install build-essential linux-headers-$(uname -r)
```

Install **libnl** development files for **`vshape_ctl`**. On Debian/Ubuntu, Generic Netlink headers and `pkg-config` come from:

```bash
sudo apt install libnl-genl-3-dev pkg-config
```

(`libnl-genl-3-dev` pulls in the core libnl headers.) The `userspace/Makefile` uses `pkg-config libnl-genl-3.0` when available, with a fallback include path.

From the **repository root**:

```bash
make
```

This builds:

| Output | Location |
|--------|----------|
| Kernel module **`vshape_mod.ko`** | `kernel/vshape_mod.ko` |
| CLI **`vshape_ctl`** | `userspace/vshape_ctl` |

---

## Installation and usage

### 1. Load the module

```bash
sudo insmod kernel/vshape_mod.ko
```

If you built from another working directory, use the path to **`vshape_mod.ko`** produced by your build.

### 2. Verify the pair

```bash
ip link show | grep -E 'vshapeA|vshapeB'
```

You should see interfaces such as **`vshapeA0`** and **`vshapeB0`**.

### 3. Optional: module parameters at load time

```bash
sudo rmmod vshape_mod   # if reloading
sudo insmod kernel/vshape_mod.ko \
  param_delay_ms=100 \
  param_jitter_ms=10 \
  param_loss_ppm=1000 \
  param_rate_kbps=10000 \
  param_burst_ms=100
```

| Parameter | Description |
|-----------|-------------|
| `param_delay_ms` | Base latency (ms). |
| `param_jitter_ms` | Jitter range ± (ms). |
| `param_loss_ppm` | Loss probability, parts per million (0–1,000,000). |
| `param_rate_kbps` | Rate limit in **kilobits/s** (`0` = unlimited). |
| `param_burst_ms` | Token bucket size in **ms** of sustained rate (default 100). |
| `param_passthrough` | `1` = bypass shaping (still applies loss logic as in code). |
| `param_max_queue` | Max queued packets per end (safety cap). |

Current values are visible under `/sys/module/vshape_mod/parameters/` when the module is loaded.

### 4. Bring interfaces up and assign addresses

The devices only forward traffic when they are **UP** and you have a sensible topology (same machine: namespaces or bridge; routing as usual). Minimal **same-namespace** example:

```bash
sudo ip link set vshapeA0 up
sudo ip link set vshapeB0 up
sudo ip addr add 10.200.1.1/24 dev vshapeA0
sudo ip addr add 10.200.1.2/24 dev vshapeB0
ping -I vshapeA0 10.200.1.2
```

For **network namespaces**, see `tests/test_rate_limit_udp.sh`, which moves **`vshapeA0` / `vshapeB0`** into two namespaces and assigns **`10.42.1.0/24`**.

### 5. Runtime configuration (Generic Netlink)

From the `userspace` directory (or with `PATH` adjusted):

```bash
sudo ./vshape_ctl set delay 100
sudo ./vshape_ctl set jitter 10
sudo ./vshape_ctl set loss 1000
sudo ./vshape_ctl set rate 10000
```

**Note:** `vshape_ctl` currently sets **one** parameter per command. **`param_burst_ms`** is **not** exposed via Netlink; change it with module reload or `/sys/module/vshape_mod/parameters/param_burst_ms` if your kernel exposes writable params.

### 6. Unload

```bash
sudo ip link set vshapeA0 down
sudo ip link set vshapeB0 down
sudo rmmod vshape_mod
```

---

## Kernel module behavior (short)

- **`ndo_start_xmit`**: enqueue with per-packet **release time** (delay + jitter), optional **loss** before enqueue, **queue cap**; starts the per-end **`hrtimer`** when needed.
- **`hrtimer` callback**: when due, dequeues skbs whose time has come; enforces the **token bucket** at dequeue; delivers to the **peer** with **`netif_rx`**.
- **Statistics**: `tx_packets`, `tx_bytes`, `tx_dropped`, `rx_packets`, `rx_bytes` via `ndo_get_stats64`.

More detail: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## User-space control (Netlink)

- Generic Netlink family name: **`vshape`** (see `kernel/netlink.h`).
- Parameters: **delay**, **jitter**, **loss** (ppm), **rate** (kbps).

---

## Tests

```bash
sudo ./tests/test_rate_limit_udp.sh
```

Optional flags: `--module`, `--bw`, `--rate`, `--time` (see script header).

If the script appears **stuck** while configuring interfaces, it is often blocked in **`ip netns exec`** waiting on the kernel **RTNL** lock (another tool is holding the network lock). **`ip addr flush`** can also wedge in **D state** (uninterruptible sleep), where even `timeout` cannot stop the process. The test script uses **`ip addr replace`** instead of flush+add to avoid that. Otherwise check with `ss -tp`, try stopping **NetworkManager** briefly, or remove leftover namespaces: `sudo ip netns del ns1_vshape ns2_vshape`. You can raise per-command waits with `IP_TIMEOUT=120 sudo ./tests/test_rate_limit_udp.sh`.

---

## Development notes

- Intended for **education and demos**, not as a replacement for **tc** / **qdisc** on production paths.
- **Burst** is controlled by **`param_burst_ms`** (default 100 ms of capacity at the configured rate unless changed).
- **Loss** is expressed in **PPM** (parts per million).

---

## License

This project is distributed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file.

---

## Author

Mohamed BEN MOUSSA.

Use it, break it, improve it. Contributions welcome.
