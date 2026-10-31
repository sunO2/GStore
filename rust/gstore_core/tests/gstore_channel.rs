//! GStore channel driver + V5 migration contract.
//!
//! Exercises the writable `channel_apps('gstore')` lane (add/remove/list/detail
//! fallback/search) and the one-shot `local_db -> gstore` promotion, including
//! its idempotency. Every test uses a private temp directory.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::channel::{ChannelDriver, GStoreDriver};
use gstore_core::db::{DbHandle, DbError};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use rusqlite::Connection;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_gstore_{tag}_{}_{}",
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

fn driver(dir: &Path) -> GStoreDriver {
    let db = DbHandle::open_at(&dir.join("gstore_core.db")).unwrap();
    GStoreDriver::new(
        ChannelKey::new("gstore").unwrap(),
        ChannelMeta {
            kind: ChannelKind::GStore,
            name: "GStore".to_string(),
            description: "GStore 本地应用库渠道".to_string(),
            enabled: true,
            priority: 1,
            support_offline: true,
            last_update_time: None,
            version: None,
        },
        db,
    )
}

fn summary(app_id: &str, name: &str) -> AppSummary {
    AppSummary {
        app_id: app_id.to_string(),
        package_name: Some(app_id.to_string()),
        name: name.to_string(),
        user: "acme".to_string(),
        repositories: "repo".to_string(),
        icon: format!("https://icons.test/{app_id}.png"),
        des: format!("{name} description"),
        readme: None,
        category: Some(vec!["TOOLS".to_string(), "MEDIA".to_string()]),
        extra: Some(
            serde_json::json!({"sourceId": "local", "packageName": app_id})
                .as_object()
                .cloned()
                .unwrap(),
        ),
        labels: Vec::new(),
    }
}

fn insert_catalog_app(db: &DbHandle, app_id: &str, name: &str, des: &str) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
             VALUES (?1,?2,'acme','repo',?3,?4,'# readme','TOOLS',?5)",
            rusqlite::params![
                app_id,
                name,
                format!("icon-{app_id}.png"),
                des,
                r#"{"packageName":"com.example.real"}"#
            ],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn count(db: &DbHandle, sql: &str, params: &[&str]) -> i64 {
    db.with_reader(|conn| {
        conn.query_row(sql, rusqlite::params_from_iter(params.iter()), |row| {
            row.get(0)
        })
        .map_err(|error| DbError(error.to_string()))
    })
    .unwrap()
}

#[test]
fn gstore_add_app_writes_saved_row() {
    let dir = TempDir::new("add");
    let driver = driver(dir.path());

    driver.add_app(&summary("com.example.alpha", "Alpha")).unwrap();

    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let (name, category, source_id, extra, add_time): (String, Option<String>, Option<String>, Option<String>, i64) =
        db.with_reader(|conn| {
            conn.query_row(
                "SELECT name,category,source_id,extra,add_time FROM channel_apps \
                 WHERE channel_key='gstore' AND app_id='com.example.alpha'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .map_err(|error| DbError(error.to_string()))
        })
        .unwrap();
    println!("saved row: name={name} category={category:?} source_id={source_id:?} add_time={add_time}");
    assert_eq!(name, "Alpha");
    assert_eq!(category.as_deref(), Some("TOOLS,MEDIA"));
    assert_eq!(source_id.as_deref(), Some("local"));
    let extra: serde_json::Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
    assert_eq!(extra["packageName"], "com.example.alpha");
    assert!(extra.get("sourceId").is_none(), "sourceId lives in its own column");
    assert!(add_time > 0);
    assert_eq!(
        count(
            &db,
            "SELECT COUNT(*) FROM channel_apps WHERE channel_key='local_db'",
            &[]
        ),
        0
    );
}

#[test]
fn gstore_remove_app_deletes_saved_row() {
    let dir = TempDir::new("remove");
    let driver = driver(dir.path());
    driver.add_app(&summary("com.example.alpha", "Alpha")).unwrap();
    driver.add_app(&summary("com.example.beta", "Beta")).unwrap();

    driver.remove_app("com.example.alpha").unwrap();

    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    assert_eq!(
        count(
            &db,
            "SELECT COUNT(*) FROM channel_apps WHERE channel_key='gstore'",
            &[]
        ),
        1
    );
    let remaining = driver.get_all_apps(false).unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].app_id, "com.example.beta");
}

