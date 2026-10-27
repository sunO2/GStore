//! Todo 10 parity: LocalDb + GitHub channel drivers.
//!
//! Every test name carries the `localdb_github_parity` prefix so the plan QA
//! command selects the whole file. Expectations are derived from the Dart
//! implementations, never guessed:
//!
//! * LocalDb rows/list/search/category:
//!   `lib/db/apps/AppInfoDao.dart` (`SELECT * FROM apps`,
//!   `searchFts` with `"word"*`, `searchWord` with `%word%`,
//!   `searchCategoryLike` with `%id%`) and
//!   `lib/core/channel/impl/LocalDbChannel.dart:123-184,708-775`.
//! * LocalDb `category` decode: `lib/db/apps/AppInfoDatabase.dart`
//!   `CategoryConverter.decode` = `databaseValue?.split(",") ?? []`.
//! * LocalDb `packageName` promotion:
//!   `AppSummary.fromDbAppInfo` reads `extra['packageName']`, never guesses.
//! * GitHub canonical id: `lib/core/channel/impl/GitHubChannel.dart:295-313`:
//!   `final metadata = await MetadataRepository.instance.fetchInfo(owner, repo);`
//!   `if (metadata == null) return appInfo.appId;`
//!   `final packageName = _validPackageName(metadata['packageName']?.toString());`
//!   `return packageName.isNotEmpty ? packageName : appInfo.appId;`
//! * GitHub search URL/headers: `GitHubChannel.dart:230-291`
//!   (`https://api.github.com/search/repositories?q=<keyword> in:name,description,readme&per_page=30`,
//!   `Accept: application/vnd.github+json`, `User-Agent: GStore-App/1.0`).
//! * GitHub add semantics: `GitHubChannel.dart:316-373`.
//! * GitHub error mapping statuses: Todo 10 contract in the wave plan.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use gstore_core::channel::{ChannelDriver, GitHubDriver, LocalDbDriver};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta, DetailSection};
use gstore_core::ports::{
    CachedMetadataPort, CoreConfig, FakeHttpPort, FakeMetadataPort, HttpOptions, HttpPort,
    HttpResponse, MetadataPort, PackageMetadata,
};
use serde_json::json;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_localdb_github_{tag}_{}_{}",
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

const TOKEN: &str = "ghp_TEST_SECRET_TOKEN_DO_NOT_LEAK";
const PROXY: &str = "http://127.0.0.1:7890";

fn meta(kind: ChannelKind, name: &str) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: name.to_string(),
        description: format!("{name} channel"),
        enabled: true,
        priority: 10,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn local_key() -> ChannelKey {
    ChannelKey::new("local_db").unwrap()
}

fn github_key() -> ChannelKey {
    ChannelKey::new("github").unwrap()
}

#[allow(clippy::too_many_arguments)]
fn insert_app(
    db: &DbHandle,
    app_id: &str,
    name: &str,
    user: &str,
    repositories: &str,
    icon: &str,
    des: &str,
    readme: Option<&str>,
    category: Option<&str>,
    extra: Option<&str>,
) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            rusqlite::params![
                app_id,
                name,
                user,
                repositories,
                icon,
                des,
                readme,
                category,
                extra
            ],
        )
        .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();
}

#[allow(clippy::too_many_arguments)]
fn insert_channel_app(
    db: &DbHandle,
    channel: &str,
    app_id: &str,
    name: &str,
    user: &str,
    repositories: &str,
    apprepo: Option<&str>,
    icon: &str,
    description: &str,
    category: Option<&str>,
    add_time: i64,
    extra: Option<&str>,
) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,apprepo,icon,\
             description,category,add_time,extra) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            rusqlite::params![
                channel,
                app_id,
                name,
                user,
                repositories,
                apprepo,
                icon,
                description,
                category,
                add_time,
                extra
            ],
        )
        .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();
}

