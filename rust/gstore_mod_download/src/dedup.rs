//! 判重键的派生与冲突策略。
//!
//! 设计原则（代理键 / 逻辑键分离）：
//! - **id 是代理键**：DB 自增、由 Rust 生成并管理，稳定、不透明、与业务无关。
//! - **dedup_key 是逻辑唯一键**：回答"什么算同一个下载"，用于判重。
//! - 撞键时由**调用方**选策略（[`ConflictPolicy`]），对齐 WorkManager 的
//!   `enqueueUniqueWork(name, ExistingWorkPolicy, ...)` 范式。
//!
//! 为什么键里**不放**业务展示字段：
//! - `app_name` 随语言变化（汉化后同一个包在中文/英文下是两个名字）→ 会被算成两个下载；
//! - `url` 是"来源"不是"身份"，国内换镜像很常见 → 会被算成两个下载。
//!
//! 因此应用的天然身份是 **包名 + 版本**；非应用资源用 `kind + resource_id`。

use serde::{Deserialize, Serialize};

/// 撞键时的处理策略。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ConflictPolicy {
    /// 复用已有任务：进行中直接返回它；已完成且文件仍在也直接返回。
    #[default]
    Keep,
    /// 重下：清掉分段与进度，按当前入参重新排队（沿用同一行、同一 id）。
    Replace,
    /// 允许重复：给键加唯一后缀，插入一条新任务（明确要存多份时用）。
    Append,
}

/// 派生判重键的输入。
///
/// 刻意**不包含** `app_name` 之类的展示字段与 `file_name` 之类的派生字段：
/// 只有稳定、与展示无关的量才允许进入键。
#[derive(Debug, Clone, Default)]
pub struct DedupInput {
    /// 调用方显式指定的键（最优先，只有调用方知道"什么算同一个"）
    pub explicit_key: Option<String>,
    /// 资源类型：app / model / asset / file …
    pub kind: String,
    /// 资源在自身类型下的标识（包名、模型仓库名、资源相对路径…）
    pub resource_id: String,
    pub resource_version: String,
    /// 文件名：同版本可能有多个构建（渠道/调试包，文件名常带构建时间），
    /// 它们内容不同、不能互相覆盖；而换镜像时文件名不变，判重仍成立。
    pub file_name: String,
    pub url: String,
    pub dest_path: String,
}

/// 派生逻辑唯一键。
///
/// 优先级：
/// 1. 调用方显式给的 `dedupKey`
/// 2. `kind:resourceId[:resourceVersion]`，例：`app:com.x:1.2.3`、`model:qwen2-0.5b-q4`
/// 3. 兜底：`url:<sha256(规范化URL + 目标路径)>`
pub fn derive_dedup_key(input: &DedupInput) -> String {
    if let Some(k) = input.explicit_key.as_ref() {
        let t = k.trim();
        if !t.is_empty() {
            return t.to_string();
        }
    }

    let kind = input.kind.trim();
    let rid = input.resource_id.trim();
    if !kind.is_empty() && !rid.is_empty() {
        let mut key = format!("{kind}:{rid}");
        let ver = input.resource_version.trim();
        if !ver.is_empty() {
            key.push(':');
            key.push_str(ver);
        }
        // 文件名也进键：同一版本可能对应多个构建（URL 与内容都不同），
        // 不加会被判成同一个下载而互相覆盖。刻意**不用 URL**——换镜像时
        // 文件名不变，判重仍然成立。
        let fname = input.file_name.trim();
        if !fname.is_empty() {
            key.push(':');
            key.push_str(fname);
        }
        return key;
    }

    // 兜底：来源 + 目标 的指纹。用摘要而不是原始拼接，键长稳定、也不把 URL 里的
    // 签名/token 原样写进库。
    let material = format!("{}\n{}", normalize_url(&input.url), input.dest_path.trim());
    format!("url:{}", sha256_hex(material.as_bytes()))
}

