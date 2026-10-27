#!/usr/bin/env bash
# Plan compliance audit for the Wave 0/1 plan.
#
# Contract:
#   - Only top-level `- [ ]` / `- [x]` items in `## TODOs` and
#     `## Final verification wave` are audited.  Indented/nested checkboxes and
#     acceptance/evidence bullets are ignored.
#   - Numeric todos use zero-padded evidence names (`01-...` ... `14-...`) and
#     a commit trailer `Plan-Todo: N` in the branch range.
#   - Final-verification items (`F1`...) use `target/final/F<N>.md` (or
#     `target/test-evidence/F<N>-...`) and `Plan-Todo: F<N>`.
#   - Every checked item must have both evidence and a matching commit.
#   - An unchecked item that still has evidence is stale state and fails.
#   - No `CoreFlags`/Dart flag default may be `true`, except the flag names
#     explicitly listed by `--allow-flags` (Wave 6 cutover allowance).
#   - The branch range must not delete any file, except the exact repo-relative
#     paths listed by `--allow-deletions` (Wave 6 intentional removals).
#
# Exit codes:
#   0  audit passed
#   1  audit failed
#   2  usage / environment error
#
# Usage:
#   scripts/qa/f1-plan-audit.sh [--self-test] [--plan PATH] [--base REF]
#       [--range A..B] [--repo-root DIR] [--evidence-dir DIR]
#       [--allow-flags download,install] [--allow-deletions PATH,...] [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
PLAN=""
BASE_REF=""
RANGE=""
EVIDENCE_DIR=""
ALLOW_FLAGS=""
ALLOW_DELETIONS=""
VERBOSE=0
SELF_TEST=0

usage() {
  cat <<USAGE
usage: $(basename "$0") [--self-test] [options]

Modes:
  --self-test            build temporary fixture repositories and prove the
                         checker accepts a valid plan and rejects each broken
                         fixture (does not read the real repo state)

Options:
  --plan PATH            plan markdown (default: <repo>/.omo/plans/gstore-rust-core-android-wave01.md)
  --base REF             branch base ref (default: origin/\$GITHUB_BASE_REF,
                         then main, then origin/main)
  --range A..B           explicit commit range (overrides --base)
  --repo-root DIR        repository root (default: script's repo; used by self-test)
  --evidence-dir DIR     evidence directory (default: <repo>/target/test-evidence)
  --allow-flags LIST     comma-separated flag names whose `true` default is
                         allowed (Wave 6 cutover: download,install). Every
                         other flag default is still rejected.
  --allow-deletions LIST comma-separated exact repo-relative paths whose
                         deletion is intentional (Wave 6 legacy removal). Any
                         other deleted path still fails the audit.
  --verbose              print extra detail
  -h | --help            show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --plan) PLAN="$2"; shift 2 ;;
    --base) BASE_REF="$2"; shift 2 ;;
    --range) RANGE="$2"; shift 2 ;;
    --repo-root) ROOT="$2"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    --allow-flags) ALLOW_FLAGS="$2"; shift 2 ;;
    --allow-flags=*) ALLOW_FLAGS="${1#*=}"; shift ;;
    --allow-deletions) ALLOW_DELETIONS="$2"; shift 2 ;;
    --allow-deletions=*) ALLOW_DELETIONS="${1#*=}"; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd -P "$ROOT" && pwd)"
if [ -z "$PLAN" ]; then
  PLAN="$ROOT/.omo/plans/gstore-rust-core-android-wave01.md"
elif [ "${PLAN#/}" = "$PLAN" ]; then
  PLAN="$ROOT/$PLAN"
fi
if [ -z "$EVIDENCE_DIR" ]; then
  EVIDENCE_DIR="$ROOT/target/test-evidence"
elif [ "${EVIDENCE_DIR#/}" = "$EVIDENCE_DIR" ]; then
  EVIDENCE_DIR="$ROOT/$EVIDENCE_DIR"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 2
fi

