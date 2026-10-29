//! Aggregation parity: channel resolution, cache fallback, tag/category merge,
//! paging, dedup, sort/filter, unicode, and empty-state coverage.
//!
//! Tests use a real migrated core database (`DbHandle::open`) and the in-memory
//! channel fake so every assertion is about observable output, not internals.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::added::apps::AddedAppsService;
use gstore_core::aggregate::service::{
    categories_from_apps, dart_lowercase, dedup_channels_and_packages, recent, sort_filter,
    AggregatedApp, AggregationService, AppFilter, AppSortMode, ChannelResolver,
};
use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver, LocalDbDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use rusqlite::params;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_aggregate_{tag}_{}_{}",
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

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn meta(code: &str, kind: ChannelKind) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: code.to_string(),
        description: format!("{code} channel"),
        enabled: true,
        priority: 0,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn summary(
    app_id: &str,
    package: Option<&str>,
    name: &str,
    des: &str,
    categories: &[&str],
) -> AppSummary {
    AppSummary {
        app_id: app_id.to_string(),
        package_name: package.map(str::to_string),
        name: name.to_string(),
        user: String::new(),
        repositories: String::new(),
        icon: String::new(),
        des: des.to_string(),
        readme: None,
        category: (!categories.is_empty())
            .then(|| categories.iter().map(|value| (*value).to_string()).collect()),
        extra: None,
        labels: Vec::new(),
    }
}

fn driver(code: &str, kind: ChannelKind, apps: Vec<AppSummary>) -> Arc<dyn ChannelDriver> {
    let key = ChannelKey::new(code).unwrap();
    Arc::new(InMemoryChannelDriver::new(key, meta(code, kind)).with_apps(apps))
}

fn resolver(drivers: Vec<Arc<dyn ChannelDriver>>) -> ChannelResolver {
    let map: BTreeMap<String, Arc<dyn ChannelDriver>> = drivers
        .into_iter()
        .map(|driver| (driver.key().as_str().to_string(), driver))
        .collect();
    Arc::new(move |code: &str| map.get(code).cloned())
}

fn add_added(db: &DbHandle, channel: &str, app_id: &str, add_time: i64) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
         VALUES (?1, ?2, ?3, 0, 1)",
        params![channel, app_id, add_time],
    )
    .unwrap();
}

fn set_tags(db: &DbHandle, channel: &str, app_id: &str, tags: &[&str]) {
    let tags: Vec<String> = tags.iter().map(|tag| (*tag).to_string()).collect();
    AddedAppsService::new(db.clone())
        .set_tags(channel, app_id, &tags)
        .unwrap();
}

fn add_category(db: &DbHandle, id: &str, description: &str) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO categories(id, description, icon) VALUES (?1, ?2, '')",
        params![id, description],
    )
    .unwrap();
}

fn ids(apps: &[AggregatedApp]) -> Vec<String> {
    apps.iter().map(|app| app.app.app_id.clone()).collect()
}

fn service(db: &DbHandle, drivers: Vec<Arc<dyn ChannelDriver>>) -> AggregationService {
    AggregationService::new(db.clone(), resolver(drivers)).unwrap()
}

fn evidence_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-evidence")
}

