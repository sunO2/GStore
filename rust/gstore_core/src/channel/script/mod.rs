//! Script-backed channel driver (Wave 5, Todo 3).
//!
//! A [`ScriptChannel`] is the in-crate [`ChannelDriver`](super::ChannelDriver)
//! implementation for JS packs: it owns one [`gstore_script::ScriptRuntime`]
//! per channel and dispatches the public driver methods through the script's
//! `main(method, params)` entrypoint.
//!
//! [`ScriptDetail`] is the page-scoped counterpart of Dart `JsDetailChannel`: it
//! owns its own runtime and exposes `versionOptions` / `switchVersion` /
//! `buildHistory` / `detailMenu`.
//!
//! Layering:
//! - `config`   — validated constructor inputs (including `pack key == key`)
//! - `dispatch` — runtime spawning, `main` invocation, envelope parsing
//! - `meta`     — optional `CHANNEL_META` read (silent degrade)
//! - `convert`  — script JSON -> `crate::dto` values
//! - `store`    — optional channel-pinned app persistence for Dart fallbacks
//! - `channel`  — the `ChannelDriver` implementation
//! - `detail`   — the page-level detail dispatcher

mod channel;
mod config;
mod convert;
mod detail;
mod dispatch;
mod meta;
mod store;

pub use channel::ScriptChannel;
pub use config::{ScriptChannelConfig, ScriptDetailConfig};
pub use detail::{
    BuildHistoryQuery, DetailAction, ScriptDetail, SwitchVersionQuery, VersionOptionsQuery,
};
pub use store::ScriptChannelStore;