/// Seeds the same observable shape as `assets/app/db/apps.db` (plus the
/// wave-1 `readme`/`extra` columns from `V1__core_schema.sql`):
///   categories: TOOLS / MEDIA
///   apps:       alpha (TOOLS,PRODUCTIVITY), beta (TOOLS), gamma (NULL)
fn seeded_local_db() -> (TempDir, DbHandle) {
    let dir = TempDir::new("local");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();

    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO categories(id,description,icon) VALUES ('TOOLS','工具','tools.svg')",
            [],
        )
        .map_err(|e| DbError(e.to_string()))?;
        conn.execute(
            "INSERT INTO categories(id,description,icon) VALUES ('MEDIA','影音','media.svg')",
            [],
        )
        .map_err(|e| DbError(e.to_string()))?;
        conn.execute(
            "INSERT INTO app_config(version,proxy) VALUES ('2026.10','http://proxy.test:1')",
            [],
        )
        .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();

    insert_app(
        &db,
        "com.example.alpha",
        "Alpha Tool",
        "acme",
        "alpha",
        "https://icons.test/alpha.png",
        "Fast alpha tool",
        Some("# Alpha\nbody"),
        Some("TOOLS,PRODUCTIVITY"),
        Some(r#"{"packageName":"com.example.alpha.real","stars":5}"#),
    );
    insert_app(
        &db,
        "com.example.beta",
        "Beta Editor",
        "",
        "",
        "beta.png",
        "Text editor for notes",
        None,
        Some("TOOLS"),
        None,
    );
    insert_app(
        &db,
        "com.example.gamma",
        "Gamma Player",
        "acme",
        "gamma",
        "",
        "Media alpha player",
        Some(""),
        None,
        Some(r#"{"packageName":""}"#),
    );
    (dir, db)
}

fn local_driver(db: DbHandle, metadata: Option<Arc<dyn MetadataPort>>) -> LocalDbDriver {
    let driver = LocalDbDriver::new(local_key(), meta(ChannelKind::LocalDb, "LocalDB"), db);
    match metadata {
        Some(metadata) => driver.with_metadata(metadata),
        None => driver,
    }
}

fn github_driver(
    db: DbHandle,
    http: Arc<FakeHttpPort>,
    metadata: Arc<dyn MetadataPort>,
) -> GitHubDriver {
    let config = CoreConfig::new(Some(PROXY.to_string()), Some(TOKEN.to_string())).unwrap();
    GitHubDriver::new(
        github_key(),
        meta(ChannelKind::Github, "GitHubAPI"),
        db,
        config,
        http,
        metadata,
    )
}

fn names(apps: &[AppSummary]) -> Vec<String> {
    apps.iter().map(|app| app.name.clone()).collect()
}

fn ids(apps: &[AppSummary]) -> Vec<String> {
    apps.iter().map(|app| app.app_id.clone()).collect()
}

fn assert_github_request(call: &gstore_core::ports::RecordedHttpCall, url: &str) {
    assert_eq!(call.method, "GET");
    assert_eq!(call.url, url, "request URL must be exact");
    assert_eq!(
        call.headers,
        vec![
            (
                "Accept".to_string(),
                "application/vnd.github+json".to_string()
            ),
            ("User-Agent".to_string(), "GStore-App/1.0".to_string()),
            ("Authorization".to_string(), format!("Bearer {TOKEN}")),
        ],
        "GitHub headers must carry the token, Accept, and User-Agent"
    );
    assert_eq!(call.proxy.as_deref(), Some(PROXY));
}

fn repo_json(full_name: &str, description: &str, html_url: &str, stars: i64) -> String {
    json!({
        "id": 1,
        "full_name": full_name,
        "name": full_name.split('/').next_back().unwrap_or(full_name),
        "description": description,
        "html_url": html_url,
        "stargazers_count": stars,
        "forks_count": 2,
        "default_branch": "main",
        "created_at": "2020-01-01T00:00:00Z"
    })
    .to_string()
}

fn search_json() -> String {
    json!({
        "total_count": 2,
        "items": [
            {
                "full_name": "acme/alpha",
                "name": "alpha",
                "description": "Alpha search hit",
                "owner": {"login": "acme", "avatar_url": "https://avatars.test/acme.png"}
            },
            {
                "full_name": "beta-org/beta",
                "name": "beta",
                "description": "Beta search hit",
                "owner": {"login": "beta-org", "avatar_url": "https://avatars.test/beta.png"}
            }
        ]
    })
    .to_string()
}

#[test]
fn localdb_github_parity_localdb_list_search_category_and_detail() {
    let (_dir, db) = seeded_local_db();
    let driver = local_driver(db, None);

    // `getAllApps` = `SELECT * FROM apps` (rowid order for a fresh table).
    let all = driver.get_all_apps(false).unwrap();
    assert_eq!(
        ids(&all),
        vec!["com.example.alpha", "com.example.beta", "com.example.gamma"]
    );
    assert_eq!(
        all[0].package_name.as_deref(),
        Some("com.example.alpha.real"),
        "AppSummary.fromDbAppInfo promotes extra.packageName"
    );
    assert_eq!(all[1].package_name, None);
    assert_eq!(
        all[2].package_name, None,
        "an empty extra.packageName is ignored, never used as a package name"
    );
    assert_eq!(
        all[0].category,
        Some(vec!["TOOLS".to_string(), "PRODUCTIVITY".to_string()]),
        "CategoryConverter.decode splits the comma-separated column"
    );
    assert_eq!(
        all[2].category,
        Some(Vec::<String>::new()),
        "Dart CategoryConverter.decode(null) returns [] (not null)"
    );
    assert_eq!(
        all[0].extra.as_ref().and_then(|map| map.get("stars")),
        Some(&json!(5))
    );
    assert!(all[1].extra.is_none());

    // `search("Alpha")`: FTS5 `"Alpha"*` yields alpha (name) + gamma (des),
    // then `LIKE %Alpha%` adds nothing new.
    let fts = driver.search_apps("Alpha", false).unwrap();
    assert_eq!(ids(&fts), vec!["com.example.alpha", "com.example.gamma"]);
    // `search("lpha")`: FTS prefix does not match inside a token, LIKE does.
    let like = driver.search_apps("lpha", false).unwrap();
    assert_eq!(
        ids(&like),
        vec!["com.example.alpha", "com.example.gamma"],
        "LIKE fallback must recover non-token-prefix matches"
    );
    assert_eq!(
        ids(&driver.search_apps("notes", false).unwrap()),
        vec!["com.example.beta"]
    );
    assert!(
        driver.search_apps("", false).unwrap().is_empty(),
        "Dart search returns [] for an empty keyword"
    );

    // `queryCategory(id)` = `category LIKE '%id%'` (substring, not equality).
    assert_eq!(
        ids(&driver.search_by_category("TOOLS", false).unwrap()),
        vec!["com.example.alpha", "com.example.beta"]
    );
    assert_eq!(
        ids(&driver.search_by_category("PRODUCTIVITY", false).unwrap()),
        vec!["com.example.alpha"]
    );
    assert_eq!(
        ids(&driver.search_by_category("TOOL", false).unwrap()),
        vec!["com.example.alpha", "com.example.beta"],
        "Dart category filtering is a LIKE, so partial ids match"
    );

    let categories = driver.get_all_categories(false).unwrap();
    assert_eq!(categories.len(), 2);
    assert_eq!(categories[0].id, "TOOLS");
    assert_eq!(categories[0].description, "工具");
    assert_eq!(categories[1].id, "MEDIA");

    let info = driver.get_app_info("com.example.alpha", false).unwrap();
    assert_eq!(info.name, "Alpha Tool");
    assert_eq!(info.user, "acme");
    assert_eq!(info.repositories, "alpha");
    assert_eq!(info.readme.as_deref(), Some("# Alpha\nbody"));
    assert_eq!(info.des, "Fast alpha tool");

    // `getAppDetail` maps the row, falls back to `des` when `readme` is absent,
    // and exposes the GitHub project URL only when owner/repo are present.
    let detail = driver.get_app_detail("com.example.alpha", false).unwrap();
    assert_eq!(detail.app_id, "com.example.alpha");
    assert_eq!(detail.name, "Alpha Tool");
    assert_eq!(detail.developer.as_deref(), Some("acme"));
    assert_eq!(
        detail.package_name.as_deref(),
        Some("com.example.alpha.real")
    );
    assert_eq!(
        detail.project_url.as_deref(),
        Some("https://github.com/acme/alpha")
    );
    assert!(detail.downloads.is_empty());
    assert_eq!(
        detail.sections,
        vec![DetailSection::Downloads, DetailSection::Readme]
    );
    assert_eq!(
        detail.extra.get("stars"),
        Some(&json!(5)),
        "LocalDb detail carries the row's extra object"
    );

    let beta = driver.get_app_detail("com.example.beta", false).unwrap();
    assert_eq!(beta.project_url, None);
    assert!(beta.sections.contains(&DetailSection::Readme));

    assert_eq!(
        driver.get_app_info("missing", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        driver.get_app_detail("missing", false).unwrap_err().code(),
        "not_found"
    );

    let config = driver.get_config(false).unwrap().unwrap();
    assert_eq!(config.version, "2026.10");
    assert_eq!(config.proxy.as_deref(), Some("http://proxy.test:1"));

    println!(
        "localdb list={:?} fts={:?} like={:?} categories={:?}",
        names(&all),
        ids(&fts),
        ids(&like),
        categories.iter().map(|c| c.id.clone()).collect::<Vec<_>>()
    );
}

#[test]
fn localdb_github_parity_localdb_metadata_override_and_writes_unsupported() {
    let (_dir, db) = seeded_local_db();
    let fake = FakeMetadataPort::new();
    fake.set(
        "acme",
        "alpha",
        Some(PackageMetadata {
            package_name: Some("com.example.alpha.meta".to_string()),
            app_name: Some("Alpha Meta".to_string()),
            icon_url: Some("https://icons.test/meta.png".to_string()),
            version_name: None,
        }),
    );
    let driver = local_driver(db.clone(), Some(Arc::new(fake.clone())));

    // `LocalDbChannel._applyMetadataOverride(..., keepExistingPackageName: false)`
    // replaces package/name/icon while preserving appId and extra.
    let info = driver.get_app_info("com.example.alpha", false).unwrap();
    assert_eq!(info.package_name.as_deref(), Some("com.example.alpha.meta"));
    assert_eq!(info.name, "Alpha Meta");
    assert_eq!(info.icon, "https://icons.test/meta.png");
    assert_eq!(info.app_id, "com.example.alpha");
    assert_eq!(
        info.extra.as_ref().and_then(|m| m.get("stars")),
        Some(&json!(5))
    );

    // `keepExistingPackageName: true` keeps the row package when metadata is
    // missing a usable package (Dart getAppDetail semantics).
    fake.set(
        "acme",
        "gamma",
        Some(PackageMetadata {
            package_name: None,
            app_name: Some("Gamma Meta".to_string()),
            icon_url: None,
            version_name: None,
        }),
    );
    let gamma = driver.get_app_detail("com.example.gamma", false).unwrap();
    assert_eq!(gamma.name, "Gamma Meta");
    // gamma's row package comes from extra.packageName, which is empty -> None.
    assert_eq!(gamma.package_name, None);

    // Dart explicitly rejects manual add/remove on the local DB channel; the
    // read-only Rust driver makes that contract typed Unsupported.
    let sample = driver.get_app_info("com.example.alpha", false).unwrap();
    assert_eq!(driver.add_app(&sample).unwrap_err().code(), "unsupported");
    assert_eq!(
        driver.remove_app("com.example.alpha").unwrap_err().code(),
        "unsupported"
    );
    assert_eq!(driver.do_update(None).unwrap_err().code(), "unsupported");

    let count: i64 = db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM apps", [], |row| row.get(0))
                .map_err(|e| DbError(e.to_string()))
        })
        .unwrap();
    assert_eq!(
        count, 3,
        "unsupported writes must not mutate the apps table"
    );

    let fts_hits = driver.search_apps("Meta", false).unwrap();
    assert!(
        fts_hits.is_empty(),
        "metadata override affects getAppInfo/detail, not list/search rows"
    );

    println!("localdb metadata info={info:?} gamma_detail={gamma:?}");
}

