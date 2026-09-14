//! 规则匹配下沉到模块：native / dex / component / static / package
//!
//! 输入：APK 路径 + 规则集合 JSON（宿主 `assets/lcrules/*.json` 原样传入）。
//! 输出：命中列表（规则名 / label / 类别 / 命中的具体项）。
//!
//! 匹配语义对齐宿主原有实现与 LibChecker：
//! - **native(0)**：`.so` 文件名；先精确，再正则
//! - **dex(5)**：类名；正则整串 / `pkg.*` 前缀 / `pkg.` 命名空间
//! - **component(1-4)**：四类组件名；先精确，再正则（按 type 过滤）
//! - **static(6)**：`uses-static-library` 名；仅精确
//! - **action(9)**：组件 intent-filter 的 action 字符串；先精确，再正则
//!   （宿主资产名为 `rules_package.json`，但内容实为 intent action）
//!
//! **正则支持范围**：只实现规则库里实际用到的子集——字面量、`\.` 等转义、
//! `.*` 与 `(.*)` 通配。遇到字符类 `[...]`、`+`、`?`、`|`、`{}` 等不支持的语法，
//! 跳过该规则（`skipped_regex` 计数返回），由宿主侧的完整正则实现兜底。
//!
//! 附带 LibChecker 的**特殊原生库伴随验证**：Flutter(libapp.so) / Unity(libmain.so) /
//! 360(libjiagu*) / SecNeo(libDexHelper*) 需要伴生 .so 或 DEX 类佐证，否则剔除。

use serde::{Deserialize, Serialize};

use crate::dex_scan::scan_dex_classes;
use crate::manifest::{parse_manifest, ComponentInfo, ManifestInfo};
use crate::structure::scan_apk_structure;

/// 规则类型常量（与 LibChecker 规则库 `LibType` 对齐）
const TYPE_NATIVE: i32 = 0;
/// 1-4：service / activity / receiver / provider
const TYPE_DEX: i32 = 5;
const TYPE_STATIC: i32 = 6;
/// 9：intent-filter action（宿主 `rules_package.json` 的内容即 action，命名沿用旧资产名）
const TYPE_ACTION: i32 = 9;

/// 一条规则（字段与 `assets/lcrules/*.json` 一致）
#[derive(Clone, Debug, Deserialize)]
pub struct Rule {
    /// 匹配键（文件名 / 类名 / 组件名 / 包名，或正则）
    pub name: String,
    /// 展示名
    #[serde(default)]
    pub label: String,
    /// 规则类型
    #[serde(default)]
    pub r#type: i32,
    /// 是否正则（JSON 中为 0/1）
    #[serde(default, rename = "isRegexRule")]
    pub is_regex: i32,
}

impl Rule {
    fn regex(&self) -> bool {
        self.is_regex != 0
    }
}

/// 一条命中
#[derive(Clone, Debug, Serialize)]
pub struct RuleHit {
    /// 命中的规则名
    pub rule_name: String,
    /// 规则展示名
    pub label: String,
    /// 类别：`native` / `dex` / `component` / `static` / `package`
    pub kind: String,
    /// 命中的具体项（.so 名 / 类名 / 组件名 / 库名 / 包名）
    pub matched: String,
    /// 命中的是否为正则规则
    pub is_regex: bool,
    /// 组件类型（1=service 2=activity 3=receiver 4=provider；非组件为 0）
    pub component_type: i32,
}

/// 匹配结果
#[derive(Clone, Debug, Default, Serialize)]
pub struct MatchResult {
    pub hits: Vec<RuleHit>,
    /// 因正则语法超出支持子集而被跳过的规则数（宿主可回退处理）
    pub skipped_regex: usize,
    /// 命中的类名总数（诊断用）
    pub dex_class_count: usize,
}

/// 执行规则匹配
pub fn match_libraries(apk_path: &str, rules_json: &str) -> Result<MatchResult, String> {
    // 一次拿到 native 名字集合（只读中央目录，不解压）
    let so_names = all_native_so_names(apk_path).unwrap_or_default();
    let manifest = parse_manifest(apk_path).ok();

    // DEX 模式 = DEX 规则推导出的模式 + 伴随验证所需模式，**一次扫描复用**
    let patterns = dex_patterns_for_rules(rules_json);
    let dex_classes = scan_dex_classes(apk_path, &patterns).unwrap_or_default();

    match_libraries_with(rules_json, &so_names, manifest.as_ref(), &dex_classes)
}

