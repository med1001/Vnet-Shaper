# libnl3 userspace: prefer pkg-config (Debian: libnl-genl-3-dev)
PKG_CONFIG ?= pkg-config

NL_CFLAGS := $(shell $(PKG_CONFIG) --silence-errors --cflags libnl-genl-3.0 2>/dev/null)
NL_LIBS := $(shell $(PKG_CONFIG) --silence-errors --libs libnl-genl-3.0 2>/dev/null)

ifeq ($(strip $(NL_CFLAGS)),)
NL_CFLAGS := -I/usr/include/libnl3
$(warning No pkg-config cflags for libnl-genl-3.0; using -I/usr/include/libnl3. Install libnl-genl-3-dev if build fails.)
endif
ifeq ($(strip $(NL_LIBS)),)
NL_LIBS := -lnl-3 -lnl-genl-3
endif

CC := gcc
CFLAGS := -O2 -Wall $(NL_CFLAGS)
LIBS := $(NL_LIBS)

all: vshape_ctl

vshape_ctl: vshape_ctl.c
	$(CC) $(CFLAGS) -o vshape_ctl vshape_ctl.c $(LIBS)

clean:
	rm -f vshape_ctl
