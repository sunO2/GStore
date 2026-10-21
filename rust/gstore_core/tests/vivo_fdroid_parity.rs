//! Todo 11 parity: Vivo + F-Droid channel drivers.
//!
//! Every test name carries the `vivo_fdroid_parity` prefix so the plan QA
//! command selects this binary. Expectations come from the Dart sources, not
//! guesswork:
//!
//! * Vivo search: `lib/core/channel/impl/VivoChannel.dart:430-500`
//!   (`POST https://h5-api.appstore.vivo.com.cn/h5appstore/search/result-list`
//!   with defaults `imei=1234567890,av=18,app_version=2100,pictype=webp,
//!   h5_websource=h5appstore,target=local,cfrom=2` plus
//!   `key=<keyword>&page_index=1&apps_per_page=20`; headers `Accept`,
//!   `Accept-Language`, `Content-Type`).
//! * Vivo search mapping: `:760-840` — `appId = packageName.isNotEmpty ?
//!   packageName : id`, `repositories = id` (the vivo id), extra carries
//!   `vivoId/packageName/title/developer/iconUrl/remark`.
//! * Vivo info mapping: `:724-782` — `appId = packageName`,
//!   `repositories = packageName`, `category = [categoryName]`.
//! * Vivo detail: `:240-380` — `vivoId = extra['vivoId'] ?? repositories ??
//!   appId`; size is KB and becomes bytes; `version_name`, `file name =
//!   packageName_versionCode.apk`, sections order Version/Statistics/Rating/
//!   Downloads/Readme/Permissions.
//! * Vivo save: `:608-640` — `channel_apps` row with `channel_key=vivo`,
//!   category joined by `,`, extra JSON preserved, `add_time` epoch millis.
//! * F-Droid search: `FdroidChannel.dart:278-345` — RepoPort search with limit
//!   50; `appId = packageName`, `repositories = packageName`,
//!   `extra.sourceId`, icon normalized against the source.
//! * F-Droid list/read: `:209-256,430-509` — channel rows, icon rebuilt from
//!   the record's own source; disabled sources must not resurrect stale rows.
//! * F-Droid detail: `:604-722` — source resolved from the record, then a
//!   package lookup; section defaults Version (when downloads exist),
//!   Downloads, Readme.
//! * F-Droid update: the Wave 1 contract refreshes through
//!   `RepoPort::download_repo` (Dart's `doUpdate` was a no-op).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::channel::{ChannelDriver, FdroidDriver, VivoDriver};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{
    AppDownload, AppSummary, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::ports::{
    CoreConfig, FakeHttpPort, FakeRepoPort, HttpOptions, HttpPort, HttpResponse, RepoApp, RepoMeta,
    RepoPort,
};
use gstore_core::Error;
use serde_json::json;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_vivo_fdroid_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
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

fn meta(kind: ChannelKind, name: &str) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: name.to_string(),
        description: format!("{name} channel"),
        enabled: true,
        priority: 10,
        support_offline: false,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn vivo_key() -> ChannelKey {
    ChannelKey::new("vivo").unwrap()
}

fn fdroid_key() -> ChannelKey {
    ChannelKey::new("fdroid").unwrap()
}

#[allow(clippy::too_many_arguments)]
fn insert_channel_app(
    db: &DbHandle,
    channel: &str,
    app_id: &str,
    name: &str,
    user: &str,
    repositories: &str,
    icon: &str,
    description: &str,
    category: Option<&str>,
    add_time: i64,
    source_id: Option<&str>,
    extra: Option<&str>,
) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,description,\
             category,add_time,source_id,extra) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            rusqlite::params![
                channel,
                app_id,
                name,
                user,
                repositories,
                icon,
                description,
                category,
                add_time,
                source_id,
                extra
            ],
        )
        .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn vivo_driver(db: DbHandle, http: Arc<FakeHttpPort>) -> VivoDriver {
    let config = CoreConfig::new(Some("http://127.0.0.1:7890".to_string()), None).unwrap();
    VivoDriver::new(
        vivo_key(),
        meta(ChannelKind::Vivo, "vivo"),
        db,
        config,
        http,
    )
}

