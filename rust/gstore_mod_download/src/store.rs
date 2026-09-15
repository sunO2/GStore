//! SQLite 持久化：任务表 + 分段表。
//!
//! 相对既有 Dart 侧 Floor 库的两处工业级改进：
//! 1. **`(app_id, version, file_name)` 唯一索引** —— Dream 侧原库只有自增主键，
//!    并发两次 `getByKey` 都查不到就会插入两行（上一轮排查出的重复任务根因之一）。
//!    这里从 schema 层堵死：`INSERT ... ON CONFLICT ... DO UPDATE` 收敛到同一行。
//! 2. **分段独立成表** —— 断点续传的最小持久化单位是"每段已落盘多少"，
//!    放在任务行里用 JSON 会随分段数增长而反复全量重写。
//!
//! `Connection` 非 Send，故外部用 `Arc<Mutex<Connection>>` 包一层，只做短锁。

use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};

use crate::model::{FailKind, Segment, ServerMeta, Task, TaskDto, TaskStatus};

/// 当前 schema 版本（`PRAGMA user_version`）。加字段/索引时 +1 并补迁移分支。
pub const SCHEMA_VERSION: i32 = 4;

pub type SharedConn = Arc<Mutex<Connection>>;

pub fn open(path: &str) -> Result<SharedConn, String> {
    let conn = if path == ":memory:" {
        Connection::open_in_memory().map_err(|e| e.to_string())?
    } else {
        if let Some(parent) = Path::new(path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        Connection::open(path).map_err(|e| e.to_string())?
    };
    // WAL：读写不互斥（进度写入频繁，避免与查询争锁）
    let _ = conn.pragma_update(None, "journal_mode", "WAL");
    let _ = conn.pragma_update(None, "foreign_keys", "ON");
    let _ = conn.pragma_update(None, "synchronous", "NORMAL");
    migrate(&conn)?;
    Ok(Arc::new(Mutex::new(conn)))
}

fn migrate(conn: &Connection) -> Result<(), String> {
    let ver: i32 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap_or(0);

    if ver < 1 {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS download_task (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id          TEXT    NOT NULL,
                app_name        TEXT    NOT NULL,
                version         TEXT    NOT NULL,
                file_name       TEXT    NOT NULL,
                url             TEXT    NOT NULL,
                file_path       TEXT    NOT NULL,
                total           INTEGER NOT NULL DEFAULT 0,
                received        INTEGER NOT NULL DEFAULT 0,
                status          INTEGER NOT NULL,
                speed_bps       INTEGER NOT NULL DEFAULT 0,
                eta_sec         INTEGER,
                error           TEXT,
                fail_kind       TEXT,
                retries         INTEGER NOT NULL DEFAULT 0,
                server_meta     TEXT,
                expected_sha256 TEXT,
                actual_sha256   TEXT,
                priority        INTEGER NOT NULL DEFAULT 0,
                queue_reason    TEXT,
                created_at      INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL
            );

            -- 同一下载（应用+版本+文件名）只允许一行：从 schema 层防重复任务
            CREATE UNIQUE INDEX IF NOT EXISTS ux_download_task_key
                ON download_task(app_id, version, file_name);

            -- 按状态取队列/统计（调度与面板高频查询）
            CREATE INDEX IF NOT EXISTS ix_download_task_status
                ON download_task(status, priority DESC, id ASC);

            CREATE TABLE IF NOT EXISTS download_segment (
                task_id    INTEGER NOT NULL,
                idx        INTEGER NOT NULL,
                start_byte INTEGER NOT NULL,
                end_byte   INTEGER NOT NULL,
                received   INTEGER NOT NULL DEFAULT 0,
                done       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (task_id, idx),
                FOREIGN KEY (task_id) REFERENCES download_task(id) ON DELETE CASCADE
            );
            "#,
        )
        .map_err(|e| e.to_string())?;
    }

    // v4：① "下载完是否自动安装"随任务持久化（Rust 内核下 Dart 侧才有依据触发安装）
    //     ② 记录"最后一次开始时间"，列表按它置顶（重试/重新下载后仍保留）
    if ver < 4 {
        conn.execute_batch(
            r#"
            ALTER TABLE download_task ADD COLUMN install_after_download INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE download_task ADD COLUMN last_started_at INTEGER NOT NULL DEFAULT 0;
            UPDATE download_task SET last_started_at = created_at WHERE last_started_at = 0;
            "#,
        )
        .map_err(|e| e.to_string())?;
    }

    // v2：判重键与"只能下应用"解耦，并补上真正的正确性兜底。
    //
    // 背景：v1 用 (app_id, version, file_name) 当唯一键，有两个问题：
    //   1) 展示字段（app_name）与业务字段被硬绑进键，换语言/换镜像会算出不同的键；
    //   2) file_path 毫无约束 —— 两个不同 app_id 指向同一目标路径时仍会并发写同一文件。
    // v2 把「判重」（语义）与「同一路径不能有两个活动任务」（正确性）拆成两层约束。
    if ver < 2 {
        conn.execute_batch(
            r#"
            ALTER TABLE download_task ADD COLUMN dedup_key        TEXT NOT NULL DEFAULT '';
            ALTER TABLE download_task ADD COLUMN kind             TEXT NOT NULL DEFAULT 'file';
            ALTER TABLE download_task ADD COLUMN resource_id      TEXT NOT NULL DEFAULT '';
            ALTER TABLE download_task ADD COLUMN resource_version TEXT NOT NULL DEFAULT '';

            -- 既有行回填 v1 的等价判重键（保持唯一，迁移不丢数据）
            UPDATE download_task
               SET dedup_key = 'app:' || app_id || ':' || version || ':' || file_name
             WHERE dedup_key = '';

            DROP INDEX IF EXISTS ux_download_task_key;

            -- 判重依据：逻辑唯一键（由调用方指定或按规则派生）
            CREATE UNIQUE INDEX IF NOT EXISTS ux_download_task_dedup
                ON download_task(dedup_key);

            -- ★ 正确性兜底：同一落盘路径不允许两个"活动"任务（历史行保留）
            CREATE UNIQUE INDEX IF NOT EXISTS ux_download_task_active_dest
                ON download_task(file_path)
                WHERE status IN (0, 1, 2);
            "#,
        )
        .map_err(|e| e.to_string())?;
    }

    // v3：持久化发起下载时携带的请求头（GitHub/OPPO 等源需要，面板要展示）
    if ver < 3 {
        conn.execute_batch(
            "ALTER TABLE download_task ADD COLUMN headers TEXT NOT NULL DEFAULT '';",
        )
        .map_err(|e| e.to_string())?;
    }

    conn.pragma_update(None, "user_version", SCHEMA_VERSION)
        .map_err(|e| e.to_string())
}