#[test]
fn localdb_github_parity_github_list_info_search_and_canonical() {
    let dir = TempDir::new("github");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    insert_channel_app(
        &db,
        "github",
        "acme/alpha",
        "Stored Alpha",
        "acme",
        "alpha",
        Some("acme/alpha"),
        "stored-alpha.png",
        "Stored alpha description",
        Some("TOOLS"),
        100,
        Some(r#"{"packageName":"com.example.stored"}"#),
    );
    insert_channel_app(
        &db,
        "github",
        "com.example.beta",
        "Stored Beta",
        "acme",
        "beta",
        Some("acme/beta"),
        "stored-beta.png",
        "Stored beta description",
        None,
        200,
        None,
    );
    // Historical dirty record: repositories was stored as the full name.
    insert_channel_app(
        &db,
        "github",
        "acme/dirty",
        "Dirty Record",
        "acme",
        "acme/dirty",
        Some("acme/dirty"),
        "dirty.png",
        "dirty description",
        None,
        50,
        None,
    );
    // Another channel must never leak into the GitHub driver.
    insert_channel_app(
        &db,
        "local_db",
        "acme/other",
        "Other Channel",
        "acme",
        "other",
        None,
        "",
        "other",
        None,
        300,
        None,
    );

    let http = Arc::new(FakeHttpPort::new());
    let fake_meta = FakeMetadataPort::new();
    fake_meta.set(
        "acme",
        "alpha",
        Some(PackageMetadata {
            package_name: Some("com.example.alpha.meta".to_string()),
            app_name: Some("Alpha Meta".to_string()),
            icon_url: Some("https://icons.test/alpha-meta.png".to_string()),
            version_name: None,
        }),
    );
    let metadata: Arc<dyn MetadataPort> = Arc::new(fake_meta);
    let driver = github_driver(db.clone(), http.clone(), metadata);

    // `getAllApps` reads `channel_added_app WHERE channelCode='github'
    // ORDER BY addTime DESC`; dirty repositories are normalized (user/repo).
    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(
        ids(&listed),
        vec!["com.example.beta", "acme/alpha", "acme/dirty"]
    );
    assert_eq!(
        listed[1].package_name.as_deref(),
        Some("com.example.stored")
    );
    assert_eq!(
        listed[1].category,
        Some(vec!["TOOLS".to_string()]),
        "channel record category is split on commas"
    );
    assert_eq!(listed[0].category, None);
    assert_eq!(listed[2].user, "acme");
    assert_eq!(listed[2].repositories, "dirty");

    // Stored hit -> metadata override, no HTTP call.
    let stored = driver.get_app_info("acme/alpha", false).unwrap();
    assert_eq!(stored.name, "Alpha Meta");
    assert_eq!(
        stored.package_name.as_deref(),
        Some("com.example.alpha.meta")
    );
    assert_eq!(stored.icon, "https://icons.test/alpha-meta.png");
    assert_eq!(stored.des, "Stored alpha description");
    assert!(
        http.calls().is_empty(),
        "stored getAppInfo must not hit HTTP"
    );

    // Non-stored owner/repo -> GET /repos/{owner}/{repo}.
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: repo_json(
            "acme/gamma",
            "Gamma from GitHub",
            "https://github.com/acme/gamma",
            7,
        )
        .into_bytes(),
    });
    let fresh = driver.get_app_info("acme/gamma", false).unwrap();
    assert_eq!(fresh.app_id, "acme/gamma");
    assert_eq!(fresh.name, "gamma");
    assert_eq!(fresh.user, "acme");
    assert_eq!(fresh.repositories, "gamma");
    assert_eq!(fresh.des, "Gamma from GitHub");
    assert_eq!(fresh.icon, "");
    assert_eq!(fresh.package_name, None);
    let calls = http.calls();
    assert_eq!(calls.len(), 1);
    assert_github_request(&calls[0], "https://api.github.com/repos/acme/gamma");

    // Search: exact Dart URL and mapped fields.
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: search_json().into_bytes(),
    });
    let hits = driver.search_apps("alpha", false).unwrap();
    assert_eq!(ids(&hits), vec!["acme/alpha", "beta-org/beta"]);
    assert_eq!(hits[0].name, "alpha");
    assert_eq!(hits[0].user, "acme");
    assert_eq!(hits[0].repositories, "alpha");
    assert_eq!(hits[0].icon, "https://avatars.test/acme.png");
    assert_eq!(hits[0].des, "Alpha search hit");
    assert_eq!(hits[0].package_name, None);
    let calls = http.calls();
    assert_eq!(
        calls[1].url,
        "https://api.github.com/search/repositories?q=alpha%20in%3Aname%2Cdescription%2Creadme&per_page=30"
    );
    assert_github_request(
        &calls[1],
        "https://api.github.com/search/repositories?q=alpha%20in%3Aname%2Cdescription%2Creadme&per_page=30",
    );

    // Canonical id: metadata package replaces owner/repo, otherwise unchanged.
    let canonical = AppSummary {
        app_id: "acme/alpha".to_string(),
        package_name: None,
        name: "Alpha".to_string(),
        user: "acme".to_string(),
        repositories: "alpha".to_string(),
        icon: String::new(),
        des: String::new(),
        readme: None,
        category: None,
        extra: None,
    };
    assert_eq!(
        driver.canonical_app_id(&canonical).unwrap(),
        "com.example.alpha.meta"
    );

    let no_metadata = AppSummary {
        app_id: "acme/no-meta".to_string(),
        user: "acme".to_string(),
        repositories: "no-meta".to_string(),
        name: "No metadata".to_string(),
        package_name: None,
        icon: String::new(),
        des: String::new(),
        readme: None,
        category: None,
        extra: None,
    };
    assert_eq!(
        driver.canonical_app_id(&no_metadata).unwrap(),
        "acme/no-meta",
        "Dart returns appInfo.appId when metadata is absent"
    );

    let unresolvable = AppSummary {
        app_id: "com.example.only-package".to_string(),
        user: String::new(),
        repositories: String::new(),
        name: "Package only".to_string(),
        package_name: Some("com.example.only-package".to_string()),
        icon: String::new(),
        des: String::new(),
        readme: None,
        category: None,
        extra: None,
    };
    assert_eq!(
        driver.canonical_app_id(&unresolvable).unwrap(),
        "com.example.only-package"
    );

    // Category filter is applied over the stored list (Dart exact equality).
    assert_eq!(
        ids(&driver.search_by_category("TOOLS", false).unwrap()),
        vec!["acme/alpha"]
    );
    assert!(driver.get_all_categories(false).unwrap().is_empty());

    println!(
        "github list={:?} fresh={:?} search={:?} canonical={}",
        names(&listed),
        fresh,
        names(&hits),
        driver.canonical_app_id(&canonical).unwrap()
    );
}

