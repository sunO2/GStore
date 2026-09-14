//! AndroidManifest.xml 深度提取（AXML 元素树遍历）
//!
//! 比宿主原先「扁平取属性值」多出：
//! - `compileSdkVersion` / `sharedUserId`
//! - 权限的 `maxSdkVersion`（LibChecker `HiddenPermissionsReader` 语义）
//! - 每类组件（activity 含 activity-alias / service / receiver / provider）的
//!   `exported` / `process` 与**嵌套 intent-filter 的 action 列表**
//! - `meta-data` 键值、`uses-static-library`（name / version / certDigest）
//!
//! 对齐 LibChecker：组件与 intent-filter 直接来自 AXML（`IntentFilterUtils
//! .parseComponentsFromApk`），不依赖 PackageManager。

use std::fs::File;
use std::io::Read;

use apk_info_axml::AXML;
use apk_info_xml::Element;
use zip::ZipArchive;

use crate::components::resolve_component_name;

/// 单项权限
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct PermissionInfo {
    /// 权限名（如 `android.permission.CAMERA`）
    pub name: String,
    /// `maxSdkVersion`（无则空串）
    pub max_sdk_version: String,
}

/// 单条 `<data>` 声明（深链/快捷启动的 scheme/host/path 规则）
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct IntentDataInfo {
    pub scheme: String,
    pub host: String,
    pub port: String,
    pub path: String,
    pub path_prefix: String,
    pub path_pattern: String,
    pub mime_type: String,
}

/// 单个 `<intent-filter>`
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct IntentFilterInfo {
    pub actions: Vec<String>,
    pub categories: Vec<String>,
    /// `android:autoVerify="true"`（仅对 http/https App Links 有意义）
    pub auto_verify: bool,
    /// 该 filter 下的全部 `<data>`（可多条，组合出多条 URI 规则）
    pub data: Vec<IntentDataInfo>,
}

/// 单个组件
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ComponentInfo {
    /// 类型：`activity` / `service` / `receiver` / `provider`
    pub kind: String,
    /// 完整类名（相对名已按包名补全）
    pub name: String,
    /// `android:exported`（缺省空串）
    pub exported: String,
    /// `android:process`（缺省空串）
    pub process: String,
    /// 嵌套 intent-filter 的 action 列表（全部 filter 的并集，规则匹配用）
    pub actions: Vec<String>,
    /// 嵌套 intent-filter 明细（含 `<data>`，深链/快捷启动分析用）
    pub intent_filters: Vec<IntentFilterInfo>,
}

/// 一条 meta-data
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct MetaDataItem {
    /// `android:name`
    pub name: String,
    /// `android:value` / `android:resource`（取到哪个用哪个）
    pub value: String,
}

/// 一条 uses-static-library
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct StaticLibraryInfo {
    /// `android:name`
    pub name: String,
    /// `android:version`
    pub version: String,
    /// `android:certDigest`
    pub cert_digest: String,
}

/// Manifest 深度提取结果
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ManifestInfo {
    pub package_name: String,
    pub version_name: String,
    pub version_code: String,
    pub min_sdk: String,
    pub target_sdk: String,
    pub compile_sdk: String,
    pub shared_user_id: String,
    /// 明文 `android:name` 主 Activity（首个 LAUNCHER activity）
    pub main_activity: String,
    pub permissions: Vec<PermissionInfo>,
    pub components: Vec<ComponentInfo>,
    pub meta_data: Vec<MetaDataItem>,
    pub static_libraries: Vec<StaticLibraryInfo>,
}

const MAX_PERMISSIONS: usize = 1024;
const MAX_COMPONENTS: usize = 4096;
const MAX_META_DATA: usize = 1024;
const MAX_STATIC_LIBS: usize = 256;

/// 解析 APK 的 AndroidManifest.xml（AXML）
pub fn parse_manifest(apk_path: &str) -> Result<ManifestInfo, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    parse_manifest_from(&mut archive)
}

/// 复用已打开的 archive（聚合入口用：一次打开产出全部节）
pub fn parse_manifest_from(archive: &mut ZipArchive<File>) -> Result<ManifestInfo, String> {
    let mut manifest_bytes = Vec::new();
    {
        let mut entry = archive
            .by_name("AndroidManifest.xml")
            .map_err(|e| format!("APK 缺少 AndroidManifest.xml: {e}"))?;
        entry
            .read_to_end(&mut manifest_bytes)
            .map_err(|e| e.to_string())?;
    }

    let mut slice = manifest_bytes.as_slice();
    let axml = AXML::new(&mut slice, None).map_err(|e| format!("解析 manifest 失败: {e}"))?;
    Ok(collect_manifest(&axml.root))
}

