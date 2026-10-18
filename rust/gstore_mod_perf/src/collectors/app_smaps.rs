//! `/proc/<pid>/smaps_rollup` 精确内存分解解析（`perf.parse_app_dumps` 的 `smaps` 段）。
//!
//! **纯解析**：输入为宿主经 Shizuku 读取 `cat /proc/<pid>/smaps_rollup` 得到的原始文本，
//! 本模块不启动 shell、不做 JNI、不需要特权，绝不 panic。输入可能是**多个进程的
//! smaps_rollup 块拼接**（应用常有多进程），故对每个字段**跨块求和**。识别不到任何
//! 字段 → `None`（JSON `null`）。
//!
//! 字段行形如 `Rss:             150000 kB`（`Rss:`/`Pss:`/`Shared_Clean:`/`Shared_Dirty:`/
//! `Private_Clean:`/`Private_Dirty:`），值单位为 `kB`，输出单位同为 `kB`。
//! 注意 `Pss_Dirty`/`Rss_Anon` 等带下划线的变体**不**匹配（标签含冒号，必须精确）。

use serde::Serialize;

use crate::collectors::app_dumps::{after_label, first_uint};

/// `smaps_rollup` 的内存分项（跨块求和，单位 KiB）。某分项从未出现 → `None`。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct SmapsStats {
    pub pss_kb: Option<u64>,
    pub rss_kb: Option<u64>,
    pub shared_clean_kb: Option<u64>,
    pub shared_dirty_kb: Option<u64>,
    pub private_clean_kb: Option<u64>,
    pub private_dirty_kb: Option<u64>,
}

/// 某标签行的值（`label` 精确出现时取其后首个整数）；标签不存在 → `None`。
fn sum_after(text: &str, label: &str) -> Option<u64> {
    let mut sum: u64 = 0;
    let mut found = false;
    for line in text.lines() {
        if let Some(v) = after_label(line, label).and_then(first_uint) {
            sum = sum.saturating_add(v);
            found = true;
        }
    }
    found.then_some(sum)
}

/// 解析 `smaps_rollup` 文本；无任何已知字段 → `None`。
pub fn parse_smaps(text: &str) -> Option<SmapsStats> {
    let stats = SmapsStats {
        pss_kb: sum_after(text, "Pss:"),
        rss_kb: sum_after(text, "Rss:"),
        shared_clean_kb: sum_after(text, "Shared_Clean:"),
        shared_dirty_kb: sum_after(text, "Shared_Dirty:"),
        private_clean_kb: sum_after(text, "Private_Clean:"),
        private_dirty_kb: sum_after(text, "Private_Dirty:"),
    };
    let any = stats.pss_kb.is_some()
        || stats.rss_kb.is_some()
        || stats.shared_clean_kb.is_some()
        || stats.shared_dirty_kb.is_some()
        || stats.private_clean_kb.is_some()
        || stats.private_dirty_kb.is_some();
    any.then_some(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个进程的 smaps_rollup 拼接（真实字段 + 地址头 + 无关 `_Dirty` 变体）。
    const SAMPLE: &str = "\
5f000000-7f000000 rw-p 00000000 00:00 0                          [stack]
Size:             200000 kB
KernelPageSize:        4 kB
MMUPageSize:           4 kB
Rss:              150000 kB
Pss:              123456 kB
Pss_Dirty:         50000 kB
Shared_Clean:       1000 kB
Shared_Dirty:          4 kB
Private_Clean:      2000 kB
Private_Dirty:     50000 kB
Referenced:       140000 kB
Anonymous:         51000 kB
5f000000-7f000000 rw-p 00000000 00:00 0
Rss:               10000 kB
Pss:                8000 kB
Shared_Clean:        500 kB
Shared_Dirty:          0 kB
Private_Clean:       100 kB
Private_Dirty:      7000 kB
";

    #[test]
    fn sums_fields_across_multiple_process_blocks() {
        let s = parse_smaps(SAMPLE).unwrap();
        assert_eq!(s.rss_kb, Some(160_000)); // 150000 + 10000
        assert_eq!(s.pss_kb, Some(131_456)); // 123456 + 8000（Pss_Dirty 不误配）
        assert_eq!(s.shared_clean_kb, Some(1_500));
        assert_eq!(s.shared_dirty_kb, Some(4));
        assert_eq!(s.private_clean_kb, Some(2_100));
        assert_eq!(s.private_dirty_kb, Some(57_000));
    }

    #[test]
    fn single_block_without_shared_fields_yields_nulls() {
        let text = "Rss: 4096 kB\nPss: 2048 kB\n";
        let s = parse_smaps(text).unwrap();
        assert_eq!(s.rss_kb, Some(4096));
        assert_eq!(s.pss_kb, Some(2048));
        assert_eq!(s.shared_clean_kb, None);
        assert_eq!(s.shared_dirty_kb, None);
        assert_eq!(s.private_clean_kb, None);
        assert_eq!(s.private_dirty_kb, None);
    }

    #[test]
    fn underscore_suffixes_are_not_matched() {
        // 只有 Pss_Anon/Rss_Anon 这类变体时不应误配裸标签（标签含冒号）。
        let text = "Pss_Anon: 100 kB\nRss_Anon: 200 kB\n";
        assert_eq!(parse_smaps(text), None);
    }

    #[test]
    fn unrecognisable_or_empty_input_is_none() {
        assert_eq!(parse_smaps(""), None);
        assert_eq!(parse_smaps("garbage\nno smaps fields\n"), None);
    }
}