#[test]
fn localdb_github_parity_github_add_and_remove() {
    let dir = TempDir::new("add");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let http = Arc::new(FakeHttpPort::new());
    let fake_meta = FakeMetadataPort::new();
    fake_meta.set(
        "acme",
        "newrepo",
        Some(PackageMetadata {
            package_name: Some("com.example.new".to_string()),
            app_name: Some("New Meta".to_string()),
            icon_url: Some("https://icons.test/new.png".to_string()),
            version_name: None,
        }),
    );
    let metadata: Arc<dyn MetadataPort> = Arc::new(fake_meta);
    let driver = github_driver(db.clone(), http, metadata);

    let app = AppSummary {
        app_id: "com.example.new".to_string(),
        package_name: None,
        name: "Old Name".to_string(),
        user: "acme".to_string(),
        repositories: "newrepo".to_string(),
        icon: "old-icon.png".to_string(),
        des: "New description".to_string(),
        readme: None,
        category: None,
        extra: None,
    };
    driver.add_app(&app).unwrap();

    let (name, user, repositories, apprepo, icon, description, extra): (
        String,
        String,
        String,
        Option<String>,
        String,
        String,
        Option<String>,
    ) = db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT name,user,repositories,apprepo,icon,description,extra FROM channel_apps \
                 WHERE channel_key='github' AND app_id='com.example.new'",
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
                    ))
                },
            )
            .map_err(|e| DbError(e.to_string()))
        })
        .unwrap();
    assert_eq!(name, "New Meta");
    assert_eq!(user, "acme");
    assert_eq!(repositories, "newrepo");
    assert_eq!(
        apprepo, None,
        "a canonical package-name appId has no owner/repo apprepo"
    );
    assert_eq!(icon, "https://icons.test/new.png");
    assert_eq!(description, "New description");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(extra.as_deref().unwrap()).unwrap(),
        json!({"packageName": "com.example.new"})
    );

    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(ids(&listed), vec!["com.example.new"]);
    assert_eq!(listed[0].name, "New Meta");
    assert_eq!(listed[0].package_name.as_deref(), Some("com.example.new"));
    assert_eq!(listed[0].icon, "https://icons.test/new.png");

    // Dart `removeApp` is a no-op DELETE; removing a missing id still succeeds.
    driver.remove_app("com.example.new").unwrap();
    assert!(driver.get_all_apps(false).unwrap().is_empty());
    driver.remove_app("com.example.missing").unwrap();

    println!("github add row name={name:?} apprepo={apprepo:?} extra={extra:?}");
}