#[test]
fn gstore_get_all_apps_returns_saved_rows_newest_first() {
    let dir = TempDir::new("list");
    let driver = driver(dir.path());
    driver.add_app(&summary("com.example.alpha", "Alpha")).unwrap();
    driver.add_app(&summary("com.example.beta", "Beta")).unwrap();
    {
        let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
        db.with_writer(|conn| {
            conn.execute(
                "UPDATE channel_apps SET add_time=200 \
                 WHERE channel_key='gstore' AND app_id='com.example.beta'",
                [],
            )
            .map_err(|error| DbError(error.to_string()))?;
            conn.execute(
                "UPDATE channel_apps SET add_time=100 \
                 WHERE channel_key='gstore' AND app_id='com.example.alpha'",
                [],
            )
            .map_err(|error| DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
    }

    let all = driver.get_all_apps(false).unwrap();
    println!("saved apps: {:?}", all.iter().map(|a| &a.app_id).collect::<Vec<_>>());
    assert_eq!(all.len(), 2);
    assert_eq!(all[0].app_id, "com.example.beta");
    assert_eq!(all[1].app_id, "com.example.alpha");
    assert_eq!(all[0].package_name.as_deref(), Some("com.example.beta"));
}

#[test]
fn gstore_get_app_info_prefers_saved_then_falls_back_to_catalog() {
    let dir = TempDir::new("info");
    let driver = driver(dir.path());
    {
        let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
        insert_catalog_app(&db, "com.example.alpha", "Catalog Alpha", "catalog alpha");
        insert_catalog_app(&db, "com.example.gamma", "Gamma", "gamma app");
    }
    driver.add_app(&summary("com.example.alpha", "Saved Alpha")).unwrap();

    let saved = driver.get_app_info("com.example.alpha", false).unwrap();
    assert_eq!(saved.name, "Saved Alpha");

    let fallback = driver.get_app_info("com.example.gamma", false).unwrap();
    println!("catalog fallback: {fallback:?}");
    assert_eq!(fallback.name, "Gamma");
    assert_eq!(fallback.readme.as_deref(), Some("# readme"));

    let detail = driver.get_app_detail("com.example.alpha", false).unwrap();
    assert_eq!(detail.channel, ChannelKind::GStore);
    assert_eq!(detail.name, "Saved Alpha");

    let catalog_detail = driver.get_app_detail("com.example.gamma", false).unwrap();
    assert_eq!(catalog_detail.channel, ChannelKind::GStore);
    assert_eq!(catalog_detail.name, "Gamma");
}

#[test]
fn gstore_search_apps_finds_catalog_apps() {
    let dir = TempDir::new("search");
    let driver = driver(dir.path());
    {
        let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
        insert_catalog_app(&db, "com.example.alpha", "Alpha Browser", "fast browser");
        insert_catalog_app(&db, "com.example.beta", "Beta Editor", "text editor");
    }

    let hits = driver.search_apps("Alpha", false).unwrap();
    println!("search hits: {:?}", hits.iter().map(|a| &a.app_id).collect::<Vec<_>>());
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].app_id, "com.example.alpha");
}

#[test]
fn gstore_migration_promotes_local_db_and_is_idempotent() {
    let dir = TempDir::new("migrate");
    let path = dir.path().join("gstore_core.db");

    {
        let mut conn = Connection::open(&path).unwrap();
        let mut runner = gstore_core::migration::migrations::runner();
        runner.set_migration_table_name(gstore_core::migration::MIGRATION_LEDGER_TABLE);
        runner
            .set_target(refinery::Target::Version(4))
            .run(&mut conn)
            .unwrap();
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 4, "fixture must be V4");
        conn.execute_batch(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra)
                 VALUES ('com.example.alpha','Alpha','acme','repo','a.png','alpha des',
                         '# alpha','TOOLS','{\"packageName\":\"com.example.real\"}');
             INSERT INTO added_apps(channel_id,app_id,add_time,sort_order,is_enabled)
                 VALUES ('local_db','com.example.alpha',100,3,0),
                        ('local_db','com.example.missing',200,0,1);
             INSERT INTO added_app_tags(channel_id,app_id,tag,add_time)
                 VALUES ('local_db','com.example.alpha','tools',100),
                        ('local_db','com.example.alpha','favorite',101);",
        )
        .unwrap();
    }

    let handle = DbHandle::open_at(&path).expect("V4 -> V5 upgrade");
    let db_path = path.clone();
    {
        let conn = handle.writer().unwrap();
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        let ledger: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| row.get(0))
            .unwrap();
        println!("after V5+V6: user_version={version} ledger={ledger}");
        assert_eq!(
            version,
            i64::from(gstore_core::migration::CORE_SCHEMA_VERSION)
        );
        assert_eq!(ledger, 6);
    }

    let members = count(
        &handle,
        "SELECT COUNT(*) FROM added_apps WHERE channel_id='gstore'",
        &[],
    );
    let legacy_members = count(
        &handle,
        "SELECT COUNT(*) FROM added_apps WHERE channel_id='local_db'",
        &[],
    );
    let saved = count(
        &handle,
        "SELECT COUNT(*) FROM channel_apps WHERE channel_key='gstore'",
        &[],
    );
    let tags = count(
        &handle,
        "SELECT COUNT(*) FROM added_app_tags WHERE channel_id='gstore'",
        &[],
    );
    let legacy_tags = count(
        &handle,
        "SELECT COUNT(*) FROM added_app_tags WHERE channel_id='local_db'",
        &[],
    );
    let catalog = count(&handle, "SELECT COUNT(*) FROM apps", &[]);
    println!(
        "members={members} legacy_members={legacy_members} saved={saved} tags={tags} \
         legacy_tags={legacy_tags} catalog={catalog}"
    );
    assert_eq!(members, 2, "both memberships move, catalog match or not");
    assert_eq!(legacy_members, 0);
    assert_eq!(saved, 1, "only catalog-matched app gets real metadata");
    assert_eq!(tags, 2);
    assert_eq!(legacy_tags, 0);
    assert_eq!(catalog, 1, "apps catalog must never be touched");

    let alpha: (String, String, Option<String>, i64, i64, i64) = handle
        .with_reader(|conn| {
            conn.query_row(
                "SELECT a.name, a.description, a.category, a.add_time, aa.sort_order, aa.is_enabled \
                 FROM channel_apps a JOIN added_apps aa \
                   ON aa.channel_id='gstore' AND aa.app_id=a.app_id \
                 WHERE a.channel_key='gstore' AND a.app_id='com.example.alpha'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .map_err(|error| DbError(error.to_string()))
        })
        .unwrap();
    println!("alpha row: {alpha:?}");
    assert_eq!(alpha.0, "Alpha");
    assert_eq!(alpha.1, "alpha des");
    assert_eq!(alpha.2.as_deref(), Some("TOOLS"));
    assert_eq!(alpha.3, 100);
    assert_eq!(alpha.4, 3);
    assert_eq!(alpha.5, 0);

    drop(handle);
    let reopened = DbHandle::open_at(&db_path).expect("reopen applies nothing new");
    let second: (i64, i64, i64) = reopened
        .with_reader(|conn| {
            Ok((
                conn.query_row(
                    "SELECT COUNT(*) FROM added_apps WHERE channel_id='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
                conn.query_row(
                    "SELECT COUNT(*) FROM channel_apps WHERE channel_key='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
                conn.query_row(
                    "SELECT COUNT(*) FROM added_app_tags WHERE channel_id='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
            ))
        })
        .unwrap();
    assert_eq!(second, (2, 1, 2), "reopen must not duplicate rows");

    reopened
        .with_writer(|conn| {
            conn.execute_batch(include_str!("../migrations/V5__gstore_channel.sql"))
                .map_err(|error| DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
    let third: (i64, i64, i64) = reopened
        .with_reader(|conn| {
            Ok((
                conn.query_row(
                    "SELECT COUNT(*) FROM added_apps WHERE channel_id='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
                conn.query_row(
                    "SELECT COUNT(*) FROM channel_apps WHERE channel_key='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
                conn.query_row(
                    "SELECT COUNT(*) FROM added_app_tags WHERE channel_id='gstore'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| DbError(error.to_string()))?,
            ))
        })
        .unwrap();
    assert_eq!(third, second, "re-running V5 SQL must be a no-op");
}
