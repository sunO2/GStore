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
  "instanceId": 7, "state": "stopped", "mode": "off", "protectFdPresent": true
} }
```

`instanceId`/`state`/`mode`/`protectFdPresent` appear only when a live instance was passed.

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

### 2.6 `node.*` — selection & latency

| method | request | data |
|---|---|---|
| `node.select` | `{ "group": string, "node": string }` | `{ "ok": true, "group": string, "node": string }` |
| `node.delay_test` | `{ "node"?: string, "group"?: string, "timeoutMs"?: 5000 }` | `{ "results": [ { "node": string, "delayMs": 123, "error"?: string } ] }` |

### 2.7 `dns.*` — resolver settings & cache

| method | request | data |
|---|---|---|
| `dns.get` | *(none)* | `DnsConfig` |
| `dns.set` | `DnsConfig` (partial) | `DnsConfig` |
| `dns.flush_cache` | *(none)* | `{ "ok": true, "flushed": 0 }` |

`DnsConfig`:
```json
{ "mode": "fake-ip"|"redir-host", "nameservers": ["1.1.1.1"],
  "fallback": ["8.8.8.8"], "doh": ["https://dns.example/dns-query"],
  "dot": ["tls://8.8.8.8:853"], "fakeIpRange": "198.18.0.1/16" }
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

### 2.10 `conn.*` — live connections

| method | request | data |
|---|---|---|
| `conn.list` | *(none)* | `{ "connections": [ConnInfo] }` |
| `conn.close` | `{ "id": string }` | `{ "ok": true }` |
| `conn.close_all` | *(none)* | `{ "ok": true, "closed": 0 }` |

`ConnInfo`:
```json
{ "id": "c1", "domain": "example.com", "dst": "1.2.3.4:443", "network": "tcp",
  "rule": "MATCH", "outbound": "proxy-a", "uploadBytes": 0, "downloadBytes": 0,
  "startedAtMs": 0 }
```

### 2.11 `rules.*` — rule set

| method | request | data |
|---|---|---|
| `rules.get` | *(none)* | `{ "rules": [Rule], "final": "PROXY" }` |
| `rules.set` | `{ "rules": [Rule], "final"?: string }` | `{ "ok": true, "count": 0 }` |

`Rule`: `{ "type": "DOMAIN-SUFFIX"|"DOMAIN"|"IP-CIDR"|"GEOIP"|"MATCH", "value": "x", "target": "DIRECT"|"REJECT"|<group> }`

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
| arm64-v8a release `.so` | **1,309,712 B (~1.25 MiB)** |
| x86_64 | 1,286,584 B |
| armeabi-v7a | 535,176 B |
| x86 | 1,284,452 B |
| **Δ full APK, arm64-v8a if bundled** | **+~1.25 MiB (~2.8 % over 45 MB)** — under budget |
| **Δ full APK, all four ABIs if bundled** | **+~4.21 MiB** |
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