/// 从 AXML 元素树提取 manifest 信息。
/// 与字节解析解耦，便于直接用构造的元素树做单元测试。
pub fn collect_manifest(root: &Element) -> ManifestInfo {
    let mut info = ManifestInfo {
        package_name: attr(root, "package"),
        version_name: attr(root, "versionName"),
        version_code: attr(root, "versionCode"),
        shared_user_id: attr(root, "sharedUserId"),
        // 旧 AGP 把 compileSdkVersion 写在 manifest 根节点
        compile_sdk: attr(root, "compileSdkVersion"),
        ..Default::default()
    };

    for child in root.childrens() {
        match child.name() {
            "uses-sdk" => {
                info.min_sdk = attr(child, "minSdkVersion");
                info.target_sdk = attr(child, "targetSdkVersion");
            }
            "uses-permission" | "uses-permission-sdk-23" | "uses-permission-sdk-m" => {
                if info.permissions.len() < MAX_PERMISSIONS {
                    let name = attr(child, "name");
                    if !name.is_empty() {
                        info.permissions.push(PermissionInfo {
                            name,
                            max_sdk_version: attr(child, "maxSdkVersion"),
                        });
                    }
                }
            }
            "application" => {
                // 先取出包名，避免同时不可变/可变借用 info
                let pkg = info.package_name.clone();
                collect_application(child, &pkg, &mut info);
            }
            _ => {}
        }
    }

    // 去重（同一权限可能被多条 uses-permission 声明）
    info.permissions.sort_by(|a, b| a.name.cmp(&b.name));
    info.permissions.dedup_by(|a, b| a.name == b.name);
    info.components.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));
    info.meta_data.sort_by(|a, b| a.name.cmp(&b.name));

    info
}

/// 遍历 `<application>` 的子节点
fn collect_application(app: &Element, package_name: &str, info: &mut ManifestInfo) {
    for child in app.childrens() {
        match child.name() {
            "activity" | "activity-alias" | "service" | "receiver" | "provider" => {
                if info.components.len() >= MAX_COMPONENTS {
                    continue;
                }
                let raw = attr(child, "name");
                if raw.is_empty() {
                    continue;
                }
                let name = resolve_component_name(&raw, package_name);
                let intent_filters = collect_intent_filters(child);
                // actions = 全部 filter 的并集（保持原有规则匹配语义）
                let mut actions: Vec<String> = intent_filters
                    .iter()
                    .flat_map(|f| f.actions.iter().cloned())
                    .collect();
                actions.sort();
                actions.dedup();
                // activity-alias 归入 activity（与宿主既有组件枚举一致）
                let kind = if child.name() == "activity-alias" {
                    "activity"
                } else {
                    child.name()
                };
                info.components.push(ComponentInfo {
                    kind: kind.to_string(),
                    name,
                    exported: attr(child, "exported"),
                    process: attr(child, "process"),
                    actions,
                    intent_filters,
                });
            }
            "meta-data" => {
                if info.meta_data.len() < MAX_META_DATA {
                    let name = attr(child, "name");
                    if !name.is_empty() {
                        let value = {
                            let v = attr(child, "value");
                            if v.is_empty() {
                                attr(child, "resource")
                            } else {
                                v
                            }
                        };
                        info.meta_data.push(MetaDataItem { name, value });
                    }
                }
            }
            "uses-static-library" => {
                if info.static_libraries.len() < MAX_STATIC_LIBS {
                    let name = attr(child, "name");
                    if !name.is_empty() {
                        info.static_libraries.push(StaticLibraryInfo {
                            name,
                            version: attr(child, "version"),
                            cert_digest: attr(child, "certDigest"),
                        });
                    }
                }
            }
            _ => {}
        }
    }

    // 主 Activity：第一个带 MAIN + LAUNCHER 的 activity
    if info.main_activity.is_empty() {
        for child in app.childrens() {
            if child.name() != "activity" && child.name() != "activity-alias" {
                continue;
            }
            let mut has_main = false;
            let mut has_launcher = false;
            for f in child.childrens() {
                if f.name() != "intent-filter" {
                    continue;
                }
                for action in f.childrens() {
                    let tag = action.name();
                    let n = attr(action, "name");
                    if tag == "action" && n == "android.intent.action.MAIN" {
                        has_main = true;
                    }
                    if tag == "category"
                        && (n == "android.intent.category.LAUNCHER"
                            || n == "android.intent.category.INFO")
                    {
                        has_launcher = true;
                    }
                }
            }
            if has_main && has_launcher {
                info.main_activity = resolve_component_name(&attr(child, "name"), package_name);
                break;
            }
        }
    }
}

