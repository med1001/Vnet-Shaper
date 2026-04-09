// SPDX-License-Identifier: GPL-2.0
/*
 * vnet_shape.c – Two-ended virtual NIC (veth-like) that emulates latency,
 * jitter, loss & rate-limit between its ends.
 *
 * Each end is a normal Ethernet netdev. Frames TX'd on A are shaped and
 * delivered to B (and vice-versa). This makes it trivial to test in netns.
 *
 * Define VNET_SHAPE_DEBUG at build time to enable verbose/rate-limited debug.
 */

#define pr_fmt(fmt) "vnet_shape: " fmt

#include <linux/module.h>
#include <linux/version.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/if_ether.h>
#include <linux/random.h>
#include <linux/ktime.h>
#include <linux/hrtimer.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/rtnetlink.h>
#include <linux/u64_stats_sync.h>
#include <linux/ratelimit.h>

#include "netlink.h"

MODULE_AUTHOR("Mohamed BEN MOUSSA");
MODULE_DESCRIPTION("Two-ended virtual NIC with latency/jitter/loss/rate shaping");
MODULE_LICENSE("GPL");
MODULE_VERSION("2.1");

/* ---------- Tunables (defaults) ---------- */
unsigned int param_delay_ms = 50;
unsigned int param_jitter_ms = 5;
unsigned int param_loss_ppm = 0;
unsigned int param_rate_kbps = 100000;
unsigned int param_burst_ms = 100;      /* bucket capacity window (ms) */
bool         param_debug = false;

bool         param_passthrough = false; /* bypass shaping (deliver immediately) */
unsigned int param_max_queue = 100000;  /* safety cap for queued packets */

module_param(param_delay_ms, uint, 0644);
MODULE_PARM_DESC(param_delay_ms, "Base latency in milliseconds");
module_param(param_jitter_ms, uint, 0644);
MODULE_PARM_DESC(param_jitter_ms, "Jitter range in milliseconds (+/- around delay)");
module_param(param_loss_ppm, uint, 0644);
MODULE_PARM_DESC(param_loss_ppm, "Packet loss probability in PPM (0-1,000,000)");
module_param(param_rate_kbps, uint, 0644);
MODULE_PARM_DESC(param_rate_kbps, "Rate limit in kilobits per second (0 = unlimited)");
module_param(param_burst_ms, uint, 0644);
MODULE_PARM_DESC(param_burst_ms, "Burst size in milliseconds for token bucket capacity");
module_param(param_debug, bool, 0644);
MODULE_PARM_DESC(param_debug, "Enable additional rate-limited debug prints (if built with VNET_SHAPE_DEBUG)");
module_param(param_passthrough, bool, 0644);
MODULE_PARM_DESC(param_passthrough, "Bypass shaping and deliver immediately to peer");
module_param(param_max_queue, uint, 0644);
MODULE_PARM_DESC(param_max_queue, "Max number of packets to queue per end");

