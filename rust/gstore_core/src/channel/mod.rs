//! Channel subsystem traits and local-pack types (Wave 1, Todo 3).
//!
//! This module is intentionally local-only: packs carry plain JSON metadata and
//! there is no signature, trust root, verification, or consent surface. Pack
//! loading from zip bytes lands in Todo 9; SQLite-backed registry persistence
//! lands in Todo 8. Until then callers can use [`ChannelRegistry`] with the
//! in-memory fakes, or the [`InMemoryChannelDriver`] directly.
//!
//! All traits are synchronous, matching the crate's existing port conventions
//! (`download::port::ModuleBridge`, `flags`), and every fallible operation
//! returns the shared [`crate::error::Error`].

mod driver;
mod fake;
mod pack;
mod registry;
mod store;

pub use driver::{ChannelCategory, ChannelConfig, ChannelDriver};
pub use fake::{InMemoryChannelDriver, InMemoryChannelStore};
pub use pack::{validate_channel_key, ChannelPack, PackIconSource};
pub use registry::ChannelRegistry;
pub use store::{ChannelRecord, ChannelStore};

/// [`ChannelRegistry`] backed by the in-memory [`ChannelStore`] fake.
pub type InMemoryChannelRegistry = ChannelRegistry<InMemoryChannelStore>;
