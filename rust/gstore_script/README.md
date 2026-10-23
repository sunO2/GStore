# gstore_script

Leaf crate that hosts the per-channel QuickJS runtime for Wave 5. It depends on
`rquickjs` only — **never** on `gstore_core`; core will depend on this crate in
later todos (Todo 3), which keeps the JS engine out of the data/decision layer.

## Responsibilities

- Own one `rquickjs::Runtime` + `Context` per channel.
- Evaluate scripts and return JSON-serialisable completion values.
- Install the Dart-compatible `sendMessage(method, payload)` + `host.*` facade
  before user code (`src/script/prelude.js`, embedded with `include_str!`).
- Expose typed host capabilities through `ScriptHost`, with DB/env isolation
  enforced by passing the runtime `ScriptChannel` into every capability.
- Enforce a wall-clock budget with QuickJS' interrupt handler and expose typed
  `CORE_E_SCRIPT_*` errors instead of panics.

## Thread model

```
ScriptRuntime::spawn(channel, options, host)
        │
        ▼
 std::thread "gstore-script:<channel>"
        ├── Runtime::new() + Context::full()      (created inside the thread)
        ├── bridge + prelude installation         (before user code)
        ├── eval / send_message command loop      (mpsc, serialised)
        └── dropped on dispose
```

- One OS thread per channel: channel isolation is a construction property, not a
  convention. Two runtimes share no JS globals.
- The `rquickjs` types never leave the thread, so the hand-off uses plain
  `std::thread` + `mpsc` and the crate forbids `unsafe`.
- The handle (`ScriptRuntime`) is `Send + Sync`; concurrent calls are serialised
  by the command loop.
- `dispose()` joins the thread. A runaway `eval` is interrupted at the budget, so
  disposal is bounded too.

## Public API

| Item | Meaning |
| --- | --- |
| `ScriptChannel::new(key)` | Validated channel key (rejects empty / NUL). |
| `ScriptRuntime::spawn(channel, options, host)` | Starts the channel thread and builds the engine. |
| `ScriptRuntime::eval(source)` | Returns `serde_json::Value`. Promise results are drained until settled. |
| `ScriptRuntime::send_message(method, payload)` | Rust-side dispatch through the host with channel affinity. Same envelope path as JS `sendMessage`. |
| `ScriptRuntime::dispose()` | Stops the thread; consumes the handle. |
| `ScriptOptions` | `eval_timeout` (default 5 s), `memory_limit_bytes` (64 MB), `stack_limit_bytes` (1 MB). |
| `ScriptHost::send_message(channel, method, payload)` | Default bridge dispatcher. Hosts normally implement capabilities instead. |
| `ScriptHost` capabilities | `http`, `db_get_apps`, `db_get_app`, `db_insert_apps`, `config_get`, `env_get`, `env_all`, `env_has`, `check_version`, `log`, `native_call`, `ui_request`. Every capability takes `&ScriptChannel` and defaults to `ScriptError::host("not implemented")`. |

A host implements only the capabilities it needs; they run on the script thread
and must be bounded and thread-safe.

## JS surface

`src/script/prelude.js` mirrors Dart's `_hostPrefixJs`; it is installed before
the channel script:

```js
sendMessage(method, payload)   // JSON string OR object/null
host.network.get(url, opts)        // -> {ok,status,data,error?}
host.network.post(url, opts)
host.database.getAppsByChannel()   // -> {ok,data:[appJson...]}
host.database.getApp(appId)        // -> {ok,data:appJson|null}
host.database.insertApps(apps)     // -> {ok,data:<count>}
host.config.get(key)               // -> {ok,data:<value|null>}
host.env.get(name) / all() / has(name)
host.log.info(msg) / error(msg)    // -> {ok:true}
host.utils.call(method, payload)   // -> host.utils.<method>
host.ui.call / core.call / alert.call(method, payload)
                                   // -> host.native.call {ns,method,payload}
```