/* ---------- Logging helpers ---------- */
#ifdef VNET_SHAPE_DEBUG
#define HOTLOG(fmt, ...) \
    do { if (param_debug) pr_info_ratelimited(fmt, ##__VA_ARGS__); } while (0)
#define PRDEBUG(fmt, ...) pr_debug(fmt, ##__VA_ARGS__)
#else
#define HOTLOG(fmt, ...) do { } while (0)
#define PRDEBUG(fmt, ...) do { } while (0)
#endif

/* ---------- Per-end private ---------- */
struct vshape_qitem {
    struct sk_buff *skb;
    ktime_t release_time;
    struct list_head list;
};

struct vshape_priv {
    struct net_device *dev;          /* this end */
    struct net_device *peer;         /* other end (paired device) */

    /* shaping queue for frames transmitted *from* this end *to* its peer */
    struct list_head tx_queue;
    spinlock_t queue_lock;
    struct hrtimer tx_timer;
    u32 queue_len;

    /* token bucket (per end, ms granularity) */
    u64 rate_bytes_per_ms;
    u64 bucket_capacity_bytes;
    u64 bucket_tokens;
    ktime_t last_bucket_update;

    /* statistics */
    struct u64_stats_sync stats_sync;
    u64 tx_packets;   /* packets accepted from this end (before shaping) */
    u64 tx_bytes;     /* bytes accepted from this end */
    u64 tx_dropped;   /* dropped by loss or queue full */
    u64 rx_packets;   /* packets delivered to peer's stack */
    u64 rx_bytes;     /* bytes delivered to peer */
};

/* Exactly one pair per module load */
static struct net_device *vshapeA_dev;
static struct net_device *vshapeB_dev;

/* convenience helper */
static inline struct vshape_priv *vshape_priv(struct net_device *dev)
{
    return (struct vshape_priv *)netdev_priv(dev);
}

/*
 * Small compatibility wrapper: avoid prandom_u32_max(), which is not
 * available on newer kernels. get_random_u32() is widely available.
 */
static u32 vshape_rand_below(u32 ceil)
{
    if (!ceil)
        return 0;
    return get_random_u32() % ceil;
}

/* ---------- Token bucket helpers ---------- */
static void vshape_bucket_update(struct vshape_priv *vp)
{
    ktime_t now = ktime_get();
    s64 ns = ktime_to_ns(ktime_sub(now, vp->last_bucket_update));
    if (ns <= 0)
        return;

    /* convert ns -> ms; keep coarse granularity to reduce overhead */
    {
        u64 ms = ns / 1000000ULL;
        u64 add;

        if (!ms)
            return;

        add = vp->rate_bytes_per_ms * ms;
        if (add > vp->bucket_capacity_bytes)
            add = vp->bucket_capacity_bytes;

        vp->bucket_tokens = min(vp->bucket_tokens + add, vp->bucket_capacity_bytes);
        vp->last_bucket_update = now;
    }
}

static bool vshape_bucket_consume(struct vshape_priv *vp, size_t bytes)
{
    if (!vp->rate_bytes_per_ms)
        return true; /* unlimited */

    vshape_bucket_update(vp);
    if (vp->bucket_tokens < bytes)
        return false;

    vp->bucket_tokens -= bytes;
    return true;
}

/* ---------- Loss ---------- */
static bool vshape_should_drop(void)
{
    if (!param_loss_ppm)
        return false;
    return vshape_rand_below(1000000) < param_loss_ppm;
}

/* ---------- timer: dequeue and deliver to peer ---------- */
static enum hrtimer_restart vshape_tx_timer_fn(struct hrtimer *timer)
{
    struct vshape_priv *vp = container_of(timer, struct vshape_priv, tx_timer);
    struct net_device *peer_dev = vp->peer;
    ktime_t now = ktime_get();
    int processed = 0;
    bool has_items = false;

    /* defensive: if we don't have a valid peer, drop queued items (safe) */
    if (!peer_dev) {
        pr_warn_ratelimited("%s: timer running but peer is NULL, flushing queue\n", vp->dev ? vp->dev->name : "(unknown)");
        spin_lock(&vp->queue_lock);
        while (!list_empty(&vp->tx_queue)) {
            struct vshape_qitem *q = list_first_entry(&vp->tx_queue, struct vshape_qitem, list);
            list_del(&q->list);
            if (vp->queue_len)
                vp->queue_len--;
            dev_kfree_skb(q->skb);
            kfree(q);
        }
        spin_unlock(&vp->queue_lock);
        return HRTIMER_NORESTART;
    }

    while (1) {
        struct vshape_qitem *q = NULL;

        spin_lock(&vp->queue_lock);
        if (list_empty(&vp->tx_queue)) {
            spin_unlock(&vp->queue_lock);
            break;
        }

        q = list_first_entry(&vp->tx_queue, struct vshape_qitem, list);
        if (ktime_after(q->release_time, now)) {
            spin_unlock(&vp->queue_lock);
            break;
        }

        if (!vshape_bucket_consume(vp, q->skb->len)) {
            spin_unlock(&vp->queue_lock);
            break;
        }

        list_del(&q->list);
        if (vp->queue_len)
            vp->queue_len--;
        spin_unlock(&vp->queue_lock);

        /* deliver to peer (peer still valid as checked above) */
        q->skb->dev = peer_dev;
        q->skb->protocol = eth_type_trans(q->skb, peer_dev);
        netif_rx(q->skb);

        /* update peer stats (rx) if peer's priv exists */
        if (peer_dev && netdev_priv(peer_dev)) {
            struct vshape_priv *peer_vp = vshape_priv(peer_dev);
            u64_stats_update_begin(&peer_vp->stats_sync);
            peer_vp->rx_packets++;
            peer_vp->rx_bytes += q->skb->len;
            u64_stats_update_end(&peer_vp->stats_sync);
        }

        kfree(q);
        processed++;
    }

    if (processed)
        pr_info_ratelimited("%s: tx_timer delivered %d packets (queue_len now %u)\n",
                            vp->dev->name, processed, vp->queue_len);

    spin_lock(&vp->queue_lock);
    has_items = !list_empty(&vp->tx_queue);
    spin_unlock(&vp->queue_lock);

    if (has_items) {
        hrtimer_forward_now(&vp->tx_timer, ms_to_ktime(1));
        return HRTIMER_RESTART;
    }
    return HRTIMER_NORESTART;
}

/* ---------- transmit: enqueue towards peer ---------- */
static netdev_tx_t vshape_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vshape_priv *vp = vshape_priv(dev);

    if (unlikely(!vp->peer || !(vp->peer->flags & IFF_UP))) {
        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_dropped++;
        u64_stats_update_end(&vp->stats_sync);
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    /* pre-enqueue loss */
    if (vshape_should_drop()) {
        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_dropped++;
        u64_stats_update_end(&vp->stats_sync);
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    /* passthrough: immediate delivery to peer */
    if (param_passthrough) {
        struct vshape_priv *peer_vp = vshape_priv(vp->peer);

        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_packets++;
        vp->tx_bytes += skb->len;
        u64_stats_update_end(&vp->stats_sync);

        skb->dev = vp->peer;
        skb->protocol = eth_type_trans(skb, vp->peer);
        netif_rx(skb);

        if (peer_vp) {
            u64_stats_update_begin(&peer_vp->stats_sync);
            peer_vp->rx_packets++;
            peer_vp->rx_bytes += skb->len;
            u64_stats_update_end(&peer_vp->stats_sync);
        }
        return NETDEV_TX_OK;
    }

    /* queue capacity check */
    spin_lock(&vp->queue_lock);
    if (vp->queue_len >= param_max_queue) {
        spin_unlock(&vp->queue_lock);
        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_dropped++;
        u64_stats_update_end(&vp->stats_sync);
        pr_warn_ratelimited("%s: queue full (%u >= %u), dropping\n",
                            dev->name, vp->queue_len, param_max_queue);
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }
    spin_unlock(&vp->queue_lock);

    /* compute release time */
    {
        s32 jitter = param_jitter_ms ? (s32)vshape_rand_below(param_jitter_ms * 2) - (s32)param_jitter_ms : 0;
        ktime_t delay = ms_to_ktime(param_delay_ms + jitter);
        ktime_t release_time = ktime_add(ktime_get(), delay);
        struct vshape_qitem *q = kmalloc(sizeof(*q), GFP_ATOMIC);

        if (!q) {
            u64_stats_update_begin(&vp->stats_sync);
            vp->tx_dropped++;
            u64_stats_update_end(&vp->stats_sync);
            dev_kfree_skb(skb);
            return NETDEV_TX_OK;
        }

        q->skb = skb;
        q->release_time = release_time;

        spin_lock(&vp->queue_lock);
        list_add_tail(&q->list, &vp->tx_queue);
        vp->queue_len++;
        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_packets++;
        vp->tx_bytes += skb->len;
        u64_stats_update_end(&vp->stats_sync);

        if (!hrtimer_is_queued(&vp->tx_timer))
            hrtimer_start(&vp->tx_timer, delay, HRTIMER_MODE_REL);
        spin_unlock(&vp->queue_lock);
    }

    return NETDEV_TX_OK;
}

/* ---------- netdev ops ---------- */
static int vshape_open(struct net_device *dev)
{
    struct vshape_priv *vp = vshape_priv(dev);
    pr_info("%s: open (peer=%s)\n", dev->name, vp->peer ? vp->peer->name : "(none)");
    netif_start_queue(dev);
    return 0;
}

static int vshape_stop(struct net_device *dev)
{
    struct vshape_priv *vp = vshape_priv(dev);
    pr_info("%s: stop\n", dev->name);
    netif_stop_queue(dev);
    hrtimer_cancel(&vp->tx_timer);
    return 0;
}

static void vshape_get_stats64(struct net_device *dev, struct rtnl_link_stats64 *stats)
{
    struct vshape_priv *vp = vshape_priv(dev);
    unsigned int seq;
    u64 t, d, r;
    u64 txb, rxb;

    do {
        seq = u64_stats_fetch_begin(&vp->stats_sync);
        t = vp->tx_packets;
        d = vp->tx_dropped;
        r = vp->rx_packets;
        txb = vp->tx_bytes;
        rxb = vp->rx_bytes;
    } while (u64_stats_fetch_retry(&vp->stats_sync, seq));

    stats->tx_packets = t;
    stats->tx_dropped = d;
    stats->rx_packets = r;
    stats->tx_bytes = txb;
    stats->rx_bytes = rxb;
}

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

    /* local MAC */
    {
        u8 mac[ETH_ALEN] = {0x02, 0x00, 0x00, 0x00, 0x00, (u8)(get_random_u32() & 0xff)};
        #if LINUX_VERSION_CODE >= KERNEL_VERSION(5,15,0)
        eth_hw_addr_set(dev, mac);
        #else
        memcpy(dev->dev_addr,mac,ETH_ALEN);
        #endif
    }
}

/* ---------- runtime update helper (netlink can call this) ---------- */
void vshape_update_rate_limit(void);

void vshape_update_rate_limit(void)
{
    struct net_device *devs[2] = { vshapeA_dev, vshapeB_dev };
    int i;
    for (i = 0; i < 2; i++) {
        struct vshape_priv *vp;
        unsigned long flags;

        if (!devs[i])
            continue;

        vp = vshape_priv(devs[i]);
        spin_lock_irqsave(&vp->queue_lock, flags);

        if (param_rate_kbps) {
            u64 bytes_per_sec = (u64)param_rate_kbps * 125ULL;
            u64 bytes_per_ms = bytes_per_sec / 1000ULL;
            if (!bytes_per_ms) bytes_per_ms = 1;
            vp->rate_bytes_per_ms = bytes_per_ms;
            vp->bucket_capacity_bytes = vp->rate_bytes_per_ms * (u64)param_burst_ms;
        } else {
            vp->rate_bytes_per_ms = 0;
            vp->bucket_capacity_bytes = 0;
        }
        vp->bucket_tokens = vp->bucket_capacity_bytes;
        vp->last_bucket_update = ktime_get();

        spin_unlock_irqrestore(&vp->queue_lock, flags);

        pr_info("%s: rate=%u kbps burst=%u ms -> %llu B/ms cap=%llu\n",
                devs[i]->name, param_rate_kbps, param_burst_ms,
                (unsigned long long)vp->rate_bytes_per_ms,
                (unsigned long long)vp->bucket_capacity_bytes);
    }
}
EXPORT_SYMBOL_GPL(vshape_update_rate_limit); /* optional if used by netlink.c */

/* ---------- netlink hooks (extern) ---------- */
extern int vshape_nl_init(void);
extern void vshape_nl_exit(void);

/* ---------- init helpers ---------- */
static int vshape_init_one(struct net_device **pdev, const char *namepat)
{
    struct net_device *dev;
    struct vshape_priv *vp;

    dev = alloc_netdev(sizeof(struct vshape_priv), namepat, NET_NAME_UNKNOWN, vshape_setup);
    if (!dev)
        return -ENOMEM;

    vp = vshape_priv(dev);
    memset(vp, 0, sizeof(*vp));
    vp->dev = dev;

    INIT_LIST_HEAD(&vp->tx_queue);
    spin_lock_init(&vp->queue_lock);
    hrtimer_init(&vp->tx_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    vp->tx_timer.function = vshape_tx_timer_fn;

    if (param_rate_kbps) {
        u64 bytes_per_sec = (u64)param_rate_kbps * 125ULL;
        u64 bytes_per_ms = bytes_per_sec / 1000ULL;
        if (!bytes_per_ms) bytes_per_ms = 1;
        vp->rate_bytes_per_ms = bytes_per_ms;
        vp->bucket_capacity_bytes = vp->rate_bytes_per_ms * (u64)param_burst_ms;
    } else {
        vp->rate_bytes_per_ms = 0;
        vp->bucket_capacity_bytes = 0;
    }
    vp->bucket_tokens = vp->bucket_capacity_bytes;
    vp->last_bucket_update = ktime_get();

    u64_stats_init(&vp->stats_sync);

    *pdev = dev;
    return 0;
}

/* ---------- init/exit: create pair ---------- */
static int __init vshape_init(void)
{
    int err;

    err = vshape_init_one(&vshapeA_dev, "vshapeA%d");
    if (err)
        return err;

    err = vshape_init_one(&vshapeB_dev, "vshapeB%d");
    if (err) {
        free_netdev(vshapeA_dev);
        vshapeA_dev = NULL;
        return err;
    }

    /* link peers (cast netdev_priv to our priv type) */
    vshape_priv(vshapeA_dev)->peer = vshapeB_dev;
    vshape_priv(vshapeB_dev)->peer = vshapeA_dev;

    /* register */
    err = register_netdev(vshapeA_dev);
    if (err) {
        pr_err("register %s failed: %d\n", vshapeA_dev->name, err);
        free_netdev(vshapeA_dev);
        free_netdev(vshapeB_dev);
        vshapeA_dev = vshapeB_dev = NULL;
        return err;
    }

    err = register_netdev(vshapeB_dev);
    if (err) {
        pr_err("register %s failed: %d\n", vshapeB_dev->name, err);
        unregister_netdev(vshapeA_dev);
        free_netdev(vshapeA_dev);
        free_netdev(vshapeB_dev);
        vshapeA_dev = vshapeB_dev = NULL;
        return err;
    }

    err = vshape_nl_init();
    if (err) {
        pr_err("netlink init failed: %d\n", err);
        unregister_netdev(vshapeB_dev);
        unregister_netdev(vshapeA_dev);
        free_netdev(vshapeB_dev);
        free_netdev(vshapeA_dev);
        vshapeA_dev = vshapeB_dev = NULL;
        return err;
    }

    pr_info("pair created: %s <-> %s  delay=%u ms jitter=%u ms loss=%u ppm rate=%u kbps burst=%u ms passthrough=%u maxq=%u\n",
            vshapeA_dev->name, vshapeB_dev->name,
            param_delay_ms, param_jitter_ms, param_loss_ppm,
            param_rate_kbps, param_burst_ms, param_passthrough, param_max_queue);

    return 0;
}

static void free_end(struct net_device **pdev)
{
    struct vshape_priv *vp;
    struct vshape_qitem *q, *tmp;
    unsigned int freed = 0;

    if (!*pdev)
        return;

    vp = vshape_priv(*pdev);

    hrtimer_cancel(&vp->tx_timer);
    spin_lock(&vp->queue_lock);
    list_for_each_entry_safe(q, tmp, &vp->tx_queue, list) {
        list_del(&q->list);
        if (vp->queue_len)
            vp->queue_len--;
        dev_kfree_skb(q->skb);
        kfree(q);
        freed++;
    }
    spin_unlock(&vp->queue_lock);
    if (freed)
        pr_info("%s: freed %u queued skbs\n", (*pdev)->name, freed);

    unregister_netdev(*pdev);
    free_netdev(*pdev);
    *pdev = NULL;
}

static void __exit vshape_exit(void)
{
    pr_info("removing pair: %s <-> %s\n",
            vshapeA_dev ? vshapeA_dev->name : "(none)",
            vshapeB_dev ? vshapeB_dev->name : "(none)");

    vshape_nl_exit();
    free_end(&vshapeA_dev);
    free_end(&vshapeB_dev);
}

module_init(vshape_init);
module_exit(vshape_exit);
