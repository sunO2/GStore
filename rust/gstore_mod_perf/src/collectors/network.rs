//! 网络采集（增强）：解析 `/proc/net/dev`，基于上次样本计算 RX/TX 字节速率。
//!
//! 参考 App 完全没有实时吞吐（`TrafficStats` 仅存在于死代码），本模块补齐。

use serde::Serialize;

use super::util;

/// 单个网络接口计数器（累计字节/包）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NetIface {
    pub name: String,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_errs: u64,
    pub tx_errs: u64,
    pub rx_drop: u64,
    pub tx_drop: u64,
    pub rx_fifo: u64,
    pub rx_frame: u64,
    pub rx_compressed: u64,
    pub multicast: u64,
    pub tx_fifo: u64,
    pub tx_compressed: u64,
}

/// 一次 `/proc/net/dev` 采样。
#[derive(Debug, Clone, PartialEq)]
pub struct NetSample {
    pub ts_ms: u64,
    pub ifaces: Vec<NetIface>,
}

impl NetSample {
    pub fn find(&self, name: &str) -> Option<&NetIface> {
        self.ifaces.iter().find(|i| i.name == name)
    }
}

fn parse_u64(tokens: &[&str], idx: usize) -> u64 {
    tokens.get(idx).and_then(|t| t.parse::<u64>().ok()).unwrap_or(0)
}

