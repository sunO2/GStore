#!/usr/bin/env bash
# baseline-aware quality gate for the GStore contract spike.
#
# Captures or compares `dart analyze` + `cargo clippy` findings against a
# baseline JSON (`docs/qa-baseline.json`).  Existing crates are baseline-only:
# their findings are captured once and a NEW finding fails the gate.  New crates
# (`--strict-crates`, default `gstore_core`) must clippy-clean with `-D warnings`
# and have no baseline.
#
# Finding identity is exactly `(file, lint/rule/code, message)` — never
# line/column — so unrelated edits that shift lines do not break the gate.
# Paths are normalized to repo-relative.  The diff is count-based per identity,
# so an added duplicate of an already-known finding is still caught.
#
# Exit codes:
#   0   capture succeeded / compare found no NEW findings and no hard failure
#   1   compare found NEW findings, a source hard-failed, or baseline missing
#   2   usage error
#
# Hard-failure semantics:
#   - dart analyze: rc 0 (clean) and rc 2 (findings) are both valid; any other
#     rc or unparseable output is a hard failure.
#   - clippy on an existing crate: rc != 0 with ONLY `clippy::` error
#     diagnostics are deny-by-default clippy lints -> captured as baseline
#     findings (the crate still `cargo build`s).  rc != 0 with a non-clippy
#     error diagnostic is a genuine compile error -> gate failure.  rc != 0 with
#     no diagnostics at all (e.g. a bindgen/libclang build-script failure) is a
#     clippy-UNAVAILABLE state, tracked in the baseline so a later
#     available<->unavailable flip is still caught.
#   - clippy on a strict crate: any finding or rc != 0 -> gate failure.
#
# Usage:
#   scripts/qa/f2-quality.sh [--capture-baseline] [options]
#   --capture-baseline    capture current findings and write the baseline
#   --strict-crates <csv> new crates checked with -D warnings (default gstore_core)
#   --baseline <path>     baseline path (default docs/qa-baseline.json)
#   --strict-manifest <m> additionally clippy-check this Cargo.toml with -D warnings
#   --verbose             print tool invocations and extra detail
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<EOF
usage: $(basename "$0") [--capture-baseline] [options]

Modes:
  --capture-baseline   capture current findings into the baseline file and exit 0
  (default: compare)   compare current findings against the baseline; exit 1 if any
                       NEW finding appears or a source hard-fails, else exit 0

Options:
  --strict-crates <csv>  new crates that must clippy-clean with -D warnings
                         (default: gstore_core; skipped if the crate dir does not exist)
  --baseline <path>      baseline JSON path (default: docs/qa-baseline.json)
  --strict-manifest <m>  additionally clippy-check this Cargo.toml with -D warnings
                         (for throwaway probe crates; may be repeated)
  --verbose              print tool invocations and extra detail
  -h | --help            show this help
EOF
}

CAPTURE=0
BASELINE=""
STRICT_CRATES="gstore_core"
VERBOSE=0
EXTRA_STRICT_MANIFESTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --capture-baseline) CAPTURE=1; shift ;;
    --strict-crates) STRICT_CRATES="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --strict-manifest) EXTRA_STRICT_MANIFESTS+=("$2"); shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$BASELINE" ]; then BASELINE="$REPO_ROOT/docs/qa-baseline.json"; fi
if [ "${BASELINE#/}" = "$BASELINE" ]; then BASELINE="$REPO_ROOT/$BASELINE"; fi

# ---- capability checks: fail loudly, never silently pass ----
for tool in dart cargo python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: $tool" >&2
    exit 1
  fi
done
if ! cargo clippy --version >/dev/null 2>&1; then
  echo "ERROR: cargo clippy is not available (clippy component missing from the Rust toolchain)" >&2
  exit 1
fi

cd "$REPO_ROOT"

