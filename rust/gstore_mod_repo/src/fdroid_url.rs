//! F-Droid 仓库 URL 规范化与 `entry.json` 解析（P0）
//!
//! 1) **自动发现**：官方客户端在用户只输入主机名时会自动尝试 `/fdroid/repo`
//!    （见 F-Droid「Setup an F-Droid App Repo」）。第三方源与**独立应用的私有源**
//!    （如 Bitwarden 的 `https://releases.bitwarden.com/fdroid/repo`）正依赖这一约定。
//! 2) **深链**：`fdroidrepos://` = https、`fdroidrepo://` = http（客户端注册的 intent filter 用这两个 scheme）。
//! 3) **entry.json**：v2 的入口文件，列出索引与 diff 文件及其 sha256/size —— 据此校验下载到的索引。

use std::collections::BTreeMap;

/// 索引/差异文件引用
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IndexRef {
    pub name: String,
    pub sha256: String,
    pub size: u64,
}

/// `entry.json` 的内容（v2）
#[derive(Clone, Debug, Default)]
pub struct EntryInfo {
    /// entry 格式版本（例如 20002）
    pub version: i64,
    /// 索引时间戳（**差异选择的真正基线**：diffs 的键就是上一个索引的 timestamp）
    pub timestamp: i64,
    /// 完整索引引用（首次更新用）
    pub index: Option<IndexRef>,
    /// 版本号 → 差异文件（后续做增量更新用；此处先解析出来）
    pub diffs: BTreeMap<i64, IndexRef>,
}

/// 规范化用户输入的仓库地址，返回**按优先级排列的候选 URL**。
///
/// - `fdroidrepos://host/path` → `https://host/path`；`fdroidrepo://` → `http://`
/// - 只给主机名（或仅 `/`）时：先试 `<base>/fdroid/repo`，再试 `<base>`（官方自动发现约定）
/// - 明确给了子路径时：只用它（尊重用户意图）
/// - 去掉 query/fragment（例如深链里的 `?fingerprint=` 不参与下载）
/// 拼接仓库地址与索引内路径。
///
/// 真机实测：`entry.index.name` / `diffs[].name` 都带**前导 `/`**（`/index-v2.json`），
/// 直接 `format!("{base}/{name}")` 会拼出 `base//index-v2.json`。
pub fn join_repo(base: &str, name: &str) -> String {
    let b = base.trim_end_matches('/');
    let n = name.trim_start_matches('/');
    format!("{b}/{n}")
}

pub fn normalize_repo_urls(input: &str) -> Vec<String> {
    let raw = input.trim();
    if raw.is_empty() {
        return Vec::new();
    }

    let (scheme, rest) = if let Some(r) = raw.strip_prefix("fdroidrepos://") {
        ("https", r)
    } else if let Some(r) = raw.strip_prefix("fdroidrepo://") {
        ("http", r)
    } else if let Some((s, r)) = raw.split_once("://") {
        (s, r)
    } else {
        // 没写 scheme：按 https 处理（私有源基本都要求 https）
        ("https", raw)
    };

    // 去掉 query / fragment
    let rest = rest.split(['?', '#']).next().unwrap_or(rest);
    let rest = rest.trim_end_matches('/');
    let mut base = format!("{scheme}://{rest}");

    // 拆出 path 部分判断用户是否给了明确路径
    let after_host = rest.split_once('/').map(|(_, p)| p).unwrap_or("");
    let mut candidates: Vec<String> = Vec::new();

    if after_host.is_empty() {
        candidates.push(format!("{base}/fdroid/repo"));
        candidates.push(base.clone());
    } else {
        candidates.push(base.clone());
    }

    // 去重并保持顺序（base 同时作为候选时避免重复）
    let mut seen = std::collections::HashSet::new();
    candidates.retain(|u| seen.insert(u.clone()));
    base.clear();
    candidates
}

/// 解析 `entry.json`；结构不合法返回 None（调用方退回直接读 index-v2.json）
pub fn parse_entry(json: &[u8]) -> Option<EntryInfo> {
    let v: serde_json::Value = serde_json::from_slice(json).ok()?;
    let mut info = EntryInfo {
        version: v.get("version").and_then(|x| x.as_i64()).unwrap_or(0),
        timestamp: v.get("timestamp").and_then(|x| x.as_i64()).unwrap_or(0),
        ..Default::default()
    };
    info.index = v.get("index").and_then(parse_index_ref);
    if let Some(diffs) = v.get("diffs").and_then(|d| d.as_object()) {
        for (k, val) in diffs {
            if let (Ok(code), Some(r)) = (k.parse::<i64>(), parse_index_ref(val)) {
                info.diffs.insert(code, r);
            }
        }
    }
    Some(info)
}