/// 解析 `/proc/net/dev`（跳过两行表头）。
pub fn parse_proc_net_dev(content: &str) -> Vec<NetIface> {
    let mut out = Vec::new();
    for line in content.lines() {
        let Some((name, rest)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let tokens: Vec<&str> = rest.split_whitespace().collect();
        if tokens.len() < 16 {
            continue;
        }
        out.push(NetIface {
            name: name.to_string(),
            rx_bytes: parse_u64(&tokens, 0),
            rx_packets: parse_u64(&tokens, 1),
            rx_errs: parse_u64(&tokens, 2),
            rx_drop: parse_u64(&tokens, 3),
            rx_fifo: parse_u64(&tokens, 4),
            rx_frame: parse_u64(&tokens, 5),
            rx_compressed: parse_u64(&tokens, 6),
            multicast: parse_u64(&tokens, 7),
            tx_bytes: parse_u64(&tokens, 8),
            tx_packets: parse_u64(&tokens, 9),
            tx_errs: parse_u64(&tokens, 10),
            tx_drop: parse_u64(&tokens, 11),
            tx_fifo: parse_u64(&tokens, 12),
            tx_compressed: parse_u64(&tokens, 15),
        });
    }
    out
}

/// 每接口速率（`bytes` 为累计，`*_per_sec` 为两次样本间的平均速率）。
#[derive(Debug, Clone, Serialize)]
pub struct IfaceRate {
    pub name: String,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
    pub rx_errors: u64,
    pub tx_errors: u64,
    pub rx_dropped: u64,
    pub tx_dropped: u64,
    pub rx_fifo: u64,
    pub tx_fifo: u64,
    pub rx_frame: u64,
    pub rx_compressed: u64,
    pub tx_compressed: u64,
    pub multicast: u64,
}

/// 网络报告（顶层为所有接口合计）。
#[derive(Debug, Clone, Serialize)]
pub struct NetworkReport {
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
    pub interfaces: Vec<IfaceRate>,
}

fn rate(delta_bytes: u64, dt_sec: f64) -> f64 {
    if dt_sec <= 0.0 {
        0.0
    } else {
        delta_bytes as f64 / dt_sec
    }
}

/// 由上次/本次样本计算速率；`prev` 为 `None` 或 `dt<=0` 时速率为 0。
pub fn compute_rates(prev: Option<&NetSample>, cur: &NetSample) -> NetworkReport {
    let dt_sec = prev
        .map(|p| (cur.ts_ms.saturating_sub(p.ts_ms)) as f64 / 1000.0)
        .unwrap_or(0.0);
    let mut interfaces = Vec::with_capacity(cur.ifaces.len());
    for iface in &cur.ifaces {
        let p = prev.and_then(|s| s.find(&iface.name));
        let (drx, dtx) = match p {
            Some(p) => (
                iface.rx_bytes.saturating_sub(p.rx_bytes),
                iface.tx_bytes.saturating_sub(p.tx_bytes),
            ),
            None => (0, 0),
        };
        interfaces.push(IfaceRate {
            name: iface.name.clone(),
            rx_bytes: iface.rx_bytes,
            tx_bytes: iface.tx_bytes,
            rx_packets: iface.rx_packets,
            tx_packets: iface.tx_packets,
            rx_bytes_per_sec: rate(drx, dt_sec),
            tx_bytes_per_sec: rate(dtx, dt_sec),
            rx_errors: iface.rx_errs,
            tx_errors: iface.tx_errs,
            rx_dropped: iface.rx_drop,
            tx_dropped: iface.tx_drop,
            rx_fifo: iface.rx_fifo,
            tx_fifo: iface.tx_fifo,
            rx_frame: iface.rx_frame,
            rx_compressed: iface.rx_compressed,
            tx_compressed: iface.tx_compressed,
            multicast: iface.multicast,
        });
    }
    let rx_bytes = interfaces.iter().map(|i| i.rx_bytes).sum();
    let tx_bytes = interfaces.iter().map(|i| i.tx_bytes).sum();
    let rx_bytes_per_sec = interfaces.iter().map(|i| i.rx_bytes_per_sec).sum();
    let tx_bytes_per_sec = interfaces.iter().map(|i| i.tx_bytes_per_sec).sum();
    NetworkReport {
        rx_bytes,
        tx_bytes,
        rx_bytes_per_sec,
        tx_bytes_per_sec,
        interfaces,
    }
}

/// 采集一次样本（`/proc/net/dev` + 时间戳）。
pub fn sample() -> NetSample {
    let ifaces = util::read_file("/proc/net/dev")
        .map(|c| parse_proc_net_dev(&c))
        .unwrap_or_default();
    NetSample {
        ts_ms: util::now_ms(),
        ifaces,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NET_DEV: &str = "Inter-|   Receive                                                |  Transmit\n\
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n\
            lo: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n\
          wlan0: 500000 400 1 2 0 0 0 0 800000 500 3 4 0 0 0 0\n";

    #[test]
    fn parse_proc_net_dev_reads_rx_tx() {
        let ifaces = parse_proc_net_dev(NET_DEV);
        assert_eq!(ifaces.len(), 2);
        let lo = &ifaces[0];
        assert_eq!(lo.name, "lo");
        assert_eq!(lo.rx_bytes, 1000);
        assert_eq!(lo.tx_bytes, 2000);
        assert_eq!(lo.rx_packets, 10);
        let wlan = &ifaces[1];
        assert_eq!(wlan.name, "wlan0");
        assert_eq!(wlan.rx_bytes, 500_000);
        assert_eq!(wlan.tx_bytes, 800_000);
        assert_eq!(wlan.rx_errs, 1);
        assert_eq!(wlan.tx_drop, 4);
    }

    #[test]
    fn parse_proc_net_dev_reads_full_error_columns() {
        // 列序：rx bytes packets errs drop fifo frame compressed multicast |
        //       tx bytes packets errs drop fifo colls carrier compressed
        let ifaces = parse_proc_net_dev(
            "eth0: 1000 10 1 2 3 4 5 6 2000 20 7 8 9 10 11 12\n",
        );
        let e = &ifaces[0];
        assert_eq!(e.rx_errs, 1);
        assert_eq!(e.rx_drop, 2);
        assert_eq!(e.rx_fifo, 3);
        assert_eq!(e.rx_frame, 4);
        assert_eq!(e.rx_compressed, 5);
        assert_eq!(e.multicast, 6);
        assert_eq!(e.tx_errs, 7);
        assert_eq!(e.tx_drop, 8);
        assert_eq!(e.tx_fifo, 9);
        assert_eq!(e.tx_compressed, 12);
    }

    #[test]
    fn compute_rates_surfaces_error_and_drop_columns() {
        let cur = NetSample {
            ts_ms: 1,
            ifaces: parse_proc_net_dev(
                "eth0: 1000 10 1 2 3 4 5 6 2000 20 7 8 9 10 11 12\n",
            ),
        };
        let rep = compute_rates(None, &cur);
        let e = &rep.interfaces[0];
        assert_eq!(e.rx_errors, 1);
        assert_eq!(e.tx_errors, 7);
        assert_eq!(e.rx_dropped, 2);
        assert_eq!(e.tx_dropped, 8);
        assert_eq!(e.rx_fifo, 3);
        assert_eq!(e.tx_fifo, 9);
        assert_eq!(e.rx_frame, 4);
        assert_eq!(e.rx_compressed, 5);
        assert_eq!(e.tx_compressed, 12);
        assert_eq!(e.multicast, 6);
    }

    #[test]
    fn compute_rates_uses_delta_and_dt() {
        let prev = NetSample {
            ts_ms: 10_000,
            ifaces: parse_proc_net_dev(NET_DEV),
        };
        let cur = NetSample {
            ts_ms: 12_000, // dt = 2s
            ifaces: parse_proc_net_dev(
                "lo: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n\
                 wlan0: 502000 400 1 2 0 0 0 0 804000 500 3 4 0 0 0 0\n",
            ),
        };
        let rep = compute_rates(Some(&prev), &cur);
        let wlan = rep.interfaces.iter().find(|i| i.name == "wlan0").unwrap();
        // Δrx = 2000 bytes over 2s → 1000 B/s; Δtx = 4000 over 2s → 2000 B/s
        assert!((wlan.rx_bytes_per_sec - 1000.0).abs() < 1e-6);
        assert!((wlan.tx_bytes_per_sec - 2000.0).abs() < 1e-6);
        assert!((rep.rx_bytes_per_sec - 1000.0).abs() < 1e-6);
        assert!((rep.tx_bytes_per_sec - 2000.0).abs() < 1e-6);
    }

    #[test]
    fn compute_rates_without_prev_is_zero() {
        let cur = NetSample {
            ts_ms: 1,
            ifaces: parse_proc_net_dev(NET_DEV),
        };
        let rep = compute_rates(None, &cur);
        assert_eq!(rep.rx_bytes_per_sec, 0.0);
        assert_eq!(rep.tx_bytes_per_sec, 0.0);
    }

    #[test]
    fn counter_reset_does_not_underflow() {
        let prev = NetSample {
            ts_ms: 1000,
            ifaces: parse_proc_net_dev("eth0: 999999 1 0 0 0 0 0 0 999999 1 0 0 0 0 0 0\n"),
        };
        let cur = NetSample {
            ts_ms: 2000,
            ifaces: parse_proc_net_dev("eth0: 5 1 0 0 0 0 0 0 5 1 0 0 0 0 0 0\n"),
        };
        let rep = compute_rates(Some(&prev), &cur);
        assert_eq!(rep.interfaces[0].rx_bytes_per_sec, 0.0);
    }
}