#[test]
fn aggregation_parity() {
    let dir = TempDir::new("parity");
    let db = DbHandle::open(dir.path()).unwrap();
    add_category(&db, "PROXY", "代理");

    add_added(&db, "github", "A", 3000);
    add_added(&db, "fdroid", "B", 2000);
    add_added(&db, "local_db", "C", 1000);
    add_added(&db, "ghost", "D", 500);

    set_tags(&db, "github", "A", &["自定义", "TOOLS"]);
    set_tags(&db, "fdroid", "B", &["视频"]);
    set_tags(&db, "local_db", "C", &["代理"]);

    let drivers = vec![
        driver(
            "github",
            ChannelKind::Github,
            vec![summary(
                "A",
                Some("com.a"),
                "App A",
                "first",
                &["TOOLS"],
            )],
        ),
        driver(
            "fdroid",
            ChannelKind::Fdroid,
            vec![summary(
                "B",
                Some("com.b"),
                "App B",
                "second",
                &["MEDIA"],
            )],
        ),
        driver(
            "local_db",
            ChannelKind::LocalDb,
            vec![summary(
                "C",
                Some("com.c"),
                "App C",
                "third",
                &["PROXY"],
            )],
        ),
    ];
    let service = service(&db, drivers);

    let all = service.aggregate_all().unwrap();
    assert_eq!(ids(&all), vec!["A", "B", "C"], "ghost is skipped, order kept");
    assert!(!all.iter().any(|app| app.channel_code == "ghost"));

    assert_eq!(
        all[0].app.category,
        Some(vec!["TOOLS".to_string(), "自定义".to_string()])
    );
    assert_eq!(
        all[1].app.category,
        Some(vec!["MEDIA".to_string(), "视频".to_string()])
    );
    assert_eq!(all[2].app.category, Some(vec!["代理".to_string()]));

    assert_eq!(all[0].channel, ChannelKind::Github);
    assert_eq!(all[1].channel, ChannelKind::Fdroid);
    assert_eq!(all[2].channel, ChannelKind::LocalDb);
    assert!(all.iter().all(|app| !app.is_from_cache && app.error.is_none()));

    let (page, total) = service.aggregate_page(0, 10).unwrap();
    assert_eq!(total, 4, "unknown channel still counts toward the page total");
    assert_eq!(page.len(), 3);
    assert_eq!(ids(&page), ids(&all));

    let (first, total_first) = service.aggregate_page(0, 2).unwrap();
    let (second, total_second) = service.aggregate_page(2, 2).unwrap();
    assert_eq!(total_first, 4);
    assert_eq!(total_second, 4);
    let mut concatenated = ids(&first);
    concatenated.extend(ids(&second));
    assert_eq!(concatenated, ids(&all));

    let evidence = evidence_dir();
    std::fs::create_dir_all(&evidence).unwrap();
    std::fs::write(
        evidence.join("65-aggregation.json"),
        serde_json::to_string_pretty(&all).unwrap(),
    )
    .unwrap();
}

#[test]
fn aggregation_missing_channel_and_cache() {
    let dir = TempDir::new("missing");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "ghost", "D", 4000);
    add_added(&db, "github", "cached-id", 3000);
    add_added(&db, "broken", "boom-id", 2000);

    // A driver pointed at a database whose `apps` table is gone produces a
    // non-NotFound error (Io), exercising the Dart catch branch.
    let broken_db = DbHandle::open(&dir.join("broken")).unwrap();
    {
        let conn = broken_db.writer().unwrap();
        conn.execute_batch("DROP TABLE apps;").unwrap();
    }
    let broken = Arc::new(LocalDbDriver::new(
        ChannelKey::new("broken").unwrap(),
        meta("broken", ChannelKind::Github),
        broken_db,
    )) as Arc<dyn ChannelDriver>;

    let service = service(
        &db,
        vec![
            // Registered but empty: get_app_info is a NotFound cache fallback.
            driver("github", ChannelKind::Github, vec![]),
            broken,
        ],
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(ids(&all), vec!["cached-id", "boom-id"]);
    assert!(!all.iter().any(|app| app.channel_code == "ghost"));

    assert_eq!(all[0].channel, ChannelKind::Github);
    assert!(all[0].is_from_cache);
    assert!(all[0].error.is_none());
    assert_eq!(all[0].app.name, "cached-id");
    assert_eq!(all[0].app.package_name, None);
    assert_eq!(all[0].app.category, None);

    assert_eq!(all[1].channel, ChannelKind::LocalDb);
    assert!(all[1].is_from_cache);
    let error = all[1].error.as_deref().expect("driver error is recorded");
    assert!(error.starts_with("[io]"), "unexpected error: {error}");
    assert_eq!(all[1].app.name, "boom-id");
    assert_eq!(all[1].app.package_name, None);

    let (page, total) = service.aggregate_page(0, 10).unwrap();
    assert_eq!(total, 3);
    assert_eq!(ids(&page), vec!["cached-id", "boom-id"]);

    // Stale-state check: a fresh listing after an added-app mutation sees it.
    AddedAppsService::new(db.clone())
        .add("github", "later", None)
        .unwrap();
    let refreshed = service.aggregate_all().unwrap();
    assert_eq!(ids(&refreshed), vec!["later", "cached-id", "boom-id"]);
    assert_eq!(service.aggregate_page(0, 10).unwrap().1, 4);
}

