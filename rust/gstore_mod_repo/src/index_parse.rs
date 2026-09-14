//! index-v2 的**流式（逐包）解析**
//!
//! 目的：干掉「整份索引的 `serde_json::Value` 树」——33MB 的索引在 Value 形态下
//! 可膨胀到数百 MB，是低内存设备上最大的内存峰值来源。
//!
//! 做法：顶层只解出 `packages`，每个包保留为 `Box<RawValue>`（**原始文本，不深解**），
//! 然后**逐个包**解析成小 `Value` 交给既有的 `AppInfo::from_json_value_v2`。
//! 于是：
//! - 深层字段的解析逻辑**完全复用**，行为等价由构造保证
//! - 峰值内存从「整索引 Value 树」降到「单个包的 Value」
//! - `versions`/`metadata` 若需要原文可直接取 `RawValue::get()`，无需重新序列化

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::value::RawValue;

use crate::models::AppInfo;

/// 顶层投影：只关心 packages（用 BTreeMap 保证顺序确定，与 Value 路径一致）
#[derive(Deserialize)]
struct IndexV2Shallow {
    #[serde(default)]
    packages: BTreeMap<String, Box<RawValue>>,
}

/// 从任意 reader **流式**解析应用列表（不建整份 Value 树）
pub fn parse_index_v2_reader<R: std::io::Read>(reader: R) -> Result<Vec<AppInfo>, String> {
    let index: IndexV2Shallow =
        serde_json::from_reader(reader).map_err(|e| format!("解析索引失败: {e}"))?;
    let mut apps = Vec::with_capacity(index.packages.len());
    for (package_name, raw) in &index.packages {
        // 单包解析：峰值内存 = 一个包，而非整个索引
        match serde_json::from_str::<serde_json::Value>(raw.get()) {
            Ok(value) => {
                if let Ok(app) = AppInfo::from_json_value_v2(package_name, &value) {
                    apps.push(app);
                }
            }
            Err(e) => {
                // 局部 gating：与 repo.rs 的 debug_print 同语义（仅调试构建输出）
                #[cfg(debug_assertions)]
                eprintln!("index_parse: 跳过包 {package_name}: {e}");
                let _ = e;
            }
        }
    }
    Ok(apps)
}

/// 仓库头 / 镜像：只需两个小字段，单独轻量解出（避免为它们建整份 Value）
#[derive(Deserialize)]
struct IndexV2Head {
    #[serde(default)]
    repo: serde_json::Value,
    #[serde(default)]
    mirrors: serde_json::Value,
}

/// 返回仅含 `repo` / `mirrors` 的小 Value，供既有的 `parse_repo_meta` 复用
pub fn parse_index_head(bytes: &[u8]) -> serde_json::Value {
    match serde_json::from_slice::<IndexV2Head>(bytes) {
        Ok(h) => {
            // v1 的镜像在**顶层** `mirrors`；v2 放在 **`repo.mirrors`** 里
            // ← 真机（Bitwarden 源）暴露：只读顶层会得到空镜像列表
            let top_empty = !h
                .mirrors
                .as_array()
                .map(|a| !a.is_empty())
                .unwrap_or(false);
            let mirrors = if top_empty {
                h.repo
                    .get("mirrors")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null)
            } else {
                h.mirrors.clone()
            };
            serde_json::json!({ "repo": h.repo, "mirrors": mirrors })
        }
        Err(_) => serde_json::json!({}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> String {
        serde_json::json!({
            "repo": {"name": "Demo", "description": "d", "icon": "icons/x.png", "timestamp": 1700000000},
            "mirrors": [{"url": "https://mirror.example.com/fdroid/repo", "countryCode": "CN"}],
            "packages": {
                "com.example.b": {"metadata": {"name": "B"}, "versions": {"2": {"file": {"name": "b.apk", "size": 20, "sha256": "bb"}}}},
                "com.example.a": {"metadata": {"name": "A"}, "versions": {"1": {"file": {"name": "a.apk", "size": 10, "sha256": "aa"}}}}
            }
        })
        .to_string()
    }

    /// 等价性：逐包解析 与 既有 Value 路径 必须产出**完全相同**的结果
    #[test]
    fn streaming_matches_value_path() {
        let text = fixture();

        // 新路径
        let streamed = parse_index_v2_reader(std::io::Cursor::new(text.as_bytes())).unwrap();

        // 旧路径（整份 Value 树）
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        let packages = value.get("packages").unwrap().as_object().unwrap();
        let mut legacy = Vec::new();
        for (pkg, data) in packages {
            legacy.push(AppInfo::from_json_value_v2(pkg, data).unwrap());
        }

        assert_eq!(streamed.len(), legacy.len());
        for (a, b) in streamed.iter().zip(legacy.iter()) {
            assert_eq!(format!("{a:?}"), format!("{b:?}"), "逐包解析结果与 Value 路径不一致");
        }
        // BTreeMap 顺序确定：应按包名升序
        assert_eq!(streamed[0].package_name, "com.example.a");
        assert_eq!(streamed[1].package_name, "com.example.b");
    }

    #[test]
    fn head_carries_repo_and_mirrors() {
        let text = fixture();
        let head = parse_index_head(text.as_bytes());
        assert_eq!(head["repo"]["name"], "Demo");
        assert_eq!(head["mirrors"][0]["url"], "https://mirror.example.com/fdroid/repo");
        // 坏输入不 panic，返回空对象
        assert!(parse_index_head(b"not json").as_object().unwrap().is_empty());
    }

    fn head_reads_nested_repo_mirrors() {
        // 真机形态（Bitwarden 源）：mirrors 在 repo 内部
        let raw = br#"{"repo":{"name":{"en-US":"Bitwarden F-Droid"},
            "mirrors":[{"isPrimary":true,"url":"https://mobileapp.bitwarden.com/fdroid/repo"},
                       {"url":"https://raw.githubusercontent.com/bitwarden/f-droid/main/fdroid/repo"}]}}"#;
        let head = parse_index_head(raw);
        assert_eq!(
            head["mirrors"][1]["url"],
            "https://raw.githubusercontent.com/bitwarden/f-droid/main/fdroid/repo"
        );
    }

    #[test]
    fn malformed_package_is_skipped_not_fatal() {
        let text = r#"{"packages":{"com.ok":{"metadata":{}},"com.bad":123}}"#;
        let apps = parse_index_v2_reader(std::io::Cursor::new(text.as_bytes())).unwrap();
        assert!(apps.iter().any(|a| a.package_name == "com.ok"));
    }
}
