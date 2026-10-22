//! Catalog query parity, FTS/LIKE merge, unicode fallback, pagination, and
//! performance contracts for [`CatalogService`].
//!
//! Every test imports a fixture catalog into a real core database (the same
//! `DbHandle` + `import_catalog` production path) except the performance test,
//! which bulk-inserts directly to keep the setup itself out of the measurement.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use gstore_core::catalog::import::{import_catalog, CatalogImportOptions};
use gstore_core::catalog::service::CatalogService;
use gstore_core::db::DbHandle;
use gstore_core::dto::DetailSection;
use rusqlite::{params, Connection};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_catalog_query_{tag}_{}_{}",
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

struct SeedApp<'a> {
    app_id: &'a str,
    name: &'a str,
    des: &'a str,
    category: &'a str,
    readme: Option<&'a str>,
    extra: Option<&'a str>,
}

impl<'a> SeedApp<'a> {
    fn new(app_id: &'a str, name: &'a str, des: &'a str, category: &'a str) -> Self {
        Self {
            app_id,
            name,
            des,
            category,
            readme: None,
            extra: None,
        }
    }
}

fn seed_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/app/db/apps.db")
}

/// Creates the source-side catalog tables. `with_optional` adds the
/// `readme`/`extra` app columns and the `config.proxy` column.
fn create_source(path: &Path, with_optional: bool) -> Connection {
    let conn = Connection::open(path).unwrap();
    let apps = if with_optional {
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT, readme TEXT, extra TEXT)"
    } else {
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT)"
    };
    let config = if with_optional {
        "CREATE TABLE config(version TEXT NOT NULL, proxy TEXT)"
    } else {
        "CREATE TABLE config(version TEXT NOT NULL)"
    };
    conn.execute_batch(&format!(
        "{apps}; CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, \
         icon TEXT NOT NULL); {config};"
    ))
    .unwrap();
    conn
}

fn add_app(conn: &Connection, app: &SeedApp<'_>, with_optional: bool) {
    if with_optional {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,category,readme,extra) \
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                app.app_id,
                app.name,
                "fixture-user",
                "fixture-repo",
                "https://example.invalid/icon.png",
                app.des,
                app.category,
                app.readme,
                app.extra,
            ],
        )
        .unwrap();
    } else {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,category) \
             VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![
                app.app_id,
                app.name,
                "fixture-user",
                "fixture-repo",
                "https://example.invalid/icon.png",
                app.des,
                app.category,
            ],
        )
        .unwrap();
    }
}

fn add_category(conn: &Connection, id: &str, description: &str) {
    conn.execute(
        "INSERT INTO category(id,description,icon) VALUES(?1,?2,?3)",
        params![id, description, "icon.png"],
    )
    .unwrap();
}

fn add_config(conn: &Connection, version: &str, proxy: Option<&str>, with_proxy: bool) {
    if with_proxy {
        conn.execute(
            "INSERT INTO config(version,proxy) VALUES(?1,?2)",
            params![version, proxy],
        )
        .unwrap();
    } else {
        conn.execute("INSERT INTO config(version) VALUES(?1)", params![version])
            .unwrap();
    }
}

fn import_source(dir: &Path, source: &Path) -> DbHandle {
    let handle = DbHandle::open(&dir.join("core")).unwrap();
    let report = import_catalog(
        &handle,
        None,
        source,
        &CatalogImportOptions { dry_run: false },
    )
    .unwrap();
    assert!(!report.dry_run);
    handle
}

fn service_for_seed(dir: &Path) -> DbHandle {
    import_source(dir, &seed_path())
}

fn ids(apps: &[gstore_core::dto::AppSummary]) -> Vec<&str> {
    apps.iter().map(|app| app.app_id.as_str()).collect()
}

