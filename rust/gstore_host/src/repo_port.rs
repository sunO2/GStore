//! `RepoPort` adapter over the existing `gstore_mod_repo` module.
//!
//! The host never shells out and never re-implements the F-Droid index parser;
//! every operation forwards to the module's existing `call` surface:
//!
//! | `RepoPort` | module method | payload |
//! |---|---|---|
//! | `download_repo` | `download_repo` | `{"url":..,"mirrors":[],"mirror_first":false}` |
//! | `get_app_count` | `get_app_count` | empty |
//! | `search_apps` | `search_apps` | `keyword NUL limit(i32 LE)` |
//! | `get_repo_meta` | `get_repo_meta` + `get_app_count` | empty |
//! | `clear_apps` | `clear_apps` | empty |
//! | `get_one_app` | `get_app_by_package` | `package` (falls back to `search_apps` (exact match) on [`Error::Unsupported`]) |
//! | `get_app_icons` | `get_app_icons` | newline-joined package names |
//!
//! The module owns the SQLite handle, so [`RepoPort::db_path`] returns the path
//! supplied when the module instance was created. Module status codes are
//! translated into the core [`Error`] enum (never collapsed into a string).

use std::path::{Path, PathBuf};

use gstore_contract::error::{ModuleError, StatusCode};
use gstore_core::ports::repo::{RepoApp, RepoMeta, RepoPort};
use gstore_core::Error;
use serde::Deserialize;
use serde_json::Value;

/// Transport seam for [`ModuleRepoPort`] (production: [`ModuleManagerBridge`]).
pub trait RepoBridge: Send + Sync {
    /// Invokes one `gstore_mod_repo` method with a raw payload.
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError>;
}

/// Bridge that routes through the host's global [`crate::manager::ModuleManager`].
#[derive(Debug, Clone, Copy)]
pub struct ModuleManagerBridge {
    module_id: u64,
    instance_id: u64,
}

impl ModuleManagerBridge {
    /// Binds to an already-created repo module instance.
    pub fn new(module_id: u64, instance_id: u64) -> Self {
        Self {
            module_id,
            instance_id,
        }
    }
}

impl RepoBridge for ModuleManagerBridge {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
        crate::manager::ModuleManager::global().call(
            self.module_id,
            Some(self.instance_id),
            method,
            payload,
        )
    }
}

/// [`RepoPort`] backed by a repo module bridge.
pub struct ModuleRepoPort<B: RepoBridge> {
    bridge: B,
    db_path: PathBuf,
}

impl<B: RepoBridge> ModuleRepoPort<B> {
    /// Creates the port. `db_path` must be the repo module's own database path
    /// (the module accepts it via its create context).
    pub fn new(bridge: B, db_path: impl Into<PathBuf>) -> Self {
        Self {
            bridge,
            db_path: db_path.into(),
        }
    }

    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, Error> {
        self.bridge.call(method, payload).map_err(map_module_error)
    }

    fn call_json(&self, method: &str, payload: &[u8]) -> Result<Value, Error> {
        let bytes = self.call(method, payload)?;
        serde_json::from_slice(&bytes).map_err(|error| {
            Error::Serialization(format!(
                "repo module {method} returned malformed JSON: {error}"
            ))
        })
    }

