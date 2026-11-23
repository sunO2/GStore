-- Agent turn traces (P3-1 observability).
--
-- One row per `chat()` turn (or background continuation turn). The wide columns
-- are the fields the UI/evals filter on; `detail` keeps the full
-- `AgentTurnTrace.toJson()` payload (tool call list, error text, raw probe) so a
-- future replay/debug view can read everything without a schema change.
--
-- Rows are pruned by count (`prune_traces(keep)`) on startup, so the table stays
-- small even on long-lived installs.

CREATE TABLE IF NOT EXISTS agent_trace(
    turn_id TEXT NOT NULL PRIMARY KEY,
    session_id TEXT,
    created_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'ok',
    provider TEXT,
    model TEXT,
    tools_enabled INTEGER NOT NULL DEFAULT 1 CHECK(tools_enabled IN (0,1)),
    prompt_chars INTEGER NOT NULL DEFAULT 0,
    message_count INTEGER NOT NULL DEFAULT 0,
    tools_offered INTEGER NOT NULL DEFAULT 0,
    model_steps INTEGER NOT NULL DEFAULT 0,
    tool_requests INTEGER NOT NULL DEFAULT 0,
    tool_responses INTEGER NOT NULL DEFAULT 0,
    tool_errors INTEGER NOT NULL DEFAULT 0,
    first_token_ms INTEGER,
    total_ms INTEGER NOT NULL DEFAULT 0,
    response_chars INTEGER NOT NULL DEFAULT 0,
    reasoning_chars INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER,
    output_tokens INTEGER,
    finish_reason TEXT,
    error TEXT,
    detail TEXT
);

CREATE INDEX IF NOT EXISTS ix_agent_trace_created
    ON agent_trace(created_at DESC);