/// 插入或按 `dedup_key` 收敛更新，返回任务 id。
///
/// 收敛键是**逻辑唯一键**，不是业务字段拼接：
/// - 展示字段（`app_name` 随语言变化）不进键
/// - URL 不进键（换镜像不该产生重复任务）
/// 命中则更新并**保留 id**（取消 token、分段归属都不会错位）。
pub fn upsert_task(conn: &SharedConn, task: &Task) -> Result<u64, String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    let existing: Option<i64> = c
        .query_row(
            "SELECT id FROM download_task WHERE dedup_key=?1 LIMIT 1",
            params![task.dedup_key],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    let fail_kind = task
        .fail_kind
        .as_ref()
        .map(|k| serde_json::to_string(k).unwrap_or_default());
    let server_meta = serde_json::to_string(&task.server_meta).unwrap_or_default();
    let headers_json = serde_json::to_string(&task.headers).unwrap_or_else(|_| "[]".to_string());

    match existing {
        Some(id) => {
            c.execute(
                r#"UPDATE download_task SET
                    dedup_key=?2, kind=?3, resource_id=?4, resource_version=?5,
                    app_name=?6, url=?7, file_path=?8, total=?9, received=?10, status=?11,
                    speed_bps=?12, eta_sec=?13, error=?14, fail_kind=?15, retries=?16,
                    server_meta=?17, expected_sha256=?18, actual_sha256=?19, priority=?20,
                    queue_reason=?21, updated_at=?22, headers=?23
                   WHERE id=?1"#,
                params![
                    id,
                    task.dedup_key,
                    task.kind,
                    task.resource_id,
                    task.resource_version,
                    task.app_name,
                    task.url,
                    task.file_path,
                    task.total as i64,
                    task.received as i64,
                    task.status.as_i32(),
                    task.speed_bps as i64,
                    task.eta_sec.map(|v| v as i64),
                    task.error,
                    fail_kind,
                    task.retries as i64,
                    server_meta,
                    task.expected_sha256,
                    task.actual_sha256,
                    task.priority,
                    task.queue_reason,
                    task.updated_at,
                    headers_json,
                ],
            )
            .map_err(|e| e.to_string())?;
            write_v4_columns(&c, id as u64, task)?;
            Ok(id as u64)
        }
        None => {
            c.execute(
                r#"INSERT INTO download_task
                   (dedup_key, kind, resource_id, resource_version,
                    app_id, app_name, version, file_name, url, file_path, total, received,
                    status, speed_bps, eta_sec, error, fail_kind, retries, server_meta,
                    expected_sha256, actual_sha256, priority, queue_reason, created_at, updated_at, headers)
                   VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26)"#,
                params![
                    task.dedup_key,
                    task.kind,
                    task.resource_id,
                    task.resource_version,
                    task.app_id,
                    task.app_name,
                    task.version,
                    task.file_name,
                    task.url,
                    task.file_path,
                    task.total as i64,
                    task.received as i64,
                    task.status.as_i32(),
                    task.speed_bps as i64,
                    task.eta_sec.map(|v| v as i64),
                    task.error,
                    fail_kind,
                    task.retries as i64,
                    server_meta,
                    task.expected_sha256,
                    task.actual_sha256,
                    task.priority,
                    task.queue_reason,
                    task.created_at,
                    task.updated_at,
                    headers_json,
                ],
            )
            .map_err(|e| e.to_string())?;
            let new_id = c.last_insert_rowid() as u64;
            write_v4_columns(&c, new_id, task)?;
            Ok(new_id)
        }
    }
}

