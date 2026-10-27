//! Canonical download-file helpers shared by the parity harness and its tests.
//!
//! These functions describe the on-disk rules both engines must agree on:
//! segmented parts are `$dest.part{i}` starting at 0 (a gap ends the
//! inventory), the merge temporary file is `.temp` on the Dart engine and
//! `.merge` on the Rust engine, and the resumable byte count prefers the final
//! file, then the merge temp, then the part sum (the Dart `_diskBytes` rule).

use std::fs;
use std::path::{Path, PathBuf};

/// One contiguous part file found next to a destination path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PartFile {
    pub index: u32,
    pub bytes: u64,
}

/// Existing `$dest.part{i}` files from index 0 until the first gap.
///
/// A bare `$dest.part` (legacy debris) is intentionally ignored: it has no
/// numeric index and must never be treated as resumable data.
pub fn part_files(dest: &Path) -> Vec<PartFile> {
    let mut parts = Vec::new();
    for index in 0u32.. {
        let path = part_path(dest, index);
        match fs::metadata(&path) {
            Ok(metadata) => parts.push(PartFile {
                index,
                bytes: metadata.len(),
            }),
            Err(_) => break,
        }
    }
    parts
}

/// Bytes already on disk for resuming: final file, then merge temp, then parts.
pub fn resume_expected_bytes(dest: &Path) -> u64 {
    if let Ok(metadata) = fs::metadata(dest) {
        return metadata.len();
    }
    if let Ok(metadata) = fs::metadata(temp_path(dest, "temp")) {
        return metadata.len();
    }
    part_files(dest).iter().map(|part| part.bytes).sum()
}

/// Non-null when a merge temp exists: `"temp"` (Dart) or `"merge"` (Rust).
pub fn merge_temp_role(dest: &Path) -> Option<&'static str> {
    if fs::metadata(temp_path(dest, "temp")).is_ok() {
        return Some("temp");
    }
    if fs::metadata(temp_path(dest, "merge")).is_ok() {
        return Some("merge");
    }
    None
}

fn part_path(dest: &Path, index: u32) -> PathBuf {
    PathBuf::from(format!("{}.part{index}", dest.display()))
}

fn temp_path(dest: &Path, extension: &str) -> PathBuf {
    PathBuf::from(format!("{}.{extension}", dest.display()))
}

/// Module/Floor status int mapped to the core `download_task.status` label.
pub fn status_core_label(code: i64) -> &'static str {
    match code {
        0..=2 => "running",
        3 => "paused",
        4 => "completed",
        5 => "failed",
        6 => "cancelled",
        _ => "failed",
    }
}

/// Module/Floor status int mapped to the Dart `DownloadStatusEnum` name.
pub fn status_enum_label(code: i64) -> &'static str {
    match code {
        0 => "queued",
        1 => "connecting",
        2 => "downloading",
        3 => "paused",
        4 => "completed",
        5 => "failed",
        6 => "cancelled",
        _ => "failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::SeqCst);
            let dir = std::env::temp_dir().join(format!(
                "gstore_download_parity_{}_{}_{}",
                std::process::id(),
                tag,
                n
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn parity_status_tables_cover_every_known_code() {
        let cases = [
            (0, "running", "queued"),
            (1, "running", "connecting"),
            (2, "running", "downloading"),
            (3, "paused", "paused"),
            (4, "completed", "completed"),
            (5, "failed", "failed"),
            (6, "cancelled", "cancelled"),
            (9, "failed", "failed"),
        ];
        for (code, core, dart) in cases {
            assert_eq!(status_core_label(code), core, "core status for {code}");
            assert_eq!(status_enum_label(code), dart, "dart status for {code}");
        }
    }

    #[test]
    fn parity_parts_temp_and_resume_precedence() {
        let dir = TempDir::new("files");
        let dest = dir.path().join("paused.bin");
        std::fs::write(format!("{}.part0", dest.display()), vec![1u8; 4]).unwrap();
        std::fs::write(format!("{}.part1", dest.display()), vec![2u8; 6]).unwrap();
        std::fs::write(format!("{}.part", dest.display()), vec![3u8; 99]).unwrap();
        std::fs::write(format!("{}.temp", dest.display()), vec![4u8; 7]).unwrap();

        assert_eq!(
            part_files(&dest),
            vec![
                PartFile { index: 0, bytes: 4 },
                PartFile { index: 1, bytes: 6 }
            ],
            "bare .part is not a segment and the inventory stops at a gap"
        );
        assert_eq!(merge_temp_role(&dest), Some("temp"));
        assert_eq!(
            resume_expected_bytes(&dest),
            7,
            "merge temp wins over the part sum"
        );

        std::fs::write(&dest, vec![5u8; 10]).unwrap();
        assert_eq!(
            resume_expected_bytes(&dest),
            10,
            "final file wins over temp and parts"
        );
    }
}