fn repo_app(package_name: &str, name: &str, icon: &str) -> RepoApp {
    RepoApp {
        package_name: package_name.to_string(),
        name: name.to_string(),
        summary: format!("{name} summary"),
        version: Some("1.2.3".to_string()),
        version_code: Some(10203),
        icon: Some(icon.to_string()),
        apk_url: Some(format!("https://fdroid.test/repo/{package_name}_10203.apk")),
        size: Some(4096),
        categories: vec!["tools".to_string()],
    }
}

fn repo_meta(source: &str, name: &str) -> RepoMeta {
    RepoMeta {
        source: source.to_string(),
        name: name.to_string(),
        description: Some(format!("{name} description")),
        version: Some("20002".to_string()),
        timestamp: Some(1_700_000_000),
        app_count: 0,
    }
}

// ---------------------------------------------------------------------------
// Recording RepoPort: the exact call log is the witness, not just an Ok.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
enum RepoCall {
    Download(String),
    AppCount(String),
    Search {
        source: String,
        query: String,
        limit: usize,
    },
    Meta(String),
    Clear(String),
    One {
        source: String,
        package: String,
    },
}

#[derive(Debug)]
struct RecordingRepoPort {
    inner: FakeRepoPort,
    calls: Mutex<Vec<RepoCall>>,
}

impl RecordingRepoPort {
    fn new(inner: FakeRepoPort) -> Self {
        Self {
            inner,
            calls: Mutex::new(Vec::new()),
        }
    }

    fn calls(&self) -> Vec<RepoCall> {
        self.calls.lock().unwrap().clone()
    }

    fn record(&self, call: RepoCall) {
        self.calls.lock().unwrap().push(call);
    }
}

impl RepoPort for RecordingRepoPort {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        self.record(RepoCall::Download(source.to_string()));
        self.inner.download_repo(source)
    }

    fn get_app_count(&self, source: &str) -> Result<u64, Error> {
        self.record(RepoCall::AppCount(source.to_string()));
        self.inner.get_app_count(source)
    }

    fn search_apps(&self, source: &str, query: &str, limit: usize) -> Result<Vec<RepoApp>, Error> {
        self.record(RepoCall::Search {
            source: source.to_string(),
            query: query.to_string(),
            limit,
        });
        self.inner.search_apps(source, query, limit)
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        self.record(RepoCall::Meta(source.to_string()));
        self.inner.get_repo_meta(source)
    }

    fn clear_apps(&self, source: &str) -> Result<(), Error> {
        self.record(RepoCall::Clear(source.to_string()));
        self.inner.clear_apps(source)
    }

    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error> {
        self.record(RepoCall::One {
            source: source.to_string(),
            package: package_name.to_string(),
        });
        self.inner.get_one_app(source, package_name)
    }

    fn db_path(&self) -> &Path {
        self.inner.db_path()
    }
}

struct FailingRepoPort;

impl RepoPort for FailingRepoPort {
    fn download_repo(&self, _source: &str) -> Result<RepoMeta, Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn get_app_count(&self, _source: &str) -> Result<u64, Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn search_apps(
        &self,
        _source: &str,
        _query: &str,
        _limit: usize,
    ) -> Result<Vec<RepoApp>, Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn get_repo_meta(&self, _source: &str) -> Result<Option<RepoMeta>, Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn clear_apps(&self, _source: &str) -> Result<(), Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn get_one_app(&self, _source: &str, _package: &str) -> Result<Option<RepoApp>, Error> {
        Err(Error::Serialization(
            "malformed repo index metadata".to_string(),
        ))
    }

    fn db_path(&self) -> &Path {
        Path::new("/tmp/failing-repo.db")
    }
}

fn fdroid_driver(db: DbHandle, repo: Arc<dyn RepoPort>, sources: Vec<&str>) -> FdroidDriver {
    let config = CoreConfig::default()
        .with_fdroid_sources(sources.into_iter().map(ToString::to_string).collect())
        .unwrap();
    FdroidDriver::new(
        fdroid_key(),
        meta(ChannelKind::Fdroid, "F-Droid"),
        db,
        config,
        repo,
    )
}

