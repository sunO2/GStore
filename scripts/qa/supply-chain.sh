#!/usr/bin/env bash
# Supply-chain gate for every Rust crate in the repository.
#
# Two independent tiers over every rust/*/Cargo.toml (11 crates; gstore_script
# has no crate-local lockfile, so it is audited against the rust/Cargo.toml
# workspace lock):
#
#   --tier=hard        cargo deny check licenses bans sources, per manifest.
#                      A finding is a hard FAIL; a missing tool is BLOCKED.
#
#   --tier=advisories  graph-aware cargo-deny advisories per manifest (quinn-proto
#                      is lockfile-only, so it never appears here) plus
#                      cargo audit --file on every lockfile.  Both outputs are
#                      diffed against rust/supply-chain-baseline.toml:
#                        [[finding]]    12 reachable findings -> BLOCKED
#                        [[suppressed]] 11 justified ignores  -> accepted
#                      The deny.toml ignore list is NOT passed to cargo audit;
#                      the JSON is diffed instead, so a RUSTSEC id in a comment
#                      can never become an ignore.  The script also asserts that
#                      deny.toml's ignore list and the baseline [[suppressed]]
#                      list are identical.
#
# Modes:
#   --mode=gate     1 on any non-baselined finding / baseline drift / new yanked
#                   crate / passed review_date; else 3 when findings are
#                   baselined; 0 only when there are zero advisory findings.
#   --mode=ratchet  0 when findings are a subset of the baseline and nothing is
#                   novel/drifted/overdue; 1 otherwise (never 3 for findings).
#   --mode=report   always 0; prints the full table (used by CI artefacts).
#
# Exit codes:
#   0  PASS (hard gate clean AND zero advisory findings; ratchet/report rules above)
#   1  FAIL (hard-gate finding, missing config/lockfile, novel advisory, baseline
#      drift, new yanked crate, passed review_date)
#   2  usage error
#   3  BLOCKED (tool/DB unavailable-or-errored, or findings are baselined)
#
# cargo-deny exit codes are a bitset of the failed checks
# (advisories=1, bans=2, licenses=4, sources=8).  On the hard tier a bitset
# containing bans/licenses/sources is a FAIL; a bare 1 is a tool/config error.
# cargo-audit: 0 clean, 1 findings, 2 error.
#
# Usage:
#   scripts/qa/supply-chain.sh [--tier=hard|advisories|all] [--mode=gate|ratchet|report]
#                              [--baseline FILE] [--deny-config FILE]
#                              [--log-dir DIR] [-v|--verbose] [-h|--help]
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

DENY_CONFIG="$REPO_ROOT/rust/deny.toml"
BASELINE="$REPO_ROOT/rust/supply-chain-baseline.toml"
LOG_DIR="$REPO_ROOT/rust/target/test-evidence/supply-chain-logs"
TIER="all"
MODE="gate"
VERBOSE=0

usage() {
  sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier=*) TIER="${1#*=}"; shift ;;
    --tier) TIER="${2:-}"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --baseline=*) BASELINE="${1#*=}"; shift ;;
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --deny-config=*) DENY_CONFIG="${1#*=}"; shift ;;
    --deny-config) DENY_CONFIG="${2:-}"; shift 2 ;;
    --log-dir=*) LOG_DIR="${1#*=}"; shift ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TIER" in hard|advisories|all) ;; *) echo "ERROR: --tier must be hard|advisories|all" >&2; exit 2 ;; esac
case "$MODE" in gate|ratchet|report) ;; *) echo "ERROR: --mode must be gate|ratchet|report" >&2; exit 2 ;; esac

mkdir -p "$LOG_DIR"
ART_DIR="$LOG_DIR/artifacts"
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"

HAVE_DENY=0
HAVE_AUDIT=0
command -v cargo-deny >/dev/null 2>&1 && HAVE_DENY=1
command -v cargo-audit >/dev/null 2>&1 && HAVE_AUDIT=1