    /// Downloads/refreshes the repository index, forwarding `mirrors` and
    /// `mirror_first` to the module's `download_repo`.
    pub fn download_repo_with_mirrors(
        &self,
        source: &str,
        mirrors: &[String],
        mirror_first: bool,
    ) -> Result<RepoMeta, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        let payload = serde_json::to_vec(&serde_json::json!({
            "url": source,
            "mirrors": mirrors,
            "mirror_first": mirror_first
        }))
        .map_err(|error| Error::Serialization(format!("repo download payload: {error}")))?;
        let bytes = self.call("download_repo", &payload)?;
        let result: ModuleDownloadResult = serde_json::from_slice(&bytes).map_err(|error| {
            Error::Serialization(format!(
                "repo module download_repo returned malformed JSON: {error}"
            ))
        })?;
        let resolved = if result.resolved_url.is_empty() {
            source.to_string()
        } else {
            result.resolved_url
        };
        Ok(RepoMeta {
            source: resolved,
            name: result.repo_name,
            description: None,
            version: None,
            timestamp: None,
            app_count: u64::try_from(result.total_apps).unwrap_or(0),
        })
    }

    fn module_search(&self, query: &str, limit: usize) -> Result<Vec<ModuleApp>, Error> {
        let limit = i32::try_from(limit)
            .map_err(|_| Error::InvalidArgument("repo search limit is too large".to_string()))?;
        let mut payload = query.as_bytes().to_vec();
        payload.push(0);
        payload.extend_from_slice(&limit.to_le_bytes());
        let bytes = self.call("search_apps", &payload)?;
        serde_json::from_slice(&bytes).map_err(|error| {
            Error::Serialization(format!(
                "repo module search_apps returned malformed JSON: {error}"
            ))
        })
    }

    fn get_app_icons_per_app(
        &self,
        source: &str,
        package_names: &[String],
    ) -> Result<Vec<(String, String)>, Error> {
        let mut icons = Vec::with_capacity(package_names.len());
        for package_name in package_names {
            if let Some(app) = self.get_one_app(source, package_name)? {
                if let Some(icon) = app.icon.filter(|icon| !icon.is_empty()) {
                    icons.push((package_name.clone(), icon));
                }
            }
        }
        Ok(icons)
    }
}

impl<B: RepoBridge> RepoPort for ModuleRepoPort<B> {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        self.download_repo_with_mirrors(source, &[], false)
    }

    fn get_app_count(&self, source: &str) -> Result<u64, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        let value = self.call_json("get_app_count", &[])?;
        let count = value.get("count").and_then(Value::as_i64).ok_or_else(|| {
            Error::Serialization("repo module get_app_count missing count".to_string())
        })?;
        u64::try_from(count).map_err(|_| {
            Error::Serialization("repo module returned a negative app count".to_string())
        })
    }

    fn search_apps(&self, source: &str, query: &str, limit: usize) -> Result<Vec<RepoApp>, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        if query.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "repo search query must not be empty".to_string(),
            ));
        }
        if limit == 0 {
            return Err(Error::InvalidArgument(
                "repo search limit must be greater than zero".to_string(),
            ));
        }
        self.module_search(query, limit)?
            .iter()
            .map(|app| app.to_repo_app(source))
            .collect()
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        let value = self.call_json("get_repo_meta", &[])?;
        let Some(object) = value.as_object() else {
            return Err(Error::Serialization(
                "repo module get_repo_meta returned a non-object".to_string(),
            ));
        };
        if object.is_empty() {
            return Ok(None);
        }
        let resolved = object
            .get("resolved_url")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or(source);
        let name = object
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let description = object
            .get("description")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let version = object
            .get("index_timestamp")
            .and_then(Value::as_i64)
            .map(|value| value.to_string());
        let timestamp = object.get("timestamp").and_then(Value::as_i64);
        let app_count = self.get_app_count(source)?;
        Ok(Some(RepoMeta {
            source: resolved.to_string(),
            name,
            description,
            version,
            timestamp,
            app_count,
        }))
    }

    fn clear_apps(&self, source: &str) -> Result<(), Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        self.call("clear_apps", &[])?;
        Ok(())
    }

    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "package name must not be empty".to_string(),
            ));
        }
        match self.call_json("get_app_by_package", package_name.as_bytes()) {
            Ok(Value::Null) => Ok(None),
            Ok(value) => {
                let app: ModuleApp = serde_json::from_value(value).map_err(|error| {
                    Error::Serialization(format!(
                        "repo module get_app_by_package returned malformed JSON: {error}"
                    ))
                })?;
                Ok(Some(app.to_repo_app(source)?))
            }
            Err(Error::Unsupported(_)) => {
                let apps = self.module_search(package_name, 50)?;
                apps.iter()
                    .find(|app| app.package_name == package_name)
                    .map(|app| app.to_repo_app(source))
                    .transpose()
            }
            Err(error) => Err(error),
        }
    }

    fn get_app_icons(
        &self,
        source: &str,
        package_names: &[String],
    ) -> Result<Vec<(String, String)>, Error> {
        gstore_core::ports::repo::validate_repo_source(source)?;
        let payload = package_names.join("\n");
        match self.call_json("get_app_icons", payload.as_bytes()) {
            Ok(value) => {
                let icons: Vec<(String, String)> =
                    serde_json::from_value(value).map_err(|error| {
                        Error::Serialization(format!(
                            "repo module get_app_icons returned malformed JSON: {error}"
                        ))
                    })?;
                Ok(icons
                    .into_iter()
                    .filter(|(package_name, icon)| !package_name.is_empty() && !icon.is_empty())
                    .collect())
            }
            Err(Error::Unsupported(_)) => self.get_app_icons_per_app(source, package_names),
            Err(error) => Err(error),
        }
    }

    fn db_path(&self) -> &Path {
        &self.db_path
    }
}