/// URL 规范化：**只用于判重**，不改变实际请求地址。
///
/// - 去掉 `#fragment`（不影响取到的字节）
/// - scheme 与 host 转小写（主机名不区分大小写）
/// - 去掉路径末尾多余的 `/`
///
/// 刻意**保留 query**：同一路径带不同 query 往往是不同产物（签名、版本参数）。
pub fn normalize_url(url: &str) -> String {
    let url = url.trim();
    let no_frag = match url.find('#') {
        Some(i) => &url[..i],
        None => url,
    };

    let (prefix, rest) = match no_frag.find("://") {
        Some(i) => (&no_frag[..i + 3], &no_frag[i + 3..]),
        None => ("", no_frag),
    };
    let (authority, tail) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };

    let mut out = format!(
        "{}{}{}",
        prefix.to_lowercase(),
        authority.to_lowercase(),
        tail
    );
    while out.len() > 1 && out.ends_with('/') && !out.ends_with("://") {
        out.pop();
    }
    out
}

pub fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(data);
    hex::encode(h.finalize())
}

/// `append` 策略用的唯一后缀：`key` → `key#2` / `key#3` …
pub fn with_suffix(base: &str, n: u32) -> String {
    format!("{base}#{n}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app_input(url: &str) -> DedupInput {
        DedupInput {
            kind: "app".into(),
            resource_id: "com.example.app".into(),
            resource_version: "1.2.3".into(),
            url: url.into(),
            dest_path: "/data/dl/app.apk".into(),
            ..Default::default()
        }
    }

    #[test]
    fn explicit_key_wins_over_everything() {
        let mut i = app_input("https://a/x.apk");
        i.explicit_key = Some("  my.own.key  ".into());
        assert_eq!(derive_dedup_key(&i), "my.own.key");

        // 空白键视为没给，退回规则派生
        i.explicit_key = Some("   ".into());
        assert_eq!(derive_dedup_key(&i), "app:com.example.app:1.2.3");
    }

    #[test]
    fn resource_key_ignores_source_url_so_mirror_switch_does_not_duplicate() {
        let official = app_input("https://f-droid.org/repo/app.apk");
        let mirror = app_input("https://mirror.example/fdroid/repo/app.apk");
        assert_eq!(
            derive_dedup_key(&official),
            derive_dedup_key(&mirror),
            "换镜像不该产生第二个下载任务"
        );
        assert_eq!(derive_dedup_key(&official), "app:com.example.app:1.2.3");
    }

    #[test]
    fn resource_key_has_no_display_fields() {
        // DedupInput 里根本没有 app_name / file_name：
        // 展示字段（随语言变化）与派生字段都不允许进入键，这是类型层面的保证。
        let i = app_input("https://a/x.apk");
        let k = derive_dedup_key(&i);
        assert!(!k.contains("app.apk"), "文件名不该进键：{k}");
        assert_eq!(k.matches(':').count(), 2, "app:<id>:<version>");
    }

    #[test]
    fn version_is_optional_for_generic_resources() {
        let i = DedupInput {
            kind: "model".into(),
            resource_id: "qwen2-0.5b-q4".into(),
            url: "https://modelscope.cn/x".into(),
            dest_path: "/data/models/q.bin".into(),
            ..Default::default()
        };
        assert_eq!(derive_dedup_key(&i), "model:qwen2-0.5b-q4");
    }

    #[test]
    fn fallback_key_is_fingerprint_of_source_and_dest() {
        let a = DedupInput {
            url: "https://x/a.bin".into(),
            dest_path: "/d/a.bin".into(),
            ..Default::default()
        };
        let b = DedupInput {
            dest_path: "/d/b.bin".into(),
            ..a.clone()
        };
        assert!(derive_dedup_key(&a).starts_with("url:"));
        assert_ne!(
            derive_dedup_key(&a),
            derive_dedup_key(&b),
            "目标路径不同就是不同下载"
        );
        // 同一来源同一目标必须稳定
        assert_eq!(derive_dedup_key(&a), derive_dedup_key(&a.clone()));
    }

    #[test]
    fn normalize_url_strips_fragment_lowercases_host_keeps_query() {
        assert_eq!(
            normalize_url("HTTPS://Example.COM/a/b#frag"),
            "https://example.com/a/b"
        );
        assert_eq!(
            normalize_url("https://example.com/a/?v=2"),
            "https://example.com/a/?v=2",
            "query 往往是不同产物，必须保留"
        );
        assert_eq!(normalize_url("https://example.com/a///"), "https://example.com/a");
        assert_eq!(normalize_url("  https://a.b/c  "), "https://a.b/c");
    }

    #[test]
    fn append_suffix_is_stable_and_distinct() {
        assert_eq!(with_suffix("app:com.x:1", 2), "app:com.x:1#2");
        assert_ne!(with_suffix("k", 2), with_suffix("k", 3));
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