const VIVO_SEARCH_URL: &str = "https://h5-api.appstore.vivo.com.cn/h5appstore/search/result-list";
const VIVO_DETAIL_URL: &str = "https://h5-api.appstore.vivo.com.cn/detailInfo";

fn vivo_default_query() -> &'static str {
    "imei=1234567890&av=18&app_version=2100&pictype=webp&h5_websource=h5appstore&target=local&cfrom=2"
}

#[test]
fn vivo_fdroid_parity_vivo_search_maps_exact_url_headers_and_fields() {
    let dir = TempDir::new("vivo-search");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let http = Arc::new(FakeHttpPort::new());
    let driver = vivo_driver(db, http.clone());

    let body = json!({
        "code": 0,
        "data": {
            "appSearchResponse": {
                "value": [
                    {
                        "id": "90123",
                        "title_zh": "微信",
                        "icon_url": "https://vivo.test/mm.png",
                        "package_name": "com.tencent.mm",
                        "developer": "腾讯",
                        "remark": "社交应用"
                    },
                    {
                        "id": "90200",
                        "title": "抖音",
                        "icon": "https://vivo.test/dy.png",
                        "packageName": "com.ss.android.ugc.aweme",
                        "developerName": "字节跳动",
                        "introduction": "短视频"
                    }
                ]
            }
        }
    })
    .to_string();
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: body.into_bytes(),
    });

    let apps = driver.search_apps("微信", false).unwrap();
    assert_eq!(
        apps.iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.tencent.mm", "com.ss.android.ugc.aweme"]
    );
    assert_eq!(apps[0].package_name.as_deref(), Some("com.tencent.mm"));
    assert_eq!(apps[0].name, "微信");
    assert_eq!(apps[0].user, "腾讯");
    assert_eq!(
        apps[0].repositories, "90123",
        "Dart stores the vivo id in repositories"
    );
    assert_eq!(apps[0].icon, "https://vivo.test/mm.png");
    assert_eq!(apps[0].des, "社交应用");
    assert_eq!(apps[0].category, None);
    let extra = apps[0].extra.as_ref().unwrap();
    assert_eq!(extra.get("vivoId").unwrap(), &json!("90123"));
    assert_eq!(extra.get("packageName").unwrap(), &json!("com.tencent.mm"));
    assert_eq!(extra.get("title").unwrap(), &json!("微信"));
    assert_eq!(extra.get("developer").unwrap(), &json!("腾讯"));
    assert_eq!(
        extra.get("iconUrl").unwrap(),
        &json!("https://vivo.test/mm.png")
    );
    assert_eq!(extra.get("remark").unwrap(), &json!("社交应用"));

    let calls = http.calls();
    assert_eq!(calls.len(), 1, "empty keyword must not reach the network");
    assert_eq!(calls[0].method, "POST");
    assert_eq!(
        calls[0].url,
        format!(
            "{VIVO_SEARCH_URL}?{}&key=%E5%BE%AE%E4%BF%A1&page_index=1&apps_per_page=20",
            vivo_default_query()
        )
    );
    assert_eq!(calls[0].body.as_deref(), Some(&b""[..]));
    assert_eq!(
        calls[0].headers,
        vec![
            (
                "Accept".to_string(),
                "application/json, text/plain, */*".to_string()
            ),
            ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
            (
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string()
            ),
        ]
    );
    assert_eq!(calls[0].proxy.as_deref(), Some("http://127.0.0.1:7890"));

    // Empty keyword short-circuits with an empty success, exactly like Dart.
    let before = http.calls().len();
    assert!(driver.search_apps("", false).unwrap().is_empty());
    assert_eq!(http.calls().len(), before);

    println!(
        "vivo search url={} headers={:?} fields={:?}",
        calls[0].url, calls[0].headers, apps
    );
}