fn parse_index_ref(v: &serde_json::Value) -> Option<IndexRef> {
    let name = v.get("name").and_then(|x| x.as_str())?.to_string();
    Some(IndexRef {
        name,
        sha256: v
            .get("sha256")
            .and_then(|x| x.as_str())
            .unwrap_or_default()
            .to_ascii_lowercase(),
        size: v.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
    })
}

/// 校验字节流的 SHA-256 是否等于期望值（十六进制，大小写不敏感）。
/// 期望值为空时视为「无约束」→ true（老仓库没有 entry.json 的场景）
pub fn verify_sha256(bytes: &[u8], expected_hex: &str) -> bool {
    use sha2::{Digest, Sha256};
    if expected_hex.trim().is_empty() {
        return true;
    }
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let actual = hex_lower(&hasher.finalize());
    actual == expected_hex.trim().to_ascii_lowercase()
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_host_gets_fdroid_repo_discovery() {
        let urls = normalize_repo_urls("https://f-droid.org");
        assert_eq!(urls, vec!["https://f-droid.org/fdroid/repo", "https://f-droid.org"]);
        // 尾斜杠等价
        assert_eq!(
            normalize_repo_urls("https://f-droid.org/"),
            vec!["https://f-droid.org/fdroid/repo", "https://f-droid.org"]
        );
    }

    #[test]
    fn explicit_path_is_respected() {
        // Bitwarden 式独立应用私有源：已给出完整路径，不再猜测
        let urls = normalize_repo_urls("https://releases.bitwarden.com/fdroid/repo");
        assert_eq!(urls, vec!["https://releases.bitwarden.com/fdroid/repo"]);
    }

    #[test]
    fn fdroidscheme_deeplink_is_translated() {
        assert_eq!(
            normalize_repo_urls("fdroidrepos://example.com/fdroid/repo"),
            vec!["https://example.com/fdroid/repo"]
        );
        // fdroidrepo:// = http
        assert_eq!(
            normalize_repo_urls("fdroidrepo://192.168.1.5/fdroid/repo"),
            vec!["http://192.168.1.5/fdroid/repo"]
        );
    }

    #[test]
    fn fingerprint_query_is_stripped() {
        // 深链常带 ?fingerprint=<sha256>，不参与下载
        let urls = normalize_repo_urls(
            "fdroidrepos://example.com/fdroid/repo?fingerprint=ABCDEF",
        );
        assert_eq!(urls, vec!["https://example.com/fdroid/repo"]);
    }

    #[test]
    fn missing_scheme_defaults_to_https() {
        assert_eq!(
            normalize_repo_urls("example.com/fdroid/repo"),
            vec!["https://example.com/fdroid/repo"]
        );
    }

    #[test]
    fn empty_input_yields_no_candidates() {
        assert!(normalize_repo_urls("   ").is_empty());
    }

    #[test]
    fn parses_entry_with_index_and_diffs() {
        let json = br#"{
            "version": 20002,
            "index": {"name":"index-v2.json","sha256":"AB12","size":100},
            "diffs": {"20001":{"name":"diff/20001.json","sha256":"cd34","size":10}}
        }"#;
        let e = parse_entry(json).expect("entry should parse");
        assert_eq!(e.version, 20002);
        let idx = e.index.unwrap();
        assert_eq!(idx.name, "index-v2.json");
        assert_eq!(idx.sha256, "ab12"); // 统一小写，比较时方便
        assert_eq!(idx.size, 100);
        assert_eq!(e.diffs.get(&20001).unwrap().name, "diff/20001.json");
    }

    #[test]
    fn parse_entry_tolerates_garbage() {
        assert!(parse_entry(b"not json").is_none());
        // 合法 JSON 但缺 index 也要能解析（只有 diffs 的中间版本）
        let e = parse_entry(br#"{"version":1}"#).unwrap();
        assert!(e.index.is_none());
        assert!(e.diffs.is_empty());
    }

    #[test]
    fn sha256_verification() {
        // "abc" 的 SHA-256
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert!(verify_sha256(b"abc", expected));
        assert!(verify_sha256(b"abc", &expected.to_uppercase())); // 大小写不敏感
        assert!(!verify_sha256(b"abcd", expected));
        // 空期望值 = 无约束（兼容没有 entry.json 的老仓库）
        assert!(verify_sha256(b"anything", ""));
    }
}