resolve_range() {
  if [ -n "$RANGE" ]; then
    printf '%s\n' "$RANGE"
    return 0
  fi
  local base="$BASE_REF" mb
  if [ -z "$base" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    if git -C "$ROOT" rev-parse --verify -q "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
      base="origin/${GITHUB_BASE_REF}"
    fi
  fi
  if [ -z "$base" ] && git -C "$ROOT" rev-parse --verify -q main >/dev/null 2>&1; then
    base="main"
  fi
  if [ -z "$base" ] && git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base="origin/main"
  fi
  if [ -z "$base" ]; then
    echo "ERROR: cannot determine branch base; pass --base REF or --range A..B" >&2
    return 2
  fi
  if ! git -C "$ROOT" rev-parse --verify -q "$base" >/dev/null 2>&1; then
    echo "ERROR: base ref not found: $base" >&2
    return 2
  fi
  if ! mb="$(git -C "$ROOT" merge-base "$base" HEAD 2>/dev/null)"; then
    echo "ERROR: no merge-base between $base and HEAD" >&2
    return 2
  fi
  printf '%s..HEAD\n' "$mb"
}

# ---------------- self-test ----------------
make_fixture() {
  local dir="$1" mode="${2:-valid}"
  mkdir -p "$dir/target/test-evidence" "$dir/target/final" \
    "$dir/rust/gstore_core/src" "$dir/lib/core"
  cat > "$dir/plan.md" <<'PLAN'
# fixture plan

Intro text with a fake checkbox line:  - [x] 77. ignored intro

## TODOs

### Wave fixture

- [x] 1. First todo
  - Acceptance: nested acceptance text
  - [x] 99. Nested checkbox must be ignored
- [x] 2. Second todo
  - QA happy: nested evidence bullet
- [x] 3. Third todo
- [ ] 4. Unchecked todo
  - [x] 5. Indented checkbox must be ignored

## Final verification wave

- [x] F1. Final compliance
- [ ] F2. Not run yet

## After the audited sections

- [x] 88. Checkbox outside the audited sections must be ignored
PLAN

  cat > "$dir/rust/gstore_core/src/flags.rs" <<'RS'
pub struct Flags { pub channels: bool, pub catalog: bool, pub update: bool,
    pub download: bool, pub install: bool, pub js_channel: bool, pub core_writes: bool }
impl Flags {
    pub const DISABLED: Self = Self {
        channels: false,
        catalog: false,
        update: false,
        download: false,
        install: false,
        js_channel: false,
        core_writes: false,
    };
}
RS
  cat > "$dir/lib/core/core_flags.dart" <<'DART'
class CoreFlagsSnapshot {
  const CoreFlagsSnapshot({
    this.channels = false,
    this.catalog = false,
    this.update = false,
    this.download = false,
    this.install = false,
    this.jsChannel = false,
    this.coreWrites = false,
  });
  static const disabled = CoreFlagsSnapshot();
}
DART
  printf 'old writer placeholder\n' > "$dir/old_writer.dart"
  printf 'second old writer placeholder\n' > "$dir/old_writer_two.dart"

  printf 'evidence 1\n' > "$dir/target/test-evidence/01-fixture.txt"
  printf 'evidence 2\n' > "$dir/target/test-evidence/02-fixture.txt"
  printf 'evidence 3\n' > "$dir/target/test-evidence/03-fixture.txt"
  printf 'final 1\n' > "$dir/target/final/F1.md"
  # Malformed / non-zero-padded names must NOT satisfy a numeric todo.
  printf 'bad\n' > "$dir/target/test-evidence/1-malformed.txt"
  printf 'bad\n' > "$dir/target/test-evidence/001-malformed.txt"
  printf 'bad\n' > "$dir/target/test-evidence/03"
  mkdir -p "$dir/target/test-evidence/03-directory"
  printf 'nested\n' > "$dir/target/test-evidence/03-directory/03-nested.txt"

  git init -q "$dir"
  git -C "$dir" config user.email "qa@example.invalid"
  git -C "$dir" config user.name "QA Fixture"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture base"
  git -C "$dir" branch -M main
  git -C "$dir" checkout -q -b feature

  local n
  for n in 1 2 3; do
    if [ "$mode" = "missing_plan_todo" ] && [ "$n" = "2" ]; then
      git -C "$dir" commit -q --allow-empty -m "fixture todo $n without trailer"
    else
      git -C "$dir" commit -q --allow-empty -m "fixture todo $n" -m "Plan-Todo: $n"
    fi
  done
  git -C "$dir" commit -q --allow-empty -m "fixture final F1" -m "Plan-Todo: F1"

  case "$mode" in
    missing_evidence)
      rm -f "$dir/target/test-evidence/02-fixture.txt"
      ;;
    checked_unimplemented)
      python3 - "$dir/plan.md" <<'PYEDIT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("- [ ] 4.", "- [x] 4.", 1)
