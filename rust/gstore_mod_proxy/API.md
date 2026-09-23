# gstore_mod_proxy — Module API (v0.1.0, ABI v3)

> **Status: FROZEN (Todo 18).** Every method and event below is verified against
> the shipped dispatch (`src/lib.rs`) and the emit sites; the Dart bindings
> (`lib/core/rust/proxy/`) and their decode tests mirror this file 1:1. The
> contract is machine-checked in both directions: a Rust test asserts every name
> in `DISPATCH_METHODS` is dispatchable and documented here; a Dart test parses
> this file and asserts its method/event set equals the Dart registry. Adding,
> renaming, or removing a method/event without updating all three (dispatch,
> this file, Dart registry) fails those tests.
>
> Module name `proxy` · `min_host_abi = 3` · `api.version = 1` · crate `rust/gstore_mod_proxy`
> (cdylib + rlib, `panic = "unwind"`, every `extern "C"` entry wrapped in `catch_unwind`).
>
> **FRB/envelope is the only contract the Flutter UI uses.** Dart never speaks
> meow's HTTP Clash API for normal operation — all UI data comes from `call`
> responses and module events (the loopback controller in §2.13 is OFF by
> default and diagnostics-only). Business logic stays in Rust.

## 1. Transport contract

Every instance `call` uses the `gstore_contract` C ABI:

```
call(instance, method, payload, payload_len, out_data, out_len) -> c_int
```

- **Success** (`ABI_OK = 0`): `out` carries a JSON payload of the shape
  ```json
  { "ok": true, "data": { } }
  ```
- **Method error**: `call` returns `ABI_ERR_DETAIL (-8)` and `out` carries a
  `ModuleError` payload the host maps back to the envelope:
  ```json
  { "status": 405, "code": "METHOD_NOT_FOUND", "message": "method not found: x.y" }
  ```
- Empty `data` never means "absent"; unused fields are omitted, not `null`, unless
  documented. Clients must tolerate explicit `null` (module parses with defaults).
- `ping`/`version` are **static-safe**: they answer even without an instance
  (`instance = 0`); all other methods require a live instance.

### Instance lifecycle

| slot | semantics |
|---|---|
| `init()` | process-global init; no side effects in Todo 2 |
| `create(config)` | `config` = `ModuleContext` JSON (`data_dir`/`cache_dir`/`db_path`/`abi`/`app_version`); returns `instance_id`. **No threads spawned in Todo 2.** |
| `call(instance, method, payload)` | dispatch table below |
| `cancel(instance, requestId)` | cancels an in-flight long call; no-op until streaming work lands |
| `destroy(instance)` | idempotent; tears down instance state (fd/thread teardown arrives in Todo 6) |
| `shutdown()` | clears all instances |
| `alloc` / `free` | module-owned memory; host must free module output with module `free` |
| `on_event(moduleId, kind, data)` | host → module downlink (v2); consumed kinds below |

### Envelope status codes used by this module

| status | code | when |
|---|---|---|
| 200 | `OK` | success (`{ok:true,...}`) |
| 405 | `METHOD_NOT_FOUND` | unknown method (never a panic) |
| 422 | `INVALID_ARGUMENT` | malformed payload |
| 410 | `INSTANCE_NOT_FOUND` | call/cancel/destroy on a dead instance |
| 500 | `INTERNAL_ERROR` | engine failure |
| custom | `PROXY_*` | domain errors (see §5) |

## 2. Methods

All methods return `{ok:true,data:{...}}` unless marked *(error)*. Request payloads
are JSON objects (UTF-8), omitted when the method takes no input.

### 2.1 `ping` — liveness

Request: *(none)*

```json
{ "ok": true, "data": {
  "pong": true, "module": "proxy", "moduleVersion": "0.1.0",
  "apiVersion": 1, "minHostAbi": 3, "hostAbi": 3,
  "instanceId": 7, "state": "stopped", "mode": "off", "protectFdPresent": true,
  "protectInstalled": false,
  "dataplaneAlive": false,
  "health": { "alive": false, "generation": 0, "restarts": 0,
              "consecutiveFailures": 0, "lastError": null, "backoffMs": 0 }
} }
```

`instanceId`/`state`/`mode`/`protectFdPresent` appear only when a live instance was passed.
`protectInstalled` reflects the process-global meow `SocketProtector` install state
(the `vpn` engine installs it at init and removes it on teardown; Todo 7).
`dataplaneAlive`/`health` reflect the Todo 24 data-plane supervisor: whether the TUN
loop is expected to be reading, how often it has auto-restarted, the consecutive
failure burst, the verbatim last failure and the pending backoff (all process-global).

### 2.2 `version` — build & capability info

```json
{ "ok": true, "data": {
  "module": "proxy", "moduleVersion": "0.1.0", "apiVersion": 1,
  "minHostAbi": 3, "hostAbi": 3,
  "meowRev": "0e718f587442caaac00b221efc91c84907aeb0e0",
  "targetArch": "aarch64"
} }
```

### 2.3 `core.*` — engine lifecycle & run mode

| method | request | data |
|---|---|---|
| `core.start` | `{ "mode": "off"\|"vpn"\|"lanProxy", "profileId"?: string, "stack"?: string, "mtu"?: number, "dns"?: object, "rules"?: [string] }` | `{ "state":"running"\|"stopped", "mode":"vpn", "instanceId": number, "spawned": bool, "idempotent": bool, "profileId"?: string, "proxies"?: number, "groups"?: number, "rules"?: number, "overlays"?: { "stack": string, "mtu": number }, "warnings"?: [Warning] }` |
| `core.stop` | *(none)* | `{ "state": "stopped", "mode": "off", "previous": "vpn", "idempotent": false }` |
| `core.restart` | same as `core.start` | `{ "state":"running", "mode":"vpn", "spawned": bool, "restarted": true, ... }` |
| `core.set_mode` | `{ "mode": "off"\|"vpn"\|"lanProxy" }` | `{ "ok": true, "mode": "vpn", "previous": "off", "idempotent": bool, "state": "running" }` |
| `core.get_mode` | *(none)* | `{ "mode": "off", "state": "stopped", "sinceMs": 0, "lastMode": "vpn", "inbound": "lan"\|"none" }` |

`core.start` (Todo 13) builds the engine from the generated config before it
reports `running`: profile → proxy registry → rules → DNS → TUN loop (which
consumes the already-installed fd last). With a stored profile and no explicit
`profileId` it generates from the first profile; with no profile at all it still
starts with meow's built-in DIRECT/REJECT fallback. `core.restart` re-runs the
same generation/re-publish path on a fresh tunnel.

### 2.3.2 Run-mode state machine (Todo 29)

`mode ∈ {"off","vpn","lanProxy"}` is a first-class run mode owned entirely by
Rust; Dart only renders and requests.

* **`vpn`** — start `VpnService` (Kotlin) → `establish()` → fd → `tun.set_fd` →
  the single TUN reader rings **and installs the `SocketProtector`** (every
  outbound is protected). LAN listeners also start when the LAN config is
  enabled. Requires a pending fd: with none, `core.start`/`core.set_mode` return
  `PROXY_TUN_FD_INVALID` (422) **before** touching the current mode.
* **`lanProxy`** — **no `VpnService`, no TUN reader, no protect hook**: the
  engine + LAN inbounds only. The module explicitly clears the protector
  (`meow_common::clear_socket_protector()`), because calling
  `VpnService.protect` with no active VPN would fail and meow would error on
  every dial. Requires an enabled LAN listener: otherwise
  `PROXY_NO_INBOUND` (422) — never a silent no-op.
* **`off`** — engine stopped, listeners closed, service stopped.

**Switching** is serialized on one mutation lane (`mode.rs`): the current mode
is fully stopped (Todo 24 ordering: stop reader → join → clear protect → stop
service) **before** the next starts, so two modes can never run at once. It is
idempotent — re-selecting the current, resource-consistent mode is a no-op (and
emits no events). Profile/node/rule/DNS state is preserved: the engine is simply
rebuilt from them. The tunnel + engine restart, never the process. The last-used
mode is persisted to `<dataDir>/mode.json` and reported as `core.get_mode.lastMode`;
a fresh instance always starts `off` (never auto-starts a mode).

Event sequence for a real switch `A → B`:

1. `proxy.state {state:"stopping", mode:A, reason:"mode.switch", target:B}` (only when `A != off`)
2. `proxy.state {state:"starting", mode:B, reason:"mode.switch", target:B}`
3. `proxy.mode {mode:B, previous:A, phase:"active"}`
4. `proxy.state {state:"running", mode:B}`

For `B == off` steps 3–4 are `proxy.mode {mode:"off", previous:A}` then
`proxy.state {state:"stopped", mode:"off"}`. An unknown `mode` string is
`PROXY_MODE_INVALID` (422).

### 2.3.1 `tun.set_fd` — inject the TUN fd (Todo 6)

| method | request | data |
|---|---|---|
| `tun.set_fd` | `{ "fd": 123 }` | `{ "fd": 123, "nonblocking": true, "replacedRunning": false }` |

**Instance-less.** The host calls this directly when `nativeSetTunFd` fires (and
again on proxy mount if the fd arrived first); no module instance is required
because a proxy process has exactly one tunnel and lwIP's pcb lists are process
globals. The module `dup()`s the fd, sets `O_NONBLOCK` on the duplicate, and
stores it as *pending*; `core.start` owns the single read loop. Invalid
(`fd < 0`, closed, or un-`dup`-able) input returns the structured domain error
`PROXY_TUN_FD_INVALID` (422) — never a panic. The host fd is never closed by the
module (Kotlin owns the `ParcelFileDescriptor`).

### 2.4 `profile.*` — subscriptions, the canonical node model & the persistent store

Todo 11 implements the import methods below; Todo 12 **persists and enumerates
the same canonical model** (it never re-parses subscription content). The store
lives under `<data_dir>/profiles/`; see §12 for the on-disk layout, schema
version, the stable ordering key, atomicity, the credential location and the
app backup/restore hook.

| method | request | data |
|---|---|---|
| `profile.import_url` | `{ "url": string, "name"?: string, "userAgent"?: string }` | `ImportedProfile` |
| `profile.import_text` | `{ "text": string, "name"?: string, "contentType"?: string }` | `ImportedProfile` |
| `profile.import_link` | `{ "link": string, "name"?: string }` | `ImportedProfile` |
| `profile.list` | *(none)* | `ProfileList` |
| `profile.get` | `{ "id": string }` | `StoredProfile` |
| `profile.create` | `{ "profile": ImportedProfile, "id"?: string, "name"?: string, "appBackup"?: object }` | `StoredProfile` |
| `profile.update` | `{ "id": string, "profile"?: ImportedProfile, "name"?: string, "appBackup"?: object\|null, "refresh"?: { "state": "requested"\|"done"\|"failed", "error"?: string } }` | `StoredProfile` |
| `profile.delete` | `{ "id": string }` | `{ "ok": true, "id": string, "deleted": true }` |
| `profile.refresh` | `{ "id": string, "force"?: bool }` | `RefreshResult` (state `done`\|`failed`) |
| `profile.refresh_all` | `{ "force"?: bool, "limit"?: number }` | `{ force, limit, attempted, count, failedCount, refreshed: [RefreshResult], skipped: [{ profileId, reason, ... }] }` |
| `profile.set_schedule` | `{ "id": string, "intervalMs"?: number }` (0 clears) | `StoredProfile` |
| `profile.export_clash` | `{ "id": string, "stack"?: string, "mtu"?: number, "dns"?: object, "rules"?: [string] }` | `GeneratedConfig` (see §2.5) |

`profile.import_url` fetches over **meow's protect-aware transport** — the same
path as every outbound socket, so `VpnService.protect` applies even in VPN mode;
it is never a raw `reqwest` fetch. It parses `Subscription-Userinfo` and
`Content-Disposition`, auto-detects the body format, and returns the canonical
profile. Each successful import emits `proxy.subscription.added`.

`profile.import_text` parses an already-fetched body; `profile.import_link`
parses one share link (`ss`/`ss2022`/`vmess`/`vless`/`trojan`/`hysteria2`).

#### 2.4.1 `ImportedProfile`

```json
{
  "name": "My Sub",
  "format": "clash" | "base64" | "uriList" | "shareLink",
  "nodeCount": 42,
  "nodes": [ ProxyNode, ... ],
  "groups": [ ProxyGroup, ... ],
  "hasProxyGroups": true,
  "userinfo": SubscriptionUserinfo | null,
  "source": {
    "origin": "url" | "text" | "link",
    "url": "https://...", "finalUrl": "https://...",
    "filename": "sub.yaml", "userAgent": "clash.meta/1.19.0",
    "fetchedAtMs": 0, "bytes": 0, "contentType": "text/yaml"
  },
  "warnings": ["proxies[3]: dropped node: type 'made-up' is not in the import whitelist"]
}
```

`hasProxyGroups` is `true` when the source declared `proxy-groups`; `false` when the engine synthesized the fallback `PROXY` group.

`ProxyNode` (all optional keys are omitted when absent):

```json
{
  "name": "node-1",
  "type": "ss" | "vmess" | "vless" | "trojan" | "hysteria2" | ...,
  "server": "1.2.3.4",
  "port": 443,
  "cipher": "aes-256-gcm",
  "password": "…",
  "uuid": "…",
  "alterId": 0,
  "security": "auto",
  "flow": "xtls-rprx-vision",
  "network": "ws" | "grpc" | "tcp",
  "tls": true,
  "sni": "example.com",
  "skipCertVerify": false,
  "alpn": ["h2"],
  "fingerprint": "chrome",
  "reality": { "publicKey": "…", "shortId": "…", "spiderX": "/" },
  "ws": { "path": "/ws", "host": "example.com" },
  "grpc": { "serviceName": "…" },
  "obfs": "salamander",
  "obfsPassword": "…",
  "udp": true,
  "groups": ["PROXY"],
  "source": { "format": "clash", "origin": "url", "index": 0 }
}
```

`udp` is the Clash `udp:` flag carried from import through the canonical model and
re-emitted into the generated config. It is emitted for the TCP-carried protocols
(`ss`/`vmess`/`vless`/`trojan`/`socks5`/`http`) as `udp: true` when absent (our model
historically dropped the field and real subscriptions overwhelmingly enable it), and
an explicit `udp: false` is respected; `hysteria2` always emits `udp: true` (UDP-native).

`ProxyGroup`: `{ "name": "PROXY", "type": "select", "members": ["node-1"] }`.

`SubscriptionUserinfo` (from the `Subscription-Userinfo` header; `expire` is Unix
seconds, normalized if the provider sent milliseconds):

```json
{ "upload": 0, "download": 0, "total": 0, "expire": 0 }
```

#### 2.4.2 Import hardening (untrusted input)

- Only `http`/`https` URLs; `file://`/`ftp://`/`data:` are rejected.
- SSRF guard blocks loopback/private/link-local/CGNAT targets and re-checks
  every redirect hop (user-supplied URLs only).
- Connect (15 s) and read (60 s) timeouts; redirect cap 5; cross-origin
  credentials stripped.
- Hard body cap (16 MiB) enforced **while streaming**; a declared
  `Content-Length` above the cap is rejected before reading.
- Any `Content-Encoding` other than `identity` is rejected (nothing is
  decompressed client-side, so a gzip bomb has no path).
- Multi-`User-Agent` retry (`clash.meta`, `mihomo`, a browser UA) because
  providers vary their output by UA.
- Clash YAML parsing is delegated to `meow_config::subscription::parse_subscription_yaml`
  (no second YAML parser); a `script`-type node, an external SIP003 `plugin`, an
  unknown proxy type, and any `dns`/`tun`/`external-controller`/`proxy-providers`
  override are dropped — the canonical model carries only a whitelisted subset.

#### 2.4.3 The persistent store (Todo 12)

