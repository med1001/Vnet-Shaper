/*
 * vnet_shape.c – Virtual NIC that emulates latency, jitter, loss & rate-limit
 * Logging in hot paths is compiled out by default. Define VNET_SHAPE_DEBUG
 * at build time to include verbose/rate-limited debug messages.
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

MODULE_AUTHOR("Your Name <you@example.com>");
MODULE_DESCRIPTION("Virtual NIC with latency, jitter, loss, and rate-limit shaping");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0");

/* ---------- Tunables (defaults) ---------- */
unsigned int param_delay_ms = 50;
unsigned int param_jitter_ms = 5;
unsigned int param_loss_ppm = 0;
unsigned int param_rate_kbps = 100000;
/* burst window in ms used to size the token bucket capacity (avoid huge 1s burst) */
unsigned int param_burst_ms = 100;
/* runtime debug flag - meaningful only if compiled with VNET_SHAPE_DEBUG */
bool param_debug = false;

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
MODULE_PARM_DESC(param_debug, "Enable additional rate-limited debug prints (only if built with VNET_SHAPE_DEBUG)");

/*
 * If VNET_SHAPE_DEBUG is defined at compile time, HOTLOG/PRDEBUG emit
 * (rate-limited) messages. Otherwise they compile to nothing and the
 * corresponding format strings do not end up in the .ko.
 */
