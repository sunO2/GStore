//! Agent session/message/memory persistence over the core database.
//!
//! Sessions and messages are plain rows; memory uses an external-content FTS5
//! index (`agent_memory_fts`, trigram tokenizer) so Chinese substring queries
//! can use `MATCH`. Queries shorter than three characters fall back to `LIKE`,
//! and an empty result set falls back to the most recent memories.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};

use crate::db::{DbError, DbHandle};
use crate::error::Error;

static NEXT_MEMORY: AtomicU64 = AtomicU64::new(1);

/// One persisted conversation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub id: String,
    #[serde(default)]
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(default)]
    pub messages: Vec<AgentMessage>,
}

/// One message in a conversation (mirrors Dart `SessionMessage`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentMessage {
    pub seq: i64,
    pub time: i64,
    pub is_user: bool,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub is_tool_result: bool,
    #[serde(default)]
    pub tool_type: Option<String>,
    #[serde(default)]
    pub tool_status: Option<String>,
    #[serde(default)]
    pub tool_detail: Option<String>,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_args: Option<String>,
    #[serde(default)]
    pub tool_result: Option<String>,
    #[serde(default)]
    pub turn_id: Option<String>,
    #[serde(default)]
    pub confirm_options: Option<Vec<String>>,
    #[serde(default)]
    pub confirm_multi_select: bool,
    #[serde(default)]
    pub reasoning: Option<String>,
}

/// One long-term memory.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentMemory {
    pub id: String,
    pub text: String,
    pub created_at: i64,
    pub last_used_at: i64,
    pub hits: i64,
}

/// One agent turn trace (P3-1 observability).
///
/// Mirrors Dart `AgentTurnTrace.toJson()`; `detail` carries the full payload so
/// a debug view can show tool calls/errors without extra columns.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTrace {
    pub turn_id: String,
    #[serde(default)]
    pub session_id: Option<String>,
    pub created_at: i64,
    /// `ok` | `error` | `cancelled`
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default = "default_true")]
    pub tools_enabled: bool,
    #[serde(default)]
    pub prompt_chars: i64,
    #[serde(default)]
    pub message_count: i64,
    #[serde(default)]
    pub tools_offered: i64,
    #[serde(default)]
    pub model_steps: i64,
    #[serde(default)]
    pub tool_requests: i64,
    #[serde(default)]
    pub tool_responses: i64,
    #[serde(default)]
    pub tool_errors: i64,
    #[serde(default)]
    pub first_token_ms: Option<i64>,
    #[serde(default)]
    pub total_ms: i64,
    #[serde(default)]
    pub response_chars: i64,
    #[serde(default)]
    pub reasoning_chars: i64,
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub finish_reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    /// Full trace JSON (tool call list, probe, etc.).
    #[serde(default)]
    pub detail: Option<String>,
}

fn default_true() -> bool {
    true
}

/// Agent store over the core database.
pub struct AgentStore {
    db: DbHandle,
}

impl AgentStore {
    pub fn new(db: DbHandle) -> Self {
        Self { db }
    }

    /// All sessions, newest-updated first, with messages ordered by seq.
    pub fn sessions(&self) -> Result<Vec<AgentSession>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(
                "SELECT id,title,created_at,updated_at FROM agent_session \
                 ORDER BY updated_at DESC, id ASC",
            )
            .map_err(sql_error)?;
        let mut sessions: Vec<AgentSession> = stmt
            .query_map([], |row| {
                Ok(AgentSession {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    created_at: row.get(2)?,
                    updated_at: row.get(3)?,
                    messages: Vec::new(),
                })
            })
            .map_err(sql_error)?
            .collect::<Result<_, _>>()
            .map_err(sql_error)?;
        for session in &mut sessions {
            session.messages = self.messages_for(&conn, &session.id)?;
        }
        Ok(sessions)
    }

    fn messages_for(
        &self,
        conn: &rusqlite::Connection,
        session_id: &str,
    ) -> Result<Vec<AgentMessage>, Error> {
        let mut stmt = conn
            .prepare(
                "SELECT seq,time,is_user,text,reasoning,is_tool_result,tool_type,tool_status,\
                 tool_detail,tool_name,tool_args,tool_result,turn_id,confirm_options,\
                 confirm_multi_select FROM agent_message WHERE session_id=?1 ORDER BY seq ASC",
            )
            .map_err(sql_error)?;
        let rows = stmt
            .query_map([session_id], |row| {
                let confirm_options: Option<String> = row.get(13)?;
                Ok(AgentMessage {
                    seq: row.get(0)?,
                    time: row.get(1)?,
                    is_user: row.get::<_, i64>(2)? != 0,
                    text: row.get(3)?,
                    reasoning: row.get(4)?,
                    is_tool_result: row.get::<_, i64>(5)? != 0,
                    tool_type: row.get(6)?,
                    tool_status: row.get(7)?,
                    tool_detail: row.get(8)?,
                    tool_name: row.get(9)?,
                    tool_args: row.get(10)?,
                    tool_result: row.get(11)?,
                    turn_id: row.get(12)?,
                    confirm_options: confirm_options
                        .as_deref()
                        .and_then(|raw| serde_json::from_str(raw).ok()),
                    confirm_multi_select: row.get::<_, i64>(14)? != 0,
                })
            })
            .map_err(sql_error)?;
        rows.collect::<Result<_, _>>().map_err(sql_error)
    }

    /// Replaces every session/message (used by Dart bulk save + migration).
    pub fn replace_sessions(&self, sessions: &[AgentSession]) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_message", []).map_err(sql_error)?;
        tx.execute("DELETE FROM agent_session", []).map_err(sql_error)?;
        for session in sessions {
            insert_session(&tx, session)?;
        }
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    /// Upserts one session and replaces its messages.
    pub fn upsert_session(&self, session: &AgentSession) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute(
            "INSERT INTO agent_session(id,title,created_at,updated_at) VALUES (?1,?2,?3,?4) \
             ON CONFLICT(id) DO UPDATE SET title=excluded.title, \
                 created_at=excluded.created_at, updated_at=excluded.updated_at",
            params![session.id, session.title, session.created_at, session.updated_at],
        )
        .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_message WHERE session_id=?1", [&session.id])
            .map_err(sql_error)?;
        for (index, message) in session.messages.iter().enumerate() {
            insert_message(&tx, &session.id, index as i64, message)?;
        }
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    pub fn delete_session(&self, id: &str) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_message WHERE session_id=?1", [id])
            .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_session WHERE id=?1", [id])
            .map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    pub fn clear_sessions(&self) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_message", []).map_err(sql_error)?;
        tx.execute("DELETE FROM agent_session", []).map_err(sql_error)?;
        tx.execute("DELETE FROM agent_meta WHERE k='current_session_id'", [])
            .map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    pub fn current_session_id(&self) -> Result<Option<String>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row(
            "SELECT v FROM agent_meta WHERE k='current_session_id'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(sql_error)
        .map(|value| value.flatten())
    }

    pub fn set_current_session_id(&self, id: Option<&str>) -> Result<(), Error> {
        let conn = self.db.writer().map_err(db_error)?;
        match id {
            Some(id) => {
                conn.execute(
                    "INSERT INTO agent_meta(k,v) VALUES ('current_session_id',?1) \
                     ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                    [id],
                )
                .map_err(sql_error)?;
            }
            None => {
                conn.execute("DELETE FROM agent_meta WHERE k='current_session_id'", [])
                    .map_err(sql_error)?;
            }
        }
        Ok(())
    }

    /// Generic small-state read (`agent_meta`). Used for the rolling context
    /// summary keyed by session id.
    pub fn read_meta(&self, key: &str) -> Result<Option<String>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row("SELECT v FROM agent_meta WHERE k=?1", [key], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()
        .map_err(sql_error)
        .map(Option::flatten)
    }

    /// Writes (or deletes when `value` is `None`) one `agent_meta` entry.
    pub fn write_meta(&self, key: &str, value: Option<&str>) -> Result<(), Error> {
        let conn = self.db.writer().map_err(db_error)?;
        match value {
            Some(value) => {
                conn.execute(
                    "INSERT INTO agent_meta(k,v) VALUES (?1,?2) \
                     ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                    params![key, value],
                )
                .map_err(sql_error)?;
            }
            None => {
                conn.execute("DELETE FROM agent_meta WHERE k=?1", [key])
                    .map_err(sql_error)?;
            }
        }
        Ok(())
    }

    pub fn memories(&self) -> Result<Vec<AgentMemory>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(
                "SELECT id,text,created_at,last_used_at,hits FROM agent_memory \
                 ORDER BY last_used_at DESC, id ASC",
            )
            .map_err(sql_error)?;
        let rows = stmt
            .query_map([], |row| {
                Ok(AgentMemory {
                    id: row.get(0)?,
                    text: row.get(1)?,
                    created_at: row.get(2)?,
                    last_used_at: row.get(3)?,
                    hits: row.get(4)?,
                })
            })
            .map_err(sql_error)?;
        rows.collect::<Result<_, _>>().map_err(sql_error)
    }

    /// Relevant memories: FTS5 trigram for queries >= 3 chars, LIKE otherwise,
    /// newest-first as a fallback when nothing matches.
    pub fn search_memories(&self, query: &str, limit: i64) -> Result<Vec<AgentMemory>, Error> {
        let limit = limit.clamp(1, 200) as usize;
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(self.memories()?.into_iter().take(limit).collect());
        }
        let conn = self.db.reader().map_err(db_error)?;
        let mut found = Vec::new();
        if trimmed.chars().count() >= 3 {
            let match_query = format!("\"{}\"", trimmed.replace('"', "\"\""));
            if let Ok(mut stmt) = conn.prepare(
                "SELECT m.id,m.text,m.created_at,m.last_used_at,m.hits \
                 FROM agent_memory_fts f JOIN agent_memory m ON m.rowid=f.rowid \
                 WHERE agent_memory_fts MATCH ?1 ORDER BY bm25(agent_memory_fts) LIMIT ?2",
            ) {
                if let Ok(rows) = stmt.query_map(params![match_query, limit as i64], |row| {
                    Ok(AgentMemory {
                        id: row.get(0)?,
                        text: row.get(1)?,
                        created_at: row.get(2)?,
                        last_used_at: row.get(3)?,
                        hits: row.get(4)?,
                    })
                }) {
                    found = rows.filter_map(Result::ok).collect();
                }
            }
        }
        if found.is_empty() {
            let pattern = format!("%{}%", trimmed.replace('%', "\\%").replace('_', "\\_"));
            let mut stmt = conn
                .prepare(
                    "SELECT id,text,created_at,last_used_at,hits FROM agent_memory \
                     WHERE text LIKE ?1 ESCAPE '\\' ORDER BY last_used_at DESC LIMIT ?2",
                )
                .map_err(sql_error)?;
            found = stmt
                .query_map(params![pattern, limit as i64], |row| {
                    Ok(AgentMemory {
                        id: row.get(0)?,
                        text: row.get(1)?,
                        created_at: row.get(2)?,
                        last_used_at: row.get(3)?,
                        hits: row.get(4)?,
                    })
                })
                .map_err(sql_error)?
                .filter_map(Result::ok)
                .collect();
        }
        if found.is_empty() {
            found = self.memories()?.into_iter().take(limit).collect();
        }
        Ok(found)
    }

    /// Adds (or bumps) one memory. Text is normalized and capped at 500 chars.
    pub fn add_memory(&self, text: &str) -> Result<AgentMemory, Error> {
        let normalized = normalize_memory(text);
        if normalized.is_empty() {
            return Err(Error::InvalidArgument(
                "CORE_E_AGENT_MEMORY_EMPTY: memory text must not be empty".to_string(),
            ));
        }
        let now = now_ms();
        let conn = self.db.writer().map_err(db_error)?;
        if let Some(existing) = conn
            .query_row(
                "SELECT id,text,created_at,last_used_at,hits FROM agent_memory WHERE text=?1",
                [&normalized],
                |row| {
                    Ok(AgentMemory {
                        id: row.get(0)?,
                        text: row.get(1)?,
                        created_at: row.get(2)?,
                        last_used_at: row.get(3)?,
                        hits: row.get(4)?,
                    })
                },
            )
            .optional()
            .map_err(sql_error)?
        {
            conn.execute(
                "UPDATE agent_memory SET hits=hits+1, last_used_at=?1 WHERE id=?2",
                params![now, existing.id],
            )
            .map_err(sql_error)?;
            return Ok(AgentMemory {
                last_used_at: now,
                hits: existing.hits + 1,
                ..existing
            });
        }
        let id = format!(
            "mem-{now}-{}",
            NEXT_MEMORY.fetch_add(1, Ordering::Relaxed)
        );
        conn.execute(
            "INSERT INTO agent_memory(id,text,created_at,last_used_at,hits) \
             VALUES (?1,?2,?3,?3,1)",
            params![id, normalized, now],
        )
        .map_err(sql_error)?;
        Ok(AgentMemory {
            id,
            text: normalized,
            created_at: now,
            last_used_at: now,
            hits: 1,
        })
    }

    /// Removes by exact id or text substring; returns removed count.
    pub fn remove_memory(&self, id_or_text: &str) -> Result<usize, Error> {
        let key = id_or_text.trim();
        if key.is_empty() {
            return Ok(0);
        }
        let conn = self.db.writer().map_err(db_error)?;
        let pattern = format!("%{}%", key.replace('%', "\\%").replace('_', "\\_"));
        conn.execute(
            "DELETE FROM agent_memory WHERE id=?1 OR text LIKE ?2 ESCAPE '\\'",
            params![key, pattern],
        )
        .map_err(sql_error)
    }

    pub fn clear_memories(&self) -> Result<(), Error> {
        let conn = self.db.writer().map_err(db_error)?;
        conn.execute("DELETE FROM agent_memory", []).map_err(sql_error)?;
        Ok(())
    }

    /// Replaces all memories (legacy SharedPreferences import).
    pub fn replace_memories(&self, memories: &[AgentMemory]) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute("DELETE FROM agent_memory", []).map_err(sql_error)?;
        for memory in memories {
            tx.execute(
                "INSERT INTO agent_memory(id,text,created_at,last_used_at,hits) \
                 VALUES (?1,?2,?3,?4,?5)",
                params![
                    memory.id,
                    memory.text,
                    memory.created_at,
                    memory.last_used_at,
                    memory.hits
                ],
            )
            .map_err(sql_error)?;
        }
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    // ---------------------------------------------------------------------
    // Turn traces (P3-1)
    // ---------------------------------------------------------------------

    /// Inserts or replaces one turn trace (same `turn_id` upserts).
    pub fn insert_trace(&self, trace: &AgentTrace) -> Result<(), Error> {
        let conn = self.db.writer().map_err(db_error)?;
        conn.execute(
            "INSERT INTO agent_trace(turn_id,session_id,created_at,status,provider,model,\
             tools_enabled,prompt_chars,message_count,tools_offered,model_steps,tool_requests,\
             tool_responses,tool_errors,first_token_ms,total_ms,response_chars,reasoning_chars,\
             input_tokens,output_tokens,finish_reason,error,detail) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) \
             ON CONFLICT(turn_id) DO UPDATE SET \
                 session_id=excluded.session_id, created_at=excluded.created_at, \
                 status=excluded.status, provider=excluded.provider, model=excluded.model, \
                 tools_enabled=excluded.tools_enabled, prompt_chars=excluded.prompt_chars, \
                 message_count=excluded.message_count, tools_offered=excluded.tools_offered, \
                 model_steps=excluded.model_steps, tool_requests=excluded.tool_requests, \
                 tool_responses=excluded.tool_responses, tool_errors=excluded.tool_errors, \
                 first_token_ms=excluded.first_token_ms, total_ms=excluded.total_ms, \
                 response_chars=excluded.response_chars, reasoning_chars=excluded.reasoning_chars, \
                 input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens, \
                 finish_reason=excluded.finish_reason, error=excluded.error, detail=excluded.detail",
            params![
                trace.turn_id,
                trace.session_id,
                trace.created_at,
                trace.status,
                trace.provider,
                trace.model,
                i64::from(trace.tools_enabled),
                trace.prompt_chars,
                trace.message_count,
                trace.tools_offered,
                trace.model_steps,
                trace.tool_requests,
                trace.tool_responses,
                trace.tool_errors,
                trace.first_token_ms,
                trace.total_ms,
                trace.response_chars,
                trace.reasoning_chars,
                trace.input_tokens,
                trace.output_tokens,
                trace.finish_reason,
                trace.error,
                trace.detail,
            ],
        )
        .map_err(sql_error)?;
        Ok(())
    }

    /// Newest traces first (capped at `limit`).
    pub fn traces(&self, limit: i64) -> Result<Vec<AgentTrace>, Error> {
        let limit = limit.clamp(1, 1000);
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(
                "SELECT turn_id,session_id,created_at,status,provider,model,tools_enabled,\
                 prompt_chars,message_count,tools_offered,model_steps,tool_requests,\
                 tool_responses,tool_errors,first_token_ms,total_ms,response_chars,\
                 reasoning_chars,input_tokens,output_tokens,finish_reason,error,detail \
                 FROM agent_trace ORDER BY created_at DESC, turn_id DESC LIMIT ?1",
            )
            .map_err(sql_error)?;
        let rows = stmt
            .query_map([limit], |row| {
                Ok(AgentTrace {
                    turn_id: row.get(0)?,
                    session_id: row.get(1)?,
                    created_at: row.get(2)?,
                    status: row.get(3)?,
                    provider: row.get(4)?,
                    model: row.get(5)?,
                    tools_enabled: row.get::<_, i64>(6)? != 0,
                    prompt_chars: row.get(7)?,
                    message_count: row.get(8)?,
                    tools_offered: row.get(9)?,
                    model_steps: row.get(10)?,
                    tool_requests: row.get(11)?,
                    tool_responses: row.get(12)?,
                    tool_errors: row.get(13)?,
                    first_token_ms: row.get(14)?,
                    total_ms: row.get(15)?,
                    response_chars: row.get(16)?,
                    reasoning_chars: row.get(17)?,
                    input_tokens: row.get(18)?,
                    output_tokens: row.get(19)?,
                    finish_reason: row.get(20)?,
                    error: row.get(21)?,
                    detail: row.get(22)?,
                })
            })
            .map_err(sql_error)?;
        rows.collect::<Result<_, _>>().map_err(sql_error)
    }

    /// Keeps only the newest `keep` traces; returns how many rows were removed.
    pub fn prune_traces(&self, keep: i64) -> Result<usize, Error> {
        let keep = keep.clamp(0, 100_000);
        let conn = self.db.writer().map_err(db_error)?;
        let removed = conn
            .execute(
                "DELETE FROM agent_trace WHERE turn_id NOT IN (\
                     SELECT turn_id FROM agent_trace \
                     ORDER BY created_at DESC, turn_id DESC LIMIT ?1)",
                [keep],
            )
            .map_err(sql_error)?;
        Ok(removed)
    }

    pub fn clear_traces(&self) -> Result<(), Error> {
        let conn = self.db.writer().map_err(db_error)?;
        conn.execute("DELETE FROM agent_trace", []).map_err(sql_error)?;
        Ok(())
    }
}

fn insert_session(tx: &rusqlite::Transaction<'_>, session: &AgentSession) -> Result<(), Error> {
    tx.execute(
        "INSERT INTO agent_session(id,title,created_at,updated_at) VALUES (?1,?2,?3,?4)",
        params![session.id, session.title, session.created_at, session.updated_at],
    )
    .map_err(sql_error)?;
    for (index, message) in session.messages.iter().enumerate() {
        // Legacy data may carry duplicate/missing seq values; list order is the
        // authoritative display order, so normalize the DB key to the index.
        insert_message(tx, &session.id, index as i64, message)?;
    }
    Ok(())
}

fn insert_message(
    tx: &rusqlite::Transaction<'_>,
    session_id: &str,
    seq: i64,
    message: &AgentMessage,
) -> Result<(), Error> {
    let confirm_options = message
        .confirm_options
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .map_err(|error| Error::Serialization(error.to_string()))?;
    tx.execute(
        "INSERT INTO agent_message(session_id,seq,time,is_user,text,reasoning,is_tool_result,\
         tool_type,tool_status,tool_detail,tool_name,tool_args,tool_result,turn_id,\
         confirm_options,confirm_multi_select) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
        params![
            session_id,
            seq,
            message.time,
            i64::from(message.is_user),
            message.text,
            message.reasoning,
            i64::from(message.is_tool_result),
            message.tool_type,
            message.tool_status,
            message.tool_detail,
            message.tool_name,
            message.tool_args,
            message.tool_result,
            message.turn_id,
            confirm_options,
            i64::from(message.confirm_multi_select),
        ],
    )
    .map_err(sql_error)?;
    Ok(())
}

