# Top-level Makefile for vnet-shape

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
USER_BIN := userspace/vshape_ctl

obj-m := vnet_shape.o
vnet_shape-objs := vnet_shape.o vshape_nl.o

all: $(USER_BIN) kernel

kernel:
	@echo "[*] Building kernel module..."
	$(MAKE) -C $(KDIR) M=$(PWD) modules

$(USER_BIN): userspace/vshape_ctl.c netlink.h
	@echo "[*] Building user-space CLI..."
	gcc -Wall -O2 userspace/vshape_ctl.c -o $(USER_BIN)

clean:
	@echo "[*] Cleaning up..."
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) $(USER_BIN)
