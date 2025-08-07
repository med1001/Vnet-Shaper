# Top-level Makefile for vnet-shape

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

KERNEL_DIR := $(PWD)/kernel
KBUILD_DIR := $(KERNEL_DIR)/build

USER_SRC := $(PWD)/userspace
USER_BIN := $(USER_SRC)/build/vshape_ctl

all: $(USER_BIN) $(KBUILD_DIR)/vnet_shape.ko

$(KBUILD_DIR)/vnet_shape.ko: $(KERNEL_DIR)/vnet_shape.c $(KERNEL_DIR)/vshape_nl.c
	@echo "[*] Building kernel module..."
	$(MAKE) -C $(KDIR) M=$(KERNEL_DIR) modules
	mkdir -p $(KBUILD_DIR)
	cp $(KERNEL_DIR)/vnet_mod.ko $(KBUILD_DIR)/vnet_shape.ko

$(USER_BIN): $(USER_SRC)/vshape_ctl.c $(KERNEL_DIR)/netlink.h
	@echo "[*] Building user-space CLI..."
	mkdir -p $(USER_SRC)/build
	gcc -Wall -O2 -I$(KERNEL_DIR) $< -o $@ -I/usr/include/libnl3 -lnl-genl-3 -lnl-3

clean:
	@echo "[*] Cleaning up..."
	$(MAKE) -C $(KDIR) M=$(KERNEL_DIR) clean
	rm -rf $(KBUILD_DIR)
	rm -rf $(USER_SRC)/build