#[test]
fn aggregation_paging() {
    let dir = TempDir::new("paging");
    let db = DbHandle::open(dir.path()).unwrap();

    let mut github_apps = Vec::new();
    for page in 0..5 {
        let app_id = format!("g{page}");
        add_added(&db, "github", &app_id, 10_000 - i64::from(page) * 1000);
        github_apps.push(summary(
            &app_id,
            Some(format!("com.{app_id}").as_str()),
            &app_id,
            "github app",
            &["TOOLS"],
        ));
    }
    add_added(&db, "ghost", "ignored", 5500);
    let mut fdroid_apps = Vec::new();
    for page in 0..5 {
        let app_id = format!("f{page}");
        add_added(&db, "fdroid", &app_id, 5000 - i64::from(page) * 1000);
        fdroid_apps.push(summary(
            &app_id,
            Some(format!("org.{app_id}").as_str()),
            &app_id,
            "fdroid app",
            &["MEDIA"],
        ));
    }

    let service = service(
        &db,
        vec![
            driver("github", ChannelKind::Github, github_apps),
            driver("fdroid", ChannelKind::Fdroid, fdroid_apps),
        ],
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(all.len(), 10);
    let all_ids = ids(&all);

    let mut paged = Vec::new();
    for offset in [0_u32, 3, 6, 9] {
        let (page, total) = service.aggregate_page(offset, 3).unwrap();
        assert_eq!(total, 11, "unknown channel counts toward total");
        paged.extend(ids(&page));
    }
    assert_eq!(paged, all_ids, "3+3+3+1 pages concatenate to aggregate_all");

    assert_eq!(service.aggregate_page(0, 0).unwrap(), (Vec::new(), 11));
    assert_eq!(service.aggregate_page(5, 0).unwrap(), (Vec::new(), 11));
    assert_eq!(service.aggregate_page(11, 10).unwrap(), (Vec::new(), 11));
    assert_eq!(service.aggregate_page(99, 10).unwrap(), (Vec::new(), 11));

    let (last, total) = service.aggregate_page(10, 100).unwrap();
    assert_eq!(total, 11);
    assert_eq!(ids(&last), vec!["f4"]);

    let (everything, total) = service.aggregate_page(0, 100).unwrap();
    assert_eq!(total, 11);
    assert_eq!(ids(&everything), all_ids);
}

#[test]
fn aggregation_fdroid_package_priority() {
    let dir = TempDir::new("fdroid");
    let db = DbHandle::open(dir.path()).unwrap();

    add_added(&db, "github", "gh1", 4000);
    add_added(&db, "fdroid", "fd1", 3000);
    add_added(&db, "github", "nopkg1", 2000);
    add_added(&db, "fdroid", "nopkg2", 1000);

    let service = service(
        &db,
        vec![
            driver(
                "github",
                ChannelKind::Github,
                vec![
                    summary("gh1", Some("com.shared"), "GitHub shared", "gh", &["TOOLS"]),
                    summary("nopkg1", None, "GitHub no package", "gh", &["TOOLS"]),
                ],
            ),
            driver(
                "fdroid",
                ChannelKind::Fdroid,
                vec![
                    summary("fd1", Some("com.shared"), "F-Droid shared", "fd", &["TOOLS"]),
                    summary("nopkg2", None, "F-Droid no package", "fd", &["TOOLS"]),
                ],
            ),
        ],
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(ids(&all), vec!["gh1", "fd1", "nopkg1", "nopkg2"]);

    let deduped = service.aggregate_all_deduped().unwrap();
    assert_eq!(ids(&deduped), vec!["fd1", "nopkg1", "nopkg2"]);
    assert_eq!(deduped[0].channel, ChannelKind::Fdroid);
    assert_eq!(deduped[0].app.package_name.as_deref(), Some("com.shared"));

    // Pure paging: no dedup, so concatenation reproduces aggregate_all even
    // though github/fdroid share a package.
    let (first, first_total) = service.aggregate_page(0, 1).unwrap();
    let (second, second_total) = service.aggregate_page(1, 1).unwrap();
    let (pair, pair_total) = service.aggregate_page(0, 2).unwrap();
    assert_eq!((first_total, second_total, pair_total), (4, 4, 4));
    let mut one_by_one = ids(&first);
    one_by_one.extend(ids(&second));
    assert_eq!(one_by_one, ids(&pair));
    assert_eq!(ids(&pair), vec!["gh1", "fd1"]);

    let mut pure_pages = Vec::new();
    for offset in 0..4_u32 {
        let (page, total) = service.aggregate_page(offset, 1).unwrap();
        assert_eq!(total, 4);
        pure_pages.extend(ids(&page));
    }
    assert_eq!(pure_pages, ids(&all));

    // Deduped paging: dedup the full list first, so pages are invariant to
    // limit and their total is the deduped length.
    let (d0, dt0) = service.aggregate_page_deduped(0, 1).unwrap();
    let (d1, dt1) = service.aggregate_page_deduped(1, 1).unwrap();
    let (d2, dt2) = service.aggregate_page_deduped(2, 1).unwrap();
    assert_eq!((dt0, dt1, dt2), (3, 3, 3));
    let mut limit_one = ids(&d0);
    limit_one.extend(ids(&d1));
    limit_one.extend(ids(&d2));

    let (e0, et0) = service.aggregate_page_deduped(0, 2).unwrap();
    let (e1, et1) = service.aggregate_page_deduped(2, 2).unwrap();
    assert_eq!((et0, et1), (3, 3));
    let mut limit_two = ids(&e0);
    limit_two.extend(ids(&e1));

    assert_eq!(limit_one, ids(&deduped));
    assert_eq!(limit_two, ids(&deduped));
    assert_eq!(limit_one, limit_two, "deduped pages are limit-invariant");

    let (full, full_total) = service.aggregate_page_deduped(0, 100).unwrap();
    assert_eq!(full_total, 3);
    assert_eq!(full, deduped);

    let mut duplicated = all.clone();
    duplicated.push(all[0].clone());
    assert_eq!(
        ids(&dedup_channels_and_packages(duplicated)),
        vec!["fd1", "nopkg1", "nopkg2"],
        "(channel, app_id) duplicates keep the first occurrence"
    );
}

#[test]
fn aggregation_sort_filter() {
    let dir = TempDir::new("sort");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "gh-zeta", 3000);
    add_added(&db, "github", "gh-alpha", 2000);
    add_added(&db, "local_db", "db-beta", 1000);

    let service = service(
        &db,
        vec![
            driver(
                "github",
                ChannelKind::Github,
                vec![
                    summary("gh-zeta", Some("com.zeta"), "Zeta", "Fast tool", &["TOOLS"]),
                    summary(
                        "gh-alpha",
                        Some("com.alpha"),
                        "alpha",
                        "Media player",
                        &["MEDIA"],
                    ),
                ],
            ),
            driver(
                "local_db",
                ChannelKind::LocalDb,
                vec![summary(
                    "db-beta",
                    Some("com.beta"),
                    "Beta",
                    "proxy helper",
                    &["代理"],
                )],
            ),
        ],
    );

    let all = service.aggregate_all().unwrap();
    let original = ids(&all);
    assert_eq!(original, vec!["gh-zeta", "gh-alpha", "db-beta"]);

    let recent_sorted = sort_filter(
        &all,
        &AppFilter {
            sort: AppSortMode::Recent,
            ..AppFilter::default()
        },
    );
    assert_eq!(ids(&recent_sorted), vec!["gh-zeta", "gh-alpha", "db-beta"]);

    let by_name = sort_filter(
        &all,
        &AppFilter {
            sort: AppSortMode::Name,
            ..AppFilter::default()
        },
    );
    assert_eq!(ids(&by_name), vec!["gh-alpha", "db-beta", "gh-zeta"]);

    let mut update_states = BTreeMap::new();
    update_states.insert("db-beta".to_string(), true);
    let update_first = sort_filter(
        &all,
        &AppFilter {
            sort: AppSortMode::UpdateFirst,
            update_states,
            ..AppFilter::default()
        },
    );
    assert_eq!(ids(&update_first), vec!["db-beta", "gh-zeta", "gh-alpha"]);

    let keyword = |value: &str| AppFilter {
        keyword: Some(value.to_string()),
        ..AppFilter::default()
    };
    assert_eq!(ids(&sort_filter(&all, &keyword("ALPHA"))), vec!["gh-alpha"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("proxy"))), vec!["db-beta"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("GH-Z"))), vec!["gh-zeta"]);
    assert_eq!(ids(&sort_filter(&all, &keyword(""))), original);

    let category = |value: &str| AppFilter {
        category: Some(value.to_string()),
        ..AppFilter::default()
    };
    assert_eq!(ids(&sort_filter(&all, &category("TOOLS"))), vec!["gh-zeta"]);
    assert!(sort_filter(&all, &category("TOOL")).is_empty());
    assert_eq!(ids(&sort_filter(&all, &category(" 代理 "))), vec!["db-beta"]);

    assert_eq!(
        categories_from_apps(&all),
        vec!["MEDIA".to_string(), "TOOLS".to_string(), "代理".to_string()]
    );
    assert_eq!(ids(&recent(&all, 2)), vec!["gh-zeta", "gh-alpha"]);
    assert_eq!(recent(&all, 10).len(), 3);
    assert!(recent(&all, 0).is_empty());
    assert_eq!(ids(&all), original, "sort_filter/recent leave the input alone");
}