#[derive(Debug, Deserialize)]
struct ModuleDownloadResult {
    #[serde(default)]
    total_apps: i32,
    #[serde(default)]
    resolved_url: String,
    #[serde(default)]
    repo_name: String,
}

#[derive(Debug, Deserialize)]
struct ModuleApp {
    package_name: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    icon: String,
    #[serde(default)]
    categories: Vec<String>,
    #[serde(default)]
    versions: Option<String>,
    #[serde(default)]
    metadata: Option<String>,
}

#[derive(Debug, Default)]
struct ModuleVersion {
    version: Option<String>,
    version_code: Option<i64>,
    apk_url: Option<String>,
    size: Option<i64>,
    added: i64,
}

impl ModuleApp {
    fn to_repo_app(&self, source: &str) -> Result<RepoApp, Error> {
        let latest = latest_version(self.versions.as_deref())?;
        let apk_url = latest.apk_url.map(|path| join_source(source, &path));
        Ok(RepoApp {
            package_name: self.package_name.clone(),
            name: self.name.clone(),
            summary: self.summary.clone(),
            version: latest.version,
            version_code: latest.version_code,
            icon: (!self.icon.is_empty()).then(|| self.icon.clone()),
            apk_url,
            size: latest.size,
            categories: self.categories.clone(),
            metadata: self.metadata.clone(),
        })
    }
}

