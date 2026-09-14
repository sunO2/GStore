//! 模块上下文（宿主 → 模块的 create 配置约定）
//!
//! 目的：把「模块运行需要的外部信息」标准化，避免每个模块各自约定位段、各自猜路径。
//! 通道复用既有的 `create(config)` 字节流 —— **零 ABI 变更**（不需要动注入表、不需要升 ABI）。
//!
//! 兼容策略：若字节不是 JSON 对象（历史模块传的是裸 DB 路径），整体作为 `db_path` 兜底，
//! 行为与旧版完全一致。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// 模块上下文：扁平字符串表（Android 路径无需嵌套结构，扁平更易解析与演进）
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModuleContext {
    /// 模块私有数据目录（宿主分配，模块自管其下文件/DB）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub data_dir: String,
    /// 可清理的缓存目录
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cache_dir: String,
    /// 显式 DB 路径（优先级高于 data_dir 推导）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub db_path: String,
    /// 当前 ABI（诊断/分发用）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub abi: String,
    /// 应用版本（诊断/兼容判断用）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub app_version: String,
    /// 预留扩展位：模块自定义键值（不破坏既有字段）
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extras: BTreeMap<String, String>,
}

impl ModuleContext {
    /// 解析 `create(config)` 字节。
    ///
    /// 非 JSON → 视为裸路径（历史约定），保证旧调用方行为不变。
    pub fn parse(bytes: &[u8]) -> Self {
        if bytes.is_empty() {
            return Self::default();
        }
        if let Ok(ctx) = serde_json::from_slice::<ModuleContext>(bytes) {
            return ctx;
        }
        Self {
            db_path: String::from_utf8_lossy(bytes).into_owned(),
            ..Self::default()
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// DB 路径优先级：显式 `db_path` > `data_dir/<fallback_name>` > `:memory:`
    pub fn resolve_db_path(&self, fallback_name: &str) -> String {
        if !self.db_path.is_empty() {
            return self.db_path.clone();
        }
        if !self.data_dir.is_empty() {
            return format!(
                "{}/{}",
                self.data_dir.trim_end_matches('/'),
                fallback_name
            );
        }
        ":memory:".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_json_context() {
        let json = br#"{"data_dir":"/data/x","cache_dir":"/cache","db_path":"/data/x/r.db","abi":"arm64-v8a","app_version":"1.2.3"}"#;
        let ctx = ModuleContext::parse(json);
        assert_eq!(ctx.data_dir, "/data/x");
        assert_eq!(ctx.cache_dir, "/cache");
        assert_eq!(ctx.db_path, "/data/x/r.db");
        assert_eq!(ctx.abi, "arm64-v8a");
        assert_eq!(ctx.app_version, "1.2.3");
    }

    #[test]
    fn legacy_raw_path_falls_back_to_db_path() {
        // 旧调用方传的是裸 UTF-8 路径，必须与旧版行为一致
        let ctx = ModuleContext::parse(b"/data/user/0/app/files/fdroid.db");
        assert_eq!(ctx.db_path, "/data/user/0/app/files/fdroid.db");
        assert!(ctx.data_dir.is_empty());
    }

    #[test]
    fn empty_bytes_is_default() {
        let ctx = ModuleContext::parse(b"");
        assert_eq!(ctx, ModuleContext::default());
        assert_eq!(ctx.resolve_db_path("repo.db"), ":memory:");
    }

    #[test]
    fn resolve_precedence() {
        // 显式 db_path 优先
        let ctx = ModuleContext { db_path: "/a/b.db".into(), data_dir: "/d".into(), ..Default::default() };
        assert_eq!(ctx.resolve_db_path("repo.db"), "/a/b.db");
        // 其次 data_dir 推导
        let ctx = ModuleContext { data_dir: "/d/".into(), ..Default::default() };
        assert_eq!(ctx.resolve_db_path("repo.db"), "/d/repo.db");
        // 都没有 → 内存库
        assert_eq!(ModuleContext::default().resolve_db_path("repo.db"), ":memory:");
    }

    #[test]
    fn encode_roundtrip_and_extras() {
        let mut ctx = ModuleContext { data_dir: "/d".into(), ..Default::default() };
        ctx.extras.insert("feature".into(), "on".into());
        let back = ModuleContext::parse(&ctx.encode());
        assert_eq!(back, ctx);
    }

    #[test]
    fn partial_json_is_tolerated() {
        // 只有部分字段也要能解析（前向/后向兼容）
        let ctx = ModuleContext::parse(br#"{"abi":"x86_64"}"#);
        assert_eq!(ctx.abi, "x86_64");
        assert!(ctx.data_dir.is_empty());
    }
}