`profile.list` returns compact summaries (no node credentials) in a **stable**
order — `(createdAtMs asc, id asc)` — plus structured warnings for corrupt or
missing sibling files; a corrupt payload is skipped, never fatal.

```json
{
  "schemaVersion": 2,
  "revision": 3,
  "count": 2,
  "profiles": [ ProfileSummary, ... ],
  "warnings": [ { "code": "PROXY_PROFILE_CORRUPT", "id": "p2", "file": "p2.json", "message": "payload JSON: ..." } ]
}
```

`StoredProfile` (returned by `get`/`create`/`update`; the per-profile file):

```json
{
  "schemaVersion": 2,
  "id": "p1",
  "revision": 1,
  "createdAtMs": 0, "updatedAtMs": 0,
  "refresh": null | { "state": "idle"|"requested"|"done"|"failed", "requestedAtMs": 0,
                      "lastAttemptMs"?: 0, "attempts": 0, "error"?: "...",
                      "errorCode"?: "PROXY_SUB_FETCH_FAILED",
                      "lastUpdatedAtMs"?: 0, "intervalMs"?: 0,
                      "consecutiveFailures": 0, "nextRefreshAtMs"?: 0 },
  "appBackup": null | { /* opaque, preserved verbatim */ },
  "profile": ImportedProfile
}
```

`ProfileSummary`: `{ "id", "name", "format", "nodeCount", "groupCount",
"createdAtMs", "updatedAtMs", "revision", "sourceOrigin"?, "sourceUrl"?,
"userinfo"?, "refresh"? }`.

`profile.create` stores an `ImportedProfile` that Dart already obtained from
`profile.import_*`; `id` is optional (default `p<nextId>`, `[A-Za-z0-9_-]{1,64}`)
and `name` overrides the profile name. `profile.update` replaces content
(`profile`), the display name, the opaque `appBackup`, and/or the refresh flag;
a content/name change bumps `revision`. `profile.delete` removes the payload and
its index entry and emits `proxy.subscription.removed`.

`profile.refresh` (Todo 14) performs the fetch **in the module** through Todo
11's protect-aware importer, emits the progress/updated/failed event sequence
(§3), and preserves the previous profile when the fetch fails:

```json
{
  "profileId": "p1", "state": "done" | "failed", "attempts": 2,
  "nodeCount": 42, "userinfo": SubscriptionUserinfo | null,
  "lastUpdatedAtMs"?: 0, "intervalMs"?: 0, "nextRefreshAtMs"?: 0,
  "retryAfterMs"?: 0, "error"?: { "code": "PROXY_SUB_FETCH_FAILED", "message": "..." },
  "profile": StoredProfile
}
```

A `text`/`link`-origin profile has no URL to re-fetch → `PROXY_PROFILE_NOT_REFRESHABLE`
(422). A non-forced refresh inside the bounded failure-backoff window →
`PROXY_PROFILE_REFRESH_BACKOFF` (507); `force: true` bypasses it. A refresh
failure is **not** a module error: the call returns `state: "failed"` with the
structured `error`, and the previous profile is left untouched (only the
`refresh` bookkeeping changes).

`profile.refresh_all` (Todo 14) is a user-triggered batch update. It skips
profiles that are not due (failure backoff, or the `intervalMs` schedule has not
elapsed) unless `force: true`, and attempts at most `limit` profiles per call
(default 8, max 32) — there is **no background/auto refresh loop and no retry
storm**. `skipped[].reason` is one of `not_refreshable | backoff | interval |
limit | error`.

`profile.set_schedule` sets (or clears with `intervalMs: 0`) a profile's
auto-update interval; the next due time is `lastUpdatedAtMs + intervalMs` once a
success has occurred. Scheduling metadata lives in `RefreshState` (§2.4.3) and is
already surfaced to the UI through `profile.list` summaries.

Events: `profile.create` → `proxy.subscription.added`,
`profile.update` → `proxy.subscription.updated`,
`profile.delete` → `proxy.subscription.removed`, and `profile.refresh` /
`profile.refresh_all` → `proxy.subscription.progress` + (`proxy.subscription.updated`
on success | `proxy.subscription.failed` on failure) (§3).

### 2.5 `config.generate` / `config.apply` — render & hot-apply the engine config (Todo 13)

| method | request | data |
|---|---|---|
| `config.generate` | `GenerateRequest` | `GeneratedConfig` |
| `config.apply` | `GenerateRequest` | `GeneratedConfig` + `{ "applied": true, "rules": number }` |
| `profile.export_clash` | `{ "id": string, ...GenerateRequest }` | `GeneratedConfig` |

`GenerateRequest`:
```json
{
  "profileId"?: "p1",
  "stack"?: "system" | "gvisor" | "mixed",
  "mtu"?: 1500,
  "dns"?: { "mode": "fake-ip", "nameservers": ["1.1.1.1"], ... },
  "rules"?: ["DOMAIN-SUFFIX,example.com,PROXY", "MATCH,DIRECT"]
}
```

`GeneratedConfig`:
```json
{
  "config": "mode: rule\n…\n",          // the generated Clash YAML document
  "format": "clash",
  "template": "gstore-controlled-v1",
  "profileId": "p1",
  "profileName": "Fixture",
  "hash": "<sha256-hex-of-config>",
  "generatedAtMs": 0,
  "counts": { "proxies": 2, "groups": 1, "rules": 1 },
  "overlays": { "stack": "gvisor", "mtu": 1500 },
  "warnings": [
    { "code": "PROXY_CONFIG_NODE_UNSUPPORTED", "node": "h1",
      "message": "node 'h1' was not built: …" }
  ]
}
```

`config.generate` is pure: it reads the stored profile, the module's DNS config
(Todo 8) and the effective rule lines (request `rules` overlay → the profile's
captured `rules:` → Todo 9's current lines, plus an appended terminal `MATCH`)
and renders the template. When
`profileId` is omitted the first profile in stable store order is used; with no
stored profile it returns `PROXY_CONFIG_PROFILE_REQUIRED` (422).
`profile.export_clash` is the same document addressed by a required `id`.

`config.apply` regenerates and **hot-applies** in one step: with a running
tunnel it publishes the new ruleset (preserving proxies), then installs the
fresh proxy registry (preserving rules), and emits `proxy.config.applied`.
The engine is not restarted and the TUN loop is not re-created. With no running
engine it records the named profile as the active selection and returns the
generated config with `"applied": false` (mirrors `node.list`, which never
errors when stopped), so a subscription switch made while disconnected still
reaches the offline `node.select` / `node.delay_test` paths.

Template guarantees are in §13.

### 2.6 `node.*` — selection & latency (Todo 10)

| method | request | data |
|---|---|---|
| `node.select` | `{ "group": string, "node": string }` | `{ "ok": true, "group": string, "node": string, "active": string }` |
| `node.delay_test` | `{ "node"?: string, "group"?: string, "url"?: string, "expectedStatus"?: string, "timeoutMs"?: 5000 }` | `{ "results": [ DelayResult ], "url": string, "timeoutMs": number, "group"?: string }` |
| `node.list` | *(none)* | `{ "engineRunning": bool, "groups": [NodeGroupInfo], "current": NodeCurrent\|null }` |

`node.list` is the **read-only live selection view** used by the home status
card's 「当前节点」 row. It never errors when the engine is stopped: with no live
tunnel it returns `{ "engineRunning": false, "groups": [], "current": null }`,
so the UI degrades to its persisted-label fallback instead of a 422. With a
running engine it enumerates the stored profile's groups (falling back to any
other group the live registry exposes) and reports each group's **live**
`now` (the selected member for a selector; the auto-picked member for
url-test/fallback) — this is distinct from a rule's matched target.

```json
{
  "engineRunning": true,
  "groups": [
    { "name": "PROXY", "type": "select", "now": "香港 01",
      "members": ["香港 01", "日本 02"], "selectable": true }
  ],
  "current": { "group": "PROXY", "now": "香港 01", "node": null }
}
```

`current` is the live rule set's terminal `MATCH`/`FINAL` target **when it names
a group** (else `null`); `node` resolves one level deeper and is non-null only
when that group's `now` is itself a nested group, so the UI can show a leaf.


`node.select` applies a user pick to a **selector / url-test / fallback** group
through meow's `ProxySelection::set` — the module never owns a second group
engine. `active` is the group's effective member afterwards (`current()`).
Success also emits a `proxy.state` event carrying
`{state, mode, reason:"node.select", group, node, active}`. Errors:
`PROXY_NODE_NOT_FOUND` (unknown group/node, or node not a member),
`PROXY_GROUP_NOT_SELECTABLE` (target is a leaf or a non-selectable group such
as load-balance/relay), `PROXY_NOT_CONFIGURED` (engine not running).

`PROXY_NODE_NOT_FOUND` has a second, **build-time** origin: when a declared
proxy-group depends on a sibling group that could not be built (for example an
unsupported node type), the dependent group is cascade-dropped from the registry
at construction, so `node.select` reports `group not found` even though the
client sent a valid pick. A **running** engine can additionally hold a stale
registry after `profile.refresh` or a subscription switch; when the selected
group exists only in the displayed profile, the UI first re-applies that profile
(`config.apply`) to reconcile the live engine rather than asking for a manual
reconnect. Engine-stopped offline selection is unaffected. Each registry build
records its outcome as `proxy: registry groups built=[...] missing=[...]`, where
`missing` names the declared groups that never entered the registry (the
potential 404 sources).

The pick persists through meow's `SelectorStore` (`<data_dir>/selector.json`,
opened at instance create; meow-config's runtime rebuild wires it into rebuilt
groups), so it survives `rules.reload` and an engine restart **when groups are
built through that store** — see §11.2 for what Todo 13 must call.