echo "== supply-chain =="
echo "repo:        $REPO_ROOT"
echo "deny config: $DENY_CONFIG"
echo "baseline:    $BASELINE"
echo "tier:        $TIER"
echo "mode:        $MODE"
if [ "$HAVE_DENY" -eq 1 ]; then
  echo "cargo-deny:  $(cargo-deny --version 2>/dev/null | head -1)"
else
  echo "cargo-deny:  MISSING (not found in PATH)"
fi
if [ "$HAVE_AUDIT" -eq 1 ]; then
  echo "cargo-audit: $(cargo-audit --version 2>/dev/null | head -1)"
else
  echo "cargo-audit: MISSING (not found in PATH)"
fi
echo

CRATES=()
for manifest in "$REPO_ROOT"/rust/*/Cargo.toml; do
  [ -f "$manifest" ] || continue
  CRATES+=("$(basename "$(dirname "$manifest")")")
done

tail_log() {
  if [ "$VERBOSE" -eq 1 ]; then
    sed -n '1,200p' "$1"
  else
    tail -n 15 "$1"
  fi
}

# ---------------------------------------------------------------------------
# Hard tier: licenses / bans / sources.
# ---------------------------------------------------------------------------
HARD_RESULT="SKIP"
HARD_FAIL=0
HARD_BLOCKED=0

run_hard() {
  if [ ! -f "$DENY_CONFIG" ]; then
    echo "FAIL: deny config not found: $DENY_CONFIG" >&2
    HARD_RESULT="FAIL"
    HARD_FAIL=$((HARD_FAIL + 1))
    return
  fi
  if [ "$HAVE_DENY" -ne 1 ]; then
    echo "BLOCKED hard: cargo-deny not installed (a skipped check is never PASS)"
    HARD_RESULT="BLOCKED"
    HARD_BLOCKED=$((HARD_BLOCKED + 1))
    return
  fi

  echo "== tier: hard (cargo deny check licenses bans sources) =="
  for crate in "${CRATES[@]}"; do
    manifest="$REPO_ROOT/rust/$crate/Cargo.toml"
    log="$ART_DIR/hard-$crate.log"
    cargo deny --config "$DENY_CONFIG" --manifest-path "$manifest" \
      check licenses bans sources >"$log" 2>&1
    rc=$?
    # bits: advisories=1, bans=2, licenses=4, sources=8
    bits=$(( rc & 14 ))
    if [ "$rc" -eq 0 ]; then
      echo "PASS   hard  $crate"
    elif [ "$bits" -ne 0 ]; then
      echo "FAIL   hard  $crate (cargo-deny exit $rc, bits=$bits) — $log" >&2
      grep -E '^error\[' "$log" | head -5 >&2 || tail_log "$log" >&2
      HARD_FAIL=$((HARD_FAIL + 1))
    else
      echo "BLOCKED hard $crate (cargo-deny exit $rc = tool/config error) — $log" >&2
      tail_log "$log" >&2
      HARD_BLOCKED=$((HARD_BLOCKED + 1))
    fi
  done

  if [ "$HARD_FAIL" -gt 0 ]; then
    HARD_RESULT="FAIL"
  elif [ "$HARD_BLOCKED" -gt 0 ]; then
    HARD_RESULT="BLOCKED"
  else
    HARD_RESULT="PASS"
  fi
  echo "HARD: $HARD_RESULT (fail=$HARD_FAIL blocked=$HARD_BLOCKED)"
  echo
}

# ---------------------------------------------------------------------------
# Advisory tier: graph-aware deny advisories + per-lockfile cargo audit.
# ---------------------------------------------------------------------------
ADV_RESULT="SKIP"

run_advisories() {
  if [ ! -f "$BASELINE" ]; then
    echo "FAIL: advisory baseline not found: $BASELINE" >&2
    ADV_RESULT="FAIL"
    return
  fi
  if [ ! -f "$DENY_CONFIG" ]; then
    echo "FAIL: deny config not found: $DENY_CONFIG" >&2
    ADV_RESULT="FAIL"
    return
  fi

  local tool_errors=0

  # A scratch config with ignore = [] so cargo-deny reports every graph finding;
  # the diff against the baseline (not deny.toml) decides what is accepted.
  if ! python3 - "$DENY_CONFIG" "$ART_DIR/deny-advisories.toml" <<'PY'
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
matches = list(re.finditer(r"(?ms)^[ \t]*ignore[ \t]*=[ \t]*\[.*?^[ \t]*\]", text))
if len(matches) != 1:
    sys.exit(f"expected exactly one ignore array in {src}, found {len(matches)}")
start, end = matches[0].span()
open(dst, "w", encoding="utf-8").write(text[:start] + "ignore = []" + text[end:])
PY
  then
    echo "BLOCKED advisories: could not build the no-ignore cargo-deny config" >&2
    ADV_RESULT="BLOCKED"
    return
  fi
  ADVISORY_CONFIG="$ART_DIR/deny-advisories.toml"

  if [ "$HAVE_DENY" -ne 1 ]; then
    echo "BLOCKED advisories: cargo-deny not installed (a skipped check is never PASS)"
    tool_errors=$((tool_errors + 1))
  fi
  if [ "$HAVE_AUDIT" -ne 1 ]; then
    echo "BLOCKED advisories: cargo-audit not installed (a skipped check is never PASS)"
    tool_errors=$((tool_errors + 1))
  fi

  if [ "$tool_errors" -eq 0 ]; then
    echo "== tier: advisories (graph-aware deny + cargo audit, diffed vs baseline) =="
    for crate in "${CRATES[@]}"; do
      manifest="$REPO_ROOT/rust/$crate/Cargo.toml"
      lock="$REPO_ROOT/rust/$crate/Cargo.lock"
      if [ ! -f "$lock" ]; then
        lock="$REPO_ROOT/rust/Cargo.lock"
      fi
      if [ ! -f "$lock" ]; then
        echo "FAIL   advisories $crate: no Cargo.lock found" >&2
        tool_errors=$((tool_errors + 1))
        continue
      fi

      # cargo-deny: -f json + --audit-compatible-output emits one JSON document
      # per advisory database on stdout; findings still set the advisories bit (1).
      dlog="$ART_DIR/deny-$crate.log"
      cargo deny --config "$ADVISORY_CONFIG" --manifest-path "$manifest" \
        -f json check --audit-compatible-output advisories \
        >"$ART_DIR/deny-$crate.json" 2>"$dlog"
      drc=$?
      if [ "$drc" -ne 0 ] && [ "$drc" -ne 1 ]; then
        echo "BLOCKED advisories $crate: cargo-deny exit $drc (not a findings exit) — $dlog" >&2
        tail_log "$dlog" >&2
        rm -f "$ART_DIR/deny-$crate.json"
        tool_errors=$((tool_errors + 1))
      fi

      # cargo-audit: 0 clean, 1 findings, 2 error/DB unavailable.
      alog="$ART_DIR/audit-$crate.log"
      cargo audit --file "$lock" --json \
        >"$ART_DIR/audit-$crate.json" 2>"$alog"
      arc=$?
      if [ "$arc" -ne 0 ] && [ "$arc" -ne 1 ]; then
        echo "BLOCKED advisories $crate: cargo-audit exit $arc (DB/IO error) — $alog" >&2
        tail_log "$alog" >&2
        rm -f "$ART_DIR/audit-$crate.json"
        tool_errors=$((tool_errors + 1))
      fi
    done
    echo
  fi

  if [ "$tool_errors" -gt 0 ]; then
    echo "BLOCKED: $tool_errors tool/DB error(s); advisory analysis is incomplete and is NOT a PASS"
    ADV_RESULT="BLOCKED"
    return
  fi

  local verdict_file="$ART_DIR/verdict.env"
  if ! python3 - "$BASELINE" "$DENY_CONFIG" "$ART_DIR" "$verdict_file" <<'PY'
import glob
import json
import os
import re
import sys
from datetime import date

try:
    import tomllib as toml
except ImportError:  # Python < 3.11 (local dev boxes); CI ships 3.12
    import tomli as toml

baseline_path, deny_path, art_dir, verdict_path = sys.argv[1:5]
baseline = toml.load(open(baseline_path, "rb"))
findings = {e["id"]: e for e in baseline.get("finding", [])}
suppressed = {e["id"]: e for e in baseline.get("suppressed", [])}


def parse_deny_ignore(text):
    """Only the [advisories].ignore array; comments are stripped first, so a
    RUSTSEC id mentioned in prose can never become an ignore."""
    in_advisories = False
    in_ignore = False
    ids = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0]
        if not in_advisories:
            if re.match(r"^\s*\[advisories\]\s*$", line):
                in_advisories = True
            continue
        if re.match(r"^\s*\[", line):
            break
        if not in_ignore:
            m = re.match(r"^\s*ignore\s*=\s*\[(.*)$", line)
            if not m:
                continue
            in_ignore = True
            line = m.group(1)
        ids.extend(re.findall(r'"([^"]+)"', line))
        if "]" in line:
            in_ignore = False
    return ids


config_drift = []
try:
    deny_ids = sorted(set(parse_deny_ignore(open(deny_path, encoding="utf-8").read())))
except OSError as exc:
    deny_ids = []
    config_drift.append(f"cannot read {deny_path}: {exc}")
baseline_ids = sorted(suppressed)
if deny_ids != baseline_ids:
    config_drift.append(
        "deny.toml [advisories].ignore != baseline [[suppressed]]: "
        f"only-in-deny={sorted(set(deny_ids) - set(baseline_ids))} "
        f"only-in-baseline={sorted(set(baseline_ids) - set(deny_ids))}"
    )

observed = {}       # id -> set("manifest-crate@dependency-version")
dep_name = {}       # id -> dependency package name
dep_versions = {}   # id -> set(dependency version)
yanked = {}         # "dependency@version" -> set(manifest crate)
db_commit = "unknown"
db_updated = "unknown"


def add(manifest, dep, version, advisory_id):
    observed.setdefault(advisory_id, set()).add(f"{manifest}@{version}")
    dep_name.setdefault(advisory_id, dep)
    dep_versions.setdefault(advisory_id, set()).add(version)


for path in sorted(glob.glob(os.path.join(art_dir, "deny-*.json"))):
    manifest = os.path.basename(path)[len("deny-"):-len(".json")]
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    docs = doc if isinstance(doc, list) else [doc]
    for d in docs:
        for item in d.get("vulnerabilities") or []:
            adv = item.get("advisory") or {}
            pkg = item.get("package") or {}
            if adv.get("id") and pkg.get("name"):
                add(manifest, pkg["name"], pkg.get("version", "?"), adv["id"])
        for kind, arr in (d.get("warnings") or {}).items():
            if kind == "yanked":
                continue  # audit-compatible JSON drops yanked; cargo audit reports it
            for w in arr or []:
                adv = w.get("advisory") or {}
                pkg = w.get("package") or {}
                if adv.get("id") and pkg.get("name"):
                    add(manifest, pkg["name"], pkg.get("version", "?"), adv["id"])

for path in sorted(glob.glob(os.path.join(art_dir, "audit-*.json"))):
    manifest = os.path.basename(path)[len("audit-"):-len(".json")]
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    database = doc.get("database") or {}
    if database.get("last-commit"):
        db_commit = database["last-commit"]
        db_updated = database.get("last-updated", db_updated)
    vulns = doc.get("vulnerabilities") or {}
    for item in vulns.get("list") or []:
        adv = item.get("advisory") or {}
        pkg = item.get("package") or {}
        if adv.get("id") and pkg.get("name"):
            add(manifest, pkg["name"], pkg.get("version", "?"), adv["id"])
    for kind, arr in (doc.get("warnings") or {}).items():
        for w in arr or []:
            pkg = w.get("package") or {}
            adv = w.get("advisory") or {}
            if not pkg.get("name"):
                continue
            ident = f"{pkg['name']}@{pkg.get('version', '?')}"
            if kind == "yanked" or not adv.get("id"):
                yanked.setdefault(ident, set()).add(manifest)
            else:
                add(manifest, pkg["name"], pkg.get("version", "?"), adv["id"])

today = date.today()
novelty = []
drift = []
overdue = []
baselined = {}
ignored_hits = {}

for advisory_id, manifests in sorted(observed.items()):
    entry = findings.get(advisory_id) or suppressed.get(advisory_id)
    expected = set(entry["applies_to"]) if entry else set()
    if entry and manifests == expected:
        if advisory_id in findings:
            baselined[advisory_id] = manifests
        else:
            ignored_hits[advisory_id] = manifests
    elif entry:
        drift.append(
            f"{advisory_id} ({entry['crate']}): observed {', '.join(sorted(manifests))} "
            f"!= baseline applies_to {', '.join(sorted(expected))}"
        )
    else:
        versions = ", ".join(sorted(dep_versions[advisory_id]))
        novelty.append(f"{advisory_id} ({dep_name[advisory_id]} {versions}): {', '.join(sorted(manifests))}")

for advisory_id, entry in findings.items():
    if advisory_id not in observed:
        drift.append(f"{advisory_id} ({entry['crate']}): baseline entry no longer observed (dependency patched?)")
for advisory_id, entry in suppressed.items():
    if advisory_id.startswith("RUSTSEC") and advisory_id not in observed:
        drift.append(f"{advisory_id} ({entry['crate']}): suppressed entry no longer observed (dependency patched?)")

yanked_expected = {i for i in suppressed if not i.startswith("RUSTSEC")}
new_yanked = sorted(set(yanked) - yanked_expected)
missing_yanked = sorted(yanked_expected - set(yanked))
for ident in new_yanked:
    novelty.append(f"YANKED {ident} is yanked on {', '.join(sorted(yanked[ident]))} and not in the baseline")
for ident in missing_yanked:
    drift.append(f"YANKED {ident}: baseline yanked entry no longer observed (lockfile updated?)")
for ident in sorted(set(yanked) & yanked_expected):
    expected = {a.rsplit("@", 1)[0] for a in suppressed[ident]["applies_to"]}
    if yanked[ident] != expected:
        drift.append(
            f"YANKED {ident}: observed on {', '.join(sorted(yanked[ident]))} "
            f"!= baseline applies_to {', '.join(sorted(expected))}"
        )

for entries in (findings, suppressed):
    for advisory_id, entry in entries.items():
        review = entry.get("review_date", "")
        try:
            review_day = date.fromisoformat(review)
        except ValueError:
            overdue.append(f"{advisory_id} ({entry['crate']}): invalid review_date {review!r}")
            continue
        if review_day < today:
            overdue.append(f"{advisory_id} ({entry['crate']}): review_date {review} has passed")

print("== advisory findings (cargo-deny graph + cargo-audit lockfiles) ==")
print(f"advisory DB: {db_commit} (updated {db_updated})")
if not observed:
    print("  (none)")
for advisory_id in sorted(observed):
    dep = dep_name[advisory_id]
    versions = ", ".join(sorted(dep_versions[advisory_id]))
    status = "BLOCKED (baseline)" if advisory_id in findings else (
        "ignored (suppressed)" if advisory_id in suppressed else "NEW"
    )
    print(f"  {advisory_id:18} {dep + ' ' + versions:32} {', '.join(sorted(observed[advisory_id])):48} {status}")
print()
print("== yanked ==")
if yanked:
    for ident in sorted(yanked):
        print(f"  {ident:24} on {', '.join(sorted(yanked[ident]))}")
else:
    print("  (none)")
print()

for label, items in (
    ("NOVELTY", novelty),
    ("DRIFT", drift),
    ("OVERDUE", overdue),
    ("CONFIG-DRIFT", config_drift),
):
    for item in items:
        print(f"{label}: {item}")

accepted = len(baselined)
print(
    f"FINDINGS: baselined={accepted} ignored={len(ignored_hits)} "
    f"yanked_ignored={len(set(yanked) & yanked_expected)} novelty={len(novelty)} "
    f"drift={len(drift)} overdue={len(overdue)} config_drift={len(config_drift)}"
)

with open(verdict_path, "w", encoding="utf-8") as fh:
    fh.write(f"BASELINED={accepted}\n")
    fh.write(f"IGNORED={len(ignored_hits)}\n")
    fh.write(f"NOVELTY={len(novelty)}\n")
    fh.write(f"DRIFT={len(drift)}\n")
    fh.write(f"OVERDUE={len(overdue)}\n")
    fh.write(f"CONFIG_DRIFT={len(config_drift)}\n")
    fh.write(f"NEW_YANKED={len(new_yanked)}\n")
    fh.write(f"DB_COMMIT={db_commit}\n")
    fh.write(f"DB_UPDATED={db_updated}\n")
PY
  then
    echo "BLOCKED advisories: baseline analysis failed" >&2
    ADV_RESULT="BLOCKED"
    return
  fi

  # shellcheck disable=SC1090
  . "$verdict_file"
  local problems=$(( ${NOVELTY:-0} + ${DRIFT:-0} + ${OVERDUE:-0} + ${CONFIG_DRIFT:-0} ))

  if [ "$problems" -gt 0 ]; then
    if [ "$MODE" = "report" ]; then
      echo "ADVISORIES: findings need attention (report mode exits 0)"
      ADV_RESULT="FAIL"
    elif [ "$MODE" = "ratchet" ]; then
      echo "RATCHET: FAIL ($problems novelty/drift/overdue item(s); baseline is stale)"
      ADV_RESULT="FAIL"
    else
      echo "FAIL: $problems advisory item(s) are not accepted by the baseline"
      ADV_RESULT="FAIL"
    fi
  elif [ "${BASELINED:-0}" -gt 0 ]; then
    if [ "$MODE" = "ratchet" ]; then
      echo "RATCHET: OK (${BASELINED} baselined findings, no novelty/drift/overdue)"
      ADV_RESULT="RATCHET_OK"
    else
      echo "BLOCKED: ${BASELINED} baselined advisory findings pending refresh"
      ADV_RESULT="BLOCKED"
    fi
  else
    echo "ADVISORIES: clean (0 findings)"
    ADV_RESULT="PASS"
  fi
  echo
}

if [ "$TIER" = "hard" ] || [ "$TIER" = "all" ]; then
  run_hard
fi
if [ "$TIER" = "advisories" ] || [ "$TIER" = "all" ]; then
  run_advisories
fi

if [ "$MODE" = "report" ]; then
  echo "RESULT: REPORT (exit 0 by contract; see the tables above)"
  exit 0
fi

if [ "$HARD_RESULT" = "FAIL" ] || [ "$ADV_RESULT" = "FAIL" ]; then
  echo "RESULT: FAIL"
  exit 1
fi
if [ "$HARD_RESULT" = "BLOCKED" ] || [ "$ADV_RESULT" = "BLOCKED" ]; then
  echo "RESULT: BLOCKED"
  exit 3
fi
if [ "$ADV_RESULT" = "RATCHET_OK" ]; then
  echo "RESULT: RATCHET OK (${BASELINED:-0} baselined findings unchanged, exit 0)"
  exit 0
fi
if [ "$HARD_RESULT" = "PASS" ] && { [ "$ADV_RESULT" = "PASS" ] || [ "$ADV_RESULT" = "SKIP" ]; }; then
  echo "RESULT: PASS (hard gate clean; no advisory findings)"
  exit 0
fi
if [ "$HARD_RESULT" = "SKIP" ] && [ "$ADV_RESULT" = "PASS" ]; then
  echo "RESULT: PASS (no advisory findings)"
  exit 0
fi

echo "RESULT: BLOCKED (incomplete tier)"
exit 3