#[test]
fn vivo_fdroid_parity_vivo_detail_and_save_use_stored_vivo_id() {
    let dir = TempDir::new("vivo-detail");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let http = Arc::new(FakeHttpPort::new());
    let driver = vivo_driver(db.clone(), http.clone());

    let search_body = json!({
        "code": 0,
        "data": {"appSearchResponse": {"value": [{
            "id": "90123",
            "title_zh": "微信",
            "icon_url": "https://vivo.test/mm.png",
            "package_name": "com.tencent.mm",
            "developer": "腾讯",
            "remark": "社交应用"
        }]}}
    })
    .to_string();
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: search_body.into_bytes(),
    });
    let saved = driver.search_apps("微信", false).unwrap().remove(0);
    driver.add_app(&saved).unwrap();

    let (channel_key, app_id, name, user, repositories, icon, description, extra): (
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        Option<String>,
    ) = db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT channel_key,app_id,name,user,repositories,icon,description,extra \
                 FROM channel_apps WHERE channel_key='vivo' AND app_id='com.tencent.mm'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                    ))
                },
            )
            .map_err(|e| DbError(e.to_string()))
        })
        .unwrap();
    assert_eq!(channel_key, "vivo");
    assert_eq!(app_id, "com.tencent.mm");
    assert_eq!(name, "微信");
    assert_eq!(user, "腾讯");
    assert_eq!(repositories, "90123");
    assert_eq!(icon, "https://vivo.test/mm.png");
    assert_eq!(description, "社交应用");
    let extra: serde_json::Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
    assert_eq!(extra["vivoId"], json!("90123"));

    // `getAllApps` is the saved rows, newest first.
    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].app_id, "com.tencent.mm");
    assert_eq!(
        listed[0].package_name.as_deref(),
        Some("com.tencent.mm"),
        "AppSummary.fromChannelAddedApp promotes extra.packageName"
    );

    // Stored info hit: no HTTP call.
    let calls_before = http.calls().len();
    let stored = driver.get_app_info("com.tencent.mm", false).unwrap();
    assert_eq!(stored.name, "微信");
    assert_eq!(http.calls().len(), calls_before);

    // Detail resolves the vivo id from the stored record even when
    // force_refresh is true; Dart does the same (`repositories` stores vivoId).
    let detail_body = json!({
        "title_zh": "微信",
        "package_name": "com.tencent.mm",
        "icon_url": "https://vivo.test/mm.png",
        "introduction": "微信，是一个生活方式",
        "version_name": "8.0.48",
        "version_code": "80048",
        "size": 2048,
        "developerName": "腾讯科技",
        "download_url": "https://down.vivo.test/mm.apk",
        "download_count": 123456,
        "score": 4.5,
        "raters_count": 900,
        "favorite_count": 33,
        "screenshotList": ["https://img.vivo.test/1.png"],
        "permissionList": [{"permissionName": "CAMERA"}, {"name": "RECORD_AUDIO"}, "INTERNET"],
        "categoryName": "社交"
    })
    .to_string();
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: detail_body.into_bytes(),
    });
    let detail = driver.get_app_detail("com.tencent.mm", true).unwrap();
    assert_eq!(detail.app_id, "com.tencent.mm");
    assert_eq!(detail.name, "微信");
    assert_eq!(detail.package_name.as_deref(), Some("com.tencent.mm"));
    assert_eq!(detail.version.as_deref(), Some("8.0.48"));
    assert_eq!(detail.developer.as_deref(), Some("腾讯科技"));
    assert_eq!(detail.description, "微信，是一个生活方式");
    assert_eq!(
        detail.sections,
        vec![
            DetailSection::Version,
            DetailSection::Statistics,
            DetailSection::Rating,
            DetailSection::Downloads,
            DetailSection::Readme,
            DetailSection::Permissions,
        ]
    );
    assert_eq!(detail.downloads.len(), 1);
    let download = &detail.downloads[0];
    assert_eq!(download.url, "https://down.vivo.test/mm.apk");
    assert_eq!(download.name, "com.tencent.mm_80048.apk");
    assert_eq!(download.size, Some(2048 * 1024), "vivo size is KB");
    assert_eq!(download.version.as_deref(), Some("8.0.48"));
    assert_eq!(download.version_code, Some(80048));
    assert_eq!(download.platform.as_deref(), Some("android"));
    assert_eq!(download.download_count, Some(123456));
    assert!(
        download.downloadable,
        "a present download_url yields a downloadable artifact"
    );
    assert_eq!(detail.extra["rating"], json!(4.5));
    assert_eq!(detail.extra["favorites"], json!(33));
    assert_eq!(
        detail.extra["permissions"],
        json!(["CAMERA", "RECORD_AUDIO", "INTERNET"])
    );

    let calls = http.calls();
    let detail_call = calls.last().unwrap();
    assert_eq!(detail_call.method, "GET");
    assert_eq!(
        detail_call.url,
        format!(
            "{VIVO_DETAIL_URL}?{}&appId=90123&frompage=messageh5",
            vivo_default_query()
        ),
        "detail must use the stored vivo id, not the package name"
    );
    assert!(
        detail_call.headers.is_empty(),
        "Dart sends no custom headers on detail"
    );

    // `getAppInfo` with force_refresh bypasses the stored row and uses appId.
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: json!({
            "title_zh": "微信",
            "package_name": "com.tencent.mm",
            "icon_url": "https://vivo.test/mm.png",
            "introduction": "intro",
            "developerName": "腾讯",
            "categoryName": "社交"
        })
        .to_string()
        .into_bytes(),
    });
    let fresh = driver.get_app_info("com.tencent.mm", true).unwrap();
    assert_eq!(fresh.name, "微信");
    assert_eq!(fresh.package_name.as_deref(), Some("com.tencent.mm"));
    assert_eq!(fresh.repositories, "com.tencent.mm");
    assert_eq!(fresh.category, Some(vec!["社交".to_string()]));
    let calls = http.calls();
    assert_eq!(
        calls.last().unwrap().url,
        format!(
            "{VIVO_DETAIL_URL}?{}&appId=com.tencent.mm&frompage=messageh5",
            vivo_default_query()
        )
    );

    println!("vivo detail={detail:?} saved={channel_key}/{app_id} extra={extra}");
}

