//! Channel subsystem traits and local-pack types (Wave 1, Todo 3).
//!
//! This module is intentionally local-only: packs carry plain JSON metadata and
//! there is no signature, trust root, verification, or consent surface. Pack
//! loading from zip bytes lands in Todo 9. Registry persistence is SQLite-backed
//! in production via
//! [`SqliteChannelStore`]; the in-memory fakes remain for tests and for callers
//! that intentionally need ephemeral state.
//!
//! All traits are synchronous, matching the crate's existing port conventions
//! (`download::port::ModuleBridge`, `flags`), and every fallible operation
//! returns the shared [`crate::error::Error`].

/// Private sealing supertrait for [`ChannelDriver`].
///
/// The module is private, so downstream crates can name neither `Sealed` nor an
/// implementation of it; therefore only this crate can implement
/// [`ChannelDriver`]. The `compile_fail` doctest on the trait pins this.
mod sealed {
    pub trait Sealed {}
}

mod driver;
mod fake;
mod fdroid;
mod github;
mod localdb;
mod pack;
mod pack_loader;
mod registry;
mod script;
mod sqlite_store;
mod store;
mod vivo;

pub use driver::{ChannelCategory, ChannelConfig, ChannelDriver};
pub use fake::{InMemoryChannelDriver, InMemoryChannelStore};
pub use fdroid::FdroidDriver;
pub use github::GitHubDriver;
pub use localdb::LocalDbDriver;
pub use pack::{validate_channel_key, ChannelPack, PackIconSource};
pub use pack_loader::{InstalledPack, PackError, PackLimits, PackPolicy, PackStore};
pub use registry::ChannelRegistry;
pub use script::{
    BuildHistoryQuery, DetailAction, ScriptChannel, ScriptChannelConfig, ScriptChannelStore,
    ScriptDetail, ScriptDetailConfig, SwitchVersionQuery, VersionOptionsQuery,
};
pub use sqlite_store::SqliteChannelStore;
pub use store::{ChannelRecord, ChannelStore};
pub use vivo::VivoDriver;

/// [`ChannelRegistry`] backed by the persistent [`SqliteChannelStore`].
pub type SqliteChannelRegistry = ChannelRegistry<SqliteChannelStore>;

/// [`ChannelRegistry`] backed by the in-memory [`ChannelStore`] fake.
///
/// Test-only: production wiring should use [`SqliteChannelRegistry`] /
/// [`ChannelRegistry::open_db`].
pub type InMemoryChannelRegistry = ChannelRegistry<InMemoryChannelStore>;