/// 由规则 JSON 推导需要扫描的 DEX 模式（含伴随验证模式），已排序去重。
///
/// 公开给聚合入口：与特征识别的 pattern 求并集后只扫一次 DEX。
pub fn dex_patterns_for_rules(rules_json: &str) -> Vec<String> {
    let Ok(rules) = serde_json::from_str::<Vec<Rule>>(rules_json) else {
        return Vec::new();
    };
    let mut patterns: Vec<String> = Vec::new();
    for rule in rules
        .iter()
        .filter(|r| r.r#type == TYPE_DEX && !r.name.is_empty())
    {
        if let Ok(p) = dex_pattern_for(rule) {
            patterns.push(p);
        }
    }
    for p in CORROBORATION_PATTERNS {
        patterns.push((*p).to_string());
    }
    patterns.sort();
    patterns.dedup();
    patterns
}

/// 纯输入版规则匹配：native 名字 / manifest / DEX 类名由调用方提供
/// （聚合入口复用已算好的结果，不重复打开 APK 或重复解析 manifest、DEX）
pub fn match_libraries_with(
    rules_json: &str,
    so_names: &[String],
    manifest: Option<&ManifestInfo>,
    dex_classes: &[String],
) -> Result<MatchResult, String> {
    let rules: Vec<Rule> =
        serde_json::from_str(rules_json).map_err(|e| format!("规则 JSON 解析失败: {e}"))?;

    let mut result = MatchResult {
        dex_class_count: dex_classes.len(),
        ..Default::default()
    };
    let mut hits: Vec<RuleHit> = Vec::new();

    for rule in &rules {
        if rule.name.is_empty() {
            continue;
        }
        match rule.r#type {
            TYPE_NATIVE => {
                // 先精确，再正则
                if let Some(name) = so_names.iter().find(|n| *n == &rule.name) {
                    hits.push(hit(rule, "native", name.clone(), 0));
                    continue;
                }
                if rule.regex() {
                    match compile(rule) {
                        Ok(matcher) => {
                            if let Some(name) = so_names.iter().find(|n| matcher.matches(n)) {
                                hits.push(hit(rule, "native", name.clone(), 0));
                            }
                        }
                        Err(_) => result.skipped_regex += 1,
                    }
                }
            }
            TYPE_DEX => {
                if let Some(class) = match_class(&dex_classes, rule, &mut result.skipped_regex) {
                    hits.push(hit(rule, "dex", class, 0));
                }
            }
            TYPE_STATIC => {
                if let Some(m) = manifest.as_ref() {
                    if let Some(lib) = m.static_libraries.iter().find(|l| l.name == rule.name) {
                        hits.push(hit(rule, "static", lib.name.clone(), 0));
                    }
                }
            }
            TYPE_ACTION => {
                // 9 = intent-filter action：匹配全部组件声明的 action 字符串
                let Some(m) = manifest.as_ref() else {
                    continue;
                };
                let actions: Vec<&String> = m
                    .components
                    .iter()
                    .flat_map(|c| c.actions.iter())
                    .collect();
                if let Some(a) = actions.iter().find(|a| a.as_str() == rule.name) {
                    hits.push(hit(rule, "action", (*a).clone(), 0));
                    continue;
                }
                if rule.regex() {
                    match compile(rule) {
                        Ok(matcher) => {
                            if let Some(a) = actions.iter().find(|a| matcher.matches(a)) {
                                hits.push(hit(rule, "action", (*a).clone(), 0));
                            }
                        }
                        Err(_) => result.skipped_regex += 1,
                    }
                }
            }
            // 组件：按 type 过滤
            1 | 2 | 3 | 4 => {
                let Some(m) = manifest.as_ref() else {
                    continue;
                };
                let candidates: Vec<&ComponentInfo> = m
                    .components
                    .iter()
                    .filter(|c| match rule.r#type {
                        1 => c.kind == "service",
                        2 => c.kind == "activity",
                        3 => c.kind == "receiver",
                        _ => c.kind == "provider",
                    })
                    .collect();
                if let Some(c) = candidates.iter().find(|c| c.name == rule.name) {
                    hits.push(hit(rule, "component", c.name.clone(), rule.r#type));
                    continue;
                }
                if rule.regex() {
                    match compile(rule) {
                        Ok(matcher) => {
                            if let Some(c) = candidates.iter().find(|c| matcher.matches(&c.name)) {
                                hits.push(hit(rule, "component", c.name.clone(), rule.r#type));
                            }
                        }
                        Err(_) => result.skipped_regex += 1,
                    }
                }
            }
            _ => {}
        }
    }

    // 特殊原生库伴随验证
    let dex_has = |prefix: &str| dex_classes.iter().any(|c| c.starts_with(prefix));
    hits.retain(|h| {
        if h.kind != "native" {
            return true;
        }
        validate_special(&h.matched, &so_names, &dex_has)
    });

    // 按（类别, 规则名）去重后按 label 排序输出
    hits.sort_by(|a, b| {
        a.kind
            .cmp(&b.kind)
            .then_with(|| a.rule_name.cmp(&b.rule_name))
    });
    hits.dedup_by(|a, b| a.rule_name == b.rule_name && a.kind == b.kind);
    hits.sort_by(|a, b| {
        a.label
            .cmp(&b.label)
            .then_with(|| a.rule_name.cmp(&b.rule_name))
    });
    result.hits = hits;
    Ok(result)
}

/// 全部 `lib/<abi>/*.so` 文件名（去重排序）
fn all_native_so_names(apk_path: &str) -> Result<Vec<String>, String> {
    let structure = scan_apk_structure(apk_path)?;
    let mut names: Vec<String> = Vec::new();
    for group in &structure.abis {
        for lib in &group.libs {
            names.push(lib.name.clone());
        }
    }
    names.sort();
    names.dedup();
    Ok(names)
}

fn hit(rule: &Rule, kind: &str, matched: String, component_type: i32) -> RuleHit {
    RuleHit {
        rule_name: rule.name.clone(),
        label: rule.label.clone(),
        kind: kind.to_string(),
        matched,
        is_regex: rule.regex(),
        component_type,
    }
}

/// DEX 规则 → 扫描模式（对齐宿主 `dexScanPatterns`）
fn dex_pattern_for(rule: &Rule) -> Result<String, ()> {
    if rule.regex() {
        // 从正则提取字面量前缀：`kotlin\.(.*)` → `kotlin.`
        let literal = rule.name.split('(').next().unwrap_or("").replace("\\.", ".");
        if literal.is_empty() {
            return Err(());
        }
        Ok(format!("{literal}*"))
    } else if rule.name.ends_with('*') {
        Ok(rule.name.clone())
    } else {
        Ok(format!("{}.*", rule.name))
    }
}

/// DEX 命名匹配（正则整串 / `*` 前缀 / 命名空间）
fn match_class(
    classes: &[String],
    rule: &Rule,
    skipped: &mut usize,
) -> Option<String> {
    if rule.regex() {
        match compile(rule) {
            Ok(matcher) => return classes.iter().find(|c| matcher.matches(c)).cloned(),
            Err(_) => {
                *skipped += 1;
                return None;
            }
        }
    }
    if let Some(prefix) = rule.name.strip_suffix('*') {
        return classes
            .iter()
            .find(|c| c.starts_with(prefix))
            .cloned();
    }
    let namespace = format!("{}.", rule.name);
    classes
        .iter()
        .find(|c| c.as_str() == rule.name || c.starts_with(&namespace))
        .cloned()
}

/// 伴随验证所需额外模式
const CORROBORATION_PATTERNS: [&str; 4] = [
    "io.flutter.*",
    "com.qihoo.util.*",
    "com.tianyu.util.*",
    "com.secneo.apkwrapper.*",
];

/// 特殊原生库伴随验证（对齐 LibChecker `RulesRepository.getRulesWithRegex`）
fn validate_special(so_name: &str, all_so: &[String], dex_has: &dyn Fn(&str) -> bool) -> bool {
    let has_so = |n: &str| all_so.iter().any(|s| s == n);

    // Flutter：有 libflutter.so 伴生直接通过，否则需 FlutterInjector 类佐证
    if so_name == "libapp.so" {
        return has_so("libflutter.so") || dex_has("io.flutter.");
    }
    // Unity：必须有 libunity.so 伴生
    if so_name == "libmain.so" {
        return has_so("libunity.so");
    }
    // 360 加固壳
    if so_name.starts_with("libjiagu") {
        return dex_has("com.qihoo.util.") || dex_has("com.tianyu.util.");
    }
    // SecNeo 加固壳
    if so_name.starts_with("libDexHelper") {
        return dex_has("com.secneo.apkwrapper.");
    }
    true
}

// ==================== 轻量正则（规则库实际用到的子集） ====================

/// 支持的正则子集：字面量 / 转义 / `.*` / `(.*)`
#[derive(Debug)]
pub enum Matcher {
    /// 纯字面量 → 整串相等
    Exact(String),
    /// 含通配 → 按段匹配
    Segments(Vec<Segment>),
}

#[derive(Debug, Clone)]
pub enum Segment {
    Literal(String),
    /// `.*` / `(.*)`：任意长度
    Any,
}

/// 编译规则名为 [`Matcher`]；语法超出子集返回 Err
fn compile(rule: &Rule) -> Result<Matcher, ()> {
    compile_pattern(&rule.name)
}

/// 编译正则子集
pub fn compile_pattern(pattern: &str) -> Result<Matcher, ()> {
    let chars: Vec<char> = pattern.chars().collect();
    let mut segments: Vec<Segment> = Vec::new();
    let mut literal = String::new();
    let mut i = 0usize;
    let mut has_wildcard = false;

    while i < chars.len() {
        let c = chars[i];
        match c {
            '\\' => {
                let Some(next) = chars.get(i + 1) else {
                    return Err(()); // 悬空转义
                };
                // 只支持转义「元字符」为字面量
                if !matches!(next, '.' | '(' | ')' | '*' | '+' | '?' | '[' | ']' | '\\' | '|' | '{' | '}' | '$' | '^') {
                    return Err(());
                }
                literal.push(*next);
                i += 2;
            }
            '(' => {
                // 仅支持 `(.*)` 形式的分组
                if chars.get(i + 1) == Some(&'.')
                    && chars.get(i + 2) == Some(&'*')
                    && chars.get(i + 3) == Some(&')')
                {
                    if !literal.is_empty() {
                        segments.push(Segment::Literal(std::mem::take(&mut literal)));
                    }
                    segments.push(Segment::Any);
                    has_wildcard = true;
                    i += 4;
                } else {
                    return Err(());
                }
            }
            '.' => {
                if chars.get(i + 1) == Some(&'*') {
                    if !literal.is_empty() {
                        segments.push(Segment::Literal(std::mem::take(&mut literal)));
                    }
                    segments.push(Segment::Any);
                    has_wildcard = true;
                    i += 2;
                } else {
                    // 裸 `.`：按字面量 '.' 处理（规则库中仅出现在 `.` 分隔符位置）
                    literal.push('.');
                    i += 1;
                }
            }
            // 其余正则元字符不在支持范围内 → 交回宿主兜底
            '+' | '?' | '[' | ']' | '|' | '{' | '}' | '$' | '^' | '*' => return Err(()),
            _ => {
                literal.push(c);
                i += 1;
            }
        }
    }
    if !literal.is_empty() {
        segments.push(Segment::Literal(literal));
    }
    if !has_wildcard {
        return match segments.as_slice() {
            [Segment::Literal(s)] => Ok(Matcher::Exact(s.clone())),
            _ => Ok(Matcher::Exact(String::new())),
        };
    }
    Ok(Matcher::Segments(segments))
}

impl Matcher {
    /// 整串匹配（Kotlin `Pattern.matches` 语义）
    pub fn matches(&self, input: &str) -> bool {
        match self {
            Matcher::Exact(s) => s == input,
            Matcher::Segments(segs) => segments_match(segs, input),
        }
    }
}

/// 段匹配：首段锚定开头、末段锚定结尾，中间段按顺序查找
fn segments_match(segs: &[Segment], input: &str) -> bool {
    let mut pos = 0usize;
    let mut idx = 0usize;
    while idx < segs.len() {
        if let Segment::Literal(lit) = &segs[idx] {
            if idx == 0 {
                if !input[pos..].starts_with(lit.as_str()) {
                    return false;
                }
                pos += lit.len();
            } else {
                match input[pos..].find(lit.as_str()) {
                    Some(k) => pos += k + lit.len(),
                    None => return false,
                }
            }
        }
        idx += 1;
    }
    match segs.last() {
        Some(Segment::Literal(_)) => pos == input.len(),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(name: &str, ty: i32, regex: i32) -> Rule {
        Rule {
            name: name.to_string(),
            label: name.to_string(),
            r#type: ty,
            is_regex: regex,
        }
    }

    #[test]
    fn compiles_exact_and_matches_whole_string() {
        let m = compile_pattern("libfoo.so").unwrap();
        assert!(m.matches("libfoo.so"));
        assert!(!m.matches("libfoo.so.bak"), "整串匹配，不接受多余后缀");
        assert!(!m.matches("xlibfoo.so"));
    }

    #[test]
    fn compiles_escaped_dot_and_wildcard() {
        // libAMapSDK_MAP_v(.*)\.so
        let m = compile_pattern(r"libAMapSDK_MAP_v(.*)\.so").unwrap();
        assert!(m.matches("libAMapSDK_MAP_v10.2.1.so"));
        assert!(m.matches("libAMapSDK_MAP_v.so")); // 通配可空
        assert!(!m.matches("libAMapSDK_MAP_v10.so.bak"), "末尾需锚定");
        assert!(!m.matches("libBMapSDK_MAP_v10.so"));
    }

    #[test]
    fn wildcard_in_middle_requires_ordered_literals() {
        let m = compile_pattern(r"libaot-Xamarin\.Android\.(.*)\.dll\.so").unwrap();
        assert!(m.matches("libaot-Xamarin.Android.Foo.dll.so"));
        assert!(!m.matches("libaot-Xamarin.Android.Foo.so"));
    }

    #[test]
    fn unsupported_syntax_is_rejected() {
        assert!(compile_pattern(r"lib[abc]\.so").is_err(), "字符类不支持");
        assert!(compile_pattern(r"libfoo+\.so").is_err(), "加号不支持");
        assert!(compile_pattern(r"lib(foo|bar)\.so").is_err(), "非 (.*) 分组不支持");
        assert!(compile_pattern(r"libfoo\.so$").is_err(), "锚点字符不支持");
    }

    #[test]
    fn bare_dot_treated_as_literal() {
        // org.hapjs.(.*)
        let m = compile_pattern("org.hapjs.(.*)").unwrap();
        assert!(m.matches("org.hapjs.Foo"));
        assert!(!m.matches("orgXhapjs.Foo"));
    }

    #[test]
    fn dex_pattern_derivation_matches_host_semantics() {
        assert_eq!(dex_pattern_for(&rule(r"kotlin\.(.*)", 5, 1)).unwrap(), "kotlin.*");
        assert_eq!(dex_pattern_for(&rule("androidx.lifecycle", 5, 0)).unwrap(), "androidx.lifecycle.*");
        assert_eq!(dex_pattern_for(&rule("pkg.*", 5, 0)).unwrap(), "pkg.*");
    }

    #[test]
    fn class_matching_semantics() {
        let classes: Vec<String> = vec![
            "androidx.lifecycle.LiveData".to_string(),
            "kotlin.coroutines.Continuation".to_string(),
            "com.foo.Bar".to_string(),
        ];
        let mut skipped = 0usize;

        // 命名空间（点边界）
        assert!(match_class(&classes, &rule("androidx.lifecycle", 5, 0), &mut skipped).is_some());
        // 前缀
        assert!(match_class(&classes, &rule("kotlin.*", 5, 0), &mut skipped).is_some());
        // 正则整串
        assert!(match_class(&classes, &rule(r"kotlin\.(.*)", 5, 1), &mut skipped).is_some());
        // 不匹配
        assert!(match_class(&classes, &rule("com.other", 5, 0), &mut skipped).is_none());
        assert_eq!(skipped, 0);
    }

    #[test]
    fn special_native_validation() {
        let all_so = vec!["libapp.so".to_string(), "libflutter.so".to_string()];
        let no_dex = |_: &str| false;
        assert!(validate_special("libapp.so", &all_so, &no_dex), "有 libflutter.so 伴生即通过");

        let only_app = vec!["libapp.so".to_string()];
        assert!(!validate_special("libapp.so", &only_app, &no_dex));
        let with_dex = |p: &str| p == "io.flutter.";
        assert!(validate_special("libapp.so", &only_app, &with_dex), "有 FlutterInjector 类佐证即通过");

        // Unity 必须有伴生
        let unity = vec!["libmain.so".to_string(), "libunity.so".to_string()];
        assert!(validate_special("libmain.so", &unity, &no_dex));
        assert!(!validate_special("libmain.so", &only_app, &no_dex));

        // 加固壳需类佐证
        let jiagu = vec!["libjiagu.so".to_string()];
        let qihoo = |p: &str| p == "com.qihoo.util.";
        assert!(validate_special("libjiagu.so", &jiagu, &qihoo));
        assert!(!validate_special("libjiagu.so", &jiagu, &no_dex));
        assert!(!validate_special("libDexHelper.so", &jiagu, &no_dex));

        // 普通库不受影响
        assert!(validate_special("libcrypto.so", &jiagu, &no_dex));
    }
}