STRICT=()
IFS=',' read -r -a _strict_parts <<< "$STRICT_CRATES"
for _s in "${_strict_parts[@]}"; do
  _s="${_s// /}"
  [ -n "$_s" ] && STRICT+=("$_s")
done
unset _strict_parts

# scan existing crates: dirs under rust/ that carry a Cargo.toml
CRATES=()
for _d in "$REPO_ROOT"/rust/*/; do
  if [ -f "$_d/Cargo.toml" ]; then CRATES+=("$(basename "$_d")"); fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dart" "$WORK/clippy"

run_dart() {
  if [ "$VERBOSE" = 1 ]; then echo "[dart] dart analyze --format=json lib/" >&2; fi
  set +e
  dart analyze --format=json lib/ > "$WORK/dart/out.json" 2> "$WORK/dart/out.err"
  local rc=$?
  set -e
  echo "$rc" > "$WORK/dart/rc"
}

run_clippy() {
  local manifest="$1" out="$2" strict_flag="$3"
  local args=()
  # -D warnings is a clippy-driver/rustc flag and must follow the `--` separator
  if [ "$strict_flag" = 1 ]; then args+=(-- -D warnings); fi
  if [ "$VERBOSE" = 1 ]; then
    echo "[clippy] cargo clippy --manifest-path $manifest --message-format=json ${args[*]+${args[*]}}" >&2
  fi
  set +e
  cargo clippy --manifest-path "$manifest" --message-format=json "${args[@]}" \
    > "$out/out.json" 2> "$out/out.err"
  local rc=$?
  set -e
  echo "$rc" > "$out/rc"
}

run_dart

: > "$WORK/crates.list"
for crate in "${CRATES[@]}"; do
  mode=base
  for s in "${STRICT[@]}"; do
    if [ "$crate" = "$s" ]; then mode=strict; fi
  done
  manifest="$REPO_ROOT/rust/$crate/Cargo.toml"
  mkdir -p "$WORK/clippy/$crate"
  printf '%s\t%s\t%s\n' "$crate" "$manifest" "$mode" >> "$WORK/crates.list"
  strict_flag=0
  [ "$mode" = strict ] && strict_flag=1
  run_clippy "$manifest" "$WORK/clippy/$crate" "$strict_flag"
done

for m in "${EXTRA_STRICT_MANIFESTS[@]}"; do
  name="strict-$(basename "$(dirname "$m")")"
  mkdir -p "$WORK/clippy/$name"
  printf '%s\t%s\tstrict\n' "$name" "$m" >> "$WORK/crates.list"
  run_clippy "$m" "$WORK/clippy/$name" 1
done

set +e
python3 - "$CAPTURE" "$REPO_ROOT" "$BASELINE" "$WORK" "$VERBOSE" <<'PY'
import json
import os
import subprocess
import sys
import datetime
from collections import Counter

capture = sys.argv[1] == '1'
repo_root = sys.argv[2]
baseline_path = sys.argv[3]
work = sys.argv[4]
verbose = sys.argv[5] == '1'


def repo_rel(p):
    if not p:
        return p
    a = os.path.abspath(p)
    try:
        return os.path.relpath(a, repo_root)
    except ValueError:
        return p


def norm_msg(s):
    return s.strip()


def finding_key(f, c, m):
    return (f, c, m)


def multiset(items):
    return Counter(finding_key(x['file'], x['code'], x['message']) for x in items)


def fmt_key(k):
    f, c, m = k
    return '%s [%s] %s' % (f, c, m)


# ---------------- dart ----------------
dart_rc = int(open(os.path.join(work, 'dart', 'rc')).read().strip())
dart_out = open(os.path.join(work, 'dart', 'out.json'),
                encoding='utf-8', errors='replace').read()
dart_findings = []
dart_hard = None
if dart_rc not in (0, 2):
    dart_hard = 'dart analyze exited with rc=%d (expected 0=clean, 2=findings); stderr tail:\n%s' % (
        dart_rc, open(os.path.join(work, 'dart', 'out.err'), encoding='utf-8',
                      errors='replace').read()[-400:])
else:
    try:
        parsed = []
        text = dart_out.strip()
        if text:
            try:
                parsed.append(json.loads(text))
            except json.JSONDecodeError:
                for ln in text.splitlines():
                    ln = ln.strip()
                    if ln:
                        parsed.append(json.loads(ln))
        for o in parsed:
            for d in o.get('diagnostics', []) or []:
                loc = d.get('location') or {}
                f = loc.get('file')
                if not f:
                    continue
                dart_findings.append({
                    'file': repo_rel(f),
                    'code': d.get('code') or '(no code)',
                    'message': norm_msg(d.get('problemMessage') or ''),
                    'severity': d.get('severity') or '',
                })
    except json.JSONDecodeError as e:
        dart_hard = 'dart analyze output is not valid JSON: %s' % e

# ---------------- clippy ----------------
crates = []
for line in open(os.path.join(work, 'crates.list')):
    line = line.strip()
    if not line:
        continue
    name, manifest, mode = line.split('\t')
    d = os.path.join(work, 'clippy', name)
    rc = int(open(os.path.join(d, 'rc')).read().strip())
    findings = []
    hard = None
    unavailable = None
    try:
        for ln in open(os.path.join(d, 'out.json'), encoding='utf-8',
                       errors='replace'):
            ln = ln.strip()
            if not ln:
                continue
            o = json.loads(ln)
            if o.get('reason') != 'compiler-message':
                continue
            m = o.get('message') or {}
            lv = m.get('level')
            if lv not in ('warning', 'error'):
                continue
            code = (m.get('code') or {}).get('code') or '(no code)'
            fname = None
            for s in m.get('spans') or []:
                if s.get('is_primary') and (s.get('file_name') or s.get('path')):
                    fname = s.get('file_name') or s.get('path')
                    break
            if fname is None:
                for s in m.get('spans') or []:
                    if s.get('file_name') or s.get('path'):
                        fname = s.get('file_name') or s.get('path')
                        break
            if fname is not None:
                if os.path.isabs(fname):
                    file = repo_rel(fname)
                else:
                    file = repo_rel(os.path.join(os.path.dirname(manifest), fname))
            else:
                file = repo_rel(manifest)
            findings.append({
                'file': file,
                'code': code,
                'message': norm_msg(m.get('message') or ''),
                'level': lv,
            })
        if rc != 0:
            errs = [x for x in findings if x['level'] == 'error']
            non_clippy = [x for x in errs if not x['code'].startswith('clippy::')]
            if non_clippy:
                hard = 'cargo clippy failed for %s: %d non-clippy error diagnostic(s) (compile error), first=%s [%s]' % (
                    name, len(non_clippy), non_clippy[0]['file'], non_clippy[0]['code'])
            elif errs:
                # deny-by-default clippy lints only -> baseline-able findings
                pass
            else:
                unavailable = ('cargo clippy could not run for %s: rc=%d with no compiler '
                               'diagnostics (build-script/toolchain failure, e.g. missing '
                               'libclang for bindgen); stderr tail:\n%s' % (
                                   name, rc, open(os.path.join(d, 'out.err'),
                                                  encoding='utf-8',
                                                  errors='replace').read()[-300:]))
    except json.JSONDecodeError as e:
        hard = 'clippy output for %s is not valid JSON: %s' % (name, e)
    crates.append({'name': name, 'manifest': manifest, 'mode': mode, 'rc': rc,
                   'findings': findings, 'hard': hard, 'unavailable': unavailable})


def commit():
    try:
        return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=repo_root,
                              capture_output=True, text=True).stdout.strip() or 'unknown'
    except Exception:
        return 'unknown'


def hard_failures():
    out = []
    if dart_hard:
        out.append(dart_hard)
    for c in crates:
        if c['hard'] and c['mode'] != 'strict':
            out.append(c['hard'])
        if c['mode'] == 'strict' and (c['rc'] != 0 or c['findings'] or c['unavailable']):
            n = len(c['findings'])
            out.append('strict crate %s has %d finding(s) / rc=%d (new crates must clippy-clean with -D warnings)%s' % (
                c['name'], n, c['rc'],
                '' if not c['findings'] else ': ' + ' | '.join(fmt_key(finding_key(x['file'], x['code'], x['message'])) for x in c['findings'][:5])))
    return out


# ---------------- capture ----------------
if capture:
    hf = hard_failures()
    if hf:
        print('FAIL: cannot capture baseline, source hard failure(s):')
        for h in hf:
            print('  - ' + h)
        sys.exit(1)
    baseline = {
        'meta': {
            'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'commit': commit(),
            'dart_analyze_exit': dart_rc,
            'clippy_exit': {c['name']: c['rc'] for c in crates},
        },
        'dart': dart_findings,
        'clippy': {c['name']: {
            'state': 'unavailable' if c['unavailable'] else 'ok',
            'reason': c['unavailable'],
            'findings': [] if c['unavailable'] else c['findings'],
        } for c in crates if c['mode'] == 'base'},
    }
    os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
    tmp = baseline_path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(baseline, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, baseline_path)
    print('== capture baseline ==')
    print('dart analyze: rc=%d findings=%d' % (dart_rc, len(dart_findings)))
    for c in crates:
        if c['mode'] != 'base':
            continue
        if c['unavailable']:
            print('clippy %s: state=unavailable rc=%d (%s)' % (
                c['name'], c['rc'], c['unavailable'].splitlines()[0]))
        else:
            print('clippy %s: rc=%d findings=%d' % (c['name'], c['rc'], len(c['findings'])))
    print('baseline written: %s' % os.path.relpath(baseline_path, repo_root))
    sys.exit(0)

# ---------------- compare ----------------
if not os.path.exists(baseline_path):
    print('FAIL: baseline file not found: %s (run --capture-baseline first)' % baseline_path)
    sys.exit(1)
try:
    with open(baseline_path, encoding='utf-8') as fh:
        base = json.load(fh)
except (json.JSONDecodeError, OSError) as e:
    print('FAIL: baseline file is not valid JSON: %s (%s)' % (baseline_path, e))
    sys.exit(1)

base_dart = base.get('dart', []) or []
base_clippy = base.get('clippy', {}) or {}
base_meta = base.get('meta', {}) or {}
base_clippy_exit = base_meta.get('clippy_exit', {}) or {}

cur_dart_ms = multiset(dart_findings)
base_dart_ms = multiset(base_dart)
dart_new, dart_fixed = [], []
for k in sorted(set(cur_dart_ms) | set(base_dart_ms)):
    cc, bc = cur_dart_ms.get(k, 0), base_dart_ms.get(k, 0)
    if cc > bc:
        dart_new.append((k, cc - bc))
    elif bc > cc:
        dart_fixed.append((k, bc - cc))

clippy_new = {}
clippy_fixed = {}
flips = []          # informational availability flips
fail_msgs = []
for c in crates:
    if c['mode'] == 'strict':
        if c['rc'] != 0 or c['findings'] or c['unavailable']:
            fail_msgs.append('strict crate %s has findings/rc=%d (must be clean with -D warnings)%s' % (
                c['name'], c['rc'],
                '' if not c['findings'] else ': ' + ' | '.join(
                    fmt_key(finding_key(x['file'], x['code'], x['message'])) for x in c['findings'][:5])))
        continue
    if c['hard']:
        fail_msgs.append(c['hard'])
        continue
    bc = base_clippy.get(c['name'])
    if bc is None:
        fail_msgs.append('crate %s is not present in the baseline (re-capture --capture-baseline)' % c['name'])
        continue
    bstate = bc.get('state', 'ok')
    cur_state = 'unavailable' if c['unavailable'] else 'ok'
    if bstate == 'unavailable' and cur_state == 'unavailable':
        flips.append('clippy %s: still unavailable (baseline)' % c['name'])
        continue
    if bstate == 'ok' and cur_state == 'unavailable':
        flips.append('clippy %s: REGRESSION baseline=ok now=unavailable: %s' % (
            c['name'], c['unavailable'].splitlines()[0]))
        fail_msgs.append('clippy could not run for %s, but the baseline captured it as available' % c['name'])
        continue
    if bstate == 'unavailable' and cur_state == 'ok':
        cur = c['findings']
        new = [(finding_key(x['file'], x['code'], x['message']), 1) for x in cur]
        clippy_new[c['name']] = new
        fail_msgs.append('crate %s was unavailable at baseline; now it runs and reports %d finding(s), all new' % (
            c['name'], len(cur)))
        continue
    base_ms = multiset(bc.get('findings', []) or [])
    cur_ms = multiset(c['findings'])
    new_l, fixed_l = [], []
    for k in sorted(set(cur_ms) | set(base_ms)):
        cc, bcc = cur_ms.get(k, 0), base_ms.get(k, 0)
        if cc > bcc:
            new_l.append((k, cc - bcc))
        elif bcc > cc:
            fixed_l.append((k, bcc - cc))
    if new_l:
        clippy_new[c['name']] = new_l
    if fixed_l:
        clippy_fixed[c['name']] = fixed_l

new_total = sum(n for _, n in dart_new) + sum(sum(n for _, n in v) for v in clippy_new.values())
fixed_total = sum(n for _, n in dart_fixed) + sum(sum(n for _, n in v) for v in clippy_fixed.values())

print('== compare quality gate ==')
print('baseline: %s' % os.path.relpath(baseline_path, repo_root))
print('dart analyze: rc=%d findings=%d (baseline %d)' % (dart_rc, len(dart_findings), len(base_dart)))
for c in crates:
    if c['mode'] != 'base':
        continue
    bc = base_clippy.get(c['name']) or {}
    n = len(c['findings']) if not c['unavailable'] else '-'
    bn = len(bc.get('findings', []) or []) if bc.get('state', 'ok') != 'unavailable' else '-'
    print('clippy %s: findings=%s rc=%d (baseline findings=%s rc=%s)' % (
        c['name'], n, c['rc'], bn, base_clippy_exit.get(c['name'], '?')))

print('NEW findings (%d):' % new_total)
for k, n in dart_new:
    print('  NEW dart: %s (x%d)' % (fmt_key(k), n))
for cname, lst in sorted(clippy_new.items()):
    for k, n in lst:
        print('  NEW clippy/%s: %s (x%d)' % (cname, fmt_key(k), n))
print('FIXED findings (%d, informational only):' % fixed_total)
for k, n in dart_fixed[:20]:
    print('  FIXED dart: %s (x%d)' % (fmt_key(k), n))
for cname, lst in sorted(clippy_fixed.items()):
    for k, n in lst[:20]:
        print('  FIXED clippy/%s: %s (x%d)' % (cname, fmt_key(k), n))
for fl in flips:
    print('  NOTE: %s' % fl)

if fail_msgs:
    print('FAIL (%d reason(s)):' % len(fail_msgs))
    for m in fail_msgs:
        print('  - ' + m)
    sys.exit(1)
if new_total > 0:
    print('FAIL: %d new finding(s)' % new_total)
    sys.exit(1)
print('PASS: no new findings (baseline only: dart=%d, clippy=%d)' % (
    len(base_dart), sum(len((base_clippy[c].get('findings') or [])) for c in base_clippy)))
sys.exit(0)
PY
PY_RC=$?
set -e
exit "$PY_RC"
