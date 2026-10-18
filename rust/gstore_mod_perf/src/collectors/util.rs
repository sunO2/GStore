//! 通用 I/O 与数值换算工具。
//!
//! 所有采集器共享：安全读文件（缺失返回 `None`，绝不 panic）、人类可读大小、
//! 单位换算与 `libc` 探针（页大小 / 时钟频率）。

/// 读取文本文件；文件缺失/不可读/非 UTF-8 均返回 `None`（读 `/proc`/`/sys` 的常态）。
pub fn read_file(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

/// 读取并去除首尾空白；空白结果视为 `None`。
pub fn read_trimmed(path: &str) -> Option<String> {
    read_file(path)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// 读取文件首行（去空白）。
pub fn read_first_line(path: &str) -> Option<String> {
    read_file(path)?.lines().next().map(|s| s.trim().to_string())
}

/// 读取整数值（trim 后按 i64 解析）。
pub fn read_i64(path: &str) -> Option<i64> {
    read_trimmed(path)?.parse::<i64>().ok()
}

/// 取字符串中的第一个整型 token（sysfs 常见 `"350000"`、`"1 2 3"`、`"300000 %"`）。
pub fn first_token_i64(s: &str) -> Option<i64> {
    s.split_whitespace().next()?.parse::<i64>().ok()
}

/// 去掉可能的 `%` 后缀后解析整数（`/sys/.../gpu_busy_percentage`）。
pub fn percent_token_i64(s: &str) -> Option<i64> {
    first_token_i64(s.trim().trim_end_matches('%'))
}

/// 将百分比限制到 `[0, 100]`。
pub fn clamp_percent(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(0.0, 100.0)
    }
}

/// KiB → 人类可读字符串（B/KB/MB/GB/TB，1024 进制，保留两位小数）。
pub fn human_kb(kib: u64) -> String {
    let bytes = kib as f64 * 1024.0;
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.2} {}", UNITS[unit])
    }
}

/// 系统页大小（KiB）。`sysconf` 失败回退 4 KiB。
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn page_size_kb() -> u64 {
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if size <= 0 {
        4
    } else {
        size as u64 / 1024
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn page_size_kb() -> u64 {
    4
}

/// 时钟节拍/秒（`_SC_CLK_TCK`）。失败回退 100。
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn clock_ticks_per_sec() -> u64 {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if hz <= 0 {
        100
    } else {
        hz as u64
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn clock_ticks_per_sec() -> u64 {
    100
}

/// 单调毫秒时间戳（用于采样速率计算，非墙钟）。
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// `getprop <key>`（Android 专用）。其他平台返回 `None`，绝不启动外部进程。
#[cfg(target_os = "android")]
pub fn getprop(key: &str) -> Option<String> {
    let out = std::process::Command::new("getprop").arg(key).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(not(target_os = "android"))]
pub fn getprop(_key: &str) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_kb_scales_across_units() {
        assert_eq!(human_kb(0), "0 B");
        assert_eq!(human_kb(1), "1.00 KB");
        assert_eq!(human_kb(1024), "1.00 MB");
        assert_eq!(human_kb(1024 * 1024), "1.00 GB");
        assert_eq!(human_kb(1024 * 1024 * 1024), "1.00 TB");
    }

    #[test]
    fn first_token_parses_sysfs_shapes() {
        assert_eq!(first_token_i64("350000\n"), Some(350000));
        assert_eq!(first_token_i64("300000 %"), Some(300000));
        assert_eq!(first_token_i64(""), None);
        assert_eq!(percent_token_i64("42%\n"), Some(42));
        assert_eq!(percent_token_i64("100"), Some(100));
    }

    #[test]
    fn clamp_percent_guards_nan_and_range() {
        assert_eq!(clamp_percent(-5.0), 0.0);
        assert_eq!(clamp_percent(150.0), 100.0);
        assert_eq!(clamp_percent(f64::NAN), 0.0);
        assert_eq!(clamp_percent(42.5), 42.5);
    }

    #[test]
    fn probes_return_plausible_values() {
        assert!(page_size_kb() >= 1);
        assert!(clock_ticks_per_sec() >= 1);
    }
}