fn latest_version(raw: Option<&str>) -> Result<ModuleVersion, Error> {
    let Some(raw) = raw.filter(|value| !value.trim().is_empty()) else {
        return Ok(ModuleVersion::default());
    };
    let value: Value = serde_json::from_str(raw).map_err(|error| {
        Error::Serialization(format!("repo app versions JSON is malformed: {error}"))
    })?;
    let entries: Vec<Value> = match value {
        Value::Object(map) => map.into_values().collect(),
        Value::Array(items) => items,
        _ => {
            return Err(Error::Serialization(
                "repo app versions must be an object or array".to_string(),
            ))
        }
    };
    let mut best = ModuleVersion::default();
    for entry in entries {
        let Value::Object(entry) = entry else {
            continue;
        };
        let added = entry.get("added").and_then(Value::as_i64).unwrap_or(0);
        let manifest = entry.get("manifest").and_then(Value::as_object);
        let version_code = manifest
            .and_then(|manifest| manifest.get("versionCode"))
            .and_then(Value::as_i64);
        let version = manifest
            .and_then(|manifest| manifest.get("versionName"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let file = entry.get("file").and_then(Value::as_object);
        let apk_url = file
            .and_then(|file| file.get("name"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let size = file
            .and_then(|file| file.get("size"))
            .and_then(Value::as_i64);
        let candidate = ModuleVersion {
            version,
            version_code,
            apk_url,
            size,
            added,
        };
        if candidate.added > best.added
            || (candidate.added == best.added && candidate.version_code > best.version_code)
        {
            best = candidate;
        }
    }
    Ok(best)
}

fn join_source(source: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    // The module normally returns absolute file names; for relative legacy
    // paths mirror Dart's `normalizeRepoAssetPath`: keep only the part after
    // the last `/repo/` so an already-`/repo` source is not doubled.
    let mut path = path.split('?').next().unwrap_or(path);
    if let Some(index) = path.rfind("/repo/") {
        path = &path[index + "/repo/".len()..];
    }
    let base = source.trim_end_matches('/');
    let path = path.trim_start_matches('/');
    if path.is_empty() {
        base.to_string()
    } else {
        format!("{base}/{path}")
    }
}

/// Maps the module's `StatusCode` into the stable core [`Error`] contract.
fn map_module_error(error: ModuleError) -> Error {
    let message = format!(
        "repo module [{}] {}: {}",
        error.status as i32, error.code, error.message
    );
    match error.status {
        StatusCode::Ok | StatusCode::Created => Error::Internal(message),
        StatusCode::ModuleNotLoaded
        | StatusCode::InstanceExpired
        | StatusCode::ModuleNotFound
        | StatusCode::InstanceNotFound => Error::NotFound(message),
        StatusCode::BadRequest | StatusCode::InvalidArgument => Error::InvalidArgument(message),
        StatusCode::MethodNotFound | StatusCode::VersionMismatch => Error::Unsupported(message),
        StatusCode::Aborted | StatusCode::ResourceExhausted => Error::Conflict(message),
        StatusCode::Timeout => Error::Network(message),
        StatusCode::InternalError | StatusCode::PanicCaught => Error::Internal(message),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};

    const SOURCE: &str = "https://f-droid.org/repo";

    #[derive(Default)]
    struct StaticBridgeState {
        responses: Mutex<VecDeque<(String, Vec<u8>)>>,
        calls: Mutex<Vec<(String, Vec<u8>)>>,
    }

    #[derive(Clone)]
    struct StaticBridge {
        state: Arc<StaticBridgeState>,
    }

    impl StaticBridge {
        fn new(responses: Vec<(&str, Value)>) -> Self {
            let state = StaticBridgeState::default();
            state.responses.lock().unwrap().extend(
                responses
                    .into_iter()
                    .map(|(method, value)| (method.to_string(), value.to_string().into_bytes())),
            );
            Self {
                state: Arc::new(state),
            }
        }

        fn calls(&self) -> Vec<(String, Vec<u8>)> {
            self.state.calls.lock().unwrap().clone()
        }

        fn call_count(&self) -> usize {
            self.state.calls.lock().unwrap().len()
        }
    }

    impl RepoBridge for StaticBridge {
        fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
            self.state
                .calls
                .lock()
                .unwrap()
                .push((method.to_string(), payload.to_vec()));
            let mut responses = self.state.responses.lock().unwrap();
            let position = responses
                .iter()
                .position(|(expected, _)| expected == method)
                .ok_or_else(|| ModuleError::method_not_found(method))?;
            Ok(responses.remove(position).unwrap().1)
        }
    }

    fn module_app(package_name: &str, icon: &str) -> Value {
        serde_json::json!({
            "package_name": package_name,
            "name": "Exact App",
            "summary": "summary",
            "icon": icon,
            "categories": ["tools"],
        })
    }

    #[test]
    fn repo_port_maps_search_and_download_fields() {
        let bridge = StaticBridge::new(vec![
            (
                "search_apps",
                serde_json::json!([{
                    "package_name": "com.example.app",
                    "name": "Example",
                    "summary": "summary",
                    "icon": "icons/com.example.app.png",
                    "categories": ["tools"],
                    "versions": serde_json::json!({
                        "1": {
                            "added": 10,
                            "manifest": {"versionName": "1.0", "versionCode": 1},
                            "file": {"name": "old.apk", "size": 10}
                        },
                        "2": {
                            "added": 20,
                            "manifest": {"versionName": "2.0", "versionCode": 2},
                            "file": {"name": "/repo/com.example.app_2.apk", "size": 20}
                        }
                    }).to_string()
                }]),
            ),
            (
                "download_repo",
                serde_json::json!({
                    "total_apps": 7,
                    "resolved_url": "https://mirror.test/repo",
                    "repo_name": "Mirror"
                }),
            ),
            ("get_app_count", serde_json::json!({"count": 7})),
            (
                "get_repo_meta",
                serde_json::json!({
                    "resolved_url": "https://mirror.test/repo",
                    "name": "Mirror",
                    "description": "desc",
                    "timestamp": 123,
                    "index_timestamp": 9
                }),
            ),
            ("clear_apps", serde_json::json!({"count": 1})),
        ]);
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let apps = port
            .search_apps("https://origin.test/repo", "example", 10)
            .unwrap();
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].package_name, "com.example.app");
        assert_eq!(apps[0].version.as_deref(), Some("2.0"));
        assert_eq!(apps[0].version_code, Some(2));
        assert_eq!(
            apps[0].apk_url.as_deref(),
            Some("https://origin.test/repo/com.example.app_2.apk")
        );
        assert_eq!(apps[0].size, Some(20));

        let meta = port.download_repo("https://origin.test/repo").unwrap();
        assert_eq!(meta.source, "https://mirror.test/repo");
        assert_eq!(meta.name, "Mirror");
        assert_eq!(meta.app_count, 7);

        let meta = port
            .get_repo_meta("https://origin.test/repo")
            .unwrap()
            .unwrap();
        assert_eq!(meta.version.as_deref(), Some("9"));
        assert_eq!(meta.timestamp, Some(123));
        assert_eq!(meta.app_count, 7);

        port.clear_apps("https://origin.test/repo").unwrap();
        assert_eq!(port.db_path(), Path::new("/data/repo.db"));
    }

    #[test]
    fn repo_port_maps_module_status_codes() {
        let cases = [
            (StatusCode::InvalidArgument, "invalid_argument"),
            (StatusCode::BadRequest, "invalid_argument"),
            (StatusCode::ModuleNotFound, "not_found"),
            (StatusCode::InstanceNotFound, "not_found"),
            (StatusCode::MethodNotFound, "unsupported"),
            (StatusCode::VersionMismatch, "unsupported"),
            (StatusCode::Timeout, "network"),
            (StatusCode::ResourceExhausted, "conflict"),
            (StatusCode::PanicCaught, "internal"),
            (StatusCode::InternalError, "internal"),
        ];
        for (status, expected) in cases {
            let error = map_module_error(ModuleError::new(status, "CODE", "message"));
            assert_eq!(error.code(), expected, "status {status:?}");
        }
    }

    #[test]
    fn get_one_app_returns_none_when_module_reports_no_row() {
        let bridge = StaticBridge::new(vec![("get_app_by_package", Value::Null)]);
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        assert_eq!(
            port.get_one_app(SOURCE, "com.example.missing").unwrap(),
            None
        );
    }

    #[test]
    fn get_one_app_maps_exact_module_row() {
        let bridge = StaticBridge::new(vec![(
            "get_app_by_package",
            module_app("com.example.app", "icons/com.example.app.png"),
        )]);
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let app = port
            .get_one_app(SOURCE, "com.example.app")
            .unwrap()
            .expect("exact row");
        assert_eq!(app.package_name, "com.example.app");
        assert_eq!(
            app.icon.as_deref(),
            Some("icons/com.example.app.png")
        );
    }

    #[test]
    fn get_one_app_falls_back_to_search_on_method_not_found() {
        let bridge = StaticBridge::new(vec![(
            "search_apps",
            serde_json::json!([
                module_app("com.example.other", "icons/other.png"),
                module_app("com.example.app", "icons/com.example.app.png"),
            ]),
        )]);
        let observer = bridge.clone();
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let app = port
            .get_one_app(SOURCE, "com.example.app")
            .unwrap()
            .expect("fallback exact row");
        assert_eq!(app.package_name, "com.example.app");
        assert_eq!(
            app.icon.as_deref(),
            Some("icons/com.example.app.png")
        );
        let methods: Vec<String> = observer
            .calls()
            .into_iter()
            .map(|(method, _)| method)
            .collect();
        assert_eq!(methods, vec!["get_app_by_package", "search_apps"]);
    }

    #[test]
    fn get_one_app_fallback_returns_none_when_search_misses() {
        let bridge = StaticBridge::new(vec![("search_apps", serde_json::json!([]))]);
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        assert_eq!(
            port.get_one_app(SOURCE, "com.example.missing").unwrap(),
            None
        );
    }

    #[test]
    fn get_app_icons_makes_one_module_call_for_twenty_packages() {
        let package_names: Vec<String> = (0..20)
            .map(|index| format!("org.example.app{index}"))
            .collect();
        let expected: Vec<(String, String)> = package_names
            .iter()
            .map(|package_name| {
                (
                    package_name.clone(),
                    format!("icons/{package_name}.png"),
                )
            })
            .collect();
        let bridge = StaticBridge::new(vec![("get_app_icons", serde_json::json!(expected))]);
        let observer = bridge.clone();
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let icons = port.get_app_icons(SOURCE, &package_names).unwrap();

        assert_eq!(icons, expected);
        assert_eq!(observer.call_count(), 1);
        let calls = observer.calls();
        assert_eq!(calls[0].0, "get_app_icons");
        assert_eq!(calls[0].1, package_names.join("\n").into_bytes());
        assert!(
            port.get_app_icons(SOURCE, &package_names).is_err(),
            "response queue is drained, so a second batch call must fail"
        );
    }

    #[test]
    fn get_app_icons_falls_back_per_app_when_module_lacks_the_method() {
        let bridge = StaticBridge::new(vec![
            (
                "get_app_by_package",
                module_app("org.example.a", "icons/a.png"),
            ),
            (
                "get_app_by_package",
                module_app("org.example.b", "icons/b.png"),
            ),
            ("get_app_by_package", Value::Null),
        ]);
        let observer = bridge.clone();
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let requested = vec![
            "org.example.a".to_string(),
            "org.example.b".to_string(),
            "org.example.missing".to_string(),
        ];
        let icons = port.get_app_icons(SOURCE, &requested).unwrap();

        assert_eq!(
            icons,
            vec![
                ("org.example.a".to_string(), "icons/a.png".to_string()),
                ("org.example.b".to_string(), "icons/b.png".to_string()),
            ]
        );
        let methods: Vec<String> = observer
            .calls()
            .into_iter()
            .map(|(method, _)| method)
            .collect();
        assert_eq!(
            methods,
            vec![
                "get_app_icons",
                "get_app_by_package",
                "get_app_by_package",
                "get_app_by_package",
            ]
        );
    }

    #[test]
    fn get_app_icons_fallback_uses_search_on_even_older_module() {
        let bridge = StaticBridge::new(vec![(
            "search_apps",
            serde_json::json!([module_app("org.example.a", "icons/a.png")]),
        )]);
        let observer = bridge.clone();
        let port = ModuleRepoPort::new(bridge, "/data/repo.db");

        let icons = port
            .get_app_icons(SOURCE, &["org.example.a".to_string()])
            .unwrap();

        assert_eq!(
            icons,
            vec![("org.example.a".to_string(), "icons/a.png".to_string())]
        );
        let methods: Vec<String> = observer
            .calls()
            .into_iter()
            .map(|(method, _)| method)
            .collect();
        assert_eq!(
            methods,
            vec!["get_app_icons", "get_app_by_package", "search_apps"]
        );
    }
}