#[test]
fn localdb_github_parity_github_detail_maps_typed_json() {
    let dir = TempDir::new("detail");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let http = Arc::new(FakeHttpPort::new());
    let metadata: Arc<dyn MetadataPort> = Arc::new(FakeMetadataPort::new());
    let driver = github_driver(db, http.clone(), metadata);

    let repo = repo_json(
        "acme/detail",
        "Detail app description",
        "https://github.com/acme/detail",
        9,
    );
    // getAppInfo repo call, then getAppDetail repo call, releases, README.
    for _ in 0..2 {
        http.push_response(HttpResponse {
            status: 200,
            headers: Vec::new(),
            body: repo.clone().into_bytes(),
        });
    }
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: json!([
            {
                "name": "v1.0",
                "tag_name": "v1.0",
                "assets": [
                    {
                        "name": "detail-arm64-v8a.apk",
                        "size": 123,
                        "download_count": 4,
                        "browser_download_url": "https://example.test/detail.apk"
                    }
                ]
            }
        ])
        .to_string()
        .into_bytes(),
    });
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: json!({
            "name": "README.md",
            "encoding": "base64",
            "content": "IyBEZXRhaWwK"
        })
        .to_string()
        .into_bytes(),
    });

    let detail = driver.get_app_detail("acme/detail", false).unwrap();
    assert_eq!(detail.app_id, "acme/detail");
    assert_eq!(detail.name, "detail");
    assert_eq!(detail.description, "Detail app description");
    assert_eq!(detail.developer.as_deref(), Some("acme"));
    assert_eq!(detail.package_name, None);
    assert_eq!(
        detail.project_url.as_deref(),
        Some("https://github.com/acme/detail")
    );
    assert_eq!(detail.version.as_deref(), Some("v1.0"));
    assert_eq!(detail.downloads.len(), 1);
    assert_eq!(detail.downloads[0].name, "detail-arm64-v8a.apk");
    assert_eq!(detail.downloads[0].size, Some(123));
    assert_eq!(detail.downloads[0].download_count, Some(4));
    assert_eq!(detail.downloads[0].platform.as_deref(), Some("arm64-v8a"));
    assert_eq!(detail.downloads[0].version.as_deref(), Some("v1.0"));
    assert_eq!(
        detail.sections,
        vec![
            DetailSection::Statistics,
            DetailSection::Version,
            DetailSection::Downloads,
            DetailSection::Readme
        ]
    );

    let calls = http.calls();
    assert_eq!(calls.len(), 4);
    let expected = [
        "https://api.github.com/repos/acme/detail",
        "https://api.github.com/repos/acme/detail",
        "https://api.github.com/repos/acme/detail/releases?per_page=1",
        "https://api.github.com/repos/acme/detail/contents/README.md",
    ];
    for (call, url) in calls.iter().zip(expected) {
        assert_github_request(call, url);
    }

    println!("github detail={detail:?}");
}

