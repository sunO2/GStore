//! 存储采集：解析 `/proc/mounts`（仅真实文件系统）+ `libc::statvfs` 容量。
//!
//! 单位 KiB；`used_percent = used_kb / total_kb * 100`（clamp 0..100）。
//! 伪文件系统（proc/sysfs/tmpfs/devpts/cgroup/overlay 等）一律跳过；按挂载点去重。
//! 非 Linux/Android 平台返回空 `volumes`，绝不 panic。

use serde::Serialize;

use super::util;

/// `/proc/mounts` 的一行（仅保留设备/挂载点/文件系统）。
#[derive(Debug, Clone, PartialEq)]
pub struct MountEntry {
    pub device: String,
    pub mount: String,
    pub fs: String,
}

/// 单个卷的容量信息（KiB + 使用率）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct VolumeInfo {
    pub mount: String,
    pub fs: String,
    pub total_kb: u64,
    pub free_kb: u64,
    pub used_kb: u64,
    pub used_percent: f64,
}

/// 存储报告。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StorageReport {
    pub volumes: Vec<VolumeInfo>,
}

/// 反转义 `/proc/mounts` 的八进制转义（`\040` 空格 / `\011` tab / `\012` 换行 / `\134` 反斜杠）。
pub fn unescape_mount(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' && i + 3 < chars.len() {
            let oct: String = chars[i + 1..i + 4].iter().collect();
            if oct.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
                if let Ok(code) = u8::from_str_radix(&oct, 8) {
                    out.push(code as char);
                    i += 4;
                    continue;
                }
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 解析 `/proc/mounts`（每行 `device mountpoint fstype options dump pass`）。
pub fn parse_proc_mounts(content: &str) -> Vec<MountEntry> {
    let mut out = Vec::new();
    for line in content.lines() {
        let mut it = line.split_whitespace();
        let Some(device) = it.next() else { continue };
        let Some(mount) = it.next() else { continue };
        let Some(fs) = it.next() else { continue };
        out.push(MountEntry {
            device: device.to_string(),
            mount: unescape_mount(mount),
            fs: fs.to_string(),
        });
    }
    out
}

/// 是否真实（块设备支持的）文件系统。伪文件系统一律拒绝。
pub fn is_real_fs(fs: &str) -> bool {
    const REAL: &[&str] = &[
        "ext2", "ext3", "ext4", "f2fs", "xfs", "btrfs", "jfs", "nilfs2", "reiserfs", "ufs",
        "minix", "vfat", "msdos", "exfat", "ntfs", "ntfs3", "fuseblk", "squashfs", "erofs",
        "iso9660", "udf", "hfsplus",
    ];
    REAL.contains(&fs)
}

/// 由总量/可用/已用（KiB）构造卷信息并计算使用率。
pub fn build_volume(entry: &MountEntry, total_kb: u64, free_kb: u64, used_kb: u64) -> VolumeInfo {
    let used_percent = if total_kb == 0 {
        0.0
    } else {
        util::clamp_percent(used_kb as f64 * 100.0 / total_kb as f64)
    };
    VolumeInfo {
        mount: entry.mount.clone(),
        fs: entry.fs.clone(),
        total_kb,
        free_kb,
        used_kb,
        used_percent,
    }
}

/// 对挂载表逐项 statvfs；跳过伪文件系统、按挂载点去重、statvfs 失败即跳过。
pub fn volumes_from_mounts<F>(mounts: &[MountEntry], mut stat: F) -> Vec<VolumeInfo>
where
    F: FnMut(&str) -> Option<(u64, u64, u64)>,
{
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for m in mounts {
        if !is_real_fs(&m.fs) || seen.contains(&m.mount) {
            continue;
        }
        if let Some((total_kb, free_kb, used_kb)) = stat(&m.mount) {
            seen.insert(m.mount.clone());
            out.push(build_volume(m, total_kb, free_kb, used_kb));
        }
    }
    out
}

/// `statvfs` → `(total_kb, free_kb, used_kb)`；`free_kb` 为非特权用户可用（`f_bavail`），
/// `used_kb = (f_blocks - f_bfree) * frsize`。
#[cfg(any(target_os = "linux", target_os = "android"))]
fn statvfs_kb(path: &str) -> Option<(u64, u64, u64)> {
    let c_path = std::ffi::CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let frsize = if st.f_frsize > 0 {
        st.f_frsize as u64
    } else {
        st.f_bsize as u64
    };
    if frsize == 0 {
        return None;
    }
    let total_kb = (st.f_blocks as u64).saturating_mul(frsize) / 1024;
    let free_kb = (st.f_bavail as u64).saturating_mul(frsize) / 1024;
    let used_kb = (st.f_blocks as u64)
        .saturating_sub(st.f_bfree as u64)
        .saturating_mul(frsize)
        / 1024;
    Some((total_kb, free_kb, used_kb))
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn statvfs_kb(_path: &str) -> Option<(u64, u64, u64)> {
    None
}

/// 采集真实文件系统的容量。
pub fn collect() -> StorageReport {
    let mounts = util::read_file("/proc/mounts")
        .map(|c| parse_proc_mounts(&c))
        .unwrap_or_default();
    StorageReport {
        volumes: volumes_from_mounts(&mounts, statvfs_kb),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 `/proc/mounts` 片段（含伪 fs 与八进制转义挂载点）。
    const MOUNTS: &str = "/dev/block/dm-0 / ext4 rw,seclabel,relatime 0 0\n\
        proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0\n\
        sysfs /sys sysfs rw,seclabel,nosuid,nodev,noexec,relatime 0 0\n\
        tmpfs /dev tmpfs rw,seclabel,nosuid,relatime,mode=755 0 0\n\
        devpts /dev/pts devpts rw,seclabel,nosuid,noexec,relatime,gid=5,mode=620 0 0\n\
        cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime 0 0\n\
        /dev/block/dm-1 /data f2fs rw,seclabel,nosuid,nodev,noatime 0 0\n\
        tmpfs /mnt/foo\\040bar tmpfs rw 0 0\n\
        overlay /system overlay ro,seclabel 0 0\n";

    #[test]
    fn parse_proc_mounts_reads_three_columns() {
        let m = parse_proc_mounts(MOUNTS);
        assert_eq!(m.len(), 9);
        assert_eq!(m[0].device, "/dev/block/dm-0");
        assert_eq!(m[0].mount, "/");
        assert_eq!(m[0].fs, "ext4");
        assert_eq!(m[1].mount, "/proc");
    }

    #[test]
    fn unescape_mount_decodes_octal() {
        assert_eq!(unescape_mount("/mnt/foo\\040bar"), "/mnt/foo bar");
        assert_eq!(unescape_mount("/a\\011b"), "/a\tb");
        assert_eq!(unescape_mount("/plain"), "/plain");
        // 非法/不完整转义原样保留
        assert_eq!(unescape_mount("/x\\04"), "/x\\04");
    }

    #[test]
    fn is_real_fs_rejects_pseudo() {
        for fs in ["ext4", "f2fs", "vfat", "squashfs", "erofs", "fuseblk"] {
            assert!(is_real_fs(fs), "{fs} should be real");
        }
        for fs in [
            "proc", "sysfs", "tmpfs", "devpts", "cgroup", "cgroup2", "overlay", "devtmpfs",
            "debugfs",
        ] {
            assert!(!is_real_fs(fs), "{fs} should be pseudo");
        }
    }

    #[test]
    fn volumes_skip_pseudo_dedupe_and_use_injected_stat() {
        let mounts = parse_proc_mounts(MOUNTS);
        let volumes = volumes_from_mounts(&mounts, |path| match path {
            "/" => Some((100_000, 40_000, 60_000)),
            "/data" => Some((200_000, 150_000, 50_000)),
            _ => None,
        });
        assert_eq!(volumes.len(), 2);
        assert_eq!(volumes[0].mount, "/");
        assert_eq!(volumes[0].fs, "ext4");
        assert_eq!(volumes[0].total_kb, 100_000);
        assert!((volumes[0].used_percent - 60.0).abs() < 1e-9);
        assert_eq!(volumes[1].mount, "/data");
        assert_eq!(volumes[1].fs, "f2fs");
        assert!((volumes[1].used_percent - 25.0).abs() < 1e-9);
    }

    #[test]
    fn volumes_dedupe_repeated_mountpoint() {
        let mounts = parse_proc_mounts(
            "/dev/a /data ext4 rw 0 0\n/dev/b /data ext4 rw 0 0\n/dev/c /data2 f2fs rw 0 0\n",
        );
        let volumes = volumes_from_mounts(&mounts, |_| Some((1000, 500, 500)));
        assert_eq!(volumes.len(), 2);
        assert_eq!(volumes[0].mount, "/data");
        assert_eq!(volumes[1].mount, "/data2");
    }

    #[test]
    fn build_volume_zero_total_is_zero_percent() {
        let e = MountEntry {
            device: "x".into(),
            mount: "/z".into(),
            fs: "ext4".into(),
        };
        let v = build_volume(&e, 0, 0, 0);
        assert_eq!(v.used_percent, 0.0);
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn statvfs_on_root_reports_positive_total() {
        let (total_kb, _free_kb, _used_kb) = statvfs_kb("/").expect("statvfs on / should work");
        assert!(total_kb > 0, "root filesystem total should be > 0");
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn collect_finds_root_or_is_empty_but_never_panics() {
        let r = collect();
        for v in &r.volumes {
            assert!(v.total_kb > 0, "volume {} has zero total", v.mount);
            assert!(v.used_percent >= 0.0 && v.used_percent <= 100.0);
        }
    }
}
