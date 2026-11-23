-- Agent sessions, long-term memory, and FTS5 memory index.
--
-- Owned by the Rust core: the Dart agent stores become thin facades over
-- `AgentStoreApi`. `agent_memory_fts` uses the trigram tokenizer so Chinese
-- substring queries can use MATCH; short queries (<3 chars) fall back to LIKE.

CREATE TABLE IF NOT EXISTS agent_session(
    id TEXT NOT NULL PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '新对话',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_agent_session_updated
    ON agent_session(updated_at DESC);

CREATE TABLE IF NOT EXISTS agent_message(
    session_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    time INTEGER NOT NULL,
    is_user INTEGER NOT NULL DEFAULT 0 CHECK(is_user IN (0,1)),
    text TEXT NOT NULL DEFAULT '',
    reasoning TEXT,
    is_tool_result INTEGER NOT NULL DEFAULT 0 CHECK(is_tool_result IN (0,1)),
    tool_type TEXT,
    tool_status TEXT,
    tool_detail TEXT,
    tool_name TEXT,
    tool_args TEXT,
    tool_result TEXT,
    turn_id TEXT,
    confirm_options TEXT,
    confirm_multi_select INTEGER NOT NULL DEFAULT 0 CHECK(confirm_multi_select IN (0,1)),
    PRIMARY KEY(session_id, seq)
);

CREATE INDEX IF NOT EXISTS ix_agent_message_session_time
    ON agent_message(session_id, time);

CREATE TABLE IF NOT EXISTS agent_meta(
    k TEXT NOT NULL PRIMARY KEY,
    v TEXT
);

CREATE TABLE IF NOT EXISTS agent_memory(
    id TEXT NOT NULL PRIMARY KEY,
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    hits INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS ix_agent_memory_last_used
    ON agent_memory(last_used_at DESC);

CREATE VIRTUAL TABLE IF NOT EXISTS agent_memory_fts USING fts5(
    text,
    content='agent_memory',
    content_rowid='rowid',
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS agent_memory_ai AFTER INSERT ON agent_memory BEGIN
    INSERT INTO agent_memory_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TRIGGER IF NOT EXISTS agent_memory_ad AFTER DELETE ON agent_memory BEGIN
    INSERT INTO agent_memory_fts(agent_memory_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
END;

CREATE TRIGGER IF NOT EXISTS agent_memory_au AFTER UPDATE ON agent_memory BEGIN
    INSERT INTO agent_memory_fts(agent_memory_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
    INSERT INTO agent_memory_fts(rowid, text) VALUES (new.rowid, new.text);
END;
