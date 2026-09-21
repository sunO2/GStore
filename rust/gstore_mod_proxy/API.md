# gstore_mod_proxy — Module API (v0.1.0, ABI v3)

> **Status: SKELETON (Todo 2), frozen for Waves 2–3.** Todo 18 verifies/expands this
> file against the shipped implementation; until then treat the signatures below as
> the contract every later todo codes against.
>
> Module name `proxy` · `min_host_abi = 3` · `api.version = 1` · crate `rust/gstore_mod_proxy`
> (cdylib + rlib, `panic = "unwind"`, every `extern "C"` entry wrapped in `catch_unwind`).

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
  "protectInstalled": false
} }
```

`instanceId`/`state`/`mode`/`protectFdPresent` appear only when a live instance was passed.
`protectInstalled` reflects the process-global meow `SocketProtector` install state
(the `vpn` engine installs it at init and removes it on teardown; Todo 7).

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
| `core.start` | `{ "mode": "vpn"\|"lanProxy", "config"?: object }` | `{ "state":"starting"\|"running", "mode":"vpn", "profileId"?: string }` |
| `core.stop` | *(none)* | `{ "state": "stopped" }` |
| `core.restart` | `{ "mode"?: string }` | `{ "state": "running", "mode": string }` |
| `core.set_mode` | `{ "mode": "off"\|"vpn"\|"lanProxy" }` | `{ "ok": true, "mode": "vpn", "previous": "off" }` |
| `core.get_mode` | *(none)* | `{ "mode": "off", "state": "stopped", "sinceMs": 0 }` |

`core.set_mode` is idempotent (same mode ⇒ no-op) and serialized on one mutation lane (Todo 29).

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

### 2.4 `profile.*` — subscription/profile store

| method | request | data |
|---|---|---|
| `profile.list` | *(none)* | `{ "profiles": [Profile] }` |
| `profile.get` | `{ "id": string }` | `Profile` |
| `profile.import` | `{ "source":"url"\|"text"\|"link", "value": string, "name"?: string }` | `Profile` |
| `profile.update` | `{ "id": string, "url"?: string }` | `Profile` |
| `profile.delete` | `{ "id": string }` | `{ "ok": true }` |

`Profile`:
```json
{ "id": "uuid", "name": "My Sub", "source": "url", "url": "https://...",
  "updatedAtMs": 0, "nodeCount": 42,
  "traffic": { "uploadBytes": 0, "downloadBytes": 0, "totalBytes": 0, "usedBytes": 0 },
  "expireAtMs": 0 }
```

### 2.5 `config.generate` — render the engine config

Request: `{ "profileId"?: string, "mode"?: "vpn"\|"lanProxy" }`

```json
{ "ok": true, "data": { "config": { }, "hash": "sha256hex", "generatedAtMs": 0 } }
```

### 2.6 `node.*` — selection & latency (Todo 10)

| method | request | data |
|---|---|---|
| `node.select` | `{ "group": string, "node": string }` | `{ "ok": true, "group": string, "node": string, "active": string }` |
| `node.delay_test` | `{ "node"?: string, "group"?: string, "url"?: string, "expectedStatus"?: string, "timeoutMs"?: 5000 }` | `{ "results": [ DelayResult ], "url": string, "timeoutMs": number, "group"?: string }` |

`node.select` applies a user pick to a **selector / url-test / fallback** group
through meow's `ProxySelection::set` — the module never owns a second group
engine. `active` is the group's effective member afterwards (`current()`).
Success also emits a `proxy.state` event carrying
`{state, mode, reason:"node.select", group, node, active}`. Errors:
`PROXY_NODE_NOT_FOUND` (unknown group/node, or node not a member),
`PROXY_GROUP_NOT_SELECTABLE` (target is a leaf or a non-selectable group such
as load-balance/relay), `PROXY_NOT_CONFIGURED` (engine not running).

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


### 2.8 `log.*` — structured engine logs

| method | request | data |
|---|---|---|
| `log.get` | `{ "level"?: "debug"\|"info"\|"warn"\|"error", "limit"?: 200, "sinceMs"?: 0 }` | `{ "records": [LogRecord] }` |
| `log.set_level` | `{ "level": "info" }` | `{ "ok": true, "level": "info" }` |
| `log.clear` | *(none)* | `{ "ok": true }` |

`LogRecord`:
```json
{ "tsMs": 0, "level": "info", "source": "tunnel", "message": "connected",
  "connId"?: "c1", "domain"?: "example.com", "outbound"?: "proxy-a" }