#[test]
fn aggregation_unicode() {
    let dir = TempDir::new("unicode");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "wx", 2000);
    add_added(&db, "github", "alp", 1000);

    let service = service(
        &db,
        vec![driver(
            "github",
            ChannelKind::Github,
            vec![
                summary("wx", Some("com.wx"), "微信", "聊天工具", &["中", "😀"]),
                summary("alp", Some("com.alp"), "Alpha", "通讯工具", &["\u{FFFD}"]),
            ],
        )],
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(
        categories_from_apps(&all),
        vec!["中".to_string(), "😀".to_string(), "\u{FFFD}".to_string()],
        "UTF-16 code-unit order, not Unicode scalar order"
    );

    let keyword = |value: &str| AppFilter {
        keyword: Some(value.to_string()),
        ..AppFilter::default()
    };
    assert_eq!(ids(&sort_filter(&all, &keyword("微"))), vec!["wx"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("ALPHA"))), vec!["alp"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("通讯"))), vec!["alp"]);

    let category = |value: &str| AppFilter {
        category: Some(value.to_string()),
        ..AppFilter::default()
    };
    assert_eq!(ids(&sort_filter(&all, &category("😀"))), vec!["wx"]);
    assert_eq!(ids(&sort_filter(&all, &category("中"))), vec!["wx"]);

    let by_name = sort_filter(
        &all,
        &AppFilter {
            sort: AppSortMode::Name,
            ..AppFilter::default()
        },
    );
    assert_eq!(ids(&by_name), vec!["alp", "wx"]);
}