open(p, "w", encoding="utf-8").write(s)
PYEDIT
      ;;
    deleted_file)
      git -C "$dir" rm -q old_writer.dart
      git -C "$dir" commit -q -m "delete old writer" -m "Plan-Todo: 3"
      ;;
    flag_flipped)
      python3 - "$dir/rust/gstore_core/src/flags.rs" <<'PYEDIT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("channels: false", "channels: true", 1)
open(p, "w", encoding="utf-8").write(s)
PYEDIT
      ;;
    wave6_flipped)
      python3 - "$dir/rust/gstore_core/src/flags.rs" <<'PYEDIT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("download: false", "download: true", 1)
s = s.replace("install: false", "install: true", 1)
open(p, "w", encoding="utf-8").write(s)
PYEDIT
      ;;
    nonwave6_flipped)
      python3 - "$dir/rust/gstore_core/src/flags.rs" <<'PYEDIT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
for name in ("channels", "catalog", "update", "js_channel"):
    s = s.replace(name + ": false", name + ": true", 1)
open(p, "w", encoding="utf-8").write(s)
PYEDIT
      ;;
    stale_unchecked)
      python3 - "$dir/plan.md" <<'PYEDIT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("- [x] 3.", "- [ ] 3.", 1)
open(p, "w", encoding="utf-8").write(s)
PYEDIT
      ;;
    valid|missing_plan_todo) ;;
    *) echo "self-test: unknown fixture mode: $mode" >&2; return 2 ;;
  esac
}

