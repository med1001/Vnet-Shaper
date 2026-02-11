# vnet-shape: Virtual NIC with Latency, Jitter, Loss & Rate-Limit Shaping

## Overview

**vnet-shape** is a Linux kernel module implementing a virtual network interface (`vshape0`) that emulates network conditions such as latency, jitter, packet loss, and bandwidth throttling.  
It is designed for educational and demo purposes, allowing you to simulate complex network environments entirely in software, without touching physical hardware.

---

## Features

- Implements a virtual network interface (`vshape0`) using the Linux `net_device` API.
- Configurable latency with jitter simulation via high-resolution timers (`hrtimer`).
- Packet loss emulation using kernel pseudo-random number generation.
- Bandwidth limiting via a token bucket algorithm.
- User-space configuration via Netlink interface.
- Safe: All operations happen in RAM, no hardware modifications.

---

## Build Instructions

Make sure you have the Linux kernel headers installed and your environment is set up for kernel module compilation.

```bash
make
```

This will build `vnet_shape.ko` (the kernel module) and `vshape_ctl` (the user-space CLI tool).

---

## Installation and Usage

1. **Insert the kernel module:**

```bash
sudo insmod vnet_shape.ko
```

2. **Verify interface creation:**

```bash
ip link show vshape0
```

3. **Configure parameters at load time (optional):**

```bash
sudo insmod vnet_shape.ko param_delay_ms=100 param_jitter_ms=10 param_loss_ppm=1000 param_rate_kbps=10000
```

4. **Configure parameters at runtime via user-space tool:**

```bash
sudo ./vshape_ctl set delay 100
sudo ./vshape_ctl set jitter 10
sudo ./vshape_ctl set loss 1000
sudo ./vshape_ctl set rate 10000
```

5. **Test network behavior:**

```bash
ping -I vshape0 8.8.8.8
```

---

## Kernel Module Details

- **ndo_start_xmit:** Enqueues packets with calculated delay+jitter, drops packets probabilistically to simulate loss, and respects bandwidth limits.
- **High-resolution timer:** Fires every millisecond to dequeue packets whose delay timer expired.
- **Token bucket:** Controls bandwidth consumption over time.
- **Statistics:** Tracks transmitted, dropped, and received packets, exposed through standard interface statistics.

---

## User-space Control via Netlink

- Implements a Generic Netlink family `vshape` to set parameters at runtime.
- Parameters configurable: delay (ms), jitter (ms), loss (ppm), rate (kbps).
- Use the `vshape_ctl` CLI to send configuration commands.

---

## Development Notes

- The module does not interact with any physical device, making it safe for testing.
- The token bucket allows bursts up to 1 second of allowed bandwidth.
- Loss is specified in parts-per-million (PPM).
- The code can be extended with features like multiple interfaces, per-flow shaping, or integration with tc/qdisc.

---

## License

MIT License. do whatever you want, just don’t break real networks with it

---

## Author
Mohamed	BEN MOUSSA.
Use it, break it, improve it. Contributions welcome!
