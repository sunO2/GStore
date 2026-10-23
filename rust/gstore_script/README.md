# gstore_script

Leaf crate that hosts the per-channel QuickJS runtime for Wave 5. It depends on
`rquickjs` only — **never** on `gstore_core`; core will depend on this crate in
later todos (Todo 3), which keeps the JS engine out of the data/decision layer.

## Responsibilities

- Own one `rquickjs::Runtime` + `Context` per channel.
- Evaluate scripts and return JSON-serialisable completion values.
- Provide the `sendMessage(method, payload)` host bridge (`ScriptHost` trait).
- Enforce a wall-clock budget with QuickJS' interrupt handler and expose typed
  `CORE_E_SCRIPT_*` errors instead of panics.

## Thread model

```
ScriptRuntime::spawn(channel, options, host)
        │
        ▼
 std::thread "gstore-script:<channel>"
        ├── Runtime::new() + Context::full()      (created inside the thread)
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
| `ScriptRuntime::send_message(method, payload)` | Dispatches through `ScriptHost` with channel affinity. Same path as JS `sendMessage`. |
| `ScriptRuntime::dispose()` | Stops the thread; consumes the handle. |
| `ScriptOptions` | `eval_timeout` (default 5 s), `memory_limit_bytes` (64 MB), `stack_limit_bytes` (1 MB). |
| `ScriptHost::send_message(&self, method, &payload)` | Host callback; runs on the script thread, must be bounded and thread-safe. |
| `UnsupportedHost` | Placeholder host until Todo 2 wires `host.*`. |

JS-visible surface installed by this todo:

```js
sendMessage(method, payload)          // throws Error("CORE_E_SCRIPT_...: ...") on host failure
globalThis.__gstoreSendMessage        // native bridge (internal, returns envelope JSON)
```

A host failure/`panic!` becomes a thrown JS `Error`; a panic never unwinds
through QuickJS and never crosses the public Rust API.

## Error codes

`ScriptError::kind()` / `ScriptError::code()` are stable; `Display` is
`<code>: <detail>`.

| Code | Kind | Trigger |
| --- | --- | --- |
| `CORE_E_SCRIPT_EVAL` | `Eval` | script threw / syntax error |
| `CORE_E_SCRIPT_TIMEOUT` | `Timeout` | wall-clock budget expired (interrupt fired) |
| `CORE_E_SCRIPT_DISPOSED` | `Disposed` | call after the thread is gone |
| `CORE_E_SCRIPT_LIMIT` | `Limit` | QuickJS OOM / stack overflow |
| `CORE_E_SCRIPT_HOST` | `Host` | `sendMessage` callback failed or panicked |
| `CORE_E_SCRIPT_INTERNAL` | `Internal` | thread spawn / engine / JSON wiring failed |
| `CORE_E_SCRIPT_INVALID_ARGUMENT` | `InvalidArgument` | invalid channel key or method |

## Tests

```bash
cargo test --manifest-path rust/gstore_script/Cargo.toml script_runtime_eval
cargo test --manifest-path rust/gstore_script/Cargo.toml script_runtime_timeout
```

The timeout tests use an 80 ms budget so a regression hangs for milliseconds,
not CI.

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

- `host.*` surface, `ScriptChannel`/`ScriptDetail` dispatch (Todos 2–3).
- Sandbox hardening beyond eval budget + heap/stack ceilings (Todo 4).
- Timers / host I/O event loop: a Promise that only settles via an external
  event currently times out. Promise chains that settle through microtasks work.
- Module loading (`loader` feature is enabled but no resolver is installed yet).
