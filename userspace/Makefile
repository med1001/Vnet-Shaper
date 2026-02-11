CC := gcc
CFLAGS := -O2 -Wall -I/usr/include/libnl3
LIBS := -lnl-3 -lnl-genl-3

all: vshape_ctl

vshape_ctl: vshape_ctl.c
	$(CC) $(CFLAGS) -o vshape_ctl vshape_ctl.c $(LIBS)

clean:
	rm -f vshape_ctl