#[test]
fn vivo_fdroid_parity_vivo_error_envelope_status_and_malformed_json() {
    let dir = TempDir::new("vivo-errors");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();

    let cases: Vec<(u16, &str, &str)> = vec![
        (500, r#"{"message":"boom"}"#, "network"),
        (404, r#"{"message":"missing"}"#, "network"),
        (200, r#"{"code":1001,"message":"bad key"}"#, "network"),
        (200, r#"{"code":"oops"}"#, "serialization"),
        (200, "{not-json", "serialization"),
        (200, "[]", "serialization"),
        (
            200,
            r#"{"code":0,"data":{"appSearchResponse":{"value":"nope"}}}"#,
            "serialization",
        ),
    ];

    for (status, body, expected_code) in cases {
        let http = Arc::new(FakeHttpPort::new());
        http.push_response(HttpResponse {
            status,
            headers: Vec::new(),
            body: body.as_bytes().to_vec(),
        });
        let driver = vivo_driver(db.clone(), http);
        let error = driver
            .search_apps("微信", false)
            .expect_err("Vivo failures must be typed, never a panic");
        assert_eq!(
            error.code(),
            expected_code,
            "status {status} body {body:?} -> {error:?}"
        );
        if status != 200 {
            assert!(error.to_string().contains(&status.to_string()));
        }
        println!("vivo {status} {body:?} -> {}", error.code());
    }

    // Detail bodies that are not an object are typed serialization errors.
    let http = Arc::new(FakeHttpPort::new());
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: b"[]".to_vec(),
    });
    let driver = vivo_driver(db.clone(), http);
    let error = driver.get_app_info("com.example.x", true).unwrap_err();
    assert_eq!(error.code(), "serialization");

    // Missing optional fields do not panic; Dart defaults them.
    let http = Arc::new(FakeHttpPort::new());
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: br#"{"data":[{"id":"7"}]}"#.to_vec(),
    });
    let driver = vivo_driver(db, http);
    let apps = driver.search_apps("anything", false).unwrap();
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].app_id, "7");
    assert_eq!(apps[0].name, "");
    assert_eq!(apps[0].package_name, None);

    println!("vivo malformed/envelope cases all typed");
}

// ---------------------------------------------------------------------------
// F-Droid
// ---------------------------------------------------------------------------

