// userspace/vshape_ctl.c – Uses libnl to set shaping parameters via Generic Netlink

#include <netlink/netlink.h>
#include <netlink/genl/genl.h>
#include <netlink/genl/ctrl.h>
#include <netlink/msg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "../kernel/netlink.h"

static int set_param(const char *param, uint32_t value) {
    struct nl_sock *sock = NULL;
    struct nl_msg *msg = NULL;
    int family_id, err = 0;

    // Open netlink socket
    sock = nl_socket_alloc();
    if (!sock) {
        fprintf(stderr, "Failed to allocate netlink socket\n");
        return -ENOMEM;
    }

    if ((err = genl_connect(sock)) < 0) {
        fprintf(stderr, "genl_connect() failed: %s\n", nl_geterror(err));
        nl_socket_free(sock);
        return err;
    }

    // Resolve the family ID from name
    family_id = genl_ctrl_resolve(sock, VSHAPE_GENL_NAME);
    if (family_id < 0) {
        fprintf(stderr, "Unable to resolve family name '%s'\n", VSHAPE_GENL_NAME);
        nl_socket_free(sock);
        return -ENOENT;
    }

    // Create the message
    msg = nlmsg_alloc();
    if (!msg) {
        fprintf(stderr, "Failed to allocate netlink message\n");
        nl_socket_free(sock);
        return -ENOMEM;
    }

    // Generic Netlink header
    genlmsg_put(msg, NL_AUTO_PID, NL_AUTO_SEQ, family_id, 0, 0,
                VSHAPE_CMD_SET_PARAMS, VSHAPE_GENL_VERSION);

    // Add the appropriate attribute
    if (strcmp(param, "delay") == 0)
        nla_put_u32(msg, VSHAPE_ATTR_DELAY_MS, value);
    else if (strcmp(param, "jitter") == 0)
        nla_put_u32(msg, VSHAPE_ATTR_JITTER_MS, value);
    else if (strcmp(param, "loss") == 0)
        nla_put_u32(msg, VSHAPE_ATTR_LOSS_PPM, value);
    else if (strcmp(param, "rate") == 0)
        nla_put_u32(msg, VSHAPE_ATTR_RATE_KBPS, value);
    else {
        fprintf(stderr, "Unknown parameter: %s\n", param);
        err = -EINVAL;
        goto out;
    }

    // Send the message
    err = nl_send_auto_complete(sock, msg);
    if (err < 0) {
        fprintf(stderr, "Failed to send message: %s\n", nl_geterror(err));
        goto out;
    }

    printf("Updated %s to %u successfully.\n", param, value);

out:
    nlmsg_free(msg);
    nl_socket_free(sock);
    return err;
}

void usage(const char *prog) {
    fprintf(stderr,
        "Usage:\n"
        "  %s set <param> <value>\n"
        "    param: delay | jitter | loss | rate\n"
        "    value: uint (e.g. delay 50 means 50ms)\n",
        prog);
}

int main(int argc, char *argv[]) {
    if (argc != 4 || strcmp(argv[1], "set") != 0) {
        usage(argv[0]);
        return 1;
    }

    const char *param = argv[2];
    uint32_t value = atoi(argv[3]);

    return set_param(param, value);
}
