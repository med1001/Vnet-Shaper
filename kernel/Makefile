# Build kernel module vnet_shape (vnet_shape.c + vshape_nl.c)
obj-m := vshape_mod.o
vshape_mod-objs := vnet_shape.o vshape_nl.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:	
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean