#!/usr/bin/env bash
# Deterministic assertion for docs/config-architecture.md (plan Todo 33 / C20).
#
# It derives the expected configuration keys from the committed Rust registry
# (rust/gstore_core/src/config/schema.rs) and requires every one of them to
# appear as a row inside the document's key table. It also requires the storage
# schema, change payload, ABI v5 contract, upgrade-migration flow, backup
# export/restore flow, and secret-handling sections.
#
# The document path can be overridden for mutation testing:
#   CONFIG_DOC_PATH=/tmp/doc-copy.md bash scripts/tests/config_docs_assert.sh
# The schema path can be overridden too:
#   CONFIG_SCHEMA_PATH=/tmp/schema-copy.rs bash scripts/tests/config_docs_assert.sh
#
# Exit 0 = every assertion passed; non-zero = a key row or required flow/section
# is missing (or the registry could not be parsed).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="${CONFIG_DOC_PATH:-$REPO_ROOT/docs/config-architecture.md}"
SCHEMA="${CONFIG_SCHEMA_PATH:-$REPO_ROOT/rust/gstore_core/src/config/schema.rs}"

python3 - "$SCHEMA" "$DOC" <<'PY'
import re
import sys

schema_path, doc_path = sys.argv[1], sys.argv[2]
FAIL = False


def fail(message: str) -> None:
    global FAIL
    FAIL = True
    print(f"[config_docs_assert] FAIL: {message}", file=sys.stderr)


try:
    schema = open(schema_path, encoding="utf-8").read()
except OSError as exc:
    fail(f"cannot read schema {schema_path}: {exc}")
    sys.exit(1)

try:
    doc = open(doc_path, encoding="utf-8").read()
except OSError as exc:
    fail(f"cannot read document {doc_path}: {exc}")
    sys.exit(1)

# ---- derive expected rows from the committed registry --------------------
# Restrict parsing to the registry builder so test-only EntrySpec fixtures can
# never inflate the expected set.
registry = schema
start = schema.find("fn build_registry()")
if start != -1:
    registry = schema[start:]
    stop = registry.find("registry.sort_by")
    if stop != -1:
        registry = registry[:stop]

ENTRY_RE = re.compile(
    r'EntrySpec::new\("([a-z0-9_-]+)",\s*"([^"]+)",\s*ConfigValueType::(\w+)\)'
    r"(.*?)(?=\n\s*EntrySpec::new\(|\n\s*module_toggle\(|$)",
    re.S,
)

expected = {}
for match in ENTRY_RE.finditer(registry):
    module, key, value_type, body = match.groups()
    wire = f"{module}.{key}"
    if ".secret()" in body:
        visibility = "Secret"
    elif ".public_read()" in body:
        visibility = "PublicRead"
    else:
        visibility = "Owner"
    sensitive = "yes" if (".sensitive()" in body or visibility == "Secret") else "no"
    expected[wire] = (module, value_type, visibility, sensitive)

# module_toggle("<name>", ...) expands to module.<name>.enabled. The call may
# be wrapped across lines, so allow arbitrary whitespace after the paren.
for name in re.findall(r'module_toggle\(\s*"([a-z0-9_-]+)"', registry):
    expected[f"module.{name}.enabled"] = ("module", "Bool", "Owner", "no")

if len(expected) < 40:
    fail(
        f"parsed only {len(expected)} registry rows from {schema_path}; "
        "schema parsing is broken (expected >= 40)"
    )
    sys.exit(1)

expected_keys = set(expected)
expected_modules = sorted({row[0] for row in expected.values()})
print(f"[config_docs_assert] registry rows parsed: {len(expected_keys)} "
      f"across {len(expected_modules)} modules")

# ---- parse the document key table (heading + columns) --------------------
BEGIN = "<!-- BEGIN config-key-table -->"
END = "<!-- END config-key-table -->"
_, sep, rest = doc.partition(BEGIN)
after, sep2, _ = rest.partition(END)
if not sep or not sep2:
    fail(f"key-table markers missing ({BEGIN} / {END}): {doc_path}")
    table = ""
else:
    table = after

HEADING_RE = re.compile(r"^### `([a-z0-9_-]+)` \((\d+) keys\)$")
ROW_RE = re.compile(
    r"^\|\s*`([a-z0-9_.-]+)`\s*\|\s*([A-Za-z]+)\s*\|"
    r"\s*([A-Za-z_]+)\s*\|\s*(yes|no)\s*\|$"
)

doc_rows = {}
section_counts = {}
current_section = None
for line in table.splitlines():
    heading = HEADING_RE.match(line)
    if heading:
        current_section = heading.group(1)
        section_counts[current_section] = int(heading.group(2))
        continue
    row = ROW_RE.match(line)
    if row:
        key, value_type, visibility, sensitive = row.groups()
        doc_rows[key] = (current_section, value_type, visibility, sensitive)

table_keys = set(doc_rows)
missing = sorted(expected_keys - table_keys)
extra = sorted(table_keys - expected_keys)

print(f"[config_docs_assert] key table rows: {len(table_keys)}")
print(f"[config_docs_assert] keys matched: {len(expected_keys) - len(missing)}/{len(expected_keys)}")

for key in missing:
    fail(f"key row missing from table: {key}")
for key in extra:
    fail(f"table row is not in the committed registry (stale row): {key}")

# Module grouping must match the registry: same module sections and counts.
expected_counts = {}
for module, _, _, _ in expected.values():
    expected_counts[module] = expected_counts.get(module, 0) + 1
for module in sorted(set(expected_counts) | set(section_counts)):
    want = expected_counts.get(module)
    got = section_counts.get(module)
    if want != got:
        fail(f"module section `{module}` count mismatch: expected {want}, found {got}")

COLUMNS = ("module", "type", "visibility", "sensitive")
for key in sorted(expected_keys & table_keys):
    want = expected[key]
    got = doc_rows[key]
    for index, column in enumerate(COLUMNS):
        if want[index] != got[index]:
            fail(
                f"row column mismatch: {key} {column} "
                f"expected {want[index]!r}, found {got[index]!r}"
            )

# ---- required sections ---------------------------------------------------
sections = [
    ("authority/module key table", "## 1. 权威边界与模块/键表"),
    ("storage schema", "## 2. 存储 schema"),
    ("change event payload", "## 3. 变更事件与过滤投递"),
    ("ABI v5 contract", "## 4. ABI v5 契约"),
    ("secret handling", "## 5. 秘密处理契约"),
    ("migration/rollback", "## 6. 升级迁移与回滚"),
    ("backup format v2", "## 7. 备份格式 v2"),
    ("assertion/evidence", "## 8. 断言与证据"),
]
found_sections = []
for label, heading in sections:
    if heading in doc:
        found_sections.append(label)
    else:
        fail(f"required section missing: {label} ({heading})")

# ---- the two event flows -------------------------------------------------
FLOW_MIGRATION = "### 事件流 A：升级迁移（legacy → Rust）"
FLOW_BACKUP = "### 事件流 B：备份导出 / 恢复"


def flow_body(header):
    if header not in doc:
        return None
    tail = doc.split(header, 1)[1]
    following = re.search(r"^#{1,3} ", tail, re.M)
    return tail[: following.start()] if following else tail


flow_a = flow_body(FLOW_MIGRATION)
flow_b = flow_body(FLOW_BACKUP)

if flow_a is not None:
    print(f"[config_docs_assert] flow A header: FOUND  {FLOW_MIGRATION}")
else:
    fail(f"migration event flow removed: {FLOW_MIGRATION}")

if flow_b is not None:
    print(f"[config_docs_assert] flow B header: FOUND  {FLOW_BACKUP}")
else:
    fail(f"backup event flow removed: {FLOW_BACKUP}")

# ---- per-flow contract tokens (a token must live in its own flow) --------
flow_tokens = {
    "migration flow": (
        flow_a,
        [
            ("migration marker", "config.migrated.v1"),
            ("migration source", 'source = "migration"'),
            ("read-back verify", "ConfigApi.verify"),
            ("old keys retained", "旧键永不删除"),
            ("bulk import", "ConfigApi.import"),
        ],
    ),
    "backup flow": (
        flow_b,
        [
            ("config_format 2", "config_format: 2"),
            ("includeAppConfig gate", "includeAppConfig"),
            ("standalone app config", "app_config.json"),
            ("embedded app config", "apps.json.appConfig"),
            ("restore source", 'source = "restore"'),
            ("raw export", "ConfigApi.export"),
        ],
    ),
}
for flow_label, (body, tokens) in flow_tokens.items():
    if body is None:
        continue
    for label, token in tokens:
        if token not in body:
            fail(f"{flow_label} token missing: {label} ({token!r})")

# ---- global contract tokens (non-flow) -----------------------------------
required_tokens = [
    # storage schema
    ("config_entry table", "config_entry"),
    ("config_change_log table", "config_change_log"),
    ("config_meta table", "config_meta"),
    ("secret_ref column", "secret_ref"),
    ("secret_hash column", "secret_hash"),
    # event payload + filtered delivery
    ("payload oldValue", '"oldValue"'),
    ("payload revision", '"revision"'),
    ("payload source", '"source"'),
    ("filtered delivery", "PublicRead"),
    ("source list internal", "`internal`"),
    ("source list restore", "`restore`"),
    # ABI v5
    ("ABI version literal", "GSTORE_MODULE_ABI_VERSION = 5"),
    ("min_host_abi rule", "min_host_abi = 5"),
    ("config context", "GStoreConfigContextV1"),
    ("config capability", "CONFIG_CAP_GET"),
    # secret handling
    ("FileSecretStore", "FileSecretStore"),
    ("masking marker", "***"),
    ("trusted raw read", "getRaw"),
    # honesty about docs_assert.sh
    ("docs_assert does not cover this doc", "docs_assert.sh"),
    ("no-coverage statement", "不覆盖"),
]
for label, token in required_tokens:
    if token not in doc:
        fail(f"required token missing: {label} ({token!r})")

if "backup_restore" in doc:
    fail("stale non-canonical source token present: backup_restore")

# ---- manual-QA channel ---------------------------------------------------
print("[config_docs_assert] sections found: " + ", ".join(found_sections))
print(f"[config_docs_assert] document: {doc_path}")

if FAIL:
    print("[config_docs_assert] FAILED", file=sys.stderr)
    sys.exit(1)
print("[config_docs_assert] PASS")
PY