#[test]
fn localdb_github_parity_metadata_cache_uses_24h_clock() {
    let dir = TempDir::new("cache");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let http = Arc::new(FakeHttpPort::new());
    let fake_meta = FakeMetadataPort::new();
    fake_meta.set(
        "acme",
        "cached",
        Some(PackageMetadata {
            package_name: Some("com.example.cached".to_string()),
            app_name: Some("Cached".to_string()),
            icon_url: None,
            version_name: None,
        }),
    );

    let start = Arc::new(AtomicI64::new(0));
    let clock_handle = Arc::clone(&start);
    let clock: gstore_core::ports::ClockFn = Arc::new(move || {
        SystemTime::UNIX_EPOCH + Duration::from_secs(clock_handle.load(Ordering::SeqCst) as u64)
    });
    let cached: Arc<dyn MetadataPort> =
        Arc::new(CachedMetadataPort::new(fake_meta.clone()).with_clock(clock));
    let driver = github_driver(db, http, Arc::clone(&cached));

    let app = AppSummary {
        app_id: "acme/cached".to_string(),
        package_name: None,
        name: "Cached".to_string(),
        user: "acme".to_string(),
        repositories: "cached".to_string(),
        icon: String::new(),
        des: String::new(),
        readme: None,
        category: None,
        extra: None,
    };

    assert_eq!(driver.canonical_app_id(&app).unwrap(), "com.example.cached");
    assert_eq!(driver.canonical_app_id(&app).unwrap(), "com.example.cached");
    assert_eq!(
        fake_meta.fetch_count(),
        1,
        "two canonical lookups inside 24h share one metadata fetch"
    );

    start.store(24 * 60 * 60 - 1, Ordering::SeqCst);
    driver.canonical_app_id(&app).unwrap();
    assert_eq!(fake_meta.fetch_count(), 1, "23:59:59 is still fresh");

    start.store(24 * 60 * 60, Ordering::SeqCst);
    driver.canonical_app_id(&app).unwrap();
    assert_eq!(
        fake_meta.fetch_count(),
        2,
        "the 24h TTL expires exactly at the boundary"
    );

    println!(
        "metadata cache fetch_count={} after 24h",
        fake_meta.fetch_count()
    );
}

