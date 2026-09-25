# Task 1 — request-debug-ui-ux: total URL query codec

- Base HEAD: `aac74b1`
- Changed files: `lib/core/request_debug/query_codec.dart` (new), `lib/core/request_debug/request_debug.dart` (barrel export), `test/query_codec_test.dart` (new)
- Commit message: `feat(request-debug): add total URL query codec with merge-based buildUri`

## 1. TDD red (test written FIRST, before implementation)

Command:

```
flutter test test/query_codec_test.dart
```

Raw output (excerpt; exit 1):

```
00:00 +0: loading .../test/query_codec_test.dart
test/query_codec_test.dart:13:8: Error: Error when reading 'lib/core/request_debug/query_codec.dart': No such file or directory
import 'package:gstore/core/request_debug/query_codec.dart';
       ^
test/query_codec_test.dart:17:24: Error: Type 'DebugQueryParam' not found.
List<String> dump(List<DebugQueryParam> params) => [
                       ^^^^^^^^^^^^^^^
...
test/query_codec_test.dart:193:14: Error: Method not found: 'mergeParams'.
test/query_codec_test.dart:209:19: Error: Method not found: 'buildUri'.
00:00 +0 -1: Some tests failed.
Failing tests:
  .../test/query_codec_test.dart: loading .../test/query_codec_test.dart
```

## 2. TDD green (after implementation)

Command:

```
flutter test test/query_codec_test.dart
```

Raw output (tail; exit 0):

```
00:00 +31: buildUri placeholder URL does not throw (braces get percent-encoded)
00:00 +32: barrel export request_debug.dart re-exports the codec API
00:00 +33: All tests passed!
```

## 3. Static analysis

Command:

```
dart analyze lib/
```

Raw output:

```
729 issues found.
errors: 0
warnings: 93
infos: 636
```

`grep -E "query_codec\.dart|request_debug\.dart"` over the analyzer output → **no issues on touched files**.
Baseline was 0 errors / 93 warnings / 636 infos = exactly 729 → **no new warnings/infos**.

## 4. Regression: affected existing suite

Command:

```
flutter test test/request_debug_editor_test.dart test/request_debug_sender_test.dart test/curl_codec_test.dart test/request_debug_facade_test.dart
```

Result: `00:03 +51: All tests passed!` (barrel export introduces no name collision).

## 5. Acceptance table → test names (all in `test/query_codec_test.dart`)

| # | Acceptance input / assertion | Test name |
|---|---|---|
| 1 | `parseUrlQuery('')` → empty; base `''`, no params, no fragment | `parseUrlQuery empty input yields empty result` |
| 2 | `'ht tp://x'`, `'http://[::1'` → no throw, `base == url` | `parseUrlQuery space-containing and malformed URLs never throw` |
| 3 | `'api.example.com/x?a=1'` | `parseUrlQuery absolute URL keeps path and parses one param` |
| 4 | `'/rel?a=1'` | `parseUrlQuery relative path parses query` |
| 5 | `'p#frag?a=1'` (fragment has no query) | `parseUrlQuery fragment is split off first; query inside fragment is ignored` |
| 6 | `'?a=1&a=2'` → 2 rows | `parseUrlQuery repeated names produce separate ordered rows` |
| 7 | `'?a=&b'` → empty value kept | `parseUrlQuery empty value is kept, valueless key is kept` |
| 8 | `'?flag'` → valueless kept | `parseUrlQuery lone valueless key is kept` |
| 9 | `'?a={{host}}'` → rebuild keeps `{{host}}`, no `%7B` | `parseUrlQuery placeholder value is kept literally (no decoding/corruption)` + `rebuildUrl placeholder is emitted raw (no %7B)` |
| 10 | `'{{host}}/p?a=1'` → base `{{host}}/p`, params `[a=1]` | `parseUrlQuery placeholder prefix base is separated from query` |
| 11 | `parseUrlQuery('?a=1+2').params[0].value == '1+2'`; rebuild emits `a=1+2` | `parseUrlQuery normalization: plus stays literal` |
| 12 | `parseUrlQuery('?a=%20').params[0].value == ' '`; rebuild emits `a=%20` | `parseUrlQuery normalization: percent-encoded space decodes to space and re-encodes` |
| 13 | `mergeParams([a=1],[a=2]) == [a=2]` | `mergeParams override replaces base value group` |
| 14 | `mergeParams([a=1],[a=2,a=3]) == [a=2,a=3]` | `mergeParams override group replaces whole base group at base position` |
| 15 | `mergeParams([a=1],[b=2]) == [a=1,b=2]` | `mergeParams base names absent from overrides keep value and position` + `mergeParams new override groups are appended in override order` |
| 16 | `buildUri('http://x/?a=1&a=2',[a=3]).queryParametersAll['a'] == ['3']` | `buildUri override replaces duplicate base keys` |
| 17 | `buildUri('http://x/p#f',[a=2]).toString() == 'http://x/p?a=2#f'` | `buildUri query is built before the fragment` |
| 18 | semicolon separator `'?a=1;b=2'` | `parseUrlQuery semicolon is a separator too` |
| 19 | malformed `%` fallback, no throw | `parseUrlQuery malformed percent-encoding falls back without throwing` |
| 20 | reserved `&`,`=`,`#` encoded; space→`%20` | `rebuildUrl reserved characters &, =, # are percent-encoded` + `rebuildUrl space encodes to %20` |
| 21 | order / repeats / valueless preserved; query before fragment | `rebuildUrl order and repeated names are preserved`, `rebuildUrl valueless key is emitted without =`, `rebuildUrl query is placed before fragment` |
| 22 | barrel re-exports codec | `barrel export request_debug.dart re-exports the codec API` |

## 6. How `buildUri` avoids `{{var}}` corruption

`parseUrlQuery` / `rebuildUrl` never touch `Uri`: parsing is a manual char scan, and
rebuilding only percent-encodes the reserved set `& = #` plus space→`%20`, so a
literal `{{host}}` survives parse→rebuild byte-for-byte (asserted: rebuild of
`?a={{host}}` emits `a={{host}}`, no `%7B`).

`buildUri` is the one place that must produce a `Uri` for the HTTP client. It does:

1. `parseUrlQuery(url)` → base + params + fragment (raw, placeholder-preserving);
2. `mergeParams(parsed.params, enabledNonEmpty)` → ordered merged groups;
3. `rebuildUrl(...)` → cleaned query string, query **before** `#fragment`;
4. `Uri.parse(cleaned)` → final `Uri`.

The raw/no-encode/no-throw guarantee applies to steps 1–3. In step 4 a `Uri`
**cannot** hold literal `{{var}}`; `Uri.parse` percent-encodes braces
(`{{host}}`→`%7B%7Bhost%7D%7D`) without throwing — this matches the pre-existing
`DebugSender._buildUri` behavior and is explicitly out of scope for the raw
guarantee. `{{var}}` resolution is performed elsewhere (`resolveEnv`) and is never
done here.

Note on valueless keys: `DebugQueryParam` carries only name/value/enabled, so
`?a=` and `?a` are indistinguishable after parsing. Rebuild emits a bare name
when value is empty (`?flag`), otherwise `name=value`. This keeps `?flag`
round-tripping and is semantically equivalent for `?a=&b` (`?a&b`).