#[test]
fn catalog_query_parity() {
    let temp = TempDir::new("seed");
    let handle = service_for_seed(temp.path());
    let service = CatalogService::new(handle.clone()).unwrap();

    let all = service.list().unwrap();
    assert_eq!(all.len(), 17, "seed catalog must expose all 17 apps");
    assert_eq!(all[0].app_id, "com.absinthe.libchecker");
    assert_eq!(all[16].app_id, "com.gopeed");

    // Stable pagination: concatenating every page reproduces `list` exactly.
    let mut paged = Vec::new();
    let mut offset = 0_u32;
    loop {
        let (page, total) = service.list_page(offset, 5).unwrap();
        assert_eq!(total, 17);
        if page.is_empty() {
            break;
        }
        paged.extend(page);
        offset += 5;
    }
    assert_eq!(paged, all);
    assert!(service.list_page(100, 5).unwrap().0.is_empty());
    assert!(service.list_page(0, 0).unwrap().0.is_empty());
    assert_eq!(service.list_page(0, 5).unwrap().1, 17);

    // FTS prefix search finds Magisk; empty keyword is empty.
    let magisk = service.search("magisk").unwrap();
    assert_eq!(ids(&magisk), vec!["com.topjohnwu.magisk"]);
    assert!(service.search("").unwrap().is_empty());

    // Category matching is a substring LIKE, matching Dart.
    let proxy = service.by_category("PROXY").unwrap();
    assert_eq!(
        ids(&proxy),
        vec![
            "com.follow.clash",
            "com.github.kr328.clash",
            "com.v2ray.ang"
        ]
    );
    assert_eq!(service.by_category("ROX").unwrap(), proxy);
    assert!(service.by_category("NO_SUCH_CATEGORY").unwrap().is_empty());

    let app = service
        .get_app("com.topjohnwu.magisk")
        .unwrap()
        .expect("magisk must exist");
    assert_eq!(app.name, "Magisk");
    assert_eq!(app.user, "topjohnwu");
    assert_eq!(app.repositories, "Magisk");
    assert_eq!(
        app.category,
        Some(vec!["HOOK".to_string(), "TOOLS".to_string()])
    );
    assert!(app.des.contains("Magisk"));
    assert_eq!(app.readme, None, "seed has no readme column");
    assert!(service.get_app("com.example.missing").unwrap().is_none());

    let detail = service
        .get_app_detail("com.topjohnwu.magisk")
        .unwrap()
        .expect("magisk detail must exist");
    assert_eq!(detail.name, "Magisk");
    assert_eq!(detail.developer.as_deref(), Some("topjohnwu"));
    assert_eq!(
        detail.project_url.as_deref(),
        Some("https://github.com/topjohnwu/Magisk")
    );
    assert_eq!(
        detail.sections,
        vec![DetailSection::Downloads, DetailSection::Readme]
    );
    assert!(detail.downloads.is_empty());
    assert!(detail.extra.is_empty());
    assert!(service
        .get_app_detail("com.example.missing")
        .unwrap()
        .is_none());

    let categories = service.categories().unwrap();
    assert_eq!(categories.len(), 13);
    assert_eq!(categories[0].id, "TOOLS");
    let proxy_category = categories
        .iter()
        .find(|category| category.id == "PROXY")
        .expect("PROXY category must exist");
    assert_eq!(proxy_category.description, "代理");

    // Repeated queries after a re-import stay stable (no stale FTS rows).
    let reloaded = import_source(temp.path(), &seed_path());
    let reloaded_service = CatalogService::new(reloaded).unwrap();
    assert_eq!(reloaded_service.list().unwrap(), all);
    assert_eq!(reloaded_service.search("magisk").unwrap(), magisk);

    let integrity: String = handle
        .with_reader(|conn| {
            conn.query_row("PRAGMA integrity_check", [], |row| row.get(0))
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(integrity, "ok");
}

#[test]
fn catalog_search_fts_and_like_merge() {
    let temp = TempDir::new("merge");
    let source = temp.path().join("source.db");
    let conn = create_source(&source, true);
    add_app(
        &conn,
        &SeedApp::new("a.fts", "Alpha Fts Tool", "plain text", "TOOLS"),
        true,
    );
    add_app(
        &conn,
        &SeedApp::new(
            "b.like",
            "BetaXAlphaY",
            "contains superneedleword here",
            "PROXY",
        ),
        true,
    );
    add_app(
        &conn,
        &SeedApp::new("c.quote", "Quoted \"Alpha\" Tool", "quotes", "TOOLS"),
        true,
    );
    add_app(
        &conn,
        &SeedApp::new("cjk.app", "中文关键词工具", "用于测试关键词", "TOOLS"),
        true,
    );
    add_category(&conn, "TOOLS", "工具");
    add_category(&conn, "PROXY", "代理");
    add_config(&conn, "1", None, true);
    drop(conn);

    let handle = import_source(temp.path(), &source);
    let service = CatalogService::new(handle).unwrap();

    // FTS-first order, then LIKE-only rows appended without duplicates.
    let alpha = service.search("Alpha").unwrap();
    assert_eq!(ids(&alpha), vec!["a.fts", "c.quote", "b.like"]);

    // `needle` is a mid-token substring, so only LIKE can find it.
    let needle = service.search("needle").unwrap();
    assert_eq!(ids(&needle), vec!["b.like"]);

    // A keyword containing quotes must survive FTS escaping and LIKE.
    let quoted = service.search("Quoted \"Alpha\"").unwrap();
    assert!(
        quoted.iter().any(|app| app.app_id == "c.quote"),
        "quoted keyword should still match its app: {:?}",
        ids(&quoted)
    );
    let mut unique = quoted
        .iter()
        .map(|app| app.app_id.as_str())
        .collect::<Vec<_>>();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), quoted.len(), "search must not duplicate rows");

    // CJK substring is not an FTS prefix, so LIKE fallback returns it.
    let cjk = service.search("关键词").unwrap();
    assert_eq!(ids(&cjk), vec!["cjk.app"]);
}

