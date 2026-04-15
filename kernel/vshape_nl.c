#include <linux/module.h>
#include <net/genetlink.h>
#include "netlink.h"

// These symbols exist in vnet_shape.c
extern unsigned int param_delay_ms;
extern unsigned int param_jitter_ms;
extern unsigned int param_loss_ppm;
extern unsigned int param_rate_kbps;

// Declare update function from vnet_shape.c
extern void vshape_update_rate_limit(void);

/* Prototypes: called from vnet_shape.c (-Wmissing-prototypes) */
int __init vshape_nl_init(void);
void vshape_nl_exit(void);

static struct genl_family vshape_family;

static const struct nla_policy vshape_policy[VSHAPE_ATTR_MAX + 1] = {
    [VSHAPE_ATTR_DELAY_MS]  = { .type = NLA_U32 },
    [VSHAPE_ATTR_JITTER_MS] = { .type = NLA_U32 },
    [VSHAPE_ATTR_LOSS_PPM]  = { .type = NLA_U32 },
    [VSHAPE_ATTR_RATE_KBPS] = { .type = NLA_U32 },
};

static int vshape_set_params(struct sk_buff *skb, struct genl_info *info)
{
    u32 val;

    if (!info)
        return -EINVAL;

    if (info->attrs[VSHAPE_ATTR_DELAY_MS])
        param_delay_ms = nla_get_u32(info->attrs[VSHAPE_ATTR_DELAY_MS]);

    if (info->attrs[VSHAPE_ATTR_JITTER_MS])
        param_jitter_ms = nla_get_u32(info->attrs[VSHAPE_ATTR_JITTER_MS]);

    if (info->attrs[VSHAPE_ATTR_LOSS_PPM]) {
        val = nla_get_u32(info->attrs[VSHAPE_ATTR_LOSS_PPM]);
        if (val > 1000000) {
            pr_warn("Netlink: loss_ppm %u clamped to 1000000\n", val);
            val = 1000000;
        }
        param_loss_ppm = val;
    }

    if (info->attrs[VSHAPE_ATTR_RATE_KBPS]) {
        param_rate_kbps = nla_get_u32(info->attrs[VSHAPE_ATTR_RATE_KBPS]);
        vshape_update_rate_limit();
    }

    if (param_jitter_ms > param_delay_ms)
        pr_warn("Netlink: jitter_ms (%u) > delay_ms (%u); some packets will have zero effective delay\n",
                param_jitter_ms, param_delay_ms);

    pr_info("Netlink: new params — delay=%u, jitter=%u, loss=%u, rate=%u\n",
            param_delay_ms, param_jitter_ms, param_loss_ppm, param_rate_kbps);

    return 0;
}

static const struct genl_ops vshape_ops[] = {
    {
        .cmd = VSHAPE_CMD_SET_PARAMS,
        .flags = GENL_ADMIN_PERM,
        .policy = vshape_policy,
        .doit = vshape_set_params,
    },
};

static struct genl_family vshape_family = {
    .name = VSHAPE_GENL_NAME,
    .version = VSHAPE_GENL_VERSION,
    .maxattr = VSHAPE_ATTR_MAX,
    .module = THIS_MODULE,
    .ops = vshape_ops,
    .n_ops = ARRAY_SIZE(vshape_ops),
};

int __init vshape_nl_init(void)
{
    int err = genl_register_family(&vshape_family);
    if (err)
        pr_err("Failed to register Netlink family: %d\n", err);
    else
        pr_info("Netlink family registered\n");
    return err;
}

void vshape_nl_exit(void)
{
    genl_unregister_family(&vshape_family);
    pr_info("Netlink family unregistered\n");
}