fn normalize_memory(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out = collapsed.trim().to_string();
    if out.chars().count() > 500 {
        out = out.chars().take(500).collect();
    }
    out
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn db_error(error: DbError) -> Error {
    Error::Internal(format!("CORE_E_AGENT_DB: {error}"))
}

fn sql_error(error: rusqlite::Error) -> Error {
    Error::Internal(format!("CORE_E_AGENT_DB: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let id = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gstore_agent_store_{}_{}",
                std::process::id(),
                id
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn store() -> (TempDir, AgentStore) {
        let dir = TempDir::new();
        let db = DbHandle::open(&dir.0).unwrap();
        (dir, AgentStore::new(db))
    }

    fn session(id: &str) -> AgentSession {
        AgentSession {
            id: id.to_string(),
            title: "测试会话".to_string(),
            created_at: 1000,
            updated_at: 2000,
            messages: vec![
                AgentMessage {
                    seq: 0,
                    time: 1000,
                    is_user: true,
                    text: "你好".to_string(),
                    is_tool_result: false,
                    tool_type: None,
                    tool_status: None,
                    tool_detail: None,
                    tool_name: None,
                    tool_args: None,
                    tool_result: None,
                    turn_id: Some("t1".to_string()),
                    confirm_options: None,
                    confirm_multi_select: false,
                    reasoning: None,
                },
                AgentMessage {
                    seq: 1,
                    time: 1001,
                    is_user: false,
                    text: "确认卸载？".to_string(),
                    is_tool_result: true,
                    tool_type: Some("confirm".to_string()),
                    tool_status: Some("running".to_string()),
                    tool_detail: Some("确认卸载".to_string()),
                    tool_name: Some("confirmAction".to_string()),
                    tool_args: Some("{\"question\":\"确认?\"}".to_string()),
                    tool_result: None,
                    turn_id: Some("t1".to_string()),
                    confirm_options: Some(vec!["确认".to_string(), "取消".to_string()]),
                    confirm_multi_select: true,
                    reasoning: Some("需要确认".to_string()),
                },
            ],
        }
    }

    #[test]
    fn sessions_roundtrip_and_delete() {
        let (_dir, store) = store();
        let s = session("session-1");
        store.upsert_session(&s).unwrap();
        let loaded = store.sessions().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].messages.len(), 2);
        assert_eq!(
            loaded[0].messages[1].confirm_options.as_deref(),
            Some(["确认".to_string(), "取消".to_string()].as_slice())
        );
        assert!(loaded[0].messages[1].confirm_multi_select);

        store.delete_session("session-1").unwrap();
        assert!(store.sessions().unwrap().is_empty());
    }

    #[test]
    fn replace_sessions_is_atomic_bulk_path() {
        let (_dir, store) = store();
        store
            .replace_sessions(&[session("a"), session("b")])
            .unwrap();
        assert_eq!(store.sessions().unwrap().len(), 2);
        store.replace_sessions(&[session("c")]).unwrap();
        let loaded = store.sessions().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "c");
    }

    #[test]
    fn legacy_duplicate_seq_is_normalized_to_list_order() {
        let (_dir, store) = store();
        let mut legacy = session("legacy");
        legacy.messages[0].seq = 0;
        legacy.messages[1].seq = 0;
        store.upsert_session(&legacy).unwrap();
        let loaded = store.sessions().unwrap();
        let seqs: Vec<i64> = loaded[0].messages.iter().map(|m| m.seq).collect();
        assert_eq!(seqs, vec![0, 1], "duplicate legacy seq must not collide");
        assert_eq!(loaded[0].messages[1].text, "确认卸载？");
    }

    #[test]
    fn memory_add_dedupe_search_and_remove() {
        let (_dir, store) = store();
        store.add_memory("用户偏好使用 F-Droid 渠道").unwrap();
        let bumped = store.add_memory("用户偏好使用 F-Droid 渠道").unwrap();
        assert_eq!(bumped.hits, 2);
        store.add_memory("用户喜欢深色主题").unwrap();
        store.add_memory("下载保存到 /sdcard/Download").unwrap();

        // 3+ 字符走 FTS5 trigram
        let fts = store.search_memories("F-Droid", 10).unwrap();
        assert_eq!(fts[0].text, "用户偏好使用 F-Droid 渠道");
        // 2 字符走 LIKE
        let like = store.search_memories("主题", 10).unwrap();
        assert_eq!(like[0].text, "用户喜欢深色主题");
        // 无命中回退最近
        let fallback = store.search_memories("zzznotexist", 10).unwrap();
        assert_eq!(fallback.len(), 3);

        let removed = store.remove_memory("F-Droid").unwrap();
        assert_eq!(removed, 1);
        assert!(!store
            .memories()
            .unwrap()
            .iter()
            .any(|m| m.text.contains("F-Droid")));
    }

    #[test]
    fn memory_normalize_cap_and_empty_rejection() {
        let (_dir, store) = store();
        assert!(store.add_memory("   ").is_err());
        let long = "a".repeat(800);
        let memory = store.add_memory(&long).unwrap();
        assert_eq!(memory.text.chars().count(), 500);
    }

    fn trace(turn_id: &str, created_at: i64, status: &str) -> AgentTrace {
        AgentTrace {
            turn_id: turn_id.to_string(),
            session_id: Some("s1".to_string()),
            created_at,
            status: status.to_string(),
            provider: Some("openai".to_string()),
            model: Some("hy4".to_string()),
            tools_enabled: true,
            prompt_chars: 1234,
            message_count: 7,
            tools_offered: 16,
            model_steps: 2,
            tool_requests: 1,
            tool_responses: 1,
            tool_errors: 0,
            first_token_ms: Some(2400),
            total_ms: 6000,
            response_chars: 21,
            reasoning_chars: 121,
            input_tokens: Some(6341),
            output_tokens: Some(62),
            finish_reason: Some("stop".to_string()),
            error: None,
            detail: Some("{\"steps\":2}".to_string()),
        }
    }

    #[test]
    fn traces_insert_roundtrip_and_order() {
        let (_dir, store) = store();
        store.insert_trace(&trace("t1", 100, "ok")).unwrap();
        store.insert_trace(&trace("t2", 200, "error")).unwrap();

        let traces = store.traces(10).unwrap();
        assert_eq!(
            traces.iter().map(|t| t.turn_id.as_str()).collect::<Vec<_>>(),
            vec!["t2", "t1"],
            "newest first"
        );
        let first = &traces[0];
        assert_eq!(first.status, "error");
        assert_eq!(first.model.as_deref(), Some("hy4"));
        assert_eq!(first.first_token_ms, Some(2400));
        assert_eq!(first.total_ms, 6000);
        assert_eq!(first.detail.as_deref(), Some("{\"steps\":2}"));

        // Same turn id upserts instead of duplicating
        let mut updated = trace("t1", 300, "cancelled");
        updated.total_ms = 42;
        store.insert_trace(&updated).unwrap();
        let traces = store.traces(10).unwrap();
        assert_eq!(traces.len(), 2);
        let t1 = traces.iter().find(|t| t.turn_id == "t1").unwrap();
        assert_eq!(t1.status, "cancelled");
        assert_eq!(t1.total_ms, 42);
    }

    #[test]
    fn traces_prune_keeps_newest_and_clear_empties() {
        let (_dir, store) = store();
        for i in 0..5 {
            store
                .insert_trace(&trace(&format!("t{i}"), i as i64, "ok"))
                .unwrap();
        }
        let removed = store.prune_traces(2).unwrap();
        assert_eq!(removed, 3);
        let remaining = store.traces(10).unwrap();
        assert_eq!(
            remaining.iter().map(|t| t.turn_id.as_str()).collect::<Vec<_>>(),
            vec!["t4", "t3"]
        );

        store.clear_traces().unwrap();
        assert!(store.traces(10).unwrap().is_empty());
        // prune with keep=0 removes everything
        store.insert_trace(&trace("t9", 9, "ok")).unwrap();
        assert_eq!(store.prune_traces(0).unwrap(), 1);
    }

    #[test]
    fn meta_read_write_and_delete() {
        let (_dir, store) = store();
        assert_eq!(store.read_meta("session_summary:s1").unwrap(), None);
        store
            .write_meta("session_summary:s1", Some("用户问过 F-Droid"))
            .unwrap();
        assert_eq!(
            store.read_meta("session_summary:s1").unwrap().as_deref(),
            Some("用户问过 F-Droid")
        );
        store.write_meta("session_summary:s1", None).unwrap();
        assert_eq!(store.read_meta("session_summary:s1").unwrap(), None);
    }
}