```

### 2.9 `stats.*` — traffic / domain statistics

| method | request | data |
|---|---|---|
| `stats.get` | `{ "rangeMs"?: 0 }` | `{ "uploadBytes":0, "downloadBytes":0, "activeConns":0, "domains": [DomainStat] }` |
| `stats.reset` | *(none)* | `{ "ok": true }` |

`DomainStat`:
```json
{ "domain": "example.com", "connections": 3, "uploadBytes": 0,
  "downloadBytes": 0, "lastSeenMs": 0, "outbound": "proxy-a", "rule": "DOMAIN-SUFFIX" }
```

### 2.10 `conn.*` — live connections (Todo 10; Todo 17 finalises)

| method | request | data |
|---|---|---|
| `conn.list` | *(none)* | `{ "connections": [ConnInfo], "count": 0, "capacity": 1024 }` |
| `conn.close` | `{ "id": string }` | `{ "ok": true, "id": string, "closed": bool }` |
| `conn.close_all` | *(none)* | `{ "ok": true, "closed": 0 }` |

`ConnInfo`:
```json
{ "id": "c1", "src": "10.10.0.2:40000", "dst": "1.2.3.4:443",
  "domain": "example.com", "network": "tcp", "rule": "DOMAIN-SUFFIX",
  "rulePayload": "example.com", "outbound": "proxy-a",
  "uploadBytes": 0, "downloadBytes": 0, "startedAtMs": 0 }
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

`conn.close` signals the flow (`Statistics::close_connection(Uuid)`), which
removes it from the table and asks the owner to drop its relay; `closed` reports
whether it was live. `conn.close_all` signals every tracked flow and returns the
count. A non-UUID id is `INVALID_ARGUMENT` (422); no engine is
`PROXY_NOT_CONFIGURED`.

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


### 2.12 `lan.*` — optional LAN listening (default OFF)

| method | request | data |
|---|---|---|
| `lan.get` | *(none)* | `LanConfig` |
| `lan.set` | `LanConfig` (partial) | `LanConfig` |
| `lan.status` | *(none)* | `{ "enabled": false, "bound": false, "addresses": [], "activeConns": 0 }` |

`LanConfig`:
```json
{ "enabled": false, "port": 1087, "bindAddress": "0.0.0.0",
  "auth": { "user": "u", "pass": "p" },
  "allowedIps": ["192.168.1.0/24"] }
```
`auth` is `null` when disabled. Enabling without `auth` must emit a `proxy.state` warning (Todo 28).

## 3. Events (module → host)

Emitted through the ABI `emit_event` channel. Payload is the JSON below; the Dart
side filters on the `proxy.` prefix. `instanceId` is always present.

| event | payload schema |
|---|---|
| `proxy.state` | `{ "state":"stopped"\|"starting"\|"running"\|"stopping", "mode":"off"\|"vpn"\|"lanProxy", "reason"?: string, "error"?: { "code": string, "message": string } }` |
| `proxy.mode` | `{ "mode":"off"\|"vpn"\|"lanProxy", "previous": string }` |
| `proxy.node.delay` | `{ "group": string, "node": string, "delayMs": 123, "error"?: string }` |
| `proxy.stats` | `{ "uploadBytes":0, "downloadBytes":0, "activeConns":0, "upBps":0, "downBps":0 }` (throttled) |
| `proxy.subscription.updated` | `{ "profileId": string, "nodeCount": 0, "traffic": { "uploadBytes":0, "downloadBytes":0 }, "expireAtMs": 0 }` |
| `proxy.subscription.added` | `{ "profileId": string, "name": string }` |
| `proxy.subscription.removed` | `{ "profileId": string }` |
| `proxy.conn` | `{ "action":"open"\|"close", "id": string, "domain"?: string, "outbound"?: string, "uploadBytes"?:0, "downloadBytes"?:0 }` |
| `proxy.log` | `LogRecord` (see §2.8) |
| `proxy.dns` | `DnsQueryRecord` (see §2.7) — one record per DNS query answered by the TUN DNS hijack; carries the domain→IP mapping for the Todo 16 domain-statistics path (Todo 8; Todo 15/16 consume it). |
| `proxy.tun.released` | `{ "fd": 123 }` — TUN read loop stopped and its thread joined; the host may clear its cached fd and Kotlin may close the PFD (Todo 6). Host-internal control event; Dart may ignore it. |

## 4. Host → module events (`on_event`)

| kind | payload | meaning |
|---|---|---|
| `config.changed` | `{ "key": string, "value": any }` | config hot-reload (e.g. `proxy.mode`) |
| `db.changed` | `{ "type": string, "data": any }` | data-store change |
| `module.lifecycle` | `{ "module": string, "lifecycle": string }` | module up/down |

## 5. Domain error codes

All use the `gstore_contract` payload (`status`/`code`/`message`). New codes are
registered in `rust/ERROR_CODES.md`.