/// 取属性值（缺省空串）
fn attr(el: &Element, name: &str) -> String {
    el.attr(name).unwrap_or_default().to_string()
}

const MAX_INTENT_FILTERS: usize = 128;
const MAX_INTENT_DATA: usize = 128;

/// 收集组件的全部 `<intent-filter>`（含嵌套 `<data>` 的 scheme/host/path 规则）。
///
/// 注意：`<data>` 的多个属性是**组合条件**（scheme+host+path 同时满足），
/// 而同一 filter 下的多条 `<data>` 是**并列规则**；本函数按后者原样展开，
/// URI 的拼接与分组交由展示层处理。
fn collect_intent_filters(component: &Element) -> Vec<IntentFilterInfo> {
    let mut out = Vec::new();
    for f in component.childrens() {
        if f.name() != "intent-filter" {
            continue;
        }
        if out.len() >= MAX_INTENT_FILTERS {
            break;
        }
        let mut info = IntentFilterInfo {
            auto_verify: attr(f, "autoVerify") == "true",
            ..Default::default()
        };
        for c in f.childrens() {
            match c.name() {
                "action" => {
                    let v = attr(c, "name");
                    if !v.is_empty() {
                        info.actions.push(v);
                    }
                }
                "category" => {
                    let v = attr(c, "name");
                    if !v.is_empty() {
                        info.categories.push(v);
                    }
                }
                "data" => {
                    if info.data.len() >= MAX_INTENT_DATA {
                        continue;
                    }
                    let d = IntentDataInfo {
                        scheme: attr(c, "scheme"),
                        host: attr(c, "host"),
                        port: attr(c, "port"),
                        path: attr(c, "path"),
                        path_prefix: attr(c, "pathPrefix"),
                        path_pattern: attr(c, "pathPattern"),
                        mime_type: attr(c, "mimeType"),
                    };
                    // 全空的 data 无意义，跳过
                    if d != IntentDataInfo::default() {
                        info.data.push(d);
                    }
                }
                _ => {}
            }
        }
        info.actions.sort();
        info.actions.dedup();
        info.categories.sort();
        info.categories.dedup();
        out.push(info);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造一份元素树：manifest → uses-sdk / uses-permission×3 / application
    /// （meta-data / uses-static-library / activity+intent-filter / activity-alias / service）
    fn build_tree() -> Element {
        let mut manifest = Element::new("manifest");
        manifest.set_attribute("package", "com.example.demo");
        manifest.set_attribute("versionName", "1.2.3");
        manifest.set_attribute("versionCode", "42");
        manifest.set_attribute("sharedUserId", "com.example.shared");
        manifest.set_attribute("compileSdkVersion", "34");

        let mut uses_sdk = Element::new("uses-sdk");
        uses_sdk.set_attribute("minSdkVersion", "21");
        uses_sdk.set_attribute("targetSdkVersion", "34");
        manifest.append_child(uses_sdk);

        let mut perm = Element::new("uses-permission");
        perm.set_attribute("name", "android.permission.CAMERA");
        manifest.append_child(perm);
        // 重复声明 → 应去重
        let mut perm_dup = Element::new("uses-permission");
        perm_dup.set_attribute("name", "android.permission.CAMERA");
        manifest.append_child(perm_dup);
        // 带 maxSdkVersion
        let mut perm2 = Element::new("uses-permission");
        perm2.set_attribute("name", "android.permission.READ_PHONE_STATE");
        perm2.set_attribute("maxSdkVersion", "22");
        manifest.append_child(perm2);

        let mut app = Element::new("application");

        let mut meta = Element::new("meta-data");
        meta.set_attribute("name", "flutter.engine");
        meta.set_attribute("value", "true");
        app.append_child(meta);

        let mut static_lib = Element::new("uses-static-library");
        static_lib.set_attribute("name", "org.apache.http.legacy");
        static_lib.set_attribute("version", "1");
        static_lib.set_attribute("certDigest", "AABB");
        app.append_child(static_lib);

        let mut activity = Element::new("activity");
        activity.set_attribute("name", ".MainActivity");
        activity.set_attribute("exported", "true");
        let mut filter = Element::new("intent-filter");
        let mut action = Element::new("action");
        action.set_attribute("name", "android.intent.action.MAIN");
        filter.append_child(action);
        let mut cat = Element::new("category");
        cat.set_attribute("name", "android.intent.category.LAUNCHER");
        filter.append_child(cat);
        activity.append_child(filter);
        app.append_child(activity);

        let mut alias = Element::new("activity-alias");
        alias.set_attribute("name", "com.example.demo.Alias");
        app.append_child(alias);

        let mut service = Element::new("service");
        service.set_attribute("name", "com.third.party.PushService");
        service.set_attribute("process", ":push");
        app.append_child(service);

        manifest.append_child(app);
        manifest
    }

    #[test]
    fn extracts_identity_and_sdk_fields() {
        let info = collect_manifest(&build_tree());
        assert_eq!(info.package_name, "com.example.demo");
        assert_eq!(info.version_name, "1.2.3");
        assert_eq!(info.version_code, "42");
        assert_eq!(info.shared_user_id, "com.example.shared");
        assert_eq!(info.compile_sdk, "34");
        assert_eq!(info.min_sdk, "21");
        assert_eq!(info.target_sdk, "34");
    }

    #[test]
    fn permissions_dedup_and_keep_max_sdk_version() {
        let info = collect_manifest(&build_tree());
        assert_eq!(info.permissions.len(), 2, "重复的 CAMERA 应去重");
        let cam = info
            .permissions
            .iter()
            .find(|p| p.name == "android.permission.CAMERA")
            .unwrap();
        assert_eq!(cam.max_sdk_version, "");
        let phone = info
            .permissions
            .iter()
            .find(|p| p.name == "android.permission.READ_PHONE_STATE")
            .unwrap();
        assert_eq!(phone.max_sdk_version, "22");
    }

    #[test]
    fn components_resolve_names_and_collect_actions() {
        let info = collect_manifest(&build_tree());
        // activity-alias 归入 activity
        let acts: Vec<&str> = info
            .components
            .iter()
            .filter(|c| c.kind == "activity")
            .map(|c| c.name.as_str())
            .collect();
        assert!(acts.contains(&"com.example.demo.MainActivity"), "相对名应补全为 {acts:?}");
        assert!(acts.contains(&"com.example.demo.Alias"));

        let main = info
            .components
            .iter()
            .find(|c| c.name == "com.example.demo.MainActivity")
            .unwrap();
        assert_eq!(main.exported, "true");
        assert_eq!(main.actions, vec!["android.intent.action.MAIN".to_string()]);

        let svc = info
            .components
            .iter()
            .find(|c| c.kind == "service")
            .unwrap();
        assert_eq!(svc.name, "com.third.party.PushService");
        assert_eq!(svc.process, ":push");
        assert!(svc.actions.is_empty());
    }

    #[test]
    fn detects_main_launcher_activity() {
        let info = collect_manifest(&build_tree());
        assert_eq!(info.main_activity, "com.example.demo.MainActivity");
    }

    #[test]
    fn meta_data_and_static_libraries() {
        let info = collect_manifest(&build_tree());
        assert_eq!(info.meta_data.len(), 1);
        assert_eq!(info.meta_data[0].name, "flutter.engine");
        assert_eq!(info.meta_data[0].value, "true");

        assert_eq!(info.static_libraries.len(), 1);
        assert_eq!(info.static_libraries[0].name, "org.apache.http.legacy");
        assert_eq!(info.static_libraries[0].version, "1");
        assert_eq!(info.static_libraries[0].cert_digest, "AABB");
    }

    #[test]
    fn meta_data_falls_back_to_resource_attribute() {
        let mut manifest = Element::new("manifest");
        let mut app = Element::new("application");
        let mut meta = Element::new("meta-data");
        meta.set_attribute("name", "com.example.icon");
        meta.set_attribute("resource", "@0x7f0e0001");
        app.append_child(meta);
        manifest.append_child(app);

        let info = collect_manifest(&manifest);
        assert_eq!(info.meta_data[0].value, "@0x7f0e0001");
    }

    #[test]
    fn attr_helper_returns_empty_for_missing() {
        let mut el = Element::new("activity");
        el.set_attribute("name", "A");
        assert_eq!(attr(&el, "name"), "A");
        assert_eq!(attr(&el, "missing"), "");
    }

    #[test]
    fn collects_intent_filter_deep_link_data() {
        let mut manifest = Element::new("manifest");
        manifest.set_attribute("package", "com.example.demo");
        let mut app = Element::new("application");

        let mut activity = Element::new("activity");
        activity.set_attribute("name", ".DeepLinkActivity");
        activity.set_attribute("exported", "true");

        // 自定义 scheme + host + pathPrefix
        let mut f1 = Element::new("intent-filter");
        f1.set_attribute("autoVerify", "false");
        let mut a1 = Element::new("action");
        a1.set_attribute("name", "android.intent.action.VIEW");
        f1.append_child(a1);
        let mut c1 = Element::new("category");
        c1.set_attribute("name", "android.intent.category.BROWSABLE");
        f1.append_child(c1);
        let mut d1 = Element::new("data");
        d1.set_attribute("scheme", "myapp");
        d1.set_attribute("host", "open");
        d1.set_attribute("pathPrefix", "/detail");
        f1.append_child(d1);
        activity.append_child(f1);

        // App Links：https + autoVerify + 两条并列 data
        let mut f2 = Element::new("intent-filter");
        f2.set_attribute("autoVerify", "true");
        let mut a2 = Element::new("action");
        a2.set_attribute("name", "android.intent.action.VIEW");
        f2.append_child(a2);
        let mut d2 = Element::new("data");
        d2.set_attribute("scheme", "https");
        d2.set_attribute("host", "www.example.com");
        d2.set_attribute("pathPattern", "/p/[0-9]+");
        f2.append_child(d2);
        let mut d3 = Element::new("data");
        d3.set_attribute("scheme", "https");
        d3.set_attribute("host", "m.example.com");
        d3.set_attribute("port", "8443");
        f2.append_child(d3);
        activity.append_child(f2);

        // 无 data 的 filter（仅 LAUNCHER）→ 不产生深链
        let mut f3 = Element::new("intent-filter");
        let mut a3 = Element::new("action");
        a3.set_attribute("name", "android.intent.action.MAIN");
        f3.append_child(a3);
        activity.append_child(f3);

        app.append_child(activity);
        manifest.append_child(app);

        let info = collect_manifest(&manifest);
        let comp = &info.components[0];
        assert_eq!(comp.kind, "activity");
        assert_eq!(comp.name, "com.example.demo.DeepLinkActivity");
        // actions 仍为并集（规则匹配兼容）
        assert_eq!(
            comp.actions,
            vec![
                "android.intent.action.MAIN".to_string(),
                "android.intent.action.VIEW".to_string()
            ]
        );
        assert_eq!(comp.intent_filters.len(), 3);

        let custom = &comp.intent_filters[0];
        assert!(!custom.auto_verify);
        assert_eq!(custom.categories, vec!["android.intent.category.BROWSABLE"]);
        assert_eq!(custom.data.len(), 1);
        assert_eq!(custom.data[0].scheme, "myapp");
        assert_eq!(custom.data[0].host, "open");
        assert_eq!(custom.data[0].path_prefix, "/detail");

        let applink = &comp.intent_filters[1];
        assert!(applink.auto_verify);
        assert_eq!(applink.data.len(), 2, "同一 filter 下可有并列多条 data");
        assert_eq!(applink.data[0].path_pattern, "/p/[0-9]+");
        assert_eq!(applink.data[1].port, "8443");

        assert!(comp.intent_filters[2].data.is_empty());
    }

    #[test]
    fn skips_empty_data_element() {
        let mut manifest = Element::new("manifest");
        let mut app = Element::new("application");
        let mut activity = Element::new("activity");
        activity.set_attribute("name", "A");
        let mut f = Element::new("intent-filter");
        f.append_child(Element::new("data")); // 全空属性 → 跳过
        activity.append_child(f);
        app.append_child(activity);
        manifest.append_child(app);

        let info = collect_manifest(&manifest);
        assert!(info.components[0].intent_filters[0].data.is_empty());
    }

    #[test]
    fn missing_manifest_errors_clearly() {
        let dir = std::env::temp_dir().join(format!("gstore_manifest_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("t.apk");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            zip.start_file("classes.dex", zip::write::SimpleFileOptions::default())
                .unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 16]).unwrap();
            zip.finish().unwrap();
        }
        let err = parse_manifest(apk.to_str().unwrap()).unwrap_err();
        assert!(err.contains("AndroidManifest.xml"));
    }
}
