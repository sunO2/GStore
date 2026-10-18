//! `dumpsys gfxinfo <pkg> framestats` 逐帧渲染解析（`perf.parse_app_dumps` 的 `render` 段）。
//!
//! **纯解析**：输入为宿主经 Shizuku 采集的原始文本，本模块不启动 shell、不做 JNI、
//! 不需要特权，绝不 panic。任何解析失败一律返回 `None`（JSON `null`）。
//!
//! - 列位置**按表头名**（大小写不敏感、去空白/BOM）定位，兼容 Android 各版本列顺序差异；
//! - 时间戳为**纳秒**，输出统一换算为**毫秒**；
//! - 跳过 `FrameCompleted == 0`（未完成帧）及所需源列为 0/缺失的行；
//! - `fps` 由 `IntendedVsync` 相邻间隔推导（交付帧率），而非由单帧耗时反推。

use serde::Serialize;

/// `gfxinfo framestats` 的 CSV 区域标记。
const MARKER: &str = "---PROFILEDATA---";
/// 一帧预算（60Hz）毫秒；jank 阈值 = 2×。
const BUDGET_MS: f64 = 16.666;

/// 逐帧渲染统计（时间单位 ms）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RenderStats {
    pub frame_count: u64,
    pub fps: f64,
    pub jank_count: u64,
    pub avg_total_ms: Option<f64>,
    pub p50_total_ms: Option<f64>,
    pub p90_total_ms: Option<f64>,
    pub p99_total_ms: Option<f64>,
    pub avg_ui_ms: Option<f64>,
    pub avg_draw_ms: Option<f64>,
    pub avg_gpu_ms: Option<f64>,
}

/// 去空白 + 去 BOM（首列可能带 UTF-8 BOM）。
fn normalize(s: &str) -> &str {
    s.trim().trim_start_matches('\u{feff}').trim()
}

/// 表头中某列的下标（大小写不敏感）。
fn header_index(header: &str, name: &str) -> Option<usize> {
    header
        .split(',')
        .position(|c| normalize(c).eq_ignore_ascii_case(name))
}

/// 取首/尾 `---PROFILEDATA---` 之间的 CSV 区域（尾标记缺失则到 EOF）。
fn csv_region(text: &str) -> Option<&str> {
    let start = text.find(MARKER)?;
    let after = &text[start + MARKER.len()..];
    let end = after.find(MARKER).unwrap_or(after.len());
    Some(&after[..end])
}

fn col_i64(cols: &[&str], idx: usize) -> Option<i64> {
    cols.get(idx)?.trim().parse::<i64>().ok()
}

/// `hi - lo` 换算为毫秒；任一源值为 0/缺失或差为负 → `None`。
fn diff_ms(hi: Option<i64>, lo: Option<i64>) -> Option<f64> {
    let hi = hi.filter(|v| *v != 0)?;
    let lo = lo.filter(|v| *v != 0)?;
    let diff = hi.checked_sub(lo)?;
    (diff >= 0).then_some(diff as f64 / 1e6)
}

fn mean(v: &[f64]) -> Option<f64> {
    if v.is_empty() {
        None
    } else {
        Some(v.iter().sum::<f64>() / v.len() as f64)
    }
}

/// 最近秩百分位：`rank = ceil(p/100·N)`，取 1-based 第 `rank` 个（夹取到 `[1,N]`）。
fn percentile_nearest_rank(values: &[f64], p: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    let rank = (p / 100.0 * n as f64).ceil() as usize;
    let idx = rank.clamp(1, n) - 1;
    sorted.get(idx).copied()
}