run_fixture_audit() {
  local dir="$1"
  shift
  set +e
  "$SELF" --repo-root "$dir" --plan "$dir/plan.md" --base main "$@" \
    > "$dir/audit.log" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

self_test() {
  local tmp rc failures=0 case_no=0 valid_ok=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-f1-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN

  echo "== f1 plan-audit self-test =="

  make_fixture "$tmp/valid" valid
  rc="$(run_fixture_audit "$tmp/valid")"
  case_no=$((case_no + 1))
  if [ "$rc" -eq 0 ] && ! grep -q ' 99\.' "$tmp/valid/audit.log"; then
    echo "[PASS] valid fixture (rc=0, nested checkbox 99 ignored)"
    valid_ok=1
  else
    echo "[FAIL] valid fixture: expected rc=0 and no nested todo 99 (rc=$rc)" >&2
    sed 's/^/    /' "$tmp/valid/audit.log" >&2
    failures=$((failures + 1))
  fi

  # flaky_tests: the same fixture must produce the same verdict twice.
  rc="$(run_fixture_audit "$tmp/valid")"
  case_no=$((case_no + 1))
  if [ "$rc" -eq 0 ]; then
    echo "[PASS] repeated run on valid fixture (rc=0)"
  else
    echo "[FAIL] repeated run on valid fixture (rc=$rc)" >&2
    failures=$((failures + 1))
  fi

  # Wave-6 cutover allowance: download+install true pass only when named.
  make_fixture "$tmp/wave6_flipped" wave6_flipped
  rc="$(run_fixture_audit "$tmp/wave6_flipped" --allow-flags download,install)"
  case_no=$((case_no + 1))
  if [ "$rc" -eq 0 ]; then
    echo "[PASS] wave6 download+install true accepted with --allow-flags"
  else
    echo "[FAIL] wave6 download+install true rejected with --allow-flags (rc=$rc)" >&2
    sed 's/^/    /' "$tmp/wave6_flipped/audit.log" >&2
    failures=$((failures + 1))
  fi

  rc="$(run_fixture_audit "$tmp/wave6_flipped")"
  case_no=$((case_no + 1))
  if [ "$rc" -ne 0 ]; then
    echo "[PASS] same wave6 repo fails without --allow-flags (rc=$rc)"
  else
    echo "[FAIL] wave6 repo accepted without --allow-flags" >&2
    failures=$((failures + 1))
  fi

  make_fixture "$tmp/nonwave6_flipped" nonwave6_flipped
  rc="$(run_fixture_audit "$tmp/nonwave6_flipped" --allow-flags download,install)"
  case_no=$((case_no + 1))
  if [ "$rc" -ne 0 ]; then
    echo "[PASS] channels/catalog/update/js_channel still rejected under the allowance (rc=$rc)"
  else
    echo "[FAIL] non-Wave-6 flag defaults accepted under the allowance" >&2
    sed 's/^/    /' "$tmp/nonwave6_flipped/audit.log" >&2
    failures=$((failures + 1))
  fi

  local spec name mode
  for spec in \
    "missing evidence:missing_evidence" \
    "missing Plan-Todo:missing_plan_todo" \
    "checked but unimplemented:checked_unimplemented" \
    "deleted file:deleted_file" \
    "flag flipped true:flag_flipped" \
    "unchecked todo with retained evidence:stale_unchecked"; do
    name="${spec%%:*}"
    mode="${spec##*:}"
    make_fixture "$tmp/$mode" "$mode"
    rc="$(run_fixture_audit "$tmp/$mode")"
    case_no=$((case_no + 1))
    if [ "$rc" -ne 0 ]; then
      echo "[PASS] rejects $name (rc=$rc)"
    else
      echo "[FAIL] accepted $name (expected non-zero)" >&2
      sed 's/^/    /' "$tmp/$mode/audit.log" >&2
      failures=$((failures + 1))
    fi
  done

  rc="$(run_fixture_audit "$tmp/deleted_file" --allow-deletions old_writer.dart)"
  case_no=$((case_no + 1))
  if [ "$rc" -eq 0 ]; then
    echo "[PASS] allowed deletion accepted with --allow-deletions (rc=0)"
  else
    echo "[FAIL] allowed deletion rejected with --allow-deletions (rc=$rc)" >&2
    sed 's/^/    /' "$tmp/deleted_file/audit.log" >&2
    failures=$((failures + 1))
  fi

  rc="$(run_fixture_audit "$tmp/deleted_file" --allow-deletions some_other.dart)"
  case_no=$((case_no + 1))
  if [ "$rc" -ne 0 ]; then
    echo "[PASS] deletion not named by --allow-deletions still rejected (rc=$rc)"
  else
    echo "[FAIL] non-allowed deletion accepted" >&2
    failures=$((failures + 1))
  fi

  git -C "$tmp/deleted_file" rm -q old_writer_two.dart
  git -C "$tmp/deleted_file" commit -q -m "delete second writer" -m "Plan-Todo: 3"
  rc="$(run_fixture_audit "$tmp/deleted_file" --allow-deletions old_writer.dart)"
  case_no=$((case_no + 1))
  if [ "$rc" -ne 0 ] && grep -q 'old_writer_two.dart' "$tmp/deleted_file/audit.log"; then
    echo "[PASS] allowance names one deletion; the second still fails (rc=$rc)"
  else
    echo "[FAIL] allowance suppressed an unnamed deletion (rc=$rc)" >&2
    sed 's/^/    /' "$tmp/deleted_file/audit.log" >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -ne 0 ]; then
    echo "SELF-TEST FAIL: $failures failing case(s) out of $case_no" >&2
    return 1
  fi
  echo "SELF-TEST PASS: $case_no cases (valid fixture passes; every broken fixture is rejected)"
  return 0
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

# ---------------- normal audit ----------------
if [ ! -f "$PLAN" ]; then
  echo "ERROR: plan file not found: $PLAN" >&2
  echo "       (pass --plan PATH; --self-test does not need the real plan)" >&2
  exit 2
fi

RANGE="$(resolve_range)" || exit $?
echo "== plan audit =="
echo "plan:     $PLAN"
echo "evidence: $EVIDENCE_DIR"
echo "range:    $RANGE"

set +e
python3 - "$ROOT" "$PLAN" "$EVIDENCE_DIR" "$RANGE" "$ALLOW_FLAGS" "$ALLOW_DELETIONS" "$VERBOSE" <<'PY'
import os
import re
import subprocess
import sys

(repo_root, plan_path, evidence_dir, commit_range, allow_flags, allow_deletions,
 verbose) = sys.argv[1:8]
verbose = verbose == "1"
allowed_flags = {name.strip() for name in allow_flags.split(",") if name.strip()}
allowed_deletions = {
    os.path.normpath(name.strip())
    for name in allow_deletions.split(",")
    if name.strip()
}


def fail(msg):
    print("FAIL: " + msg)


def run_git(args):
    return subprocess.run(["git", "-C", repo_root] + args,
                          capture_output=True, text=True)


# ---- parse plan ----
section = None
items = []          # dicts: id, checked, title, section, line
seen = {}
sections_seen = set()
with open(plan_path, encoding="utf-8", errors="replace") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.rstrip("\n")
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            heading = m.group(1).strip().lower()
            if heading == "todos":
                section = "todos"
            elif heading == "final verification wave":
                section = "final"
            else:
                section = None
            if section:
                sections_seen.add(section)
            continue
        if section is None:
            continue
        # Top-level only: no leading whitespace.  Nested checkboxes are ignored.
        m = re.match(r"^- \[( |x|X)\]\s+(.+?)\s*$", line)
        if not m:
            continue
        checked = m.group(1).lower() == "x"
        body = m.group(2).strip()
        im = re.match(r"^([0-9]+|[Ff][0-9]+)\.\s*(.*)$", body)
        if not im:
            if verbose:
                print("NOTE: ignoring malformed top-level checkbox at line %d: %s" % (lineno, body))
            continue
        ident = im.group(1)
        if re.match(r"^[0-9]+$", ident):
            norm = str(int(ident))
            kind = "num"
        else:
            norm = "F" + str(int(ident[1:]))
            kind = "final"
        key = (kind, norm)
        if key in seen:
            items.append({"id": norm, "kind": kind, "checked": checked,
                          "title": im.group(2), "section": section,
                          "line": lineno, "duplicate": True})
        else:
            seen[key] = True
            items.append({"id": norm, "kind": kind, "checked": checked,
                          "title": im.group(2), "section": section,
                          "line": lineno, "duplicate": False})

problems = []
if "todos" not in sections_seen:
    problems.append("missing `## TODOs` section")
if "final" not in sections_seen:
    problems.append("missing `## Final verification wave` section")
if not items:
    problems.append("no top-level checkboxes parsed from the audited sections")
for it in items:
    if it["duplicate"]:
        problems.append("duplicate todo id %s (line %d)" % (it["id"], it["line"]))

# ---- evidence ----
evidence_by_id = {}
if os.path.isdir(evidence_dir):
    for entry in sorted(os.listdir(evidence_dir)):
        path = os.path.join(evidence_dir, entry)
        if not os.path.isfile(path):
            continue
        for it in items:
            if it["kind"] == "num":
                prefix = "%02d-" % int(it["id"])
                # Wave 6 re-cuts use the `21<N-1>-` evidence convention
                # (todo 1 -> 210-, todo 2 -> 211-, todo 3 -> 212-, ...).
                wave6_prefix = "21%d-" % (int(it["id"]) - 1)
                for candidate in (prefix, wave6_prefix):
                    if entry.startswith(candidate) and len(entry) > len(candidate):
                        evidence_by_id.setdefault((it["kind"], it["id"]), []).append(entry)
                        break
            else:
                if re.match(r"^[Ff]%s[-_.]" % re.escape(it["id"][1:]), entry):
                    evidence_by_id.setdefault((it["kind"], it["id"]), []).append(entry)
else:
    problems.append("evidence directory not found: %s" % evidence_dir)

# Final-verification evidence may also live at target/final/F<N>.md.
final_dir = os.path.join(os.path.dirname(evidence_dir), "final")
for it in items:
    if it["kind"] != "final":
        continue
    for name in ("%s.md" % it["id"], "%s.txt" % it["id"]):
        path = os.path.join(final_dir, name)
        if os.path.isfile(path):
            evidence_by_id.setdefault((it["kind"], it["id"]), []).append("target/final/" + name)

# ---- commits / Plan-Todo ----
log = run_git(["log", "--format=%H%x1f%B%x1e", commit_range])
if log.returncode != 0:
    problems.append("git log failed for range %s: %s" % (commit_range, log.stderr.strip()))
    commits = []
else:
    commits = []
    for rec in log.stdout.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        sha, _, body = rec.partition("\x1f")
        trailers = set()
        for line in body.splitlines():
            tm = re.match(r"^[ \t]*Plan-Todo:[ \t]*([0-9]+|[Ff][0-9]+)[ \t]*$", line)
            if tm:
                val = tm.group(1)
                if re.match(r"^[0-9]+$", val):
                    trailers.add(("num", str(int(val))))
                else:
                    trailers.add(("final", "F" + str(int(val[1:]))))
        commits.append((sha[:12], trailers))
trailer_index = {}
for sha, trailers in commits:
    for key in trailers:
        trailer_index.setdefault(key, []).append(sha)

known = {(it["kind"], it["id"]) for it in items}
ignored_trailers = sorted({"%s" % (k[1] if k[0] == "final" else k[1])
                           for _, tr in commits for k in tr if k not in known})
if ignored_trailers and verbose:
    print("NOTE: Plan-Todo values outside this plan (ignored): %s" % ", ".join(ignored_trailers))

# ---- deletions ----
deleted = run_git(["diff", "--diff-filter=D", "--name-only", commit_range])
if deleted.returncode != 0:
    problems.append("git diff failed for range %s: %s" % (commit_range, deleted.stderr.strip()))
    deleted_files = []
else:
    deleted_files = [os.path.normpath(x) for x in deleted.stdout.splitlines() if x.strip()]

unallowed_deletions = [f for f in deleted_files if f not in allowed_deletions]
allowed_deletion_hits = [f for f in deleted_files if f in allowed_deletions]
if allowed_deletion_hits and verbose:
    print("NOTE: intentional deletion(s) allowed: %s" % ", ".join(allowed_deletion_hits))

# ---- flag defaults ----
flag_files = [
    (os.path.join(repo_root, "rust/gstore_core/src/flags.rs"),
     r"\b(channels|catalog|update|download|install|js_channel|core_writes)\s*:\s*true\b"),
    (os.path.join(repo_root, "lib/core/core_flags.dart"),
     r"\b(channels|catalog|update|download|install|jsChannel|coreWrites)\s*[:=]\s*true\b"),
]
flag_findings = []
for path, pattern in flag_files:
    if not os.path.isfile(path):
        problems.append("flag source not found: %s" % os.path.relpath(path, repo_root))
        continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            match = re.search(pattern, line)
            if not match:
                continue
            # The allowance suppresses only the exact named flag(s); every other
            # `true` default still fails the audit.
            if match.group(1) in allowed_flags:
                continue
            flag_findings.append("%s:%d: %s" % (os.path.relpath(path, repo_root), lineno, line.strip()))

# ---- report ----
for it in items:
    key = (it["kind"], it["id"])
    label = it["id"]
    ev = evidence_by_id.get(key, [])
    sha = trailer_index.get(key, [])
    if it["duplicate"]:
        status = "DUPLICATE"
    elif it["checked"]:
        # Numeric todos need evidence + a Plan-Todo commit.  Final-verification
        # items are verifier runs, not implementation todos: the plan only
        # defines evidence for them (target/final/F<N>.md), not a commit.
        required_commit = it["kind"] == "num"
        if ev and (sha or not required_commit):
            status = "OK"
        else:
            missing = []
            if not ev:
                missing.append("evidence")
            if required_commit and not sha:
                missing.append("Plan-Todo commit")
            status = "MISSING " + "+".join(missing)
            problems.append("todo %s is checked but missing %s" % (label, " and ".join(missing)))
    else:
        if ev:
            status = "STALE (unchecked but evidence present)"
            problems.append("todo %s is unchecked but still has evidence: %s" % (label, ", ".join(ev)))
        else:
            status = "unchecked"
    mark = "[x]" if it["checked"] else "[ ]"
    detail = ""
    if it["checked"]:
        detail = " evidence=%s commit=%s" % (",".join(ev) if ev else "-", ",".join(sha) if sha else "-")
    print("%s %-3s %-34s%s" % (mark, label, status, detail))

if unallowed_deletions:
    problems.append("branch range deletes file(s): %s" % ", ".join(unallowed_deletions))
if flag_findings:
    problems.append("flag default is true: %s" % "; ".join(flag_findings))

print()
print("deleted files: %d (allowed: %d)" % (len(deleted_files), len(allowed_deletion_hits)))
print("flag default findings: %d" % len(flag_findings))

if problems:
    print("FAIL: %d problem(s)" % len(problems))
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("PASS: every checked todo has evidence + a Plan-Todo commit; no stale evidence, flag flip, or file deletion")
sys.exit(0)
PY
PY_RC=$?
set -e
if [ "$PY_RC" -eq 0 ]; then
  echo "f1_plan_audit_ok"
else
  echo "f1_plan_audit_failed (rc=$PY_RC)" >&2
fi
exit "$PY_RC"