const ENABLED_SOURCE: &str = "https://fdroid.test/repo";
const DISABLED_SOURCE: &str = "https://disabled.test/repo";

fn seeded_repo() -> RecordingRepoPort {
    let inner = FakeRepoPort::new("/tmp/module-repo.db");
    inner.add_repo(repo_meta(ENABLED_SOURCE, "Enabled Repo"));
    inner.add_repo(repo_meta(DISABLED_SOURCE, "Disabled Repo"));
    inner.add_app(
        ENABLED_SOURCE,
        repo_app("com.enabled", "Enabled App", "icons/com.enabled.png"),
    );
    inner.add_app(
        DISABLED_SOURCE,
        repo_app("com.disabled", "Disabled App", "icons/com.disabled.png"),
    );
    RecordingRepoPort::new(inner)
}

fn seeded_channel_db(dir: &TempDir) -> DbHandle {
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    insert_channel_app(
        &db,
        "fdroid",
        "com.enabled",
        "Enabled App",
        "Enabled Author",
        "com.enabled",
        "icons/com.enabled.png",
        "enabled summary",
        Some("tools"),
        200,
        Some(ENABLED_SOURCE),
        None,
    );
    insert_channel_app(
        &db,
        "fdroid",
        "com.disabled",
        "Disabled App",
        "Disabled Author",
        "com.disabled",
        "icons/com.disabled.png",
        "disabled summary",
        Some("games"),
        300,
        Some(DISABLED_SOURCE),
        None,
    );
    db
}

#[test]
fn vivo_fdroid_parity_fdroid_search_list_detail_and_update() {
    let dir = TempDir::new("fdroid-main");
    let db = seeded_channel_db(&dir);
    let repo = Arc::new(seeded_repo());
    let driver = fdroid_driver(db.clone(), repo.clone(), vec![ENABLED_SOURCE]);

    // list: only records whose own source is enabled; disabled rows are stale.
    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(
        listed
            .iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.enabled"]
    );
    assert_eq!(listed[0].name, "Enabled App");
    assert_eq!(listed[0].user, "Enabled Author");
    assert_eq!(
        listed[0].icon,
        "https://fdroid.test/repo/icons/com.enabled.png"
    );
    assert_eq!(listed[0].category, Some(vec!["tools".to_string()]));
    assert_eq!(
        listed[0].extra.as_ref().unwrap()["sourceId"],
        json!(ENABLED_SOURCE)
    );
    assert!(
        repo.calls().is_empty(),
        "list reads channel rows and must not touch the repository"
    );

    // search: one exact RepoPort call, limit 50, mapped fields.
    let hits = driver.search_apps("Enabled", false).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].app_id, "com.enabled");
    assert_eq!(hits[0].package_name.as_deref(), Some("com.enabled"));
    assert_eq!(hits[0].name, "Enabled App");
    assert_eq!(hits[0].user, "");
    assert_eq!(hits[0].repositories, "com.enabled");
    assert_eq!(
        hits[0].icon,
        "https://fdroid.test/repo/icons/com.enabled.png"
    );
    assert_eq!(hits[0].des, "Enabled App summary");
    assert_eq!(hits[0].category, Some(vec!["tools".to_string()]));
    assert_eq!(
        hits[0].extra.as_ref().unwrap()["sourceId"],
        json!(ENABLED_SOURCE)
    );
    assert_eq!(
        repo.calls(),
        vec![RepoCall::Search {
            source: ENABLED_SOURCE.to_string(),
            query: "Enabled".to_string(),
            limit: 50,
        }],
        "disabled sources must not be searched"
    );

    // detail: source comes from the channel row, then get_one_app.
    let detail = driver.get_app_detail("com.enabled", false).unwrap();
    assert_eq!(detail.app_id, "com.enabled");
    assert_eq!(detail.name, "Enabled App");
    assert_eq!(detail.package_name.as_deref(), Some("com.enabled"));
    assert_eq!(detail.description, "Enabled App summary");
    assert_eq!(detail.version.as_deref(), Some("1.2.3"));
    assert_eq!(
        detail.sections,
        vec![
            DetailSection::Version,
            DetailSection::Downloads,
            DetailSection::Readme,
        ]
    );
    assert_eq!(detail.downloads.len(), 1);
    let download = &detail.downloads[0];
    assert_eq!(
        download.url,
        "https://fdroid.test/repo/com.enabled_10203.apk"
    );
    assert_eq!(download.name, "com.enabled_10203.apk");
    assert_eq!(download.size, Some(4096));
    assert_eq!(download.version.as_deref(), Some("1.2.3"));
    assert_eq!(download.version_code, Some(10203));
    assert_eq!(detail.extra["sourceId"], json!(ENABLED_SOURCE));
    let calls = repo.calls();
    assert_eq!(
        calls.last(),
        Some(&RepoCall::One {
            source: ENABLED_SOURCE.to_string(),
            package: "com.enabled".to_string(),
        })
    );

    // update: do_update downloads each active source and reports true.
    let mut progress = Vec::new();
    let updated = driver
        .do_update(Some(&mut |current, total| progress.push((current, total))))
        .unwrap();
    assert!(updated);
    assert_eq!(progress, vec![(1, 1)]);
    assert_eq!(
        repo.calls().last(),
        Some(&RepoCall::Download(ENABLED_SOURCE.to_string()))
    );
    assert_eq!(repo.inner.download_count(), 1);

    // Repeated update is idempotent from the caller's perspective.
    assert!(driver.do_update(None).unwrap());
    assert_eq!(repo.inner.download_count(), 2);

    // update detection uses repository metadata, never a stale row.
    assert!(driver.check_update().unwrap());

    // categories match Dart's hard-coded list.
    let categories = driver.get_all_categories(false).unwrap();
    assert_eq!(categories.len(), 17);
    assert_eq!(categories[0].id, "1");
    assert_eq!(categories[0].description, "Games");
    assert!(driver
        .search_by_category("tools", false)
        .unwrap()
        .is_empty());

    println!(
        "fdroid list={:?} hits={:?} detail={detail:?} calls={:?}",
        listed, hits, calls
    );
}