`sendMessage` accepts a JSON **string** (what the Dart prefix passes) or an
object/null. It returns the parsed envelope **verbatim**: it never unwraps
`.data`, never throws for `{ok:false}`, and returns synchronously so `await` is
a no-op. Only malformed arguments throw a JS `Error` tagged
`CORE_E_SCRIPT_INVALID_ARGUMENT` (invalid JSON string or non-object payload).

Envelope/error rules:

- A host `Err(ScriptError)` becomes `{ok:false, error:"<CODE>: <detail>"}` — an
  envelope, not a thrown JS exception.
- A host panic is caught and becomes the same envelope with
  `CORE_E_SCRIPT_HOST`; it never unwinds through QuickJS.
- `host.network.*` passes non-2xx responses through with their body and adds
  `error:"HTTP <status>"`.
- DB writes ignore any script-supplied `channelCode`; reads are pinned to the
  runtime channel.
- An unregistered `host.native.call` returns
  `{ok:false, error:"host.native.<ns>.<method> 未注册"}`.

## Error codes

`ScriptError::kind()` / `ScriptError::code()` are stable; `Display` is
`<code>: <detail>`.

| Code | Kind | Trigger |
| --- | --- | --- |
| `CORE_E_SCRIPT_EVAL` | `Eval` | script threw / syntax error |
| `CORE_E_SCRIPT_TIMEOUT` | `Timeout` | wall-clock budget expired (interrupt fired) |
| `CORE_E_SCRIPT_DISPOSED` | `Disposed` | call after the thread is gone |
| `CORE_E_SCRIPT_LIMIT` | `Limit` | QuickJS OOM / stack overflow |
| `CORE_E_SCRIPT_HOST` | `Host` | host capability failed or panicked (delivered as an envelope) |
| `CORE_E_SCRIPT_INTERNAL` | `Internal` | thread spawn / engine / JSON wiring failed |
| `CORE_E_SCRIPT_INVALID_ARGUMENT` | `InvalidArgument` | invalid channel key, method, or `sendMessage` payload |

## Tests

```bash
cargo test --manifest-path rust/gstore_script/Cargo.toml script_runtime_eval
cargo test --manifest-path rust/gstore_script/Cargo.toml script_runtime_timeout
cargo test --manifest-path rust/gstore_script/Cargo.toml script_host_api
```

The timeout tests use an 80 ms budget so a regression hangs for milliseconds,
not CI. `script_host_api_*` covers envelope shapes, all 13 host methods, channel
isolation, typed failure paths, and a parity run of the unmodified
`assets/channels/example.js`.

## Android

`rquickjs-sys` ships no pre-generated bindings for Android, so the manifest
enables its `bindgen` feature only under `cfg(target_os = "android")`; host
builds never need libclang. Example check (NDK 27):

```bash
NDK=/home/hezhihu89/develop/android/sdk/ndk/27.0.12077973
BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
CC_aarch64_linux_android=$BIN/aarch64-linux-android21-clang \
AR_aarch64_linux_android=$BIN/llvm-ar \
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$BIN/aarch64-linux-android21-clang \
LIBCLANG_PATH=$NDK/toolchains/llvm/prebuilt/linux-x86_64/musl/lib \
cargo check --target aarch64-linux-android \
  --manifest-path rust/gstore_script/Cargo.toml
```

## Out of scope (later todos)

- `ScriptChannel`/`ScriptDetail` dispatch (Todo 3).
- Real HTTP/database/device I/O: the host is injected; this crate only defines
  the bridge and contract (no `reqwest`/`rusqlite`).
- Sandbox hardening beyond eval budget + heap/stack ceilings (Todo 4).
- Timers / host I/O event loop: a Promise that only settles via an external
  event currently times out. Promise chains that settle through microtasks work.
- Module loading (`loader` feature is enabled but no resolver is installed yet).
