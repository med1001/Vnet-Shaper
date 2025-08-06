// vshape_ctl.c – Userspace CLI to configure vnet_shape parameters via Netlink
// Compile with: gcc vshape_ctl.c -o vshape_ctl

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include "../netlink.h" // Adjust path if needed

#define NETLINK_VSHAPE_NAME "vshape_ctl"
#define MAX_PAYLOAD 256

static int send_netlink_cmd(const char *param, uint32_t value) {
    struct sockaddr_nl src_addr, dest_addr;
    struct nlmsghdr *nlh = NULL;
    struct iovec iov;
    struct msghdr msg;
    int sock_fd;
    struct vshape_config cfg;

    memset(&cfg, 0, sizeof(cfg));

    if (strcmp(param, "delay") == 0)
        cfg.delay_ms = value;
    else if (strcmp(param, "jitter") == 0)
        cfg.jitter_ms = value;
    else if (strcmp(param, "loss") == 0)
        cfg.loss_ppm = value;
    else if (strcmp(param, "rate") == 0)
        cfg.rate_kbps = value;
    else {
        fprintf(stderr, "Unknown parameter: %s\n", param);
        return -EINVAL;
    }

    // Create socket
    sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_USERSOCK);
    if (sock_fd < 0) {
        perror("socket");
        return -1;
    }

    // Prepare source address
    memset(&src_addr, 0, sizeof(src_addr));
    src_addr.nl_family = AF_NETLINK;
    src_addr.nl_pid = getpid(); // self pid

    if (bind(sock_fd, (struct sockaddr *)&src_addr, sizeof(src_addr)) < 0) {
        perror("bind");
        close(sock_fd);
        return -1;
    }

    // Prepare destination (kernel)
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.nl_family = AF_NETLINK;
    dest_addr.nl_pid = 0; // kernel
    dest_addr.nl_groups = 0;

    // Allocate message buffer
    nlh = (struct nlmsghdr *)malloc(NLMSG_SPACE(sizeof(cfg)));
    if (!nlh) {
        perror("malloc");
        close(sock_fd);
        return -1;
    }

    nlh->nlmsg_len = NLMSG_LENGTH(sizeof(cfg));
    nlh->nlmsg_pid = getpid();
    nlh->nlmsg_flags = 0;
    nlh->nlmsg_type = VSHAPE_CMD_SET;

    memcpy(NLMSG_DATA(nlh), &cfg, sizeof(cfg));

    // Build message
    iov.iov_base = (void *)nlh;
    iov.iov_len = nlh->nlmsg_len;
    memset(&msg, 0, sizeof(msg));
    msg.msg_name = (void *)&dest_addr;
    msg.msg_namelen = sizeof(dest_addr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    // Send message
    if (sendmsg(sock_fd, &msg, 0) < 0) {
        perror("sendmsg");
        free(nlh);
        close(sock_fd);
        return -1;
    }

    printf("Updated %s to %u successfully.\n", param, value);

    free(nlh);
    close(sock_fd);
    return 0;
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

    return send_netlink_cmd(param, value);
}