#[test]
fn vivo_fdroid_parity_fdroid_add_app_and_source_filtering() {
    let dir = TempDir::new("fdroid-add");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let repo = Arc::new(seeded_repo());
    let driver = fdroid_driver(db.clone(), repo.clone(), vec![ENABLED_SOURCE]);

    let app = AppSummary {
        app_id: "com.new".to_string(),
        package_name: Some("com.new".to_string()),
        name: "New App".to_string(),
        user: "New Author".to_string(),
        repositories: "com.new".to_string(),
        icon: "https://fdroid.test/repo/icons/com.new.png".to_string(),
        des: "new summary".to_string(),
        readme: None,
        category: Some(vec!["tools".to_string(), "games".to_string()]),
        extra: Some(
            [("sourceId".to_string(), json!(ENABLED_SOURCE))]
                .into_iter()
                .collect(),
        ),
    };
    driver.add_app(&app).unwrap();

    let (name, category, source_id, icon, app_id): (
        String,
        Option<String>,
        Option<String>,
        String,
        String,
    ) = db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT name,category,source_id,icon,app_id FROM channel_apps \
                 WHERE channel_key='fdroid' AND app_id='com.new'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .map_err(|e| DbError(e.to_string()))
        })
        .unwrap();
    assert_eq!(name, "New App");
    assert_eq!(category.as_deref(), Some("tools,games"));
    assert_eq!(source_id.as_deref(), Some(ENABLED_SOURCE));
    assert_eq!(app_id, "com.new");
    assert_eq!(
        icon, "icons/com.new.png",
        "Dart stores only the repo-relative icon path"
    );

    // A record that carries no source is kept only while some source is active
    // (Dart falls back to the current source).
    insert_channel_app(
        &db,
        "fdroid",
        "com.legacy",
        "Legacy",
        "",
        "com.legacy",
        "",
        "legacy",
        None,
        400,
        None,
        None,
    );
    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(
        listed
            .iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.new", "com.legacy"]
    );
    assert_eq!(
        listed[1].icon, "https://fdroid.test/repo/icons/com.legacy.png",
        "an empty stored icon falls back to icons/<appId>.png on the current source"
    );

    // remove app is a plain DELETE (missing rows still succeed).
    driver.remove_app("com.new").unwrap();
    driver.remove_app("com.missing").unwrap();
    assert_eq!(
        driver
            .get_all_apps(false)
            .unwrap()
            .iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.legacy"]
    );

    println!("fdroid add row name={name:?} category={category:?} source={source_id:?}");
}