struct FailingHttpPort;

impl HttpPort for FailingHttpPort {
    fn get(&self, _url: &str, _options: &HttpOptions) -> Result<HttpResponse, gstore_core::Error> {
        Err(gstore_core::Error::Network(
            "timeout while contacting github".to_string(),
        ))
    }

    fn post(
        &self,
        _url: &str,
        _body: &[u8],
        _options: &HttpOptions,
    ) -> Result<HttpResponse, gstore_core::Error> {
        Err(gstore_core::Error::Network(
            "timeout while contacting github".to_string(),
        ))
    }
}

#[test]
fn localdb_github_parity_github_error_mapping_and_token_redaction() {
    let dir = TempDir::new("errors");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let fake_meta = FakeMetadataPort::new();
    let metadata: Arc<dyn MetadataPort> = Arc::new(fake_meta);

    let cases: Vec<(u16, &str, &str, bool)> = vec![
        (404, r#"{"message":"Not Found"}"#, "not_found", true),
        (
            401,
            r#"{"message":"Bad credentials"}"#,
            "unauthorized",
            true,
        ),
        (
            403,
            r#"{"message":"Resource not accessible"}"#,
            "forbidden",
            true,
        ),
        (
            403,
            r#"{"message":"API rate limit exceeded for 1.2.3.4"}"#,
            "rate_limited",
            true,
        ),
        (
            429,
            r#"{"message":"too many requests"}"#,
            "rate_limited",
            true,
        ),
        (500, r#"{"message":"boom"}"#, "network", true),
        (418, r#"{"message":"teapot"}"#, "network", true),
        (200, "{not-json", "serialization", true),
        (200, r#"{"full_name":123}"#, "serialization", true),
    ];

    for (status, body, expected_code, expect_status_in_message) in cases {
        let http = Arc::new(FakeHttpPort::new());
        http.push_response(HttpResponse {
            status,
            headers: Vec::new(),
            body: body.as_bytes().to_vec(),
        });
        let driver = github_driver(db.clone(), http.clone(), Arc::clone(&metadata));
        let error = driver
            .get_app_info("acme/err", false)
            .expect_err("status must map to a typed error");
        assert_eq!(
            error.code(),
            expected_code,
            "status {status} body {body:?} mapped to {error:?}"
        );
        let rendered = error.to_string();
        assert!(
            !rendered.contains(TOKEN),
            "the GitHub token must never appear in an error: {rendered}"
        );
        if expect_status_in_message {
            assert!(
                rendered.contains(&status.to_string()),
                "status {status} must appear in the message: {rendered}"
            );
        }
        // The header carried the token even though the error redacts it.
        let expected_auth = format!("Bearer {TOKEN}");
        assert_eq!(
            http.calls()[0]
                .headers
                .iter()
                .find(|(name, _)| name == "Authorization")
                .map(|(_, value)| value.as_str()),
            Some(expected_auth.as_str())
        );
        println!("github status {status} -> {} ({rendered})", error.code());
    }

    // A transport timeout is already a typed Network error.
    let config = CoreConfig::new(Some(PROXY.to_string()), Some(TOKEN.to_string())).unwrap();
    let timeout_driver = GitHubDriver::new(
        github_key(),
        meta(ChannelKind::Github, "GitHubAPI"),
        db,
        config,
        Arc::new(FailingHttpPort),
        metadata,
    );
    let timeout = timeout_driver.get_app_info("acme/err", false).unwrap_err();
    assert_eq!(timeout.code(), "network");
    assert!(!timeout.to_string().contains(TOKEN));

    // Malformed proxy/token configuration is rejected before any request.
    let bad_proxy = CoreConfig::new(Some("not a proxy url".to_string()), None).unwrap_err();
    assert_eq!(bad_proxy.code(), "invalid_argument");
    let bad_token = CoreConfig::new(None, Some("   ".to_string())).unwrap_err();
    assert_eq!(bad_token.code(), "invalid_argument");
    assert!(!bad_proxy.to_string().contains(TOKEN));
    assert!(!bad_token.to_string().contains(TOKEN));

    println!(
        "error mapping complete: 404/401/403/429/500/418/malformed/timeout all typed; token redacted"
    );
}

#[test]
fn localdb_github_parity_localdb_missing_table_is_typed_error() {
    let dir = TempDir::new("bad-db");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    db.with_writer(|conn| {
        conn.execute("DROP TABLE apps", [])
            .map_err(|e| DbError(e.to_string()))?;
        conn.execute("DROP TABLE app_config", [])
            .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();

    let driver = local_driver(db, None);
    let error = driver.get_all_apps(false).unwrap_err();
    assert_eq!(
        error.code(),
        "io",
        "a broken schema is typed, never a panic"
    );
    assert!(
        !driver.check_available().unwrap(),
        "checkAvailable mirrors Dart's try/catch probe"
    );

    println!("missing apps table -> {error}");
}
