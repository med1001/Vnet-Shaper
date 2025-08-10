/*
 * vnet_shape.c – Virtual NIC that emulates latency, jitter, loss & rate-limit
 */

#define pr_fmt(fmt) "vnet_shape: " fmt

#include <linux/module.h>
#include <linux/version.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/random.h>
#include <linux/ktime.h>
#include <linux/hrtimer.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/rtnetlink.h>
#include <linux/u64_stats_sync.h>

#include "netlink.h"

MODULE_AUTHOR("Your Name <you@example.com>");
MODULE_DESCRIPTION("Virtual NIC with latency, jitter, loss, and rate-limit shaping");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0");

/* ---------- Tunables (defaults) ---------- */
unsigned int param_delay_ms = 50;
unsigned int param_jitter_ms = 5;
unsigned int param_loss_ppm = 0;
unsigned int param_rate_kbps = 100000;
module_param(param_delay_ms, uint, 0644);
MODULE_PARM_DESC(param_delay_ms, "Base latency in milliseconds");
module_param(param_jitter_ms, uint, 0644);
MODULE_PARM_DESC(param_jitter_ms, "Jitter range in milliseconds (+/- around delay)");
module_param(param_loss_ppm, uint, 0644);
MODULE_PARM_DESC(param_loss_ppm, "Packet loss probability in PPM (0-1,000,000)");
module_param(param_rate_kbps, uint, 0644);
MODULE_PARM_DESC(param_rate_kbps, "Rate limit in kilobits per second (0 = unlimited)");

/* ---------- Internal structures ---------- */
struct vshape_priv {
    struct net_device *dev;
    struct list_head tx_queue;
    spinlock_t queue_lock;
    struct hrtimer tx_timer;

    /* Token bucket */
    u64 rate_bytes_per_ns;
    u64 bucket_capacity_bytes;
    u64 bucket_tokens;
    ktime_t last_bucket_update;

    u64 tx_packets;
    u64 tx_dropped;
    u64 rx_packets;
    struct u64_stats_sync stats_sync;
};

struct vshape_qitem {
    struct sk_buff *skb;
    ktime_t release_time;
    struct list_head list;
};

/* ---------- Token bucket logic ---------- */
static void vshape_bucket_update(struct vshape_priv *vp)
{
    ktime_t now = ktime_get();
    s64 ns = ktime_to_ns(ktime_sub(now, vp->last_bucket_update));
    if (ns <= 0)
        return;

    u64 add = mul_u64_u64_div_u64(vp->rate_bytes_per_ns, ns, 1);
    if (add > vp->bucket_capacity_bytes)
        add = vp->bucket_capacity_bytes;

    vp->bucket_tokens = min((u64)(vp->bucket_tokens + add), vp->bucket_capacity_bytes);
    vp->last_bucket_update = now;
}

static bool vshape_bucket_consume(struct vshape_priv *vp, size_t bytes)
{
    if (!vp->rate_bytes_per_ns)
        return true;

    vshape_bucket_update(vp);
    if (vp->bucket_tokens < bytes)
        return false;

    vp->bucket_tokens -= bytes;
    return true;
}

/* ---------- Packet drop logic ---------- */
static bool vshape_should_drop(void)
{
    if (!param_loss_ppm)
        return false;
    return (prandom_u32_max(1000000) < param_loss_ppm);
}

/* ---------- Timer dequeue ---------- */
static enum hrtimer_restart vshape_tx_timer_fn(struct hrtimer *timer)
{
    struct vshape_priv *vp = container_of(timer, struct vshape_priv, tx_timer);
    struct vshape_qitem *qitem, *tmp;
    ktime_t now = ktime_get();