#[test]
fn aggregation_dart_lowercase() {
    let dir = TempDir::new("lowercase");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "ist", 5000);
    add_added(&db, "github", "file", 4000);
    add_added(&db, "github", "greek", 3000);
    add_added(&db, "github", "izmir", 2000);
    add_added(&db, "github", "alpha", 1000);

    let service = service(
        &db,
        vec![driver(
            "github",
            ChannelKind::Github,
            vec![
                summary("ist", Some("com.ist"), "İSTANBUL", "city", &["TOOLS"]),
                summary("file", Some("com.file"), "FİLE", "docs", &["TOOLS"]),
                summary("greek", Some("com.greek"), "ΟΔΟΣ", "street", &["TOOLS"]),
                summary("izmir", Some("com.izmir"), "Izmir", "city", &["TOOLS"]),
                summary("alpha", Some("com.alpha"), "Alpha", "ascii", &["TOOLS"]),
            ],
        )],
    );

    let all = service.aggregate_all().unwrap();
    let keyword = |value: &str| AppFilter {
        keyword: Some(value.to_string()),
        ..AppFilter::default()
    };
    assert_eq!(ids(&sort_filter(&all, &keyword("istanbul"))), vec!["ist"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("file"))), vec!["file"]);
    assert_eq!(ids(&sort_filter(&all, &keyword("οδοσ"))), vec!["greek"]);
    assert_eq!(
        ids(&sort_filter(&all, &keyword("city"))),
        vec!["ist", "izmir"]
    );
    assert_eq!(ids(&sort_filter(&all, &keyword("ALPHA"))), vec!["alpha"]);

    let by_name = sort_filter(
        &all,
        &AppFilter {
            sort: AppSortMode::Name,
            ..AppFilter::default()
        },
    );
    assert_eq!(
        ids(&by_name),
        vec!["alpha", "file", "ist", "izmir", "greek"],
        "Dart lowercase puts İstanbul before Izmir"
    );

    assert_eq!(dart_lowercase("İSTANBUL"), "istanbul");
    assert_eq!(dart_lowercase("FİLE"), "file");
    assert_eq!(dart_lowercase("ΟΔΟΣ"), "οδοσ");
}

#[test]
fn aggregation_empty() {
    let dir = TempDir::new("empty");
    let db = DbHandle::open(dir.path()).unwrap();
    let service = service(&db, vec![]);

    assert!(service.aggregate_all().unwrap().is_empty());
    assert_eq!(service.aggregate_page(0, 10).unwrap(), (Vec::new(), 0));
    assert_eq!(service.aggregate_page(0, 0).unwrap(), (Vec::new(), 0));
    assert_eq!(service.aggregate_page(5, 10).unwrap(), (Vec::new(), 0));

    let empty: Vec<AggregatedApp> = Vec::new();
    assert!(categories_from_apps(&empty).is_empty());
    assert!(recent(&empty, 8).is_empty());
    assert!(sort_filter(&empty, &AppFilter::default()).is_empty());
    assert!(dedup_channels_and_packages(empty).is_empty());
}
