//! 设备身份采集：`/proc/version`、`/proc/cpuinfo`、`/proc/loadavg`、`getprop`、
//! `os-release` 回退。
//!
//! 关键映射 `map_cpu_hardware_to_name` 复刻参考 App 的 SoC 关键字表（PERF_SPEC §3.6）。

use serde::Serialize;

use super::cpu::{self, LoadAvg};
use super::util;

/// SoC `hardware` 串 → 可读处理器名（关键字表）。
pub fn map_cpu_hardware_to_name(hw: &str) -> String {
    let h = hw.to_ascii_lowercase();

    // 先匹配各厂独有 SoC 代号（无需厂商前缀即可识别）。
    const QCOM: &[(&str, &str)] = &[
        ("lahaina", "Snapdragon 888"),
        ("kona", "Snapdragon 865"),
        ("msmnile", "Snapdragon 855"),
        ("sm8450", "Snapdragon 8 Gen 1"),
        ("sm8350", "高通骁龙处理器"),
    ];
    const MTK: &[(&str, &str)] = &[
        ("mt6893", "联发科天玑1200"),
        ("dimensity 1200", "联发科天玑1200"),
        ("mt6885", "联发科天玑1000"),
        ("dimensity 1000", "联发科天玑1000"),
    ];
    for (key, name) in QCOM.iter().chain(MTK.iter()) {
        if h.contains(key) {
            return (*name).to_string();
        }
    }

    if h.contains("qcom") || h.contains("snapdragon") {
        return "高通骁龙处理器".to_string();
    }
    if h.contains("mt") || h.contains("mediatek") || h.contains("dimensity") {
        return "联发科处理器".to_string();
    }
    if h.contains("exynos") {
        return if h.contains("2100") {
            "Exynos 2100".to_string()
        } else if h.contains("990") {
            "Exynos 990".to_string()
        } else {
            "三星Exynos处理器".to_string()
        };
    }
    if h.contains("kirin") {
        return if h.contains("9000") {
            "麒麟9000".to_string()
        } else if h.contains("990") {
            "麒麟990".to_string()
        } else {
            "华为麒麟处理器".to_string()
        };
    }
    hw.to_string()
}

/// 解析 `/proc/cpuinfo` 的处理器标识：`Hardware`（命中即停）优先，其次
/// `model name` / `Processor`（键名精确匹配，避免 x86 逐核小写 `processor: 0` 污染）。
pub fn parse_cpuinfo_hardware(content: &str) -> Option<String> {
    let mut acc: Vec<String> = Vec::new();
    for line in content.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        if key == "Hardware" {
            acc.push(value.to_string());
            break;
        }
        if key == "model name" || key == "Processor" {
            acc.push(value.to_string());
        }
    }
    if acc.is_empty() {
        None
    } else {
        Some(acc.join(" "))
    }
}

/// 解析 `os-release` 的 `PRETTY_NAME=`。
pub fn parse_os_release(content: &str) -> Option<String> {
    content.lines().find_map(|l| {
        l.strip_prefix("PRETTY_NAME=")
            .map(|v| v.trim().trim_matches('"').to_string())
            .filter(|v| !v.is_empty())
    })
}

/// 设备报告（缺省字段为 `null`）。
#[derive(Debug, Clone, Serialize)]
pub struct DeviceReport {
    pub kernel_version: Option<String>,
    pub hardware: Option<String>,
    pub cpu_name: Option<String>,
    pub model: Option<String>,
    pub android_release: Option<String>,
    pub board_platform: Option<String>,
    pub core_count: usize,
    pub loadavg: Option<LoadAvg>,
    pub os_release: Option<String>,
}

/// 采集设备身份。
pub fn collect() -> DeviceReport {
    let cpuinfo = util::read_file("/proc/cpuinfo").unwrap_or_default();
    let hardware = parse_cpuinfo_hardware(&cpuinfo);
    let cpu_name = hardware.as_deref().map(map_cpu_hardware_to_name);

    DeviceReport {
        kernel_version: util::read_first_line("/proc/version"),
        cpu_name,
        hardware,
        model: util::getprop("ro.product.model"),
        android_release: util::getprop("ro.build.version.release"),
        board_platform: util::getprop("ro.board.platform"),
        core_count: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
        loadavg: util::read_file("/proc/loadavg").and_then(|c| cpu::parse_loadavg(&c)),
        os_release: util::read_file("/etc/os-release").and_then(|c| parse_os_release(&c)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_qualcomm_hardware() {
        assert_eq!(map_cpu_hardware_to_name("lahaina"), "Snapdragon 888");
        assert_eq!(map_cpu_hardware_to_name("kona"), "Snapdragon 865");
        assert_eq!(map_cpu_hardware_to_name("msmnile"), "Snapdragon 855");
        assert_eq!(map_cpu_hardware_to_name("qcom,foo"), "高通骁龙处理器");
    }

    #[test]
    fn maps_mediatek_exynos_kirin_and_falls_back() {
        assert_eq!(map_cpu_hardware_to_name("MT6893"), "联发科天玑1200");
        assert_eq!(map_cpu_hardware_to_name("exynos2100"), "Exynos 2100");
        assert_eq!(map_cpu_hardware_to_name("kirin9000"), "麒麟9000");
        assert_eq!(map_cpu_hardware_to_name("some-weird-soc"), "some-weird-soc");
    }

    #[test]
    fn parse_cpuinfo_hardware_stops_at_hardware_line() {
        let cpuinfo = "Processor\t: AArch64 Processor rev 14\n\
             model name\t: ARMv8\n\
             Hardware\t: Qualcomm Technologies, Inc SM8350\n\
             Revision\t: 0000\n";
        assert_eq!(
            parse_cpuinfo_hardware(cpuinfo).as_deref(),
            Some("AArch64 Processor rev 14 ARMv8 Qualcomm Technologies, Inc SM8350")
        );
    }

    #[test]
    fn parse_cpuinfo_hardware_returns_none_when_absent() {
        assert!(parse_cpuinfo_hardware("processor\t: 0\n").is_none());
    }

    #[test]
    fn os_release_pretty_name_is_parsed() {
        assert_eq!(
            parse_os_release("NAME=Android\nPRETTY_NAME=\"Android 14\"\n").as_deref(),
            Some("Android 14")
        );
        assert!(parse_os_release("NAME=Linux\n").is_none());
    }
}
