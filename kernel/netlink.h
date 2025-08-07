// kernel/netlink.h
#ifndef _VSHAPE_NETLINK_H_
#define _VSHAPE_NETLINK_H_

#define VSHAPE_GENL_NAME "vshape"
#define VSHAPE_GENL_VERSION 1

enum vshape_commands {
    VSHAPE_CMD_UNSPEC,
    VSHAPE_CMD_SET_PARAMS,
    __VSHAPE_CMD_MAX,
};
#define VSHAPE_CMD_MAX (__VSHAPE_CMD_MAX - 1)

enum vshape_attrs {
    VSHAPE_ATTR_UNSPEC,
    VSHAPE_ATTR_DELAY_MS,
    VSHAPE_ATTR_JITTER_MS,
    VSHAPE_ATTR_LOSS_PPM,
    VSHAPE_ATTR_RATE_KBPS,
    __VSHAPE_ATTR_MAX,
};
#define VSHAPE_ATTR_MAX (__VSHAPE_ATTR_MAX - 1)

#endif