#[test]
fn vivo_fdroid_parity_fdroid_disabled_source_is_empty_not_error_and_no_download() {
    let dir = TempDir::new("fdroid-disabled");
    let db = seeded_channel_db(&dir);
    let repo = Arc::new(seeded_repo());
    // No configured source == every source disabled.
    let driver = fdroid_driver(db.clone(), repo.clone(), Vec::new());

    let listed = driver.get_all_apps(false).unwrap();
    assert!(
        listed.is_empty(),
        "a disabled source must not resurrect cached channel rows: {listed:?}"
    );
    let hits = driver.search_apps("Enabled", false).unwrap();
    assert!(
        hits.is_empty(),
        "disabled source search returns empty success, not an error: {hits:?}"
    );
    assert!(
        repo.calls().is_empty(),
        "a disabled source must not reach RepoPort at all: {:?}",
        repo.calls()
    );
    assert_eq!(repo.inner.download_count(), 0);
    assert!(!driver.do_update(None).unwrap());
    assert_eq!(repo.inner.download_count(), 0);
    assert!(!driver.check_update().unwrap());

    let info = driver.get_app_info("com.enabled", false);
    assert_eq!(
        info.unwrap_err().code(),
        "not_found",
        "detail requires an enabled source"
    );
    let detail = driver.get_app_detail("com.enabled", false);
    assert_eq!(detail.unwrap_err().code(), "not_found");

    // Configure only the *other* source: the enabled row is now the stale one.
    let other = fdroid_driver(db, repo.clone(), vec![DISABLED_SOURCE]);
    let listed = other.get_all_apps(false).unwrap();
    assert_eq!(
        listed
            .iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.disabled"]
    );
    let hits = other.search_apps("App", false).unwrap();
    assert_eq!(
        hits.iter()
            .map(|app| app.app_id.as_str())
            .collect::<Vec<_>>(),
        vec!["com.disabled"]
    );
    assert_eq!(
        repo.calls(),
        vec![RepoCall::Search {
            source: DISABLED_SOURCE.to_string(),
            query: "App".to_string(),
            limit: 50,
        }],
        "only the configured source is queried"
    );

    println!(
        "disabled source QA: list=[] search=[] downloads=0 calls={:?}",
        repo.calls()
    );
}

#[test]
fn vivo_fdroid_parity_fdroid_repo_errors_are_typed_and_do_not_panic() {
    let dir = TempDir::new("fdroid-errors");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let driver = fdroid_driver(db, Arc::new(FailingRepoPort), vec![ENABLED_SOURCE]);

    let search = driver.search_apps("anything", false).unwrap_err();
    assert_eq!(search.code(), "serialization");
    assert!(search.to_string().contains("malformed repo index metadata"));

    let detail = driver.get_app_detail("com.example.x", false).unwrap_err();
    assert_eq!(detail.code(), "serialization");

    let update = driver.do_update(None).unwrap_err();
    assert_eq!(update.code(), "serialization");

    // Unknown/missing metadata is a typed NotFound for a package lookup.
    let empty = FakeRepoPort::new("/tmp/empty-repo.db");
    let driver = fdroid_driver(
        DbHandle::open_at(&dir.path().join("other.db")).unwrap(),
        Arc::new(empty),
        vec![ENABLED_SOURCE],
    );
    assert_eq!(
        driver.get_app_info("com.none", false).unwrap_err().code(),
        "not_found"
    );

    println!("fdroid error mapping: search/detail/update all typed");
}

// Keep unused imports justified in test-only compile paths.
#[allow(dead_code)]
fn _assert_http_port_object_safe(_: &dyn HttpPort, _: &HttpOptions) -> Option<AppDownload> {
    None
}