pub fn save_segments(conn: &SharedConn, task_id: u64, segments: &[Segment]) -> Result<(), String> {
    let mut c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    let tx = c.transaction().map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM download_segment WHERE task_id=?1", params![task_id as i64])
        .map_err(|e| e.to_string())?;
    for s in segments {
        tx.execute(
            "INSERT INTO download_segment (task_id, idx, start_byte, end_byte, received, done)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                task_id as i64,
                s.index as i64,
                s.start_byte as i64,
                s.end_byte as i64,
                s.received as i64,
                if s.done { 1 } else { 0 },
            ],
        )
        .map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())
}

fn load_segments(c: &Connection, task_id: i64) -> Result<Vec<Segment>, String> {
    let mut st = c
        .prepare(
            "SELECT idx, start_byte, end_byte, received, done FROM download_segment
             WHERE task_id=?1 ORDER BY idx ASC",
        )
        .map_err(|e| e.to_string())?;
    let rows = st
        .query_map(params![task_id], |r| {
            Ok(Segment {
                index: r.get::<_, i64>(0)? as u32,
                start_byte: r.get::<_, i64>(1)? as u64,
                end_byte: r.get::<_, i64>(2)? as u64,
                received: r.get::<_, i64>(3)? as u64,
                done: r.get::<_, i64>(4)? != 0,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

const TASK_COLUMNS: &str = "id, app_id, app_name, version, file_name, url, file_path, total, received,
     status, speed_bps, eta_sec, error, fail_kind, retries, server_meta, expected_sha256,
     actual_sha256, priority, queue_reason, created_at, updated_at,
     dedup_key, kind, resource_id, resource_version, headers, install_after_download, last_started_at";

fn row_to_task(r: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let fail_kind_raw: Option<String> = r.get(13)?;
    let server_meta_raw: Option<String> = r.get(15)?;
    Ok(Task {
        id: r.get::<_, i64>(0)? as u64,
        app_id: r.get(1)?,
        app_name: r.get(2)?,
        version: r.get(3)?,
        file_name: r.get(4)?,
        url: r.get(5)?,
        file_path: r.get(6)?,
        total: r.get::<_, i64>(7)? as u64,
        received: r.get::<_, i64>(8)? as u64,
        status: TaskStatus::from_i32(r.get::<_, i64>(9)? as i32),
        speed_bps: r.get::<_, i64>(10)? as u64,
        eta_sec: r.get::<_, Option<i64>>(11)?.map(|v| v as u64),
        error: r.get(12)?,
        fail_kind: fail_kind_raw.and_then(|s| serde_json::from_str::<FailKind>(&s).ok()),
        retries: r.get::<_, i64>(14)? as u32,
        server_meta: server_meta_raw
            .and_then(|s| serde_json::from_str::<ServerMeta>(&s).ok())
            .unwrap_or_default(),
        expected_sha256: r.get(16)?,
        actual_sha256: r.get(17)?,
        priority: r.get::<_, i64>(18)? as i32,
        queue_reason: r.get(19)?,
        created_at: r.get(20)?,
        updated_at: r.get(21)?,
        dedup_key: r.get(22)?,
        install_after_download: r.get::<_, i64>(27)? != 0,
        last_started_at: r.get(28)?,
        kind: r.get(23)?,
        resource_id: r.get(24)?,
        resource_version: r.get(25)?,
        headers: r
            .get::<_, String>(26)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<(String, String)>>(&s).ok())
            .unwrap_or_default(),
        segments: Vec::new(),
    })
}

pub fn get_task(conn: &SharedConn, id: u64) -> Result<Option<Task>, String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    let sql = format!("SELECT {TASK_COLUMNS} FROM download_task WHERE id=?1");
    let mut task = c
        .query_row(&sql, params![id as i64], row_to_task)
        .optional()
        .map_err(|e| e.to_string())?;
    if let Some(t) = task.as_mut() {
        t.segments = load_segments(&c, id as i64)?;
    }
    Ok(task)
}

/// 清空某任务的全部分段记录（`replace` 策略 / 服务端变更后重新开始时用）。
pub fn clear_segments(conn: &SharedConn, task_id: u64) -> Result<(), String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    c.execute(
        "DELETE FROM download_segment WHERE task_id=?1",
        params![task_id as i64],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// 按逻辑唯一键查任务（判重的唯一入口）。
pub fn find_by_dedup_key(conn: &SharedConn, dedup_key: &str) -> Result<Option<Task>, String> {
    let id: Option<i64> = {
        let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
        c.query_row(
            "SELECT id FROM download_task WHERE dedup_key=?1 LIMIT 1",
            params![dedup_key],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
    };
    match id {
        Some(id) => get_task(conn, id as u64),
        None => Ok(None),
    }
}

/// 查"占用同一落盘路径的活动任务"（排除自身）。
///
/// 这是**正确性**约束的查询面：两个活动任务写同一路径必然互相破坏，
/// schema 层用 `ux_download_task_active_dest` 兜底，这里用于给出更友好的错误。
pub fn find_active_by_dest(
    conn: &SharedConn,
    file_path: &str,
    exclude_id: Option<u64>,
) -> Result<Option<Task>, String> {
    let id: Option<i64> = {
        let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
        c.query_row(
            "SELECT id FROM download_task WHERE file_path=?1 AND status IN (0,1,2) AND id != ?2 LIMIT 1",
            params![file_path, exclude_id.unwrap_or(0) as i64],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
    };
    match id {
        Some(id) => get_task(conn, id as u64),
        None => Ok(None),
    }
}

/// 列表查询。[status_filter] 为空 = 全部；按优先级与创建时间排序（面板顺序稳定）。
pub fn list_tasks(conn: &SharedConn, status_filter: &[TaskStatus]) -> Result<Vec<Task>, String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    let sql = format!(
        "SELECT {TASK_COLUMNS} FROM download_task ORDER BY priority DESC, id ASC"
    );
    let mut st = c.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = st.query_map([], row_to_task).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in rows {
        let t = r.map_err(|e| e.to_string())?;
        if !status_filter.is_empty() && !status_filter.contains(&t.status) {
            continue;
        }
        out.push(t);
    }
    drop(st);
    for t in out.iter_mut() {
        t.segments = load_segments(&c, t.id as i64)?;
    }
    Ok(out)
}

pub fn delete_task(conn: &SharedConn, id: u64) -> Result<(), String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    c.execute("DELETE FROM download_task WHERE id=?1", params![id as i64])
        .map_err(|e| e.to_string())?;
    let _ = c.execute("DELETE FROM download_segment WHERE task_id=?1", params![id as i64]);
    Ok(())
}

/// 进度类字段的窄更新（高频路径，避免整行重写的写放大）。
pub fn update_progress(
    conn: &SharedConn,
    id: u64,
    received: u64,
    total: u64,
    speed_bps: u64,
    eta_sec: Option<u64>,
    status: TaskStatus,
    updated_at: i64,
) -> Result<(), String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    c.execute(
        "UPDATE download_task SET received=?2, total=?3, speed_bps=?4, eta_sec=?5, status=?6, updated_at=?7 WHERE id=?1",
        params![
            id as i64,
            received as i64,
            total as i64,
            speed_bps as i64,
            eta_sec.map(|v| v as i64),
            status.as_i32(),
            updated_at
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// 崩溃恢复：进程重启后 `downloading`/`connecting` 已无实际执行者。
///
/// 工业做法是**不静默续跑**（用户可能不想要流量），统一降级为 `paused` 并注明原因，
/// 由用户决定是否恢复；`queued` 保持排队，模块初始化后会被调度器重新拾起。
pub fn recover_after_restart(conn: &SharedConn) -> Result<(usize, usize), String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    let now = crate::model::now_ms();
    let paused = c
        .execute(
            "UPDATE download_task SET status=?1, speed_bps=0, eta_sec=NULL, queue_reason=?2, updated_at=?3
             WHERE status IN (?4, ?5)",
            params![
                TaskStatus::Paused.as_i32(),
                "应用重启，已暂停（可手动继续）",
                now,
                TaskStatus::Downloading.as_i32(),
                TaskStatus::Connecting.as_i32(),
            ],
        )
        .map_err(|e| e.to_string())?;
    let queued = c
        .query_row(
            "SELECT COUNT(*) FROM download_task WHERE status=?1",
            params![TaskStatus::Queued.as_i32()],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0);
    Ok((paused, queued as usize))
}

pub fn dto_of(task: &Task) -> TaskDto {
    TaskDto::from(task)
}

/// 单独写 v4 新增的两列。
///
/// 刻意不塞进 upsert 主语句：那样会打乱占位符编号；这两列更新频率极低，
/// 多一条语句换可读性是划算的。
fn write_v4_columns(c: &rusqlite::Connection, id: u64, task: &Task) -> Result<(), String> {
    c.execute(
        "UPDATE download_task SET install_after_download=?2, last_started_at=?3 WHERE id=?1",
        params![id as i64, task.install_after_download as i64, task.last_started_at],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// 只刷新「最后开始时间」（重试/继续/重新下载时调用），避免整行重写。
pub fn touch_last_started_at(conn: &SharedConn, id: u64, now: i64) -> Result<(), String> {
    let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
    c.execute(
        "UPDATE download_task SET last_started_at=?2, updated_at=?2 WHERE id=?1",
        params![id as i64, now],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::now_ms;

    /// 造一条任务：判重键与 v1 的 (app, version, file) 等价，便于对照迁移语义。
    fn sample(app: &str, ver: &str, file: &str) -> Task {
        Task {
            id: 0,
            dedup_key: format!("app:{app}:{ver}:{file}"),
            app_id: app.into(),
            app_name: "app".into(),
            version: ver.into(),
            file_name: file.into(),
            url: "http://x/f.apk".into(),
            file_path: format!("/tmp/{file}"),
            total: 0,
            received: 0,
            status: TaskStatus::Queued,
            speed_bps: 0,
            eta_sec: None,
            error: None,
            fail_kind: None,
            retries: 0,
            segments: vec![],
            server_meta: ServerMeta::default(),
            expected_sha256: None,
            actual_sha256: None,
            priority: 0,
            queue_reason: None,
            created_at: now_ms(),
            updated_at: now_ms(),
            ..Default::default()
        }
    }

    #[test]
    fn upsert_same_key_collapses_to_one_row_keep_same_id() {
        let conn = open(":memory:").unwrap();
        let mut t = sample("com.a", "1.0", "a.apk");
        let id1 = upsert_task(&conn, &t).unwrap();
        // 同键再次插入（并发/重复点击场景）→ 必须收敛到同一行
        t.received = 500;
        t.status = TaskStatus::Downloading;
        let id2 = upsert_task(&conn, &t).unwrap();
        assert_eq!(id1, id2, "同键必须复用同一 id，不能新增行");

        let all = list_tasks(&conn, &[]).unwrap();
        assert_eq!(all.len(), 1, "唯一索引必须保证同一下载只有一行");
        assert_eq!(all[0].received, 500);
    }

    #[test]
    fn different_versions_are_independent_tasks_when_destinations_differ() {
        let conn = open(":memory:").unwrap();
        upsert_task(&conn, &sample("com.a", "1.0", "v1.apk")).unwrap();
        upsert_task(&conn, &sample("com.a", "2.0", "v2.apk")).unwrap();
        upsert_task(&conn, &sample("com.a", "1.0", "other.apk")).unwrap();
        assert_eq!(
            list_tasks(&conn, &[]).unwrap().len(),
            3,
            "不同版本/文件应是独立任务"
        );
    }

    /// 正确性兜底：同一落盘路径不允许两个**活动**任务（两个 writer 会互相破坏）。
    #[test]
    fn two_active_tasks_may_not_share_one_destination() {
        let conn = open(":memory:").unwrap();
        let mut first = sample("com.a", "1.0", "same.apk");
        first.status = TaskStatus::Downloading;
        let first_id = upsert_task(&conn, &first).unwrap();

        // 另一个版本指向同一落盘路径、同处活动态 → 必须被 schema 拦下
        let second = sample("com.a", "2.0", "same.apk");
        let err = upsert_task(&conn, &second).unwrap_err();
        assert!(err.contains("file_path"), "应由落盘路径唯一索引拦下：{err}");

        // 前一个进入终态后，同一路径可以再下（例如升级覆盖）——历史行保留
        let mut done = get_task(&conn, first_id).unwrap().unwrap();
        done.status = TaskStatus::Completed;
        upsert_task(&conn, &done).unwrap();
        upsert_task(&conn, &second).unwrap();
        assert_eq!(list_tasks(&conn, &[]).unwrap().len(), 2);
    }

    #[test]
    fn segments_roundtrip_and_replace() {
        let conn = open(":memory:").unwrap();
        let t = sample("com.a", "1.0", "a.apk");
        let id = upsert_task(&conn, &t).unwrap();
        let segs = vec![
            Segment { index: 0, start_byte: 0, end_byte: 99, received: 100, done: true },
            Segment { index: 1, start_byte: 100, end_byte: 199, received: 40, done: false },
        ];
        save_segments(&conn, id, &segs).unwrap();
        let got = get_task(&conn, id).unwrap().unwrap();
        assert_eq!(got.segments.len(), 2);
        assert!(got.segments[0].done);
        assert_eq!(got.segments[1].received, 40);

        // 再次保存必须整体替换（不是追加），否则分段会无限增长
        save_segments(&conn, id, &segs[..1]).unwrap();
        assert_eq!(get_task(&conn, id).unwrap().unwrap().segments.len(), 1);
    }

    #[test]
    fn recover_marks_running_as_paused_and_counts_queued() {
        let conn = open(":memory:").unwrap();
        let mut a = sample("com.a", "1", "a.apk");
        a.status = TaskStatus::Downloading;
        let mut b = sample("com.b", "1", "b.apk");
        b.status = TaskStatus::Connecting;
        let mut c = sample("com.c", "1", "c.apk");
        c.status = TaskStatus::Queued;
        upsert_task(&conn, &a).unwrap();
        upsert_task(&conn, &b).unwrap();
        upsert_task(&conn, &c).unwrap();

        let (paused, queued) = recover_after_restart(&conn).unwrap();
        assert_eq!(paused, 2, "downloading/connecting 应降级为 paused");
        assert_eq!(queued, 1, "queued 保持排队");

        let all = list_tasks(&conn, &[]).unwrap();
        assert!(all.iter().all(|t| t.status != TaskStatus::Downloading && t.status != TaskStatus::Connecting));
        assert!(all.iter().any(|t| t.status == TaskStatus::Paused));
    }

    #[test]
    fn delete_removes_segments_too() {
        let conn = open(":memory:").unwrap();
        let id = upsert_task(&conn, &sample("com.a", "1", "a.apk")).unwrap();
        save_segments(&conn, id, &[Segment { index: 0, start_byte: 0, end_byte: 9, received: 10, done: true }]).unwrap();
        delete_task(&conn, id).unwrap();
        assert!(get_task(&conn, id).unwrap().is_none());
        let c = conn.lock().unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM download_segment WHERE task_id=?1", params![id as i64], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0, "删任务必须级联清分段行");
    }

    #[test]
    fn find_by_key_matches_unique_index_semantics() {
        let conn = open(":memory:").unwrap();
        upsert_task(&conn, &sample("com.a", "1", "a.apk")).unwrap();
        assert!(find_by_dedup_key(&conn, "app:com.a:1:a.apk").unwrap().is_some());
        assert!(find_by_dedup_key(&conn, "app:com.a:2:a.apk").unwrap().is_none());
    }

    #[test]
    fn high_frequency_progress_update_is_narrow() {
        let conn = open(":memory:").unwrap();
        let id = upsert_task(&conn, &sample("com.a", "1", "a.apk")).unwrap();
        update_progress(&conn, id, 1234, 5000, 4096, Some(12), TaskStatus::Downloading, now_ms()).unwrap();
        let t = get_task(&conn, id).unwrap().unwrap();
        assert_eq!(t.received, 1234);
        assert_eq!(t.total, 5000);
        // 窄更新不应该动其它字段
        assert_eq!(t.app_name, "app");
        assert_eq!(t.url, "http://x/f.apk");
    }
}