`node.delay_test` performs an HTTP **HEAD** probe per node against `url` (or the
group's own `test_url`, else `https://www.gstatic.com/generate_204`) with
`expectedStatus` (default `200-299`) and `timeoutMs` clamped to `100..120000`.
Probes run on a **dedicated bounded runtime, never the tunnel loop**. An
unreachable node is a **per-node result**, not a call error:

```json
{ "node": "A", "delayMs": 0, "alive": false, "error": "timeout" }
{ "node": "B", "delayMs": 123, "alive": true }
```

`error` is `"timeout"` for a dial/response timeout or the transport message for
any other failure. Each result also emits a `proxy.node.delay` event.

### 2.7 `dns.*` — resolver settings & cache (Todo 8)

| method | request | data |
|---|---|---|
| `dns.get` | *(none)* | `{ "mode": string, "config": DnsConfig, "stats": DnsStats, "mappings": [DnsMapping], "recentQueries": [DnsQueryRecord] }` |
| `dns.set` | `DnsConfig` (partial) | `{ "ok": true, "config": DnsConfig }` |
| `dns.clear_cache` | *(none)* | `{ "ok": true, "flushed": number }` |
| `dns.flush_cache` | *(none)* | alias of `dns.clear_cache` (legacy skeleton name) |

`dns.set` merges the JSON object over the current effective config, validates it,
rebuilds the meow resolver, and installs it. Invalid nameserver/DoH/DoT URLs,
a bad fake-IP range, or an empty nameserver list return
`PROXY_DNS_CONFIG_INVALID` (422). `dns.clear_cache` also flushes every fake-IP
allocation.

`DnsConfig` (all fields optional on input; `dns.get` returns the effective set):

```json
{ "mode": "fake-ip"|"redir-host"|"normal",
  "nameservers": ["1.1.1.1", "tcp://1.0.0.1:53"],
  "fallback": ["8.8.8.8"],
  "doh": ["https://dns.example/dns-query#dns.example"],
  "dot": ["tls://8.8.8.8:853#dns.google"],
  "defaultNameservers": ["223.5.5.5"],
  "fakeIpRange": "198.18.0.0/16",
  "fakeIpRangeV6": null,
  "fakeIpTtlMs": null,
  "fakeIpFilter": ["*.lan"],
  "fakeIpFilterMode": "blacklist"|"whitelist",
  "useHosts": true, "ipv6": true, "hijack": true,
  "hosts": { "example.com": ["93.184.216.34"] } }
```

`doh` / `dot` are merged into the primary nameserver set (`https://` / `tls://`
meow transports). `defaultNameservers` is the **bootstrap** list (plain UDP/TCP
IP literals only) used to resolve the encrypted upstreams' own hostnames.

The built-in default is CN-reachable primaries `223.5.5.5` / `119.29.29.29`
with `1.1.1.1` / `8.8.8.8` as `fallback` (all plain IPs, so no bootstrap list
is needed); `dns.get` reflects them and an explicit `dns.set` replaces either
list.

`DnsStats`: `{ "queries": 0, "failures": 0, "cacheEntries": 0, "fakeIpActive": false, "fakeIpRange": "198.18.0.0/16" }`

`DnsQueryRecord` (also emitted as the `proxy.dns` event and the
`proxy.dns.query` / `proxy.dns.failure` module log line):

```json
{ "tsMs": 0, "domain": "example.com", "qtype": "A", "rcode": "NoError",
  "answers": ["198.18.0.4"], "resolver": "fake-ip", "latencyMs": 2,
  "ok": true, "mode": "fake-ip", "note": "fake-ip" }
```

`DnsMapping` (the domain→IP feed for the Todo 16 domain-statistics path):

```json
{ "domain": "example.com", "ip": "198.18.0.4", "fake": true,
  "tsMs": 0, "domainKnown": true }
```


### 2.8 `log.*` — structured engine logs (Todo 15)

Module logs flow to `LogManager` through the host `log` callback + LogBridge
(push channel, architecture §6.8). `log.*` is the **pull** side: a bounded
in-process ring (last **N = 1000** records) with a **monotonic cursor**. It is a
side channel only — the datapath never waits on it.

| method | request | data |
|---|---|---|
| `log.get` | `{ "sinceCursor"?: 0, "limit"?: 200, "level"?: "debug"\|"info"\|"warn"\|"error" }` | `LogPage` |
| `log.set_level` | `{ "level": "debug"\|"info"\|"warn"\|"error" }` | `{ "ok": true, "level": "info" }` |
| `log.clear` | *(none)* | `{ "ok": true }` |

`log.get` returns retained records with a cursor **strictly greater** than
`sinceCursor`, oldest first, capped at `limit` (clamped to N). Pass the returned
`nextCursor` back as `sinceCursor` to poll. The cursor never rewinds; `log.clear`
drops the records but keeps advancing. An optional `level` filters the page to
records at or above that level.

`LogPage`:

```json
{ "records": [LogRecord], "cursor": 42, "nextCursor": 41, "firstCursor": 1,
  "retained": 41, "capacity": 1000, "dropped": 0, "sinkDropped": 0,
  "level": "info" }
```

* `cursor` — next cursor the module will assign (diagnostic).
* `nextCursor` — pass as `sinceCursor` for the next page; equals the last
  returned cursor, or `sinceCursor` when the page is empty.
* `firstCursor` — oldest retained cursor (`0` when empty). A `sinceCursor`
  below it means records were lost to eviction.
* `dropped` — records discarded because they were below the retention level.
* `sinkDropped` — records retained but not delivered to the host sink
  (disconnected). The module keeps running in both cases.

`LogRecord` (stable envelope; the `kind` selects the payload):

```json
{ "cursor": 1, "tsMs": 0, "level": "info", "kind": "message",
  "message": "proxy: core.start mode=vpn",
  "connection"?: ConnectionLog, "dns"?: DnsQueryRecord }
```

`kind` is `message` (plain module line), `connection`, or `dns`. Exactly one of
`connection`/`dns` is present for the structured kinds. Records never contain
node credentials, UUIDs, passwords, subscription URLs, or other secrets.

`ConnectionLog` (`kind:"connection"`, Todo 15) — emitted from the connection
projection diff (`open`/`close`) and from `conn.close*`:

```json
{ "id": "uuid", "direction": "in", "domain": "example.com",
  "outbound": "proxy-a", "rule": "DOMAIN-SUFFIX", "rulePayload": "example.com",
  "network": "tcp", "src": "10.10.0.2:40000", "dst": "93.184.216.34:443",
  "uploadBytes": 0, "downloadBytes": 0, "bytes": 0, "durationMs": 0,
  "error"?: "..." }
```

`direction` is `in` for a flow entering from the TUN (the side Todo 15
records); `out` is reserved for the upstream leg. `bytes` is
`uploadBytes + downloadBytes`. `error` is absent on a clean close (populated
only when a failure is known).

`DnsQueryRecord` (`kind:"dns"`) is the Todo 8 schema documented in §2.7. The
same record is emitted as the `proxy.dns` event.

### 2.9 `stats.*` — domain statistics & aggregate traffic (Todo 16)

| method | request | data |
|---|---|---|
| `stats.domain.get` | `{ "rangeMs"?: 0, "sort"?: "bytes"\|"connections"\|"lastSeen"\|"domain", "limit"?: 100 }` | `DomainPage` |
| `stats.domain.reset` | *(none)* | `{ "ok": true, "cleared": 0 }` |
| `stats.traffic.get` | `{ "topDomains"?: 5 }` | `TrafficSnapshot` |
| `stats.get` (alias) | as `stats.domain.get` | `DomainPage` |
| `stats.reset` (alias) | as `stats.domain.reset` | `{ "ok": true, "cleared": 0 }` |

`DomainPage`:
```json
{
  "domains": [DomainStat],
  "count": 0, "returned": 0, "capacity": 2048, "domainCap": 2048,
  "evicted": 0, "rangeMs": 0, "sort": "bytes"
}
```

`DomainStat`:
```json
{ "domain": "example.com", "domainKnown": true, "connections": 3,
  "uploadBytes": 0, "downloadBytes": 0, "lastSeenMs": 0,
  "rule": "DOMAIN-SUFFIX", "rulePayload": "example.com", "outbound": "proxy-a" }
```

`TrafficSnapshot`:
```json
{ "uploadBytes": 0, "downloadBytes": 0, "activeConns": 0, "upBps": 0,
  "downBps": 0, "domainCount": 0, "capacity": 2048, "evicted": 0,
  "topDomains": [DomainStat] }
```

**Feed.** The aggregate is folded from the same bounded projection diff
`conn.list` uses (Todo 10): every dispatch-monitor tick calls
`conn::sync_full(meow Statistics)`, then accumulates per-live-flow byte
**deltas** into the domain totals (so long flows are counted while open, not
only at close). `connections` increments once per flow. `rangeMs` filters
records by `lastSeenMs >= now - rangeMs` (0 = all). Unknown `sort` is
`PROXY_STATS_SORT_INVALID` (422); the default is `bytes` (up+down descending,
ties by `connections` then domain). Sorts are fully deterministic.

`stats.traffic.get` accepts an optional `topDomains` count (default `5`, capped
at `DOMAIN_CAP = 2048`; `0` returns an empty `topDomains`) that bounds the
returned `topDomains` array (still sorted by total bytes). The push mirror is
the throttled `proxy.stats` event (§3).

**Primary path.** `stats.domain.get` / `stats.traffic.get` are the primary,
pull-based path. There are **two independent channels**: the host task-stream
ring holds `EVENT_BUFFER_CAP = 128` (`rust/gstore_host/src/task_bridge.rs:65`)
while the module event ring holds `EVENT_BUFFER_CAP = 100`
(`rust/gstore_host/src/event_bridge.rs:21`), so the module never streams
per-connection events; see the `proxy.stats` snapshot in §3.

**Memory bound & eviction.** At most `DOMAIN_CAP = 2048` distinct domains are
retained. When the cap is exceeded the entry with the **oldest `lastSeenMs`** is
evicted; ties are broken **lexicographically by domain (ascending)**, so
eviction is deterministic. Every eviction is logged (warn) and counted in
`evicted`. Byte accounting is O(live flows), never per packet.

**Persistence (optional).** When the instance has a data dir, aggregates are
persisted to `<dataDir>/proxy_stats.db` (SQLite, `journal_mode=WAL`,
`synchronous=NORMAL`). Writes are **batched** — one transactional upsert every
`PERSIST_INTERVAL_MS = 5000` ms, never per packet — and rows outside the
rolling `RETENTION_MS = 24h` window are pruned in the same transaction. On
startup the in-memory aggregate is seeded from rows still inside the window.
`stats.domain.reset` also clears the persisted rows.

**Domain availability.** Attribution has two sources: the UDP:53 fake-IP
mapping, and, for TCP, the SNI / HTTP-Host sniffer armed in the dispatch path
(§9.8). A domain is still **unavailable** for ECH/ESNI, QUIC-without-SNI and
plain-IP flows. The module then records the flow under its destination IP and
marks the record `domainKnown: false` (see §9.5). Before falling back it consults
the DNS reverse mapping (fake-IP allocation or the mapping ring) so any
fake-IP or sniffed domain is attributed when known.

### 2.10 `conn.*` — live connections (Todo 10; Todo 17 finalises)

| method | request | data |
|---|---|---|
| `conn.list` | `{ "offset"?: 0, "limit"?: 256, "domain"?: string, "outbound"?: string }` | `ConnPage` |
| `conn.close` | `{ "id": string }` | `{ "ok": true, "id": string, "closed": bool, "alreadyClosed": bool }` |
| `conn.close_all` | *(none)* | `{ "ok": true, "closed": 0 }` |

`ConnInfo`:
```json
{ "id": "c1", "src": "10.10.0.2:40000", "dst": "1.2.3.4:443",
  "domain": "example.com", "network": "tcp", "rule": "DOMAIN-SUFFIX",
  "rulePayload": "example.com", "outbound": "proxy-a",
  "uploadBytes": 0, "downloadBytes": 0, "startedAtMs": 0 }
```

`ConnPage`:
```json
{ "connections": [ConnInfo], "count": 0, "returned": 0, "total": 0,
  "offset": 0, "limit": 256, "hasMore": false, "capacity": 1024 }
```

Byte accounting and the connection lifecycle are **meow's**: every TCP flow is
inserted into `Statistics::connections` (a live `DashMap<Uuid, ConnectionInfo>`
keyed by UUID) by `tcp::route_inbound_tcp`, counters are bumped by the relay, and
the entry is removed when the flow ends. The module keeps a **bounded
projection** rebuilt from that table on every `conn.list`, capped at
`capacity = 1024`; if more than the cap are live the oldest-started entries are
dropped from the view (meow still accounts their bytes). `startedAtMs` is parsed
from meow's RFC3339 `ConnectionInfo.start`. `outbound` is the first proxy in
meow's connection `chains` (else `DIRECT`). Only TCP flows are tracked; UDP
sessions live in meow's NAT table and are not in `conn.list`.

**Ids.** `ConnInfo.id` is meow's `ConnectionInfo.id` rendered as an opaque
canonical **UUID string** (v4). It is stable for the life of the flow and is the
only handle a client passes back to `conn.close`; the module never exposes a raw
pointer, `Uuid`, or `ConnectionInfo` reference across the ABI.

**`conn.list` (Todo 17).** Paginated and filterable:

* `offset` (default `0`) is applied after filtering; an offset past the end
  returns an empty page (never an error).
* `limit` defaults to `256` and is clamped to `1..=capacity`; a client pages by
  increasing `offset` until `hasMore` is `false`.
* `domain` filters by **case-insensitive substring** of `ConnInfo.domain`; an
  empty/blank value means "no filter".
* `outbound` filters by **case-insensitive exact** match of
  `ConnInfo.outbound` (so `DIRECT` never matches `DIRECT-2`); empty means "no
  filter".
* `count` is the number of rows matching the filters **before** pagination;
  `returned` is the page size, `total` the number of live rows overall.
* Order is stable across calls — newest `startedAtMs` first, ties broken by
  `id` ascending — so a paged read never skips or duplicates a row.

**`conn.close`.** Signals one flow via meow's
`Statistics::close_connection(Uuid)`, which removes the entry and drops its
counter guard (this is what asks the owning relay task to stop); it does not and
cannot crash the tunnel loop. Semantics:

* **Live** id → `closed: true, alreadyClosed: false`; one `proxy.conn` event
  (`action:"close"`) is emitted and a close record is logged.
* **Already-closed** id (one this module saw closed, tracked in a bounded
  1024-entry tombstone) → idempotent success: `closed: false,
  alreadyClosed: true`, no event, no error.
* **Unknown** id (never tracked) → `PROXY_CONN_NOT_FOUND` (404).
* Non-UUID id → `INVALID_ARGUMENT` (422); no running engine →
  `PROXY_NOT_CONFIGURED`.

`conn.close_all` signals every tracked flow, marks them all closed, returns the
count, and emits a single `proxy.conn` event with `action:"close_all"` when it
closed at least one.

### 2.11 `rules.*` — rule set (Todo 9)

| method | request | data |
|---|---|---|
| `rules.get` | *(none)* | `RulesSnapshot` |
| `rules.reload` | `{ "config"?: string, "configPath"?: string, "geo"?: GeoRequest }` | `RulesSnapshot` |

`rules.reload` parses a Clash config (inline `config` YAML string, or
`configPath` read from disk), loads `rule-providers`, resolves geo assets and
publishes the compiled rule set into the running tunnel. It **never blocks on a
geo download or an `http` rule-provider**: those resolve on a background thread
and the snapshot reports their status. Exactly one of `config`/`configPath` is
required; neither ⇒ `PROXY_RULE_INVALID` (422). `rules.get` is read-only.

`RulesSnapshot`:
```json
{
  "rules": [
    { "index": 0, "lineNumber": 1, "line": "DOMAIN-SUFFIX,example.com,PROXY",
      "type": "DOMAIN-SUFFIX", "value": "example.com", "target": "PROXY",
      "source": "config" }
  ],
  "final": "DIRECT", "count": 1, "revision": 1,
  "groups": ["PROXY"],
  "providers": [
    { "name": "cn-domains", "type": "inline", "behavior": "domain",
      "url": "", "status": "loaded", "count": 120, "updatedAtMs": 0 }
  ],
  "geo": {
    "status": "ready",
    "assets": [
      { "kind": "geoip", "file": "country.mmdb", "path": "/.../geo/country.mmdb",
        "status": "ready", "verified": true, "sha256": "abc…" }
    ]
  },
  "errors": [
    { "lineNumber": 4, "line": "BOGUS-TYPE,x,DIRECT",
      "code": "PROXY_RULE_INVALID", "message": "unknown rule type: BOGUS-TYPE" }
  ],
  "warnings": []
}
```

* `rules[]` is the successfully parsed rules **in declaration order**;
  `index` is the position in this list and `lineNumber` the 1-based position in
  the source `rules:` block. `type` is meow's `RuleType` (`DOMAIN`,
  `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `GEOIP`, `GEOSITE`,
  `PROCESS-NAME`, `DST-PORT`, `RULE-SET`, `MATCH`, …); `value` is the rule
  payload; `target` is the outbound/group name.
* `final` is the target of the last `MATCH` rule (else `"DIRECT"`).
* `providers[].status` ∈ `pending|loading|loaded|failed`; `count` is the loaded
  entry count. `http` providers start `loading` and settle to `loaded`/`failed`
  in the background (a `RULE-SET` rule referencing one exists immediately and
  starts matching as soon as its set lands).
* `geo.status` ∈ `idle|missing|downloading|ready|failed`; each asset's
  `status` ∈ `missing|downloading|ready|unverified|failed|checksum_mismatch|checksum_required`.
* `errors[].code` is `PROXY_RULE_INVALID` (malformed/unknown rule line) or
  `PROXY_GEO_UNAVAILABLE` (a `GEOIP`/`GEOSITE`/`IP-ASN` line whose database is
  not loaded). A malformed line is reported here **and the rest of the config
  still loads** — it never fails the whole call.

`GeoRequest`:
```json
{
  "download": true,
  "bundleDir": "/path/to/bundled/geo",
  "urls": { "country.mmdb": "https://…/country.mmdb" },
  "assets": {
    "country.mmdb": { "url": "https://…/country.mmdb", "sha256": "<hex>" }
  }
}
```
Assets live under `<data_dir>/geo/`. A `bundleDir` is checked first; an existing
file is used only after its sha256 matches the manifest (a file with no manifest
hash is loaded as `unverified`). A download is refused with `checksum_required`
unless a sha256 is supplied — the module never installs unverified geo data.


### 2.11.1 Routing mode (direct / rule / global)

The **runtime tunnel routing mode** — how meow resolves each flow — is a
separate axis from the **run mode** (`core.get_mode` / `core.set_mode`, §2.3.2:
`off`/`vpn`/`lanProxy`). `routing.*` never touches the run mode, and there is
**no name overlap**: the run mode keeps `core.*`.

- `direct` — every flow uses meow's `DIRECT` adapter (no proxying).
- `rule` — the compiled Clash rule set decides (meow's default).
- `global` — every flow uses the `GLOBAL` select group (built by the config
  generator with all proxies as members), so the user picks one outbound for all
  traffic.

| method | request | data |
|---|---|---|
| `routing.get_mode` | *(none)* | `{ "mode": "direct"\|"rule"\|"global", "engineRunning": bool }` |
| `routing.set_mode` | `{ "mode": "direct"\|"rule"\|"global" }` | `{ "mode": "direct"\|"rule"\|"global", "applied": bool, "engineRunning": bool }` |

`routing.get_mode` reads the live tunnel (`tunnel.mode()`). With the engine
stopped it degrades **non-fatally** like `node.list`: `{ "mode": "rule",
"engineRunning": false }` (never a 422).

`routing.set_mode` applies the mode to the running tunnel via meow's
`Tunnel::set_mode`; `applied:true` and `mode` echo the effective mode. With the
engine stopped it is also **non-error**: `{ "mode": <requested>, "applied":
false, "engineRunning": false }`, so a caller can persist the intent and
re-apply after `core.start`. An unknown/missing `mode` is
`INVALID_ARGUMENT` (422) with a clear message, in both states. Only the three
exact lowercase strings are accepted.

### 2.12 `lan.*` — optional LAN listening (Todo 28)

The module can expose one optional, **default-OFF** LAN inbound on
`bindAddress:port` (default `0.0.0.0:1087`). It serves **HTTP**, **SOCKS5** and
**SOCKS4/4a** on the same port.

> **Protocol ownership.** HTTP and SOCKS5 are meow's native handlers
> (`meow_listener::http_proxy::handle_http` / `meow_listener::socks5::handle_socks5`
> — exactly what `MixedListener` dispatches to, driven directly because
> `MixedListener` has no SOCKS4/IP-ACL seam). SOCKS4/4a is a minimal front-end in
> **this adapter**. The IP allow-list is ours too: meow has **no**
> `lan-allowed-ips`. Auth is meow's global `AuthConfig`; loopback is always
> exempt. The module never binds the TUN interface and never claims SOCKS4 via
> meow config.

| method | request | data |
|---|---|---|
| `lan.get` | *(none)* | `{ "config": LanConfig, "warning": Warning\|null }` |
| `lan.set` | `LanConfig` (partial) | `{ "config": LanConfig, "status": LanStatus, "warning": Warning\|null }` |
| `lan.status` | *(none)* | `LanStatus` |

`LanConfig`:
```json
{ "enabled": false, "port": 1087, "bindAddress": "0.0.0.0",
  "auth": { "user": "u", "pass": "p" }, "allowedIps": ["192.168.1.0/24"] }
```
`auth` is `null` when disabled (an explicit JSON `null` clears it);
`allowedIps` is a CIDR allow-list (`[]` = allow any source). Invalid
`bindAddress`/`allowedIps`/`port` or an empty `auth.user`/`auth.pass` returns
`PROXY_LAN_CONFIG_INVALID` (422).

`LanStatus`:
```json
{ "enabled": false, "bound": false, "listening": false,
  "addresses": [], "activeConns": 0, "port": 1087,
  "bindAddress": "0.0.0.0", "engineOnly": false,
  "warning": Warning | null, "config": LanConfig }
```
`addresses` holds the bound endpoint(s) (`["0.0.0.0:1087"]`), `activeConns` is
the live accepted-connection count, and `engineOnly` is `true` when the listener
built its own tunnel (no TUN/VPN engine was live).

`Warning`: `{ "code": "PROXY_LAN_NO_AUTH", "message": string }`.

**Lifecycle & safety.**
* `lan.set {enabled:true}` starts (or restarts) the listener; `{enabled:false}`
  stops it. It is idempotent and serialized on one mutation lane.
* When a TUN/VPN engine is live the listener shares that tunnel; otherwise it
  builds an **engine-only** tunnel (no `VpnService`, no protect hook), so LAN
  sharing works with **or without** the VPN. `core.start` re-reconciles the
  listener onto the new tunnel.
* Enabling without `auth` emits a `proxy.state` warning
  (`reason:"lan.no_auth"`, `warning.code:"PROXY_LAN_NO_AUTH"`); every response
  carries the same `warning`.
* A peer outside `allowedIps` is dropped **before dispatch**. A SOCKS4 peer that
  requires auth but is not exempt (loopback is always exempt) is rejected with
  `0x5B`, because SOCKS4 has no password field.
* The listener runs on a dedicated thread with a bounded runtime
  (`worker_threads(4)`); stop joins it deterministically.

`core.start` / `core.set_mode` with `mode:"lanProxy"` are implemented by the
run-mode state machine (§2.3.2): they require an enabled LAN listener and
otherwise return `PROXY_NO_INBOUND` (422). An enabled LAN listener is bound
standalone (engine-only) by `lan.set`; in `vpn` mode it shares the TUN tunnel,
and in `off` mode a mode switch closes it.


### 2.13 `diagnostics.clash_api.*` — optional loopback Clash controller (Todo 18)

| method | request | data |
|---|---|---|
| `diagnostics.clash_api.start` | `{ "port"?: number }` (0/default = ephemeral) | `ClashApiStatus` |
| `diagnostics.clash_api.stop` | *(none)* | `{ "enabled": false, "wasRunning": bool }` |
| `diagnostics.clash_api.status` | *(none)* | `ClashApiStatus` |

`ClashApiStatus`:
```json
{ "enabled": true, "bound": true, "address": "127.0.0.1:9090",
  "loopbackOnly": true, "port": 9090 }
```

**We do not implement a controller.** meow already ships a mihomo-compatible
REST/WebSocket controller (`meow-api`, coverage table in meow's
`docs/mihomo-api-compatibility.md`); this module only *embeds* it. It is:

* **OFF by default** — nothing starts at `create`/`core.start`; a developer must
  call `diagnostics.clash_api.start`.
* **Loopback only** — the bind host is a hard-coded `127.0.0.1` literal, never
  `0.0.0.0` and never caller-supplied. `address` always begins `127.0.0.1:`.
* **Secret-authenticated** — a fresh 128-bit UUIDv4 secret is generated per run
  and enforced by meow's `require_auth` (`Authorization: Bearer <secret>`). The
  secret is **never** returned by any method, never emitted as an event, and
  never written to a log line. For on-device diagnostics it is written, mode
  `0600`, to the app-private file `<data_dir>/.clash_api_secret`; there is no
  envelope method that reads it back.
* **Bound to the live engine** — `start` requires a running tunnel
  (`core.start`) or returns `PROXY_NOT_CONFIGURED` (409); `core.stop`,
  `core.restart`, `destroy`, and `shutdown` stop it. A failure to bind/spawn is
  `PROXY_CLASH_API_FAILED` (500).

This exists purely for diagnostics and third-party panels. **Dart/Flutter never
calls this HTTP API for normal operation**; the UI reads state through the
envelope (`core.*`, `stats.*`, `conn.*`) and module events.

### 2.14 `requests.*` — per-request timeline (Todo 5)

| method | request | data |
|---|---|---|
| `requests.get` | `{ "cursor"?: recordId, "limit"?: 256, "filter"?: { "domain"?: string, "uid"?: number, "network"?: string, "outbound"?: string, "sinceMs"?: number, "untilMs"?: number } }` | `RequestPage` |
| `requests.reset` | *(none)* | `{ "ok": true, "cleared": 0 }` |

`RequestRecord`:
```json
{ "recordId": 1, "connId": "uuid", "openTsMs": 0, "closeTsMs": null,
  "durationMs": null, "domain": "example.com", "domainKnown": true,
  "dstIp": "1.2.3.4", "dstPort": 443, "src": "10.0.0.2:40000",
  "network": "tcp", "uid": null, "packages": [], "uidState": "unknown",
  "rule": "MATCH", "rulePayload": "", "outbound": "DIRECT",
  "uploadBytes": 0, "downloadBytes": 0, "closeReason": "open" }
```

| field | type | notes |
|---|---|---|
| `recordId` | u64 | monotonic, never reused; the cursor key |
| `connId` | string | meow connection id; **not unique** over time |
| `openTsMs` | u64 | flow start (meow) |
| `closeTsMs` | u64? | **approximate** (sampling tick); `null` while open |
| `durationMs` | u64? | **approximate** `closeTsMs - openTsMs`; `null` while open |
| `domain` | string | attributed domain, or the target IP when unknown |
| `domainKnown` | bool | `false` → `domain` holds the target IP |
| `dstIp` | string | bare IP (IPv6 without brackets) |
| `dstPort` | number | destination port |
| `src` | string | `ip:port` |
| `network` | string | `"tcp"` / `"udp"` (production capture is TCP-only, §2.10) |
| `uid` | number? | owning Android UID; `null` when unknown |
| `packages` | string[] | packages for `uid` |
| `uidState` | string | `"known"` / `"pending"` / `"unknown"` |
| `rule` / `rulePayload` / `outbound` | string | matched rule and outbound |
| `uploadBytes` / `downloadBytes` | u64 | flow byte counters |
| `closeReason` | string | `"open"` / `"closed"` / `"stale"` |

`RequestPage`:
```json
{ "records": [RequestRecord], "nextCursor": 0, "firstCursor": 0,
  "retained": 0, "capacity": 4096, "dropped": 0, "evicted": 0,
  "windowStartMs": 0 }
```

**Pull-based.** `requests.get` is the primary, pull-based path over the bounded
in-memory ring (`REQUEST_RING_CAP = 4096`); the host event ring is never fed
per-request. `cursor` is a `recordId`: only records with `recordId > cursor` are
returned, ordered by `openTsMs` descending, ties broken by `recordId` ascending.
A `cursor` below `firstCursor` means records were evicted; `nextCursor` is the
high-water mark and is never reclaimed by eviction or `requests.reset`.
`closeTsMs`/`durationMs` are derived from the sampling tick and are therefore
**approximate**. Filters: `domain` is a case-sensitive substring,
`network`/`outbound` are exact, and `sinceMs`/`untilMs` bound `openTsMs`
inclusively. `requests.reset` clears the in-memory ring (the cursor stays
monotonic). Both require a live instance (structured `INSTANCE_NOT_FOUND`
otherwise), never `METHOD_NOT_FOUND`.

## 3. Events (module → host)

Emitted through the ABI `emit_event` channel. Payload is the JSON below; the Dart
side filters on the `proxy.` prefix. `instanceId` is always present.

| event | payload schema |
|---|---|
| `proxy.state` | `{ "state":"stopped"\|"starting"\|"running"\|"stopping", "mode":"off"\|"vpn"\|"lanProxy", "reason"?: string, "target"?: "off"\|"vpn"\|"lanProxy", "error"?: { "code": string, "message": string }, "health"?: { "alive": bool, "generation": number, "restarts": number, "consecutiveFailures": number, "lastError": string\|null, "backoffMs": number }, "source"?: string }` — `source:"kotlin"` marks a host-injected VpnService lifecycle event (Todo 24); a mode switch emits `stopping`/`starting` progress with `reason:"mode.switch"` and `target` (Todo 29) |
| `proxy.mode` | `{ "mode":"off"\|"vpn"\|"lanProxy", "previous": string, "phase": "active" }` — emitted once the target mode is fully up (Todo 29) |
| `proxy.node.delay` | `{ "group": string, "node": string, "delayMs": 123, "error"?: string }` |
| `proxy.stats` | `{ "uploadBytes":0, "downloadBytes":0, "activeConns":0, "upBps":0, "downBps":0, "domainCount":0, "capacity":2048, "topDomains":[DomainStat] }` — **throttled to at most one event per second** (Todo 16); pull `stats.traffic.get` for on-demand reads |
| `proxy.request` | `{ "seq": 0, "count": 0, "tsMs": 0 }` — **payload-free dirty signal** for the per-request timeline (Todo 6). Emitted **only by `requests::tick`**, throttled to at most one event per second and only when records were created/changed since the previous emit; `seq` is monotonic, `count` is the number of new/changed records since the previous emit. A client reacts by pulling `requests.get` (§2.14); no per-record data is ever streamed (module event ring holds only 100 entries, `event_bridge.rs:21`). |
| `proxy.subscription.updated` | `{ "profileId": string, "nodeCount": 0, "traffic": { "uploadBytes":0, "downloadBytes":0, "totalBytes":0, "usedBytes":0 }, "expireAtMs": 0, "lastUpdatedAtMs"?: 0, "intervalMs"?: 0, "nextRefreshAtMs"?: 0 }` |
| `proxy.subscription.progress` | `{ "profileId": string, "phase": "fetch"\|"persist", "state": "started"\|"succeeded"\|"failed", "attempts": 0 }` — one `started` per refresh attempt and one terminal `succeeded`/`failed` (Todo 14) |
| `proxy.subscription.failed` | `{ "profileId": string, "attempts": 0, "consecutiveFailures": 0, "lastAttemptMs": 0, "nextRefreshAtMs": 0, "error": { "code": string, "message": string } }` — the previous profile is preserved and the next attempt is bounded by the backoff (Todo 14) |
| `proxy.subscription.added` | `{ "profileId": string, "name": string }` |
| `proxy.subscription.removed` | `{ "profileId": string }` |
| `proxy.conn` | `{ "action":"close"\|"close_all", "id"?: string, "domain"?: string, "outbound"?: string, "uploadBytes"?:0, "downloadBytes"?:0, "closed"?: number }` — emitted once per explicit `conn.close` (action `close`) / `conn.close_all` (action `close_all`, carries `closed`); the steady open/close stream is **not** streamed per connection (the module event ring holds only 100 — `event_bridge.rs:21`; the host task-stream ring's 128 is a separate channel — `task_bridge.rs:65`) — read the throttled `proxy.stats` snapshot and `log.get` instead (Todo 17) |
| `proxy.dns` | `DnsQueryRecord` (see §2.7) — one record per DNS query answered by the TUN DNS hijack; carries the domain→IP mapping for the Todo 16 domain-statistics path (Todo 8; Todo 15/16 consume it). |
| `proxy.tun.released` | `{ "fd": 123 }` — TUN read loop stopped and its thread joined; the host may clear its cached fd and Kotlin may close the PFD (Todo 6). Host-internal control event; Dart may ignore it. |
| `proxy.config.applied` | `{ "profileId": string, "hash": string, "template": string }` — `config.apply` hot-applied a new config on the running engine without a process restart (Todo 13). |

> **Not an `emit_event` type: `proxy.log`.** The push log lane is the ABI `log`
> callback captured at register (LogBridge → `LogManager`), **not** the event
> channel; there is no `proxy.log` `emit_event` payload. Structured variants are
> delivered on that same callback as `proxy.conn {json}` and
> `proxy.dns.query|failure {json}` lines. Pull with `log.get` (§2.8) instead.
> The Dart event registry therefore excludes `proxy.log` even though the log
> records themselves are typed (`LogRecord`).

## 4. Host → module events (`on_event`)

| kind | payload | meaning |
|---|---|---|
| `config.changed` | `{ "key": string, "value": any }` | config hot-reload (e.g. `proxy.mode`) |
| `db.changed` | `{ "type": string, "data": any }` | data-store change |
| `module.lifecycle` | `{ "module": string, "lifecycle": string }` | module up/down |
| `vpn.stop` | `{}` | host/Kotlin-initiated teardown: stop the TUN reader loop **without** a supervisor restart (Todo 24). The host broadcasts it from `nativeStopTunnel` and waits (bounded) for `proxy.tun.released` before Kotlin closes the PFD. |
| `vpn.network_changed` | `{}` | underlying network handover (Wi-Fi↔cellular / airplane mode); Kotlin already rebuilt the default interface via `setUnderlyingNetworks(null)` — the datapath keeps running (Todo 24). |
| `proxy.uid.query` | `{ "queries": [ { "recordId": 0, "protocol": "tcp", "srcIp": string, "srcPort": 0, "dstIp": string, "dstPort": 0 } ] }` | **module → host** (this table's only reverse lane): the module asks the host to resolve the Android owner UID for a TCP flow. The host **consumes and drops** it — it is **never** forwarded into the Dart event ring (Todo 11/13). |
| `uid.result` | `{ "results": [ { "recordId": 0, "uid": 0, "packages": [] } ] }` | host → module reply to `proxy.uid.query`, delivered on the module's `on_event` (Todo 11/13). |

## 5. Domain error codes

All use the `gstore_contract` payload (`status`/`code`/`message`). New codes are
registered in `rust/ERROR_CODES.md`.

| code | status | meaning |
|---|---|---|
| `METHOD_NOT_FOUND` | 405 | unknown method (protocol) |
| `INVALID_ARGUMENT` | 422 | bad payload (protocol) |
| `INSTANCE_NOT_FOUND` | 410 | dead instance (protocol) |
| `PROXY_NOT_CONFIGURED` | 409 | engine/tunnel not running when `node.*`/`conn.list` is called (`config.apply` is tolerant offline: it records the profile and returns `applied: false`) |
| `PROXY_TUN_FD_INVALID` | 422 | invalid/closed TUN fd (Todo 6) |
| `PROXY_CONFIG_PROFILE_REQUIRED` | 422 | `config.generate`/`profile.export_clash` with no stored profile and no `profileId`, or an instance with an empty data dir (Todo 13) |
| `PROXY_CONFIG_INVALID` | 422 | config overlay invalid (e.g. `mtu` below 1280) or the generated document failed to parse (Todo 13) |
| `PROXY_CONFIG_NODE_UNSUPPORTED` | — (in-line warning) | a canonical node type the enabled protocol set cannot reconstruct/build; the node is emitted in the YAML but skipped at registry build, without aborting startup (Todo 13) |
| `PROXY_PERMISSION_DENIED` | 403 | VPN consent missing/revoked (Todo 4/24) |
| `PROXY_PROFILE_NOT_FOUND` | 404 | unknown profile id |
| `PROXY_PROFILE_INVALID` | 422 | invalid store request: missing/empty profile, malformed id, duplicate id, bad refresh state (Todo 12) |
| `PROXY_PROFILE_NOT_REFRESHABLE` | 422 | `profile.refresh` on a profile whose source is not a URL (text/link origin) (Todo 12) |
| `PROXY_PROFILE_REFRESH_BACKOFF` | 507 | a non-forced `profile.refresh` inside the bounded failure-backoff window (30s→6h exponential); `force: true` bypasses it (Todo 14) |
| `PROXY_PROFILE_SCHEMA_UNSUPPORTED` | 422 | on-disk profile schema is newer than this module supports (Todo 12) |
| `PROXY_PROFILE_TOO_LARGE` | 507 | profile/index payload exceeds the hard cap, too many profiles, or too many nodes (Todo 12) |
| `PROXY_PROFILE_STORE_FAILED` | 500 | profile store I/O/atomic-write failure (Todo 12) |
| `PROXY_PROFILE_CORRUPT` | —（warning）/ 500 on `get` | a payload/index file is unparseable; `profile.list` skips it and reports a warning, `profile.get` returns 500 (Todo 12) |
| `PROXY_PROFILE_MISSING` | —（warning） | the index references a payload file that no longer exists; `profile.list` warns (Todo 12) |
| `PROXY_NODE_NOT_FOUND` | 404 | unknown node/group; also a declared group cascade-dropped at registry build when a sibling dependency is unbuildable (see §2.6, §11.2) |
| `PROXY_SUB_URL_INVALID` | 422 | subscription URL failed validation: non-`http(s)` scheme (`file://`/`ftp://`/…), unparseable URL, or no host (Todo 11) |
| `PROXY_SUB_SSRF_BLOCKED` | 422 | user-supplied subscription URL targets a loopback/private/link-local/CGNAT address (SSRF guard) (Todo 11) |
| `PROXY_SUB_FETCH_FAILED` | 500 | subscription fetch failed: connect/read/TLS error, non-2xx status, redirect without `Location`, too many redirects, or unsupported `Content-Encoding` (Todo 11) |
| `PROXY_SUB_TOO_LARGE` | 507 | subscription body/text/link exceeds the hard cap, or declares a `Content-Length` above it, or exceeds the node-count limit (Todo 11) |
| `PROXY_SUB_FORMAT_UNKNOWN` | 422 | body is not Clash YAML, base64 URI list, or a plain URI list (Todo 11) |
| `PROXY_SUB_PARSE_FAILED` | 422 | detected format failed to parse (malformed YAML, non-UTF-8 body) (Todo 11) |
| `PROXY_SUB_NODE_INVALID` | 422 | a share link is malformed or lacks a required field (server/port/secret, external SIP003 plugin) (Todo 11) |
| `PROXY_SUB_SCHEME_UNSUPPORTED` | 422 | share-link scheme is not in the supported set (Todo 11) |
| `PROXY_SUB_NO_NODES` | 422 | the subscription parsed but contained no importable nodes (Todo 11) |
| `PROXY_ENGINE_START_FAILED` | 500 | meow engine failed to start |
| `PROXY_LAN_CONFIG_INVALID` | 422 | `lan.set` payload invalid: bad `bindAddress`/`allowedIps` CIDR/`port`, or empty `auth` user/pass; also a listener bind failure (Todo 28) |
| `PROXY_LAN_DISABLED` | 422 | LAN requested while disabled (Todo 28). `StatusCode` has no 409; 422 is the domain-error convention here |
| `PROXY_NO_INBOUND` | 422 | `lanProxy` selected with no enabled LAN listener (Todo 29) |
| `PROXY_MODE_INVALID` | 422 | `core.set_mode`/`core.start` got an unknown `mode` (Todo 29) |
| `PROXY_PROTECT_FAILED` | 500 | host `protect_fd(fd)` returned non-zero; the dial is aborted so an unprotected socket never reaches the network (Todo 7) |
| `PROXY_DNS_CONFIG_INVALID` | 422 | invalid DNS config: nameserver/DoH/DoT URL parse failure, bad fake-IP range, empty nameserver set (Todo 8) |
| `PROXY_DNS_BOOTSTRAP_FAILED` | 500 | DNS bootstrap / encrypted-upstream construction failed (422 when a `default-nameserver` is not plain) (Todo 8) |
| `PROXY_DNS_TIMEOUT` | 504 | DNS query produced no answer (unreachable upstream, no fallback); a `proxy.dns.failure` record is logged first (Todo 8) |
| `PROXY_LOG_LEVEL_INVALID` | 422 | `log.set_level` / `log.get` received an unknown level (expected `debug\|info\|warn\|error`) (Todo 15) |
| `PROXY_STATS_SORT_INVALID` | 422 | `stats.domain.get` received an unknown sort key (expected `bytes\|connections\|lastSeen\|domain`) (Todo 16) |
| `PROXY_CONN_NOT_FOUND` | 404 | `conn.close` was given a UUID this module has never tracked (not live and not in the recently-closed tombstone) (Todo 17) |
| `PROXY_CLASH_API_FAILED` | 500 | `diagnostics.clash_api.start` could not bind `127.0.0.1:<port>` or spawn its runtime/thread (Todo 18) |
| `PROXY_DATAPLANE_DEAD` | — (supervisor event) | a TUN worker (reader/egress/ingress) ended or panicked while the tunnel was up; reported as a structured `proxy.state` `error.code` with the verbatim reason, then the loop restarts with bounded backoff (Todo 24) |

## 6. Module distribution decision (state it now)

**Decision: `proxy` is a downloadable module (GitHub Release asset consumed by
`ModuleBootstrap`) and is NOT bundled in either the full or the slim APK in this
todo.** `scripts/ci/assert_apk_module_payload.sh` enforces this with a negative
assertion for `libgstore_mod_proxy.so`; Todo 25 owns any later flip to bundled
distribution (and must update this section plus the APK payload assertion).

> **⚠ TEMPORARY REVERSAL (debug/verification builds only).** The decision above is
> **temporarily overridden**: `proxy` is now bundled into the **full** APK by
> default — its `.so` is staged in `android/app/src/main/jniLibs/<abi>/` for all
> four ABIs (alongside `libc++_shared.so`), it is listed in
> `assets/app/modules_builtin.json`, and `scripts/ci/assert_apk_module_payload.sh`
> positively requires `libgstore_mod_proxy.so` in the full package (the
> download-only negative assertion is removed). The **slim** package still
> excludes all `libgstore_mod_*.so`; `libc++_shared.so` ships in both packages
> because proxy's `DT_NEEDED` names it.
>
> **To revert to the download-only decision:** remove `proxy` from `MODULES` in
> `scripts/ci/assert_apk_module_payload.sh` and restore the
> `DOWNLOAD_ONLY_MODULES=(proxy)` negative assertion; in
> `scripts/ci/assert_proxy_module_artifacts.sh` flip the `modules_builtin.json`
> and `jniLibs` checks back to "must NOT contain"; drop
> `libgstore_mod_proxy.so` from `android/app/src/main/jniLibs/<abi>/`; and
> regenerate `modules.json` / `modules_builtin.json`. Both CI scripts carry a
> `TEMPORARY` header note marking these exact reversals.

Rationale and budgets versus the current `~45 MB` arm64 baseline (per
`rust/ARCHITECTURE.md` P0). Sizes below are the **ABI-complete** release builds
(`./build_android_rust.sh --module gstore_mod_proxy`, measured in Todo 2):

| item | value |
|---|---|
| arm64-v8a release `.so` | **12,847,984 B (~12.25 MiB)** — Todo 25 final (`strip=true`, `panic=unwind`, `lto`, `opt-level="z"`) |
| armeabi-v7a | **8,386,276 B (~8.00 MiB)** |
| x86_64 | **14,722,056 B (~14.04 MiB)** |
| x86 | **14,778,412 B (~14.09 MiB)** |
| **Δ full APK, arm64-v8a if bundled** | **+~12.25 MiB (~+27 % over the 45 MB P0 baseline)** — the Todo 2 `+~1.25 MiB` estimate is stale; the module now carries the full meow tunnel/rule/DNS/geo/runtime/`rusqlite` graph. A bundled arm64 APK would grow materially, which is why the download-only decision stands |
| **Δ full APK, all four ABIs if bundled** | **+~50.7 MiB** across all ABIs (sum of the four `.so`) |
| slim APK | 0 (downloaded on first use, verified by sha256 against `modules.json`) |
| shipped ABIs (built + manifest) | **arm64-v8a, armeabi-v7a, x86, x86_64** (all four build; manifest carries all four) |

The Todo 1 spike measured 933,992 B for arm64 before the `gstore_contract` ABI
landed; the +~0.35 MiB delta is `gstore_contract` (prost + ed25519 + serde). Both
figures are far under the budget, so the decision is unchanged.

Notes:
- `libc++_shared.so` (BoringSSL runtime) already ships in the APK, so the module adds
  no extra runtime dependency beyond its own `.so`.
- `DT_NEEDED` is Android-system-only (`libc.so`, `libdl.so`, `libm.so`,
  `libc++_shared.so`) on all four ABIs; no host-only libraries and no
  `libgstore_*.so` coupling. Enforced by
  `scripts/ci/assert_proxy_module_artifacts.sh` (allow-list + 16 KB `PT_LOAD`
  alignment + stripped/unwind + manifest naming/sha256).
- This decision is re-validated in Todo 25 (packaging/manifest/slim exclusion); any
  flip to "bundled by default" must update this section and the APK payload assertions
  in the same change.

## 7. TUN datapath decisions (Todo 6)

### 7.1 fd ownership & teardown (pinned)

- Kotlin owns the `ParcelFileDescriptor`; it passes only `pfd.fd` (`nativeSetTunFd`).
- The module `dup()`s it, sets `O_NONBLOCK` on the duplicate, and never closes the
  host fd. `O_NONBLOCK` is a *file status* flag shared by the description, so it is
  also visible through the host fd (same as `madeye/meow`'s `tun2socks.rs`).
- Exactly **one** reader exists: module state holds at most one `ActiveLoop`;
  `core.start` is idempotent while running and `tun.set_fd` fully joins an existing
  loop before replacing its fd.
- Teardown order: `core.stop` signals the loop → aborts reader/ingress/egress tasks →
  joins the dedicated thread → waits for lwIP `core_done` → emits `proxy.tun.released`
  (host clears its cache) → Kotlin `nativeClear()` + `ParcelFileDescriptor.close()`.
- Runtime: one bounded `new_multi_thread().worker_threads(4)` per loop, created inside
  the dedicated thread; the `NetStack` is built there so meow's `tokio::spawn` uses
  `Handle::current()`. Never `Runtime::new()` / CPU-default workers (Android SIGSEGV).

### 7.2 Host → module fd delivery (recorded design)

`nativeSetTunFd` stores the fd and calls the loaded `proxy` module's `tun.set_fd`
(plain `call`, no new ABI slot). If `proxy` is not mounted yet the fd stays in the
host and is flushed by `ModuleManager::register_inner` when `proxy` registers. This
is order-independent and needs no `gstore_contract` change.

### 7.3 Addressing / routes / MTU / UDP

- **IPv4 + IPv6 dual stack**: the loop is version-agnostic (shuttles raw IP frames);
  `meow_lwip::NetStack` is dual-stack. Kotlin defaults (unchanged by this todo):
  addresses `10.10.0.2/32` + `fd00:1:...:1/128`, routes `0.0.0.0/0` + `::/0`.
- **MTU**: Kotlin defaults to 1500 (`DEFAULT_MTU`); the reader buffer is 65535 to
  cover any MTU/headroom.
- **UDP forwarding (DNS + QUIC)**: UDP frames enter the netstack and arrive on the
  `UdpSocket`; DNS hijack/fake-IP (Todo 8) and QUIC/TCP flow dispatch (Todo 7) consume
  them. Todo 6 keeps the `TcpListener`/`UdpSocket` handles alive; it does not route.

### 7.4 `VpnService.Builder` decisions (Kotlin; changes deferred to Todos 24/29)

| Builder call | Decision | Current Kotlin | Action |
|---|---|---|---|
| `setBlocking` | **Leave default (blocking)**. The Rust side sets `O_NONBLOCK` on its dup; Android has no `setBlocking` builder method anyway (blocking mode is the default; `VpnService` fds are read non-blocking by consumers). | not called | none |
| `allowFamily(AF_INET/AF_INET6)` | **Add both** explicitly on a future pass so the tunnel is provably dual-stack even if `addAddress` list changes to a single family. Not required for correctness today because both families are configured. | not called | Todo 24/29 |
| `setMetered(metered)` | **Respect the config flag** (default `false` = unmetered). Already implemented. | `setMetered(cfg.metered)` (API 29+) | none |
| `setUnderlyingNetworks` | **Leave default** (system default network) for Todo 6. A later pass may pass the active network after `ConnectivityManager` tracking so the tunnel follows Wi-Fi/cellular handover. | not called | Todo 24/29 |
| `addAllowedApplication` / `addDisallowedApplication` | allow-list vs disallow-list (mutually exclusive); full-tunnel uses neither and relies on `protect_fd` to avoid the app loop. | implemented | none |

All on-device VpnService paths remain **UNVERIFIED** (no adb device); the Linux
loopback harness proves the fd/thread/teardown mechanics.

## 8. Outbound-socket protection & flow dispatch (Todo 7)

### 8.1 One protector for every outbound socket

At engine init (`core.start` → TUN loop startup) the module installs the
host-injected `entry.protect_fd` as meow's global `SocketProtector`
(`meow_common::set_socket_protector`, Android-only API). meow then calls it
before **every** outbound `connect()`/`bind()` on the paths
`meow_common::connect_tcp` / `connect_tcp_host` / `bind_udp`, which every proxy
adapter, the DIRECT adapter, and the DNS subsystem use. Teardown calls
`clear_socket_protector()` so no stale hook survives a stop/restart.

Hostname resolution is covered separately by the cross-platform
`HostResolver` hook: the module installs `meow_dns::ResolverHostHook` over the
tunnel resolver, so `connect_tcp_host` never falls back to libc `getaddrinfo`
(whose own DNS sockets would be unprotected and loop through the VPN). Both
hooks are installed together at init and cleared together at teardown.

`protect_fd` returning non-zero aborts the dial with `PROXY_PROTECT_FAILED`
(500); the socket is dropped before any traffic, so a socket cannot silently
skip protection.

### 8.2 Flow dispatch (Todo 7)

| netstack handle | dispatch |
|---|---|
| `meow_lwip::TcpListener` accept stream | each `(TcpStream, src, dst)` is wrapped in a `ProxyConn` (`Mutex<meow_lwip::TcpStream>`, `ConnType::Tun`) and handed to `meow_tunnel::tcp::handle_tcp`. |
| `meow_lwip::UdpSocket` receive stream | each `(data, src, dst)` becomes `Metadata { network: Udp, conn_type: Tun }` and is handed to `meow_tunnel::udp::handle_udp`. |

The engine currently runs with an empty route table (meow falls back to its
built-in DIRECT adapter); Todos 8/9 install the DNS subsystem, proxy list and
rule set. UDP upstream→tun reply pumping and the DNS hijack/snoop path are
owned by Todo 8 (the `UdpSocket` send half is retained alive for it).

### 8.3 Raw-socket audit (required)

The module adds **no** raw outbound client: it has no `reqwest`/`hyper`/`ureq`
dependency and no direct `TcpStream::connect` / `UdpSocket::bind` call. Its own
outbound constructors — `protect::connect_tcp` / `protect::bind_udp` — apply the
protector before traffic and are the only sanctioned way for this crate to open
a socket (subscription/geo fetchers in later todos must use meow's
protect-aware transport or these helpers, never a raw HTTP client).

Note on the wider app: the host/Flutter process is the VPN app, so its normal
network traffic is *intentionally* tunneled; only the proxy's own upstream
sockets must bypass the tunnel, and those go through meow's protected path.
`addDisallowedApplication(self)` is deliberately **not** used for loop
avoidance (see §7.4) — `protect_fd` is the sole mechanism.

### 8.4 Verification status

The protect wrapper, its count instrumentation, and the failure path are proven
on the host (`cargo test -p gstore_mod_proxy`, `protect::tests`). meow's
`set_socket_protector` is compiled only on Android, so the **actual meow-hook
integration on device is UNVERIFIED** (no adb device attached).

## 9. DNS subsystem decisions (Todo 8)

### 9.1 One resolver, shared by tunnel + hijack

`core.start` builds the DNS engine (`crate::dns::ensure_engine`) and hands its
`Arc<meow_dns::Resolver>` to both the meow tunnel (`Tunnel::new`) and the TUN
UDP:53 hijack. `meow_dns::ResolverHostHook` is installed over the same resolver,
so proxy-server hostnames and DoH/DoT upstream hostnames never hit libc
`getaddrinfo`. `dns.set` rebuilds the engine; DNS queries use it immediately,
while the already-built tunnel keeps the previous resolver until `core.restart`
(the tunnel's resolver is only used for rule/host matching, not for the
nameserver list).

### 9.2 (a) Bootstrap resolver outside the tunnel + `protect()`

`defaultNameservers` (Clash `default-nameserver`) is the bootstrap list for the
encrypted upstreams' own hostnames. meow requires these to be **plain** entries
(`udp://`/`tcp://`/bare IP); a DoH/DoT bootstrap entry is rejected with
`PROXY_DNS_BOOTSTRAP_FAILED` (422) because it would recurse. Every DNS socket —
bootstrap UDP/TCP, DoH, DoT — is created by the module's
`dns::ProtectedSocketFactory` (installed via `meow_dns::set_socket_factory`),
which dials through `crate::protect::{connect_tcp,bind_udp}`. On device that
applies the host `protect_fd` before the first packet, so the bootstrap/DoH
socket bypasses the VPN; on host tests the same constructor path is exercised
(no protector installed ⇒ no-op). This is what breaks the full-tunnel fake-IP
self-recursion: the proxy server's own hostname (and any DoH upstream hostname)
is resolved by the bootstrap socket that is explicitly *outside* the tunnel.

Loopback upstreams (`127.0.0.0/8`) are bound directly by meow (loopback is never
routed into the TUN) and need no protect; that is the only unprotected DNS path
and it is loopback-only.

### 9.3 (b) Android Private DNS / DoT (port 853) — **UNVERIFIED on device**

Android's Private DNS (DoT) is a **system** resolver setting. With a full-tunnel
VpnService, the OS opens TCP/853 to the configured DoT server; that connection
enters the TUN as an ordinary TCP flow and is handled by meow, **not** by our
UDP:53 hijack. Consequence: fake-IP synthesis and the `proxy.dns` log record do
**not** see Private-DNS queries — apps using a system-wide DoT resolver bypass
them. We do **not** terminate TLS on 853 (that would require MITM), so the
handling is explicit and documented, not code:

- Private DNS `Off`/`Automatic` (or per-app DNS via the app's own UDP:53) ⇒
  queries hit the TUN DNS hijack and get fake-IP + logging.
- Private DNS `On <hostname>` ⇒ queries are routed as TCP/853 flows through the
  tunnel; fake-IP does not apply. The product/UX must surface this (Todo 24/29).
- All on-device Private-DNS behaviour is **UNVERIFIED — no adb device**.

### 9.4 (c) IPv6-only / NAT64 / DNS64

- The fake-IP v4 pool default is `198.18.0.0/16` (Clash default), which is
  reserved benchmarking space and never overlaps a real/NAT64 prefix. Keep any
  configured `fakeIpRange` out of the real network range and out of
  `64:ff9b::/96` (NAT64) / `64:ff9b:1::/48`.
- A fake IPv4 answer still works on an IPv6-only access network: the address is
  inside the pool, the TUN route captures it, and meow dials the real host over
  whatever the underlying network provides. fake-IP does **not** depend on the
  access network having IPv4.
- We do **not** synthesise fake AAAA by default (`fakeIpRangeV6` is `null`), so
  on a DNS64/NAT64 network the client still receives the real AAAA (or the
  DNS64-synthesised AAAA), which is routed through the tunnel normally. If a
  v6 fake pool is configured, `meow`'s `ipv6hint` stripping keeps HTTP/3 from
  reading a real origin IP out of HTTPS/SVCB answers (`DnsServer` handles it).
- `ipv6: false` makes AAAA queries answer empty NOERROR (no upstream wait).

### 9.5 (d) fake-IP vs redir-host → the domain-statistics feed

- **fake-IP** knows the domain at query time: the answer is synthesised from the
  pool, so the mapping is recorded immediately (`domain → fakeIp`, `fake:true`).
  This is the reliable feed for Todo 16 and for meow's reverse lookup.
- **redir-host** (`DnsMode::Mapping`) only learns the domain when the query is
  seen by our DNS server; meow's DNS cache then holds `domain → realIp`. A flow
  dialed from a cached/OS answer that we never saw is recovered on TCP by
  **SNI / HTTP Host sniffing**, now enabled in the TUN dispatch path before every
  connection (§9.8). Sniffing is best-effort: it still fails for **ECH/ESNI**,
  for **QUIC/HTTP3 (UDP)**, and for ports outside the sniff list. For those, the
  domain is unavailable: Todo 16 records the flow under the **IP** and marks the
  record (`domainKnown: false`) rather than inventing a domain.
  `DnsMapping.domainKnown` carries that flag for the records we do produce. The
  reverse-lookup fallback in §2.9 / §15 then consults the DNS mapping ring first
  and only falls back to the IP when both sources miss.
- Todo 16 therefore prefers fake-IP mode for domain attribution; redir-host
  plus sniffing is best-effort and tolerates missing domains.

### 9.6 Query logging

Every query answered by the hijack flows through `DnsEngine::query`, which emits:
a `proxy.dns.query` (success) or `proxy.dns.failure` (failure) JSON line via the
module log path, and a `proxy.dns` event with the same payload (domain, qtype,
rcode, answer IPs, resolver label, latency ms). A bounded ring (256 records) and
a bounded mapping ring (1024) are exposed through `dns.get` so Todo 15/16 can
consume them until Todo 15 owns the log ring buffer.

### 9.7 Verification status

`cargo test -p gstore_mod_proxy` proves: fake-IP allocation/reverse-lookup,
fake-IP query logging + mapping, cache clear, a fixture query resolved via a stub
upstream, an unreachable primary + fallback, a structured timeout without
fallback, `dns.get`/`dns.set`/`dns.clear_cache` over the C ABI, and the DoH URL
being routed to a stub endpoint (fails closed on the untrusted self-signed stub:
see below). The real DoH/DoT TLS exchange and all on-device Private-DNS
behaviour are **UNVERIFIED** (no adb device; meow's own DoH/DoT integration tests
are network-gated `#[ignore]`).

**Offline DoH-stub limitation (recorded).** meow's DoH client hardcodes
certificate verification against the Mozilla roots and exposes no
`additional_roots` / `skip_cert_verify` hook (`meow-dns/src/client.rs:1178`
builds a fixed `TlsConfig`); a local self-signed DoH stub can therefore never be
trusted without patching/forking meow, which this task forbids. The test proves
the `https://` URL is parsed, routed through the DoH transport and our protected
socket factory, and fails closed (structured `PROXY_DNS_TIMEOUT`, no hang);
end-to-end DoH resolution is covered by meow's network-gated integration tests.

### 9.8 (f) TCP SNI / HTTP Host sniffing — best-effort second domain source

`fake-IP` (§9.5) attributes a domain only when our UDP:53 hijack saw the query.
DoH, Android Private DNS (`DoT`, TCP/853 — §9.3), cached answers and plain-IP
dials never reach the hijack, so their TCP flows used to be recorded under the
destination IP with `domainKnown:false`. `crate::sniff` closes that gap for TCP:

- The TCP accept loop in `dispatch::spawn` builds **one** `sniff::Sniffer`
  (`SnifferConfig::default()` with `enable:true`) and shares it across flows. For
  every accepted connection it prefetches the client's first flight and tries
  `meow_common::sniffer::{sniff_tls,sniff_http}` before handing the flow to the
  tunnel.
- **Prefetch-and-replay.** meow's own `SnifferRuntime` uses
  `tokio::net::TcpStream::peek`, which our channel-based `meow_lwip::TcpStream`
  does not offer. Instead the module reads the first flight into a `Vec<u8>` and
  replays it verbatim through `sniff::PrefixedStream` before the live stream, so
  the tunnel observes an unmodified byte sequence (no drop, no reorder).
- **Bounds.** A single overall deadline of `100 ms` (`SnifferConfig::timeout`),
  at most `8192` bytes buffered, and early stop once a full TLS record is
  buffered (`buf.len() >= 5 + record_len`) or an HTTP header terminator
  (`\r\n\r\n`) is seen.
- **Ports.** `443/8443` are parsed as TLS, `80/8080/8880` as HTTP
  (`SnifferConfig::default()`). A disabled sniffer or an off-list port reads
  **nothing** and adds no latency or data consumption (e.g. port 22).
- **Routing is unchanged.** The result is written to `metadata.sniff_host` only.
  `metadata.host` and `override_destination` are **not** touched, so rule
  matching/dialing still targets the original destination; `sniff_host` is a
  display/attribution source (`Metadata::rule_host` prefers it over `host`, and
  `conn.rs` records it as the connection domain). Sniffing is strictly a
  **best-effort second source** that complements fake-IP, not a replacement.
- **Not covered (falls back to the IP with `domainKnown:false`):** ECH/ESNI
  handshakes (no SNI in cleartext), QUIC/HTTP3, which is UDP and deliberately
  **out of scope** here (`handle_udp` is untouched), protocols on ports outside
  the lists above, and non-TLS/non-HTTP payloads.

**Verification.** `cargo test -p gstore_mod_proxy` proves: `PrefixedStream`
replays `prefix + inner` in order; `sniff_prefix` extracts a synthetic TLS SNI
and returns the prefix byte-identical; it extracts an HTTP `Host`; an off-list
port (22) and a disabled sniffer read **nothing**; and a silent client returns
within `timeout + slack` with no host and no panic. All sniffing here is
host-side; on-device dispatch stays **UNVERIFIED** (no adb device).

## 10. Rule engine and routing (Todo 9)

### 10.1 meow owns matching; we own the Clash policy

The module does **not** implement a rule engine. Every non-`RULE-SET` line is
compiled by `meow_config::rule_parser::parse_one_rule_or_subrule` (which
delegates to `meow_rules::parse_rule`), `RULE-SET` entries are
`meow_rules::RuleSetRule` values over a `meow_rules::RuleSet`, and the compiled
`Vec<Box<dyn Rule>>` is published with `meow_tunnel::Tunnel::update_rules`.
Rule matching, the domain trie/IR (`meow-trie`, `rule_ir`) and `MATCH`
fall-through are entirely meow's.

Supported rule types are therefore meow's full set: `DOMAIN`,
`DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`/`IP-CIDR6`, `GEOIP`/`SRC-GEOIP`,
`GEOSITE`, `PROCESS-NAME`/`PROCESS-PATH`, `DST-PORT`/`SRC-PORT`, `IN-*`,
`NETWORK`, `RULE-SET`, logic (`AND`/`OR`/`NOT`) and `MATCH`.

### 10.2 Where rules enter the tunnel

`dispatch::build_engine` calls `rules::attach_tunnel` after `Tunnel::new`, so the
engine is built with whatever rule set is current (empty until the first
`rules.reload`, which resolves to DIRECT exactly as before). `rules.reload`
recompiles and `update_rules`s the live tunnel; `Dispatcher::shutdown` calls
`rules::detach_tunnel`. `proxy-groups:` are parsed and exposed as
`RulesSnapshot.groups`; a rule whose target is not yet a built route-table entry
is skipped by meow's `target_usable` (mihomo `continue` semantics), so groups and
nodes can be populated later (Todos 10/13) without reimporting the rules.

### 10.3 Lazy rule-providers

`inline` and `file` providers load synchronously on `rules.reload` (fast, local);
`http` providers are loaded on a background thread. Every provider is a
`ProviderSlot` — a live `RuleSet` whose inner set is swapped when the provider
finishes, so a `RULE-SET` rule created at reload time starts matching the moment
its payload lands, with no re-parse. `RulesSnapshot.providers` reports
`pending|loading|loaded|failed` plus entry count/error. Behaviors `domain`,
`ipcidr` and `classical` are delegated to meow's `build_rule_set`.

### 10.4 Geo assets: lazy, checksum-verified, never blocking

Required assets are derived by scanning the config for `GEOIP`/`SRC-GEOIP`
(→ `country.mmdb`), `IP-ASN`/`SRC-IP-ASN` (→ `GeoLite2-ASN.mmdb`) and `GEOSITE`
(→ `geosite.dat`). Files live under `<data_dir>/geo/`.

* An existing/bundled file is used only after its sha256 matches the manifest
  (`geo.assets[file].sha256`); a mismatch yields `checksum_mismatch` and the
  asset is not loaded.
* A missing asset with a sha256 is downloaded on a background thread via
  **meow's protect-aware transport** (`meow_config::internal_http::fetch`, which
  dials through `connect_tcp_host` and therefore the host `SocketProtector`),
  verified against the sha256, and atomically renamed into place. A download
  without a manifest sha256 is refused (`checksum_required`) — unverified geo
  data is never installed. This mirrors the app's sha256 manifest convention
  (`lib/core/rust/ModuleDownloader.dart`, `generate_modules_manifest.sh`).
* `rules.reload` returns immediately with `geo.status = downloading|missing`; the
  compiled rule set is re-published once an asset lands, at which point
  `GEOIP`/`GEOSITE` rules become active. A `GEOIP`/`GEOSITE` line whose DB is not
  yet available is reported as `PROXY_GEO_UNAVAILABLE` while the rest loads.

`CountryIndex`/`AsnIndex`/`GeositeDB` are meow's; the module only builds them from
the verified file.

### 10.5 Malformed rule lines

A line that fails to parse is recorded in `RulesSnapshot.errors` with
`code = PROXY_RULE_INVALID`, its 1-based `lineNumber` and the raw `line` text;
every other line still compiles and is published. An unreadable/unparseable
whole config (bad JSON payload, unreadable `configPath`, invalid YAML) returns a
top-level `PROXY_RULE_INVALID` (422).

### 10.6 Verification status

`cargo test -p gstore_mod_proxy` proves: the fixture rules parse in declaration
order and `rules.get` returns them; each of domain / domain-suffix /
domain-keyword / ip-cidr / dst-port / process-name / rule-set / match matches the
expected metadata; a `DOMAIN-SUFFIX` fixture rule routes the fixture domain to
the named outbound through `Tunnel::resolve_proxy`; inline (domain, ipcidr) and
file (classical) providers load and match; malformed lines are rejected with
`PROXY_RULE_INVALID` naming the line while the rest loads; geo checksum
verification (known sha256 vector, mismatch rejection, download+install under a
local HTTP stub) and the non-blocking `missing`/`checksum_required` statuses; plus
`rules.reload`/`rules.get` over the C ABI.

**UNVERIFIED**: real GeoIP/ASN MMDB and geosite `.dat`/`.mrs` matching (no DB
fixtures are shipped in-tree; the indexes are meow's own, exercised by meow's
tests), real geo CDN downloads, and all on-device routing (no adb device).

## 11. Node/group selection, latency tests, connection tracking (Todo 10)

### 11.1 meow owns the group and statistics machinery

The module implements **no** group engine and **no** second statistics store.
Selection goes through meow's `ProxySelection` on the live group handle
(`Tunnel::proxy(name)` → `proxy.selection()`); url-test/fallback pickers,
per-proxy delay state and provider handling stay in meow. Delay probes use
`meow_proxy::health::{probe_many_bounded_detailed, url_test, probe_and_record}`.
Live connections and byte counters are meow's
`meow_tunnel::statistics::Statistics` (published as `Tunnel::statistics()` /
`TunnelInner.stats`); the module only keeps a bounded projection of it.

### 11.2 What Todo 13 must do to wire proxies/groups

`node.*` and `conn.*` read the **live** registry/statistics, so Todo 13 must
publish proxies/groups into the tunnel after generating the config:

1. Open the persistent store once (the module already does this at `create`
   when `data_dir` is non-empty, but a config generator that runs standalone
   must ensure it): `meow_proxy::SelectorStore::open(<data_dir>/selector.json)`
   — the first `open()` wins the process-global slot, and meow-config's
   `rebuild_from_raw_runtime` reads `SelectorStore::global()` while building
   groups.
2. Build the `HashMap<SmolStr, Arc<dyn Proxy>>` for every leaf node **and**
   group (meow-config's proxy parser does this), then call
   `crate::nodes::install_proxies(&tunnel, map)` (a thin `Tunnel::update_proxies`
   wrapper) or `Tunnel::update_proxies` directly. `rules.reload` only swaps the
   rule set; `update_rules` preserves the current proxies map, so a
   `rules.reload` never loses groups. An engine restart (`core.restart`) builds a
   fresh tunnel, so Todo 13 must re-publish after it.
3. Construct selector/url-test/fallback groups through the store
   (`SelectorGroup::with_store` / `UrlTestGroup::with_store` /
   `FallbackGroup::with_store`) so user picks persist across rebuilds. Groups
   built without a store still select in memory; only persistence is lost.

Until Todo 13 attaches proxies, `node.*`/`conn.list` return
`PROXY_NOT_CONFIGURED` (no live tunnel) or `PROXY_NODE_NOT_FOUND` (empty
registry).

A running engine can also hold a **stale** registry after `profile.refresh` or a
subscription switch: the tunnel keeps the groups installed at the last build, so
a group present in the displayed profile can be absent from the live engine.
Instead of requiring a manual reconnect, the UI re-applies the displayed profile
(`config.apply`) on a divergent node selection to reconcile the live engine;
`refresh_running_registry` hot-installs the rebuilt map without tearing the
dataplane down, while an engine-stopped offline selection is unaffected. Each
build logs its outcome as `proxy: registry groups built=[...] missing=[...]`;
`missing` names declared groups that did not enter the registry because a sibling
group they depend on could not be built, which is the build-time cascade behind
`PROXY_NODE_NOT_FOUND`.

### 11.3 Off-tunnel-loop probes and bounded connection tracking

* Delay probes run on a dedicated process-wide `bounded_runtime()`
  (`worker_threads(4)`), built lazily by `nodes::ops_runtime` — **not** the
  tunnel loop's runtime and never `Runtime::new()`/CPU-default workers. A slow
  or hung probe therefore cannot stall frame I/O. The C ABI `call` thread blocks
  on that runtime only for the duration of the call.
* Probes dial through each adapter's `TcpDialer`, which reaches
  `meow_common::connect_tcp_host`/`connect_tcp` and therefore the host
  `SocketProtector`; they do not open a raw socket.
* The connection projection is rebuilt from meow's live table on each
  `conn.list`, reusing parsed start times, and is capped at 1024
  (`conn.list.capacity`); the oldest live entries are dropped from the view when
  the cap is exceeded. The projection never grows without bound.

### 11.4 Verification status

`cargo test -p gstore_mod_proxy` proves: a selector group's effective outbound
flips on `node.select` and `Tunnel::resolve_proxy` keeps routing to the group; a
selection persists across a group rebuild through the same `SelectorStore`; a
hanging/unreachable node yields a per-node `timeout` result (no error, no panic)
and the probe runtime stays usable across repeated calls; a group's members are
probed once each; `conn.list` returns fixture connections with
src/dst/domain/rule/rulePayload/outbound/startedAtMs/bytes, the projection is
clamped to the cap, closed connections leave it, and `conn.close_all` clears it;
plus the `node.select` → `proxy.state`, `node.delay_test` → `proxy.node.delay`
events and `conn.list`/`conn.close` over the real C ABI.

Todo 17 adds: `conn.list` filtering/pagination (`page_records_filters_and_paginates`),
deterministic order across calls (`sync_order_is_stable_across_calls_for_pagination`),
`conn.close` of a live id then an idempotent re-close then a structured
`PROXY_CONN_NOT_FOUND` for an unknown id (`close_is_idempotent_and_unknown_is_not_found`),
and the same flow over the real C ABI including the `proxy.conn {action:"close"}`
event (`abi_conn_list_filter_pagination_and_close`).

**UNVERIFIED**: real upstream latency (tests use hanging stubs and loopback, no
network); on-device selection/routing (no adb device); UDP connections are not
in `conn.list` (meow tracks UDP in a NAT table with no byte counters).

## 12. Persistent profile store (Todo 12)

### 12.1 Layout and atomicity

`profile.*` persists under the module data directory (`ModuleContext.data_dir`,
i.e. `<app documents>/gstore_mods/proxy/` on Android — see
`lib/core/rust/ModuleContext.dart:53-77`):

```text
<data_dir>/profiles/
  index.json     ProfileIndex: { schemaVersion, revision, nextId, profiles[] }
  <id>.json      StoredProfile: store metadata + the canonical ImportedProfile
```

- The **payload is the source of truth**; `index.json` is an
  enumeration/cache used to allocate ids and list without scanning the
  directory.
- Every write is **atomic**: a sibling temp file (`.name.tmp-<pid>-<seq>`) is
  written, `fsync`ed, then `rename`d over the destination in the same
  directory, then the directory is `fsync`ed best-effort. A concurrent reader
  therefore sees the complete old or complete new file — never a partial one.
  On failure the temp file is removed and the old file is left untouched.
- Writes are serialized by a process-wide store mutex.
- Hard bounds: 4096 profiles, 4096 nodes/profile, 4 MiB index, 32 MiB payload;
  oversized input is `PROXY_PROFILE_TOO_LARGE` (507).

### 12.2 Schema versioning and migration

Current schema is **v2**. A v1 fixture (index with a top-level `version` and a
payload that was the bare `ImportedProfile`) is migrated on read; the next
mutation rewrites it in the v2 wrapper. Migrated fields: `schemaVersion: 2`,
`revision: 1`, `updatedAtMs = createdAtMs`, `refresh: null`, `appBackup: null`,
and `nextId = max(numeric id) + 1`. A `schemaVersion` **newer** than supported
is refused with `PROXY_PROFILE_SCHEMA_UNSUPPORTED` so an old module never
silently truncates newer data.

### 12.3 Stable ordering

`profile.list.profiles` is sorted by the total key
**`(createdAtMs ascending, id ascending)`**, computed from the payload (not
from hash/filesystem iteration order), so the order is identical across
reloads and process restarts.

### 12.4 Credentials / secrets location

`ProxyNode.password` / `ProxyNode.uuid` (and REALITY/obfs secrets) are
credentials. They are written **only** to
`<data_dir>/profiles/<id>.json`, which is inside the app sandbox (app-private
documents directory). The module never copies them to shared storage, to
`cache_dir`, to logs, or to `profile.list` summaries. If the app adds a
backup/restore transport it must treat this directory as sensitive.

### 12.5 App backup/restore hook (explicit, uncoupled)

The store is plain JSON under one directory, and each `StoredProfile` carries an
opaque `appBackup` field preserved verbatim. The app
(`lib/core/service/backup_service.dart` / `lib/core/config/AppConfig.dart`) can
embed the records (or copy the directory) under a key of its choosing. The
module does **not** read, write, version, or depend on the app backup format —
see `profile::APP_BACKUP_HOOK`.

### 12.6 Outcome surface for other todos

- **Todo 13** reads `profile.get(id).profile` to generate the Clash config.
- **Todo 14** wires `profile.refresh`/`profile.refresh_all` to the protect-aware
  importer, emits `proxy.subscription.progress`/`.updated`/`.failed`, and stores
  the per-profile `intervalMs`/`lastUpdatedAtMs`/backoff metadata.
- **Todo 20** consumes `profile.list` summaries (name/userinfo/refresh state +
  scheduling metadata) and calls `profile.refresh`/`profile.refresh_all`/
  `profile.set_schedule`; Dart only decodes/displays.

### 12.7 Verification status

`cargo test -p gstore_mod_proxy` proves: CRUD round-trip surviving a store
reload; stable `(createdAtMs, id)` ordering across reloads; atomic-write
failure (temp/rename) leaving the previous file intact with no temp residue;
a failed create not corrupting the index; v1 → v2 index+payload migration with
`nextId` derivation and on-disk upgrade; a corrupt payload skipped with a
structured warning while valid profiles list; a corrupt index rebuilt from the
payload directory; `profile.refresh` persisting the flag and returning the fetch
spec; and structured errors for unknown/traversal/duplicate ids and a newer
schema. Todo 14 adds: the refresh event sequence
(`progress(started)→progress(succeeded)→updated` on success, `progress(started)→
progress(failed)→failed` on failure) with the previous profile preserved on
failure; bounded backoff refusing a non-forced retry and `force` bypassing it;
and `profile.refresh_all` skipping non-due profiles (`interval`/`backoff`) while
never exceeding the per-call limit. **UNVERIFIED**: on-device storage/`adb`
reload and a real on-device subscription fetch (no device) — the store is
exercised against host temp directories, the refresh success path uses an
injected import, and the failure path uses an SSRF-blocked loopback URL.

## 13. Generated engine config & lifecycle (Todo 13)

### 13.1 We author the template

`config.generate` / `profile.export_clash` always render **our own** controlled
Clash template from the whitelisted canonical model (Todo 11/12) plus
module-owned overlays. Raw provider YAML is never handed to the engine — the
community pitfall is that injected rules/groups in a provider document are
ignored (or worse, a hostile document smuggles configuration in). The provider
document's nodes, `proxy-groups` and `rules:` **are** captured into the
canonical model at import (Todo 11) and re-emitted through this template; every
other key (`dns`, `tun`, `external-controller`, providers, `script`, …) is
dropped.

The document contains exactly:

| block | source |
|---|---|
| `proxies` | stored `ImportedProfile.nodes`, reconstructed field-by-field |
| `proxy-groups` | stored `ImportedProfile.groups` (+ a synthesized `PROXY` select group when absent) |
| `rules` | the `rules` overlay → the profile's captured Clash `rules:` → Todo 9's current rule lines, then a terminal `MATCH` is appended when absent (`MATCH,PROXY` when the profile has nodes, else `MATCH,DIRECT`) |
| `dns` | Todo 8's effective `DnsConfig` (with the request's partial overlay merged) |
| `tun` | `enable: true` + `stack` + `mtu` only |
| `hosts` | Todo 8's static host map (when non-empty) |
| `mode` / `log-level` | fixed (`rule` / `warning`) |

The first non-empty source wins: an explicit `rules` overlay is honoured
verbatim (except for the appended terminal when it is missing), otherwise the
subscription's `rules:` captured at import are used, otherwise the last
`rules.reload` lines. A profile with nodes can therefore never silently fall
back to `MATCH,DIRECT` — the proxy stays selected by default. Profiles stored
before this field existed lack `rules`; `ImportedProfile.rules` is
`#[serde(default)]`, so they still load and fall back to the appended
`MATCH,PROXY` until re-imported.

**Pinned guarantees:**

- `external-controller` and `secret` are **never** emitted. The module runs no
  control server, and a subscription cannot configure a control port/secret.
- `proxy-providers`, `rule-providers`, `script` nodes, and any
  `dns`/`tun`/`external-controller` field from imported content are **not**
  merged: the DNS/tun blocks are module-owned.
- `tun.file-descriptor` is **not** emitted. meow's `RawTun` has no such field;
  generating it would be silently ignored. The fd is injected out-of-band into
  our netstack pump (Todo 6/tun.rs).
- `stack` defaults to `gvisor`; `mtu` defaults to 1500 and must be ≥ 1280
  (matching meow's hard minimum) or `PROXY_CONFIG_INVALID` (422).
- A REALITY VLESS node is always emitted with `tls: true` and a
  `client-fingerprint` (the explicit value wins, else `chrome`). meow
  **hard-errors** on a REALITY node missing either, while mihomo infers both —
  without this default a subscription that omitted the fingerprint would drop
  every REALITY node at registry build.

### 13.2 Registry build & selector persistence

`build_registry` reconstructs meow's `name -> Arc<dyn Proxy>` map: the built-in
`DIRECT`/`REJECT`/`REJECT-DROP` adapters, every leaf node via
`meow_config::proxy_parser::parse_proxy_provider_node` (external SIP003 plugins
rejected), then every group via `parse_proxy_group_lenient_with_store` with a
multi-pass dependency resolver, and finally an auto-created `GLOBAL` selector.
Groups are wired to the process-wide `SelectorStore` opened by
`nodes::ensure_selector_store(<data_dir>/selector.json)` (first `open()` wins),
so user picks persist across rebuilds. A node or group that cannot be built is
reported as a warning and skipped — never fatal.

Protocol features enabled on `meow-config`: `ss`, `trojan`, `vless`,
`vless-vision`, `vmess`, `hysteria2` (plus `http`/`socks5`, which need no
feature). `hysteria2` is implemented in-tree on quiche (QUIC + HTTP/3) built on
the same vendored BoringSSL that `meow-transport` already links
(`boringssl-boring-crate`; no rustls, no second crypto), so a mihomo/Clash
subscription — commonly ~1/3 hysteria2 nodes — now builds all of them. Nodes of
the remaining canonical types (`snell`, `anytls`, `tuic`, `ssr`, `wireguard`)
are still emitted in the YAML but skipped with
`PROXY_CONFIG_NODE_UNSUPPORTED` until their features/dependencies are enabled.

### 13.3 `core.start` step order (pinned)

```
profile.load -> config.generate -> proxy registry -> rules.reload -> dns
             -> tun loop (consumes the already-installed TUN fd last)
```

`core.start` waits (bounded) for the loop to publish the routing engine before
returning `running`, so a subsequent `node.select` sees the live registry.
`core.restart` re-runs the same path on a fresh tunnel (re-publishing proxies);
`config.apply` swaps rules then proxies on the **existing** tunnel.

### 13.4 Verification status

`cargo test -p gstore_mod_proxy` proves: the generated YAML has
`proxies`/`proxy-groups`/`rules`/`dns`/`tun.enable` and none of
`external-controller`/`secret`/`proxy-providers`/`file-descriptor`; the tun
block carries only `stack`/`mtu`; `mtu < 1280` is a structured 422; the registry
builds leaves+groups+built-ins and uses the store; an unsupported node (e.g.
`snell`) is warned and skipped without aborting; an `hysteria2` node is built
into the registry with no `PROXY_CONFIG_NODE_UNSUPPORTED` warning; a REALITY
VLESS node without an explicit fingerprint emits `tls: true` +
`client-fingerprint: chrome` (an explicit fingerprint wins, a non-REALITY node
is unaffected); the rules
pipeline emits the profile's captured `rules:` verbatim, appends `MATCH,PROXY`
for a profile with nodes that has no terminal match, keeps `MATCH,DIRECT` only
for a nodeless profile, lets an explicit overlay win, and round-trips `rules`
through serde and the `ProfileStore`; and the full C-ABI flow (generate →
start → `node.select` → unreachable-node `node.delay_test` → `config.apply`
without a restart → stop) reaches `running`. **UNVERIFIED**: on-device
engine/TUN start (no adb device) — proven against the host socketpair harness
only.

## 14. Logging pipeline (Todo 15)

Two lanes over one bounded, non-blocking sink:

* **Push (host → Dart).** Every record is forwarded through the ABI `log`
  callback captured at register (`gstore_contract::logging` /
  `gstore_host::log_bridge::host_log`) and reaches `LogManager` via the existing
  LogBridge. The module also calls
  `gstore_contract::logging::attach_host_logger` so its own `log::` macros (and
  any dependency log lines) use the same contract path. No second transport is
  introduced.
* **Pull (`log.get`).** The module keeps the last **N = 1000** records in an
  in-memory ring with a **monotonic cursor**; `log.get(sinceCursor, limit,
  level?)` pages through it. The ring is a bounded projection for diagnostics
  and does not duplicate the host's own buffer.

### 14.1 Non-blocking / bounded guarantees

* A push is one `Mutex` + `VecDeque::push_back` (O(1)); no I/O, no `.await`, no
  unbounded growth. It never blocks the TUN read loop or the relay.
* On overflow the **oldest** record is evicted; cursors are never reused.
* A disconnected host sink drops records (counted in `sinkDropped`) and the ring
  keeps serving; a poisoned lock is recovered via `into_inner`. The data plane
  never panics on logging.

### 14.2 Levels

`log.set_level` sets the retention threshold: records below it are dropped at
the source (counted in `dropped`) and never reach the ring or the host. It also
mirrors the level into `log::set_max_level` for the macro path. Levels align
with the host encoding (`0=debug,1=info,2=warn,3=error`). Default is `info`.

### 14.3 Secrets

Records carry only the fields documented in §2.8. There is deliberately no
request/response payload, URL, password, UUID, or PSK field; connection records
are built from meow's public connection metadata only. This is asserted by a
test that serialises a `ConnectionLog` and rejects secret-shaped keys.

### 14.4 Verification status

`cargo test -p gstore_mod_proxy` proves: ring overflow keeps the last N with
monotonic cursors; `log.get` paginates by cursor and a drained page does not
rewind; `log.set_level` filters retention and `log.get(level=…)`; a forced sink
disconnect drops logs (counted) with no panic and the ring keeps serving;
connection records are structured and secret-free; `log::` reaches the host via
`attach_host_logger`; and the full C-ABI flow (`set_level` → filter → paginate →
`clear` keeps the cursor → unknown level 422). `cargo test -p gstore_host`
proves a module `log` line reaches the LogBridge buffer and that buffering
survives with no StreamSink. **UNVERIFIED**: on-device LogManager rendering and
sink reconnection across an isolate restart (no adb device).

## 15. Domain statistics & aggregate traffic (Todo 16)

One process-global aggregate fed from the dispatch path, plus a throttled
`proxy.stats` snapshot.

* **Feed.** The dispatch monitor (a bounded-runtime `tokio` task owned by the
  `Dispatcher`) ticks every `STATS_TICK_MS = 500` ms, calls
  `conn::sync_full(meow Statistics)` and folds the projection diff into the
  per-domain map. Live-flow byte counters are tracked as **deltas** in
  `FlowObs`, so a long-lived flow is counted while open. Connection count
  increments once per flow; `lastSeenMs`, `rule` and `outbound` come from
  meow's connection metadata.
* **Pull is primary.** `stats.domain.get` / `stats.traffic.get` (§2.9) read the
  aggregate directly. The only push is a single `proxy.stats` snapshot per
  `MIN_EMIT_INTERVAL_MS = 1000` ms (`should_emit`), because there are **two
  independent channels**: the host task-stream ring holds
  `EVENT_BUFFER_CAP = 128` (`rust/gstore_host/src/task_bridge.rs:65`) and the
  module event ring holds `EVENT_BUFFER_CAP = 100`
  (`rust/gstore_host/src/event_bridge.rs:21`). No per-connection event is ever
  emitted.
* **Eviction.** `DOMAIN_CAP = 2048`; the oldest `lastSeenMs` is evicted first,
  ties broken lexicographically by domain (ascending). Evictions are logged
  (warn) and counted in `evicted`.
* **Persistence.** `<dataDir>/proxy_stats.db`, SQLite WAL +
  `synchronous=NORMAL`, one transactional upsert per `PERSIST_INTERVAL_MS =
  5000` ms and a rolling `RETENTION_MS = 24h` prune in the same transaction.
  Seeds memory on startup; `stats.domain.reset` clears it. No per-packet write.
* **Domain availability.** Unknown domains (ECH/ESNI, QUIC-without-SNI,
  plain-IP) fall back to the destination IP with `domainKnown: false`; a DNS
  reverse mapping is consulted first, and TCP SNI/HTTP-Host sniffing (§9.8)
  feeds `metadata.sniff_host` before dispatch (see §9.5).

### 15.1 Verification status

`cargo test -p gstore_mod_proxy` proves: accumulation across flows (connection
counts + periodic byte deltas + close does not double-count), eviction at the
cap is deterministic (oldest last-seen, lexical tie-break) and bounded, reset
clears aggregates/totals/active, the event throttle obeys the >= 1 s interval
bound, an IP-shaped flow is marked `domainKnown: false`, `stats.domain.get`
sorts deterministically and rejects unknown sorts (422), SQLite
flush/prune/seed round-trips within the rolling window, a live meow
`Statistics` table feeds `stats.traffic.get`, and the full C-ABI flow
(`stats.domain.get` → `stats.traffic.get` → reset). **UNVERIFIED**: on-device
aggregation/persistence across a real module reload and the real-time event
cadence (no adb device).


## 16. Traffic stream & connection control (Todo 17)

`conn.list` / `conn.close` (finalised in §2.10) and `stats.traffic.get` (§2.9)
are the control/read surface for the live traffic stream.

* **Paginated, filterable list.** `conn.list { offset, limit, domain, outbound }`
  returns `ConnPage`; order is newest-first with an `id` ascending tie-break, so
  paging is stable. Filters are applied before pagination; `count` is the
  filtered total and `returned` the page size.
* **Opaque, stable ids.** A connection id is meow's v4 UUID rendered as a
  canonical string. No pointer, `Uuid`, or `ConnectionInfo` reference crosses
  the ABI. The same string is the `proxy.conn` event id and the `conn.close`
  handle.
* **Idempotent, non-crashing close.** `conn.close` is meow's
  `Statistics::close_connection` (remove entry + drop the counter guard, which
  signals the owning relay). A live id closes and reports `closed:true`; a
  re-close reports `alreadyClosed:true`; a never-tracked id is
  `PROXY_CONN_NOT_FOUND` (404). The tombstone of recently-closed ids is bounded
  at `CONN_TOMBSTONE_CAP = 1024`.
* **Events.** Explicit `conn.close` emits one `proxy.conn {action:"close"}` and
  `conn.close_all` one `proxy.conn {action:"close_all", closed}`. Per-connection
  open/close is **not** streamed as events (the module event ring holds only
  100 — `event_bridge.rs:21`; the host task-stream ring's 128 is a separate
  channel — `task_bridge.rs:65`); it appears in the throttled `proxy.stats`
  snapshot and in `log.get`.

### 16.1 Verification status

`cargo test -p gstore_mod_proxy` proves the four Todo-17 cases named in §11.4:
list filtering (domain substring / outbound exact), pagination (offset/limit,
`hasMore`, offset past the end), a live close (removed from the projection, no
counter, `proxy.conn` event), an idempotent re-close, and an unknown id →
`PROXY_CONN_NOT_FOUND` (404, no panic). **UNVERIFIED**: on-device list/close over
a real TUN flow (no adb device) — the flow is exercised against a fixture meow
`Statistics` tunnel on the host.

## 17. Frozen contract & typed Dart bindings (Todo 18)

The control/event contract above is frozen here. It is enforced mechanically:

* **Rust → doc:** `every_dispatch_method_is_actually_dispatchable` calls every
  name in `crate::DISPATCH_METHODS` (the single source of truth next to the
  dispatch) and asserts it never answers `METHOD_NOT_FOUND`;
  `api_md_documents_every_dispatch_method` asserts each name appears verbatim
  (`` `name` ``) in this file.
* **Doc → Dart:** a pure-Dart test parses this file's method tables and event
  table and asserts the sets equal the Dart registries in
  `lib/core/rust/proxy/ProxyContract.dart`.
* **Dart decode:** every response/event model has a hand-written `fromJson`
  decode test (`test/proxy_contract_test.dart`), so a schema drift breaks the
  build instead of surfacing at runtime.

**Hand-written, no code-gen.** The models follow the repo convention
(`lib/core/rust/contract/ModuleTypes.dart`): plain Dart classes with
`fromJson`/`toJson`, tolerant of unknown/`null` fields (a missing key decodes to
a documented default, never a throw). Secrets (`ProxyNode.password`/`uuid`,
REALITY/obfs keys) are decoded only transiently when the UI must show a profile;
they are never logged.

**Envelope errors.** A non-`ok` response decodes to a structured
`ProxyModuleException` carrying `status`/`code`/`message`; an undecodable
(truncated / non-UTF-8 / non-JSON) response payload surfaces as
`PAYLOAD_DECODE_FAILED` (status 400) — never a crash and never a bare `FormatException`.

### 17.1 Verification status

`cargo test -p gstore_mod_proxy` proves: every dispatch method is dispatchable
and documented; unknown methods are a structured 405; a truncated JSON payload is
a structured 422 (no panic); the loopback controller defaults OFF, binds a
`127.0.0.1` literal on an ephemeral port, writes a `0600` secret file, never
serializes a secret, and stops deterministically. **UNVERIFIED**: the loopback
controller against a real device/panel (no adb device); meow's controller routes
are exercised only through bind/start/stop on the host.

## 18. Lifecycle, failure modes & data-plane supervisor (Todo 24)

### 18.1 Data-plane supervisor

The TUN datapath (`src/tun.rs`) runs one dedicated std thread owning a bounded
runtime and three guarded tasks: the single fd **reader**, the ingress and egress
pumps. Each task reports every exit — clean end, error, or **panic** (the module is
`panic=unwind`; `catch_unwind` only guards the C ABI boundary) — on an internal death
channel. The loop also wraps its own body in `catch_unwind`.

On an abnormal exit the supervisor:

1. records the **verbatim** reason (never masked) and emits structured `proxy.state`
   `{ reason:"dataplane_dead", error:{code:"PROXY_DATAPLANE_DEAD", message:<reason>}, health:{...} }`;
2. restarts the loop with **bounded exponential backoff** `250ms·2^(n-1)` capped at
   `8s`, at most `MAX_RESTARTS = 5` consecutive failures (re-arm the last host fd via
   `dup`; if Kotlin already closed it → structured `PROXY_TUN_FD_INVALID` and stop);
3. after the budget is exhausted, emits `{ reason:"dataplane_failed" }` and leaves the
   plane stopped (the operator must re-issue `core.start`).

An explicit `core.start`/`core.restart` (or process shutdown) resets the failure burst.
A `vpn.stop` (Kotlin-initiated) stops the loop through the clean path and never restarts.

### 18.2 fd teardown ordering (pinned)

`stop loop → join → host clears → Kotlin closes`.
`nativeStopTunnel` (host JNI) broadcasts `vpn.stop`, waits **bounded** (800 ms) for
`proxy.tun.released` (emitted after the reader thread is joined), which clears the host
cache, then Kotlin closes the `ParcelFileDescriptor`. The module only ever holds a
`dup`; if the bounded wait times out the host still clears and Kotlin's close is safe.

### 18.3 Engine / Dart-isolate restart

Resetting host bridges (`HostInspector.reset_bridges`) drops only the stale log / event /
task sinks. The Rust kernel (loaded modules + tunnel fd) is **not** torn down; module
events keep buffering, and a new isolate re-subscribes and receives the replay. Proven by
`tun_bridge::tests::engine_restart_keeps_tunnel_and_resumes_events`.

### 18.4 Kotlin lifecycle (UNVERIFIED on device — no adb)

`onRevoke` → structured `proxy.state` (`reason:"vpn_revoked"`) + clean stop. Network
handover → `ConnectivityManager.registerDefaultNetworkCallback` →
`setUnderlyingNetworks(null)` rebuilds the default interface; `network_changed` event.
Null-Intent (always-on / process-death) restart → persisted config + `always_on_restart`
event. Start failure → `start_failed` event. `SUPPORTS_ALWAYS_ON` is declared; the app
does not toggle the system setting (guidance + `alwaysOnSettings` channel).

## 19. Performance, memory budget & foreground notification (Todo 27)

### 19.1 Bounded memory (single source of truth)

Every accumulator that can grow with traffic is capped at its source. `src/limits.rs`
re-exports the caps and computes a numeric worst-case budget; the test
`limits::tests::every_accumulator_cap_is_within_its_ceiling` fails if a cap is raised
past its reviewed ceiling.

| Accumulator | Cap | Notes |
|---|---|---|
| log ring (`logging::RING_CAPACITY`) | 1000 | oldest-first; cursors monotonic |
| per-domain stats (`stats::DOMAIN_CAP`) | 2048 | oldest `lastSeenMs` evicted (ties: domain asc) |
| per-flow delta trackers (`stats::FLOW_CAP`) | 2048 | **Todo 27**: previously unbounded — it grew with meow's live table |
| connection projection (`conn::CONN_TRACK_CAP`) | 1024 | |
| recently-closed tombstones (`conn::CONN_TOMBSTONE_CAP`) | 1024 | |
| DNS query / mapping rings | 256 / 1024 | |
| fake-IP store | 4096 | |
| lwIP ingress+egress channel depth (`STACK_BUFFER_SIZE`) | 1024 | `NetStack::with_buffer_size`; meow default 512 |
| lwIP UDP channel depth (`UDP_BUFFER_SIZE`) | 256 | meow default 64 |
| reader→ingress queue (`INGRESS_CHANNEL`) | 256 | reader's `Vec<u8>` bounded by `READ_BUFFER_SIZE` (65535) |
| per-read buffer (`READ_BUFFER_SIZE`) | 65535 | ≥ any TUN MTU (Kotlin default 1500) |

Worst-case retained bytes (MTU-sized frames) is asserted ≤ 32 MiB by
`limits::tests::worst_case_memory_budget_is_bounded`.

Flow eviction is **amortized O(1)**: when the map exceeds `FLOW_CAP` it is trimmed to
half the cap in one deterministic pass, so a sustained excess does not re-sort on every
tick. Under connection pressure the aggregate degrades gracefully (a lost flow only loses
its exact byte delta; `stats.traffic.get` keeps reporting `flowCount`/`flowCapacity`/
`evictedFlows`). Proven by `stats::tests::flow_trackers_are_bounded_under_connection_pressure`.

### 19.2 Reader readiness handling (data-plane robustness)

`AsyncFd` is edge-triggered; `guard.try_io` returns the outer `Err(TryIoError)` whenever
the closure observes `WouldBlock` (readiness consumed, no data). This is routine under
load and whenever a burst drains into an idle fd. The reader now **retries** it instead of
treating it as fatal; previously it returned `"TUN read readiness cancelled"`, which killed
the single reader and forced a full supervisor restart of the data plane. Regression test:
`tun::tests::reader_survives_idle_gaps_between_bursts`.

### 19.3 Data plane never blocks the FRB worker

The reader/ingress/egress tasks run on the TUN loop's own std thread and bounded
`bounded_runtime` (4 workers) — see §18.1. Only the synchronous C-ABI calls reach the
host; host long-calls use `gstore_host::task_bridge` (dedicated thread per task), and
short calls run on FRB's task pool. No data-plane work is scheduled on an FRB worker.

### 19.4 Foreground notification

`ProxyVpnService` uses a dedicated `IMPORTANCE_LOW`, badge-less, `VISIBILITY_PRIVATE`
channel, a monochrome status-bar icon (`drawable/ic_stat_proxy_vpn`), `CATEGORY_SERVICE`,
`setShowWhen(false)`, `setOnlyAlertOnce(true)`, subtext, and a **Stop** action
(`ACTION_STOP` → the normal teardown path). `setForegroundServiceBehavior(IMMEDIATE)` on
API 31+.

### 19.5 Main-thread ANR avoidance

`nativeStopTunnel()` blocks ≤800 ms host-side (stop loop → join). It (and the PFD close)
now run on a single-thread `gstore-vpn-teardown` executor, so `onRevoke`/`onDestroy`/
`ACTION_STOP` never block the main thread. A lifecycle-generation guard skips a stale
teardown if a new `start` superseded it.

### 19.6 Local benchmark harness

`rust/gstore_mod_proxy/bench/run.sh [frames]` runs the two `#[ignore]` host benchmarks and
greps `GSTORE_BENCH` lines: `dataplane_read` (reader throughput + RSS/CPU) and
`stats_ingest` (aggregation throughput + RSS/CPU under domain/flow pressure). Host/debug,
relative comparison only — an on-device soak remains **UNVERIFIED** (no adb).