    spin_lock(&vp->queue_lock);
    list_for_each_entry_safe(qitem, tmp, &vp->tx_queue, list) {
        if (ktime_after(now, qitem->release_time)) {
            if (vshape_bucket_consume(vp, qitem->skb->len)) {
                list_del(&qitem->list);
                spin_unlock(&vp->queue_lock);

                qitem->skb->dev = vp->dev;
                qitem->skb->protocol = eth_type_trans(qitem->skb, vp->dev);
                netif_rx(qitem->skb);

                spin_lock(&vp->queue_lock);
                vp->rx_packets++;
                kfree(qitem);
            }
        }
    }

    if (!list_empty(&vp->tx_queue)) {
        hrtimer_forward(timer, now, ns_to_ktime(1e6));
        spin_unlock(&vp->queue_lock);
        return HRTIMER_RESTART;
    }

    spin_unlock(&vp->queue_lock);
    return HRTIMER_NORESTART;
}

/* ---------- Packet transmit ---------- */
static netdev_tx_t vshape_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vshape_priv *vp = netdev_priv(dev);
    struct ethhdr *eth;

    /* Drop if configured loss */
    if (vshape_should_drop()) {
        vp->tx_dropped++;
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    /* Avoid sending frames with our own source MAC (bridge warning) */
    if (skb_mac_header_was_set(skb) && skb_mac_header_len(skb) >= ETH_HLEN) {
        eth = eth_hdr(skb);
        if (ether_addr_equal(eth->h_source, dev->dev_addr)) {
            struct sk_buff *nskb = skb_copy(skb, GFP_ATOMIC);
            if (!nskb) {
                dev_kfree_skb(skb);
                return NETDEV_TX_OK;
            }
            dev_kfree_skb(skb);
            skb = nskb;
            eth = eth_hdr(skb);
            eth->h_source[5] ^= 0x01; /* tweak last byte */
        }
    }

    s32 jitter = (param_jitter_ms) ?
        (s32)prandom_u32_max(param_jitter_ms * 2) - (s32)param_jitter_ms : 0;
    ktime_t delay = ms_to_ktime(param_delay_ms + jitter);
    ktime_t release_time = ktime_add(ktime_get(), delay);

    struct vshape_qitem *qitem = kmalloc(sizeof(*qitem), GFP_ATOMIC);
    if (!qitem) {
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    qitem->skb = skb;
    qitem->release_time = release_time;

    spin_lock(&vp->queue_lock);
    list_add_tail(&qitem->list, &vp->tx_queue);
    vp->tx_packets++;

    if (!hrtimer_is_queued(&vp->tx_timer))
        hrtimer_start(&vp->tx_timer, delay, HRTIMER_MODE_REL);
    spin_unlock(&vp->queue_lock);

    return NETDEV_TX_OK;
}

/* ---------- Net device ops ---------- */
static int vshape_open(struct net_device *dev)
{
    netif_start_queue(dev);
    return 0;
}

static int vshape_stop(struct net_device *dev)
{
    netif_stop_queue(dev);
    return 0;
}

static void vshape_get_stats64(struct net_device *dev, struct rtnl_link_stats64 *stats)
{
    struct vshape_priv *vp = netdev_priv(dev);
    u64 t, d, r;

    u64_stats_fetch_begin(&vp->stats_sync);
    t = vp->tx_packets;
    d = vp->tx_dropped;
    r = vp->rx_packets;
    u64_stats_fetch_retry(&vp->stats_sync, 0);

    stats->tx_packets = t;
    stats->tx_dropped = d;
    stats->rx_packets = r;
}

static struct net_device *vshape_dev;

/* ---------- Exposed: runtime rate limit update ---------- */
void vshape_update_rate_limit(void)
{
    if (!vshape_dev)
        return;

    struct vshape_priv *vp = netdev_priv(vshape_dev);
    unsigned long flags;

    spin_lock_irqsave(&vp->queue_lock, flags);

    if (param_rate_kbps) {
        vp->rate_bytes_per_ns = (u64)param_rate_kbps * 1000 / 8;
        do_div(vp->rate_bytes_per_ns, 1000000000ULL);
        vp->bucket_capacity_bytes = vp->rate_bytes_per_ns * 1000000ULL;
    } else {
        vp->rate_bytes_per_ns = 0;
        vp->bucket_capacity_bytes = 0;
    }

    vp->bucket_tokens = vp->bucket_capacity_bytes;
    vp->last_bucket_update = ktime_get();

    spin_unlock_irqrestore(&vp->queue_lock, flags);

    pr_info("Updated rate limiting: %u kbps\n", param_rate_kbps);
}

/* ---------- Device setup ---------- */
static const struct net_device_ops vshape_netdev_ops = {
    .ndo_open        = vshape_open,
    .ndo_stop        = vshape_stop,
    .ndo_start_xmit  = vshape_start_xmit,
    .ndo_get_stats64 = vshape_get_stats64,
};

static void vshape_setup(struct net_device *dev)
{
    ether_setup(dev);
    dev->netdev_ops = &vshape_netdev_ops;
    dev->features |= NETIF_F_HW_CSUM;
    dev->priv_flags |= IFF_TX_SKB_SHARING;

    /* Locally administered unicast MAC, random last byte to avoid duplicates */
    u8 mac[ETH_ALEN] = {0x02, 0x00, 0x00, 0x00, 0x00, (u8)(get_random_u32() & 0xFF)};
    eth_hw_addr_set(dev, mac);
}

/* ---------- Netlink hooks ---------- */
extern int vshape_nl_init(void);
extern void vshape_nl_exit(void);

/* ---------- Init/Exit ---------- */
static int __init vshape_init(void)
{
    int err;

    vshape_dev = alloc_netdev(sizeof(struct vshape_priv), "vshape%d", NET_NAME_UNKNOWN, vshape_setup);
    if (!vshape_dev)
        return -ENOMEM;

    struct vshape_priv *vp = netdev_priv(vshape_dev);
    vp->dev = vshape_dev;
    INIT_LIST_HEAD(&vp->tx_queue);
    spin_lock_init(&vp->queue_lock);
    hrtimer_init(&vp->tx_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    vp->tx_timer.function = vshape_tx_timer_fn;

    if (param_rate_kbps) {
        vp->rate_bytes_per_ns = (u64)param_rate_kbps * 1000 / 8;
        do_div(vp->rate_bytes_per_ns, 1000000000ULL);
        vp->bucket_capacity_bytes = vp->rate_bytes_per_ns * 1000000ULL;
    } else {
        vp->rate_bytes_per_ns = 0;
        vp->bucket_capacity_bytes = 0;
    }
    vp->bucket_tokens = vp->bucket_capacity_bytes;
    vp->last_bucket_update = ktime_get();
    u64_stats_init(&vp->stats_sync);

    if ((err = register_netdev(vshape_dev))) {
        pr_err("register_netdev failed: %d\n", err);
        free_netdev(vshape_dev);
        return err;
    }

    if ((err = vshape_nl_init())) {
        pr_err("netlink init failed: %d\n", err);
        unregister_netdev(vshape_dev);
        free_netdev(vshape_dev);
        return err;
    }

    pr_info("vshape0 created: delay=%u ms jitter=%u ms loss=%u ppm rate=%u kbps\n",
            param_delay_ms, param_jitter_ms, param_loss_ppm, param_rate_kbps);
    return 0;
}

static void __exit vshape_exit(void)
{
    struct vshape_priv *vp = netdev_priv(vshape_dev);
    struct vshape_qitem *qitem, *tmp;

    hrtimer_cancel(&vp->tx_timer);

    spin_lock(&vp->queue_lock);
    list_for_each_entry_safe(qitem, tmp, &vp->tx_queue, list) {
        dev_kfree_skb(qitem->skb);
        kfree(qitem);
    }
    spin_unlock(&vp->queue_lock);

    vshape_nl_exit();
    unregister_netdev(vshape_dev);
    free_netdev(vshape_dev);

    pr_info("vshape0 removed\n");
}

module_init(vshape_init);
module_exit(vshape_exit);