#[test]
fn catalog_search_unicode_fallback() {
    let temp = TempDir::new("unicode");
    let source = temp.path().join("source.db");
    let conn = create_source(&source, true);
    add_app(
        &conn,
        &SeedApp::new("cjk.only", "中文关键词工具", "用于测试", "TOOLS"),
        true,
    );
    add_category(&conn, "TOOLS", "工具");
    add_config(&conn, "1", None, true);
    drop(conn);

    let handle = import_source(temp.path(), &source);
    let fts_matches: i64 = handle
        .with_reader(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM apps WHERE rowid IN \
                 (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?1)",
                ["\"关键词\"*"],
                |row| row.get(0),
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    let like_matches: i64 = handle
        .with_reader(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM apps WHERE name LIKE ?1 OR des LIKE ?1",
                ["%关键词%"],
                |row| row.get(0),
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    println!("unicode probe keyword=关键词 fts_matches={fts_matches} like_matches={like_matches}");
    assert_eq!(fts_matches, 0, "CJK substring is not an FTS prefix token");
    assert_eq!(like_matches, 1);

    let service = CatalogService::new(handle).unwrap();

    let keyword = service.search("关键词").unwrap();
    assert_eq!(ids(&keyword), vec!["cjk.only"]);
    assert_eq!(ids(&service.search("测试").unwrap()), vec!["cjk.only"]);
    assert!(service.search("").unwrap().is_empty());
    assert!(service.search("不存在").unwrap().is_empty());
}

#[test]
fn catalog_pagination_stability() {
    let temp = TempDir::new("paging");
    let source = temp.path().join("source.db");
    let conn = create_source(&source, true);
    for index in 0..100 {
        add_app(
            &conn,
            &SeedApp::new(
                &format!("com.example.app{index:03}"),
                &format!("Paged App {index:03}"),
                "pagination fixture",
                "TOOLS",
            ),
            true,
        );
    }
    add_category(&conn, "TOOLS", "工具");
    add_config(&conn, "1", None, true);
    drop(conn);

    let handle = import_source(temp.path(), &source);
    let service = CatalogService::new(handle).unwrap();
    let all = service.list().unwrap();
    assert_eq!(all.len(), 100);
    assert_eq!(all[0].app_id, "com.example.app000");
    assert_eq!(all[99].app_id, "com.example.app099");

    let mut paged = Vec::new();
    let mut offset = 0_u32;
    loop {
        let (page, total) = service.list_page(offset, 7).unwrap();
        assert_eq!(total, 100);
        if page.is_empty() {
            break;
        }
        assert!(page.len() <= 7);
        paged.extend(page);
        offset += 7;
    }
    assert_eq!(paged, all, "page concatenation must equal list()");
    assert_eq!(paged.len(), 100);

    assert!(service.list_page(1000, 7).unwrap().0.is_empty());
    assert!(service.list_page(0, 0).unwrap().0.is_empty());
    assert!(service.list_page(99, 0).unwrap().0.is_empty());
    assert_eq!(service.list_page(99, 7).unwrap().0.len(), 1);
}

#[test]
fn catalog_query_perf_10k() {
    let temp = TempDir::new("perf");
    let handle = DbHandle::open(&temp.path().join("core")).unwrap();
    {
        let mut conn = handle.writer().unwrap();
        let tx = conn.transaction().unwrap();
        {
            let mut stmt = tx
                .prepare(
                    "INSERT INTO apps(appId,name,user,repositories,icon,des,category) \
                     VALUES(?1,?2,?3,?4,?5,?6,?7)",
                )
                .unwrap();
            for index in 0..10_000 {
                let name = if index % 100 == 0 {
                    format!("Perf App {index:05}")
                } else {
                    format!("Perf Item {index:05}")
                };
                stmt.execute(params![
                    format!("com.perf.app{index:05}"),
                    name,
                    "perf-user",
                    "perf-repo",
                    "https://example.invalid/icon.png",
                    "perf description",
                    "TOOLS",
                ])
                .unwrap();
            }
        }
        tx.commit().unwrap();
    }

    let service = CatalogService::new(handle).unwrap();
    assert_eq!(service.list().unwrap().len(), 10_000);

    // Warm up both query shapes before measuring.
    for _ in 0..10 {
        service.list_page(0, 50).unwrap();
        service.search("app").unwrap();
    }

    let mut page_samples = Vec::with_capacity(100);
    for _ in 0..100 {
        let started = Instant::now();
        let (page, total) = service.list_page(0, 50).unwrap();
        page_samples.push(started.elapsed());
        assert_eq!(total, 10_000);
        assert_eq!(page.len(), 50);
    }

    let mut search_samples = Vec::with_capacity(100);
    for _ in 0..100 {
        let started = Instant::now();
        let results = service.search("app").unwrap();
        search_samples.push(started.elapsed());
        assert!(!results.is_empty());
    }

    let page_p50 = percentile(&mut page_samples, 50);
    let page_p95 = percentile(&mut page_samples, 95);
    let search_p50 = percentile(&mut search_samples, 50);
    let search_p95 = percentile(&mut search_samples, 95);
    println!(
        "catalog_query_perf_10k list_page(0,50) p50={page_p50:?} p95={page_p95:?}; \
         search(\"app\") p50={search_p50:?} p95={search_p95:?}"
    );

    assert!(
        page_p95 < Duration::from_millis(50),
        "list_page p95 {page_p95:?} exceeded 50ms"
    );
    assert!(
        search_p95 < Duration::from_millis(50),
        "search p95 {search_p95:?} exceeded 50ms"
    );
}

#[test]
fn catalog_query_missing_optional_columns() {
    let temp = TempDir::new("optional");
    let source = temp.path().join("source.db");
    let conn = create_source(&source, false);
    add_app(
        &conn,
        &SeedApp::new("seven.col", "Seven Columns", "no readme here", "TOOLS"),
        false,
    );
    add_category(&conn, "TOOLS", "工具");
    add_config(&conn, "1", None, false);
    drop(conn);

    let handle = import_source(temp.path(), &source);
    let service = CatalogService::new(handle).unwrap();

    let all = service.list().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].readme, None);
    assert_eq!(all[0].extra, None);
    assert_eq!(all[0].category, Some(vec!["TOOLS".to_string()]));

    let app = service.get_app("seven.col").unwrap().unwrap();
    assert_eq!(app.readme, None);
    assert_eq!(app.extra, None);

    let detail = service.get_app_detail("seven.col").unwrap().unwrap();
    assert_eq!(detail.description, "no readme here");
    assert_eq!(detail.extra, serde_json::Map::new());
    assert_eq!(
        detail.sections,
        vec![DetailSection::Downloads, DetailSection::Readme],
        "des is the readme fallback when the readme column is absent"
    );
    assert_eq!(service.categories().unwrap().len(), 1);
}

#[test]
fn catalog_query_sql_hazard() {
    let temp = TempDir::new("hazard");
    let handle = service_for_seed(temp.path());
    let service = CatalogService::new(handle).unwrap();

    // Parameterized LIKE: the injection payload is a literal substring.
    assert!(service.by_category("PROXY' OR 1=1 --").unwrap().is_empty());
    assert_eq!(service.by_category("PROXY").unwrap().len(), 3);

    // FTS metacharacters must not panic; LIKE fallback keeps the query alive.
    for keyword in ["\"", "*", ":", "\"*:", "PROXY' OR 1=1 --", "a\"b*c:d"] {
        assert!(
            service.search(keyword).is_ok(),
            "search({keyword:?}) must not fail"
        );
    }
}

fn percentile(samples: &mut [Duration], percent: usize) -> Duration {
    samples.sort_unstable();
    let index = (samples.len() * percent / 100).min(samples.len() - 1);
    samples[index]
}
