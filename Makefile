# Top-level Makefile for vnet-shape

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
USER_BIN := userspace/vshape_ctl
KMOD := vnet_shape.ko

obj-m := vnet_shape.o
vnet_shape-objs := kernel/vnet_shape.o kernel/vshape_nl.o

all: $(USER_BIN) $(KMOD)

$(KMOD):
	@echo "[*] Building kernel module..."
	$(MAKE) -C $(KDIR) M=$(PWD) modules

$(USER_BIN): userspace/vshape_ctl.c kernel/netlink.h
	@echo "[*] Building user-space CLI..."
	gcc -Wall -O2 -I./kernel userspace/vshape_ctl.c -o $(USER_BIN) \
		-I/usr/include/libnl3 -lnl-genl-3 -lnl-3

clean:
	@echo "[*] Cleaning up..."
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) $(USER_BIN) $(KMOD)