| code | status | meaning |
|---|---|---|
| `METHOD_NOT_FOUND` | 405 | unknown method (protocol) |
| `INVALID_ARGUMENT` | 422 | bad payload (protocol) |
| `INSTANCE_NOT_FOUND` | 410 | dead instance (protocol) |
| `PROXY_NOT_CONFIGURED` | 409 | start without a selected profile |
| `PROXY_TUN_FD_INVALID` | 422 | invalid/closed TUN fd (Todo 6) |
| `PROXY_PERMISSION_DENIED` | 403 | VPN consent missing/revoked (Todo 4/24) |
| `PROXY_PROFILE_NOT_FOUND` | 404 | unknown profile id |
| `PROXY_NODE_NOT_FOUND` | 404 | unknown node/group |
| `PROXY_SUBSCRIPTION_PARSE_FAILED` | 422 | subscription YAML/link parse failure |
| `PROXY_ENGINE_START_FAILED` | 500 | meow engine failed to start |
| `PROXY_LAN_DISABLED` | 409 | LAN requested while disabled (Todo 28) |
| `PROXY_NO_INBOUND` | 409 | `lanProxy` with no LAN listener (Todo 29) |
| `PROXY_PROTECT_FAILED` | 500 | host `protect_fd(fd)` returned non-zero; the dial is aborted so an unprotected socket never reaches the network (Todo 7) |
| `PROXY_DNS_CONFIG_INVALID` | 422 | invalid DNS config: nameserver/DoH/DoT URL parse failure, bad fake-IP range, empty nameserver set (Todo 8) |
| `PROXY_DNS_BOOTSTRAP_FAILED` | 500 | DNS bootstrap / encrypted-upstream construction failed (422 when a `default-nameserver` is not plain) (Todo 8) |
| `PROXY_DNS_TIMEOUT` | 504 | DNS query produced no answer (unreachable upstream, no fallback); a `proxy.dns.failure` record is logged first (Todo 8) |

## 6. Module distribution decision (state it now)

**Decision: `proxy` is a downloadable module (GitHub Release asset consumed by
`ModuleBootstrap`) and is NOT bundled in either the full or the slim APK in this
todo.** `scripts/ci/assert_apk_module_payload.sh` enforces this with a negative
assertion for `libgstore_mod_proxy.so`; Todo 25 owns any later flip to bundled
distribution (and must update this section plus the APK payload assertion).

Rationale and budgets versus the current `~45 MB` arm64 baseline (per
`rust/ARCHITECTURE.md` P0). Sizes below are the **ABI-complete** release builds
(`./build_android_rust.sh --module gstore_mod_proxy`, measured in Todo 2):

| item | value |
|---|---|
| arm64-v8a release `.so` | **1,309,712 B (~1.25 MiB)** at Todo 2; **4,080,584 B (~3.89 MiB)** after Todo 7 wired the real tunnel routing engine |
| x86_64 | 1,286,584 B |
| armeabi-v7a | 535,176 B |
| x86 | 1,284,452 B |
| **Δ full APK, arm64-v8a if bundled** | **+~1.25 MiB (~2.8 % over 45 MB)** at Todo 2 — under budget; Todo 7 raises the real figure to **+~3.89 MiB (~8.6 %)**, still under budget but Todo 25 must re-measure |
| **Δ full APK, all four ABIs if bundled** | **+~4.21 MiB** (Todo 2) |
| slim APK | 0 (downloaded on first use, verified by sha256 against `modules.json`) |
| shipped ABIs (built + manifest) | **arm64-v8a, armeabi-v7a, x86, x86_64** (all four build; manifest carries all four) |

The Todo 1 spike measured 933,992 B for arm64 before the `gstore_contract` ABI
landed; the +~0.35 MiB delta is `gstore_contract` (prost + ed25519 + serde). Both
figures are far under the budget, so the decision is unchanged.

Notes:
- `libc++_shared.so` (BoringSSL runtime) already ships in the APK, so the module adds
  no extra runtime dependency beyond its own `.so`.
- `DT_NEEDED` is Android-system-only (`libc.so`, `libdl.so`, `libc++_shared.so`); no
  host-only libraries.
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
  dialed from a cached/OS answer that we never saw must be recovered by
  **SNI / HTTP Host sniffing** (meow's sniffer, Todo 10/16), which fails for
  **ECH/ESNI** and for **plain-IP** connections. For those, the domain is
  unavailable: Todo 16 must record the flow under the **IP** and mark the record
  (`domainKnown: false`) rather than inventing a domain. `DnsMapping.domainKnown`
  already carries that flag for the records we do produce.
- Todo 16 should therefore prefer fake-IP mode for domain attribution; redir-host
  plus sniffing is best-effort and must tolerate missing domains.

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

**UNVERIFIED**: real upstream latency (tests use hanging stubs and loopback, no
network); on-device selection/routing (no adb device); UDP connections are not
in `conn.list` (meow tracks UDP in a NAT table with no byte counters).