/// 解析 `gfxinfo framestats` 文本；无 `---PROFILEDATA---` 区域、无 `FrameCompleted` 列或无有效帧 → `None`。
pub fn parse_render(text: &str) -> Option<RenderStats> {
    let region = csv_region(text)?;
    let header = region.lines().map(str::trim).find(|l| !l.is_empty())?;
    let c_frame = header_index(header, "FrameCompleted")?;
    let c_intended = header_index(header, "IntendedVsync");
    let c_draw_start = header_index(header, "DrawStart");
    let c_issue = header_index(header, "IssueDrawCommandsStart");
    let c_sync = header_index(header, "SyncStart");

    let mut frame_count: u64 = 0;
    let mut totals: Vec<f64> = Vec::new();
    let mut uis: Vec<f64> = Vec::new();
    let mut draws: Vec<f64> = Vec::new();
    let mut gpus: Vec<f64> = Vec::new();
    let mut intendeds: Vec<i64> = Vec::new();

    let mut saw_header = false;
    for line in region.lines().map(str::trim) {
        if !saw_header {
            if line.is_empty() {
                continue;
            }
            saw_header = true;
            continue;
        }
        if line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split(',').collect();
        let fc = match col_i64(&cols, c_frame) {
            Some(v) if v != 0 => v,
            _ => continue,
        };
        frame_count += 1;

        let intended_val = c_intended.and_then(|i| col_i64(&cols, i));
        if let Some(iv) = intended_val.filter(|v| *v != 0) {
            intendeds.push(iv);
        }
        if let Some(v) = diff_ms(Some(fc), intended_val) {
            totals.push(v);
        }
        let draw_start_val = c_draw_start.and_then(|i| col_i64(&cols, i));
        if let Some(v) = diff_ms(draw_start_val, intended_val) {
            uis.push(v);
        }
        let issue_val = c_issue.and_then(|i| col_i64(&cols, i));
        if let Some(v) = diff_ms(issue_val, draw_start_val) {
            draws.push(v);
        }
        let sync_val = c_sync.and_then(|i| col_i64(&cols, i));
        if let Some(v) = diff_ms(Some(fc), sync_val) {
            gpus.push(v);
        }
    }

    if frame_count == 0 {
        return None;
    }

    let fps = if intendeds.len() >= 2 {
        let first = intendeds[0];
        let last = intendeds[intendeds.len() - 1];
        let span = last.saturating_sub(first);
        if span > 0 {
            (intendeds.len() - 1) as f64 * 1e9 / span as f64
        } else {
            0.0
        }
    } else {
        0.0
    };

    let jank_count = totals.iter().filter(|v| **v > 2.0 * BUDGET_MS).count() as u64;

    Some(RenderStats {
        frame_count,
        fps,
        jank_count,
        avg_total_ms: mean(&totals),
        p50_total_ms: percentile_nearest_rank(&totals, 50.0),
        p90_total_ms: percentile_nearest_rank(&totals, 90.0),
        p99_total_ms: percentile_nearest_rank(&totals, 99.0),
        avg_ui_ms: mean(&uis),
        avg_draw_ms: mean(&draws),
        avg_gpu_ms: mean(&gpus),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Android 真实表头（20 列）。
    const HEADER: &str = "Flags,IntendedVsync,Vsync,OldestInputEvent,NewestInputEvent,HandleInputStart,AnimationStart,PerformTraversalsStart,DrawStart,SyncQueued,SyncStart,IssueDrawCommandsStart,SwapBuffers,FrameCompleted,DequeueBufferDuration,QueueBufferDuration,GpuCompleted,SwapBuffersCompleted,DisplayPresentTime,ProcessFinished";

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-4, "expected {b}, got {a}");
    }

    fn csv_row(cols: &[i64; 20]) -> String {
        cols.iter()
            .map(|v| v.to_string())
            .collect::<Vec<_>>()
            .join(",")
    }

    /// 10 个有效帧 + 1 个未完成帧：
    /// total(ms) = [10,11,12,13,14,15,16,17,18,40]；ui=5.5；draw=4.0；gpu=3.0；
    /// IntendedVsync 间隔 16_666_667ns → fps≈60。
    fn realistic_fixture() -> String {
        let base: i64 = 1_000_000_000;
        let step: i64 = 16_666_667;
        let totals = [10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 40.0];
        let uis = [5.0, 6.0, 5.0, 6.0, 5.0, 6.0, 5.0, 6.0, 5.0, 6.0];
        let mut lines: Vec<String> = vec![HEADER.to_string()];
        // 未完成帧（FrameCompleted=0）应被整体跳过。
        lines.push(csv_row(&[0; 20]));
        for (i, total) in totals.iter().enumerate() {
            let iv = base + i as i64 * step;
            let fc = iv + (total * 1e6) as i64;
            let ds = iv + (uis[i] * 1e6) as i64;
            let issue = ds + 4_000_000;
            let sync = fc - 3_000_000;
            lines.push(csv_row(&[
                0,
                iv,
                iv,
                iv - 1_000_000,
                iv - 500_000,
                iv + 500_000,
                iv + 1_000_000,
                iv + 1_500_000,
                ds,
                ds + 100_000,
                sync,
                issue,
                fc - 500_000,
                fc,
                100_000,
                200_000,
                fc,
                fc,
                -1,
                fc,
            ]));
        }
        lines.join("\n")
    }

    #[test]
    fn parses_realistic_framestats() {
        let text = format!("---PROFILEDATA---\n{}\n---PROFILEDATA---\n", realistic_fixture());
        let r = parse_render(&text).unwrap();
        assert_eq!(r.frame_count, 10); // 未完成帧被跳过
        approx(r.avg_total_ms.unwrap(), 16.6);
        approx(r.p50_total_ms.unwrap(), 14.0);
        approx(r.p90_total_ms.unwrap(), 18.0);
        approx(r.p99_total_ms.unwrap(), 40.0);
        approx(r.avg_ui_ms.unwrap(), 5.5);
        approx(r.avg_draw_ms.unwrap(), 4.0);
        approx(r.avg_gpu_ms.unwrap(), 3.0);
        assert_eq!(r.jank_count, 1); // 仅 40ms > 2×16.666
        approx(r.fps, 60.0);
    }

    #[test]
    fn header_name_lookup_handles_reordered_and_missing_columns() {
        // 列被重排，且缺少 DrawStart / IssueDrawCommandsStart → ui/draw 应为 null，其余仍正确。
        let header = "FrameCompleted,SyncStart,IntendedVsync,Flags";
        let base: i64 = 1_000_000_000;
        let step: i64 = 16_666_667;
        let totals = [10.0, 20.0, 30.0, 40.0];
        let gpus = [1.0, 2.0, 3.0, 4.0];
        let mut lines = vec![header.to_string()];
        for (i, total) in totals.iter().enumerate() {
            let iv = base + i as i64 * step;
            let fc = iv + (total * 1e6) as i64;
            let sync = fc - (gpus[i] * 1e6) as i64;
            lines.push(format!("{fc},{sync},{iv},0"));
        }
        let text = format!("garbage before\n---PROFILEDATA---\n{}\n---PROFILEDATA---\n", lines.join("\n"));
        let r = parse_render(&text).unwrap();
        assert_eq!(r.frame_count, 4);
        approx(r.avg_total_ms.unwrap(), 25.0);
        approx(r.p50_total_ms.unwrap(), 20.0);
        approx(r.p90_total_ms.unwrap(), 40.0);
        approx(r.avg_gpu_ms.unwrap(), 2.5);
        assert_eq!(r.avg_ui_ms, None);
        assert_eq!(r.avg_draw_ms, None);
        approx(r.fps, 60.0);
    }

    #[test]
    fn render_is_none_without_marker_or_region_data() {
        assert_eq!(parse_render("Total frames rendered: 10\nJanky frames: 1 (10.0%)\n"), None);
        assert_eq!(parse_render(""), None);
        assert_eq!(parse_render("---PROFILEDATA---\n"), None); // 无表头
        let header_only = "---PROFILEDATA---\nFrameCompleted,IntendedVsync\n---PROFILEDATA---\n";
        assert_eq!(parse_render(header_only), None); // 无数据行
    }

    #[test]
    fn render_is_none_when_frame_completed_column_absent() {
        let text = "---PROFILEDATA---\nIntendedVsync,DrawStart\n1000000000,1005000000\n---PROFILEDATA---\n";
        assert_eq!(parse_render(text), None);
    }

    #[test]
    fn missing_optional_columns_yield_null_metrics() {
        // 仅有 FrameCompleted + IntendedVsync → total 可算，ui/draw/gpu 为 null。
        let base: i64 = 1_000_000_000;
        let text = format!(
            "---PROFILEDATA---\nFrameCompleted,IntendedVsync\n{},{}\n---PROFILEDATA---\n",
            base + 10_000_000,
            base
        );
        let r = parse_render(&text).unwrap();
        assert_eq!(r.frame_count, 1);
        approx(r.avg_total_ms.unwrap(), 10.0);
        assert_eq!(r.avg_ui_ms, None);
        assert_eq!(r.avg_draw_ms, None);
        assert_eq!(r.avg_gpu_ms, None);
        assert_eq!(r.fps, 0.0); // 单帧 → 0
    }

    #[test]
    fn percentile_nearest_rank_edges() {
        assert_eq!(percentile_nearest_rank(&[], 50.0), None);
        assert_eq!(percentile_nearest_rank(&[5.0], 99.0), Some(5.0));
        approx(percentile_nearest_rank(&[3.0, 1.0, 2.0], 50.0).unwrap(), 2.0);
        approx(percentile_nearest_rank(&[1.0, 2.0, 3.0, 4.0], 90.0).unwrap(), 4.0);
    }
}