#ifdef VNET_SHAPE_DEBUG
#define HOTLOG(fmt, ...) \
    do { if (param_debug) pr_info_ratelimited(fmt, ##__VA_ARGS__); } while (0)
#define PRDEBUG(fmt, ...) pr_debug(fmt, ##__VA_ARGS__)
#else
#define HOTLOG(fmt, ...) do { } while (0)
#define PRDEBUG(fmt, ...) do { } while (0)
#endif

/* ---------- Internal structures ---------- */
struct vshape_priv {
    struct net_device *dev;
    struct list_head tx_queue;
    spinlock_t queue_lock;
    struct hrtimer tx_timer;

    /* Token bucket (ms granularity) */
    u64 rate_bytes_per_ms;
    u64 bucket_capacity_bytes;
    u64 bucket_tokens;
    ktime_t last_bucket_update;

    /* queue length for diagnostics */
    u32 queue_len;

    /* statistics (protected with u64_stats_sync) */
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

    /* convert to milliseconds elapsed */
    u64 ms = ns / 1000000ULL;
    if (ms == 0)
        return;

    /* add = rate_bytes_per_ms * ms */
    u64 add = vp->rate_bytes_per_ms * ms;

    if (add > vp->bucket_capacity_bytes)
        add = vp->bucket_capacity_bytes;

    vp->bucket_tokens = min((u64)(vp->bucket_tokens + add), vp->bucket_capacity_bytes);
    vp->last_bucket_update = now;

    PRDEBUG("bucket_update: added=%llu ms=%llu tokens=%llu capacity=%llu\n",
           (unsigned long long)add, (unsigned long long)ms,
           (unsigned long long)vp->bucket_tokens,
           (unsigned long long)vp->bucket_capacity_bytes);
}

static bool vshape_bucket_consume(struct vshape_priv *vp, size_t bytes)
{
    /* if rate_bytes_per_ms == 0 => unlimited */
    if (!vp->rate_bytes_per_ms)
        return true;

    vshape_bucket_update(vp);
    if (vp->bucket_tokens < bytes) {
        PRDEBUG("bucket_consume: insufficient tokens (%llu < %zu)\n",
                (unsigned long long)vp->bucket_tokens, bytes);
        return false;
    }

    vp->bucket_tokens -= bytes;
    PRDEBUG("bucket_consume: consumed=%zu tokens_left=%llu\n",
            bytes, (unsigned long long)vp->bucket_tokens);
    return true;
}

/* ---------- Packet drop logic ---------- */
static bool vshape_should_drop(void)
{
    if (!param_loss_ppm)
        return false;
    /* prandom_u32_max returns in [0, max-1] */
    u32 r = prandom_u32_max(1000000);
    bool drop = (r < param_loss_ppm);
    if (drop)
        HOTLOG("should_drop: random=%u loss_ppm=%u -> DROP\n", r, param_loss_ppm);
    return drop;
}

/* ---------- Timer dequeue (safer loop) ---------- */
static enum hrtimer_restart vshape_tx_timer_fn(struct hrtimer *timer)
{
    struct vshape_priv *vp = container_of(timer, struct vshape_priv, tx_timer);
    ktime_t now = ktime_get();
    int processed = 0;

    while (1) {
        struct vshape_qitem *qitem = NULL;

        spin_lock(&vp->queue_lock);
        if (list_empty(&vp->tx_queue)) {
            /* nothing queued */
            spin_unlock(&vp->queue_lock);
            break;
        }

        /* peek first queued item */
        qitem = list_first_entry(&vp->tx_queue, struct vshape_qitem, list);

        /* if not yet time to release, leave for later */
        if (ktime_after(qitem->release_time, now)) {
            spin_unlock(&vp->queue_lock);
            break;
        }

        /* if tokens available, remove and send; otherwise, keep and retry later */
        if (vshape_bucket_consume(vp, qitem->skb->len)) {
            list_del(&qitem->list);
            if (vp->queue_len)
                vp->queue_len--;
            /* we will process this item outside the lock */
            spin_unlock(&vp->queue_lock);

            /* prepare for reception into stack */
            qitem->skb->dev = vp->dev;
            qitem->skb->protocol = eth_type_trans(qitem->skb, vp->dev);

            PRDEBUG("tx_timer: re-injecting skb len=%u proto=0x%04x\n",
                    qitem->skb->len, ntohs(qitem->skb->protocol));
            netif_rx(qitem->skb);

            /* update rx counter safely */
            u64_stats_update_begin(&vp->stats_sync);
            vp->rx_packets++;
            u64_stats_update_end(&vp->stats_sync);

            kfree(qitem);
            processed++;
            /* continue loop to try next queued item */
        } else {
            /* Not enough tokens: schedule retry later; small summary log if debug enabled */
            HOTLOG("tx_timer: not enough tokens to send skb len=%u, will retry\n", qitem->skb->len);
            spin_unlock(&vp->queue_lock);
            break;
        }
    }

    if (processed)
        pr_info_ratelimited("tx_timer: processed %d packets (queue_len now %u)\n",
                            processed, vp->queue_len);

    /* if queue still has items, schedule next tick in 1ms */
    spin_lock(&vp->queue_lock);
    bool has_items = !list_empty(&vp->tx_queue);
    spin_unlock(&vp->queue_lock);

    if (has_items) {
        /* schedule next tick in 1ms relative to now */
        hrtimer_forward_now(timer, ms_to_ktime(1));
        return HRTIMER_RESTART;
    }

    return HRTIMER_NORESTART;
}

/* ---------- Packet transmit ---------- */
static netdev_tx_t vshape_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vshape_priv *vp = netdev_priv(dev);

    HOTLOG("start_xmit: called len=%u dev=%s\n", skb->len, dev->name);

    /* Drop if configured loss */
    if (vshape_should_drop()) {
        u64_stats_update_begin(&vp->stats_sync);
        vp->tx_dropped++;
        u64_stats_update_end(&vp->stats_sync);

        HOTLOG("start_xmit: dropping packet due to loss policy (len=%u)\n", skb->len);
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    /* Avoid sending frames with our own source MAC (bridge warning)
     * If source MAC equals device MAC, copy and tweak last byte of source
     * to avoid "received packet on dev with own address" bridge warnings.
     *
     * Use skb_copy(skb, GFP_ATOMIC) to ensure a private, writable copy.
     */
    if (skb_mac_header_was_set(skb) && skb_mac_header_len(skb) >= ETH_HLEN) {
        struct ethhdr *eth = eth_hdr(skb);
        if (ether_addr_equal(eth->h_source, dev->dev_addr)) {
            HOTLOG("start_xmit: source MAC matches device MAC, copying skb and tweaking\n");
            struct sk_buff *nskb = skb_copy(skb, GFP_ATOMIC);
            if (!nskb) {
                pr_warn("start_xmit: skb_copy failed, dropping\n");
                dev_kfree_skb(skb);
                return NETDEV_TX_OK;
            }
            /* free original and replace with copy */
            dev_kfree_skb(skb);
            skb = nskb;
            eth = eth_hdr(skb);
            eth->h_source[5] ^= 0x01; /* tweak last byte */
            HOTLOG("start_xmit: tweaked source MAC -> %pM\n", eth->h_source);
        }
    }

    /* compute jitter and release time */
    s32 jitter = (param_jitter_ms) ? (s32)prandom_u32_max(param_jitter_ms * 2) - (s32)param_jitter_ms : 0;
    ktime_t delay = ms_to_ktime(param_delay_ms + jitter);
    ktime_t release_time = ktime_add(ktime_get(), delay);

    struct vshape_qitem *qitem = kmalloc(sizeof(*qitem), GFP_ATOMIC);
    if (!qitem) {
        pr_warn("start_xmit: kmalloc failed, dropping skb\n");
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    qitem->skb = skb;
    qitem->release_time = release_time;

    spin_lock(&vp->queue_lock);
    list_add_tail(&qitem->list, &vp->tx_queue);
    vp->queue_len++;
    /* update tx counter safely */
    u64_stats_update_begin(&vp->stats_sync);
    vp->tx_packets++;
    u64_stats_update_end(&vp->stats_sync);

    HOTLOG("start_xmit: enqueued skb len=%u release_ms=%lld total_queued=%u\n",
           skb->len, (long long)ktime_to_ms(delay), vp->queue_len);

    /* if timer not queued, start it to fire at 'delay' from now */
    if (!hrtimer_is_queued(&vp->tx_timer)) {
        HOTLOG("start_xmit: starting hrtimer for next release (delay_ms=%lld)\n",
               (long long)ktime_to_ms(delay));
        hrtimer_start(&vp->tx_timer, delay, HRTIMER_MODE_REL);
    }
    spin_unlock(&vp->queue_lock);

    return NETDEV_TX_OK;
}

/* ---------- Net device ops ---------- */
static int vshape_open(struct net_device *dev)
{
    pr_info("netdev_open: %s\n", dev->name);
    netif_start_queue(dev);
    return 0;
}

static int vshape_stop(struct net_device *dev)
{
    pr_info("netdev_stop: %s\n", dev->name);
    netif_stop_queue(dev);
    return 0;
}

static void vshape_get_stats64(struct net_device *dev, struct rtnl_link_stats64 *stats)
{
    struct vshape_priv *vp = netdev_priv(dev);
    unsigned int seq;
    u64 t, d, r;

    do {
        seq = u64_stats_fetch_begin(&vp->stats_sync);
        t = vp->tx_packets;
        d = vp->tx_dropped;
        r = vp->rx_packets;
    } while (u64_stats_fetch_retry(&vp->stats_sync, seq));

    stats->tx_packets = t;
    stats->tx_dropped = d;
    stats->rx_packets = r;

    HOTLOG("get_stats64: tx=%llu tx_dropped=%llu rx=%llu\n",
           (unsigned long long)t, (unsigned long long)d, (unsigned long long)r);
}

static struct net_device *vshape_dev;

/* ---------- Exposed: runtime rate limit update ---------- */
void vshape_update_rate_limit(void)
{
    if (!vshape_dev) {
        pr_info("update_rate: no device present yet\n");
        return;
    }

    struct vshape_priv *vp = netdev_priv(vshape_dev);
    unsigned long flags;

    spin_lock_irqsave(&vp->queue_lock, flags);

    if (param_rate_kbps) {
        /* bytes_per_sec = kbps * 1000 / 8 = kbps * 125 */
        u64 bytes_per_sec = (u64)param_rate_kbps * 125ULL;
        u64 bytes_per_ms = bytes_per_sec / 1000ULL;
        if (bytes_per_ms == 0)
            bytes_per_ms = 1;

        vp->rate_bytes_per_ms = bytes_per_ms;
        /* bucket capacity = burst_ms worth of tokens (configurable) */
        vp->bucket_capacity_bytes = vp->rate_bytes_per_ms * (u64)param_burst_ms;
    } else {
        vp->rate_bytes_per_ms = 0;
        vp->bucket_capacity_bytes = 0;
    }

    vp->bucket_tokens = vp->bucket_capacity_bytes;
    vp->last_bucket_update = ktime_get();

    spin_unlock_irqrestore(&vp->queue_lock, flags);

    pr_info("Updated rate limiting: %u kbps burst=%u ms -> rate_bytes_per_ms=%llu capacity=%llu\n",
            param_rate_kbps, param_burst_ms,
            (unsigned long long)vp->rate_bytes_per_ms,
            (unsigned long long)vp->bucket_capacity_bytes);
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

    pr_info("vshape_setup: dev=%s mac=%pM\n", dev->name, dev->dev_addr);
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

    vp->queue_len = 0;

    /* Initialize token bucket using ms granularity */
    if (param_rate_kbps) {
        /* bytes_per_sec = kbps * 1000 / 8 = kbps * 125 */
        u64 bytes_per_sec = (u64)param_rate_kbps * 125ULL;
        u64 bytes_per_ms = bytes_per_sec / 1000ULL; /* integer division */

        /* avoid zero for tiny rates: at least 1 byte/ms */
        if (bytes_per_ms == 0)
            bytes_per_ms = 1;

        vp->rate_bytes_per_ms = bytes_per_ms;
        /* bucket capacity = burst_ms worth of tokens (configurable) */
        vp->bucket_capacity_bytes = vp->rate_bytes_per_ms * (u64)param_burst_ms;
    } else {
        vp->rate_bytes_per_ms = 0;
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

    pr_info("vshape0 created: name=%s delay=%u ms jitter=%u ms loss=%u ppm rate=%u kbps burst=%u ms\n",
            vshape_dev->name, param_delay_ms, param_jitter_ms, param_loss_ppm,
            param_rate_kbps, param_burst_ms);

    return 0;
}

static void __exit vshape_exit(void)
{
    struct vshape_priv *vp = netdev_priv(vshape_dev);
    struct vshape_qitem *qitem, *tmp;
    unsigned int freed = 0;

    pr_info("vshape_exit: tearing down device %s\n", vshape_dev->name);

    /* stop timer and flush queue */
    hrtimer_cancel(&vp->tx_timer);

    spin_lock(&vp->queue_lock);
    list_for_each_entry_safe(qitem, tmp, &vp->tx_queue, list) {
        list_del(&qitem->list);
        if (vp->queue_len)
            vp->queue_len--;
        dev_kfree_skb(qitem->skb);
        kfree(qitem);
        freed++;
    }
    spin_unlock(&vp->queue_lock);

    if (freed)
        pr_info("vshape_exit: freed %u queued skbs\n", freed);

    vshape_nl_exit();
    unregister_netdev(vshape_dev);
    free_netdev(vshape_dev);

    pr_info("vshape0 removed\n");
}

module_init(vshape_init);
module_exit(vshape_exit);
