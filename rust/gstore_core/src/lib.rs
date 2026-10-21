//! gstore_core — spike skeleton (channels/catalog/update land in the main migration plan).

pub mod channel;
pub mod channel_migration;
pub mod db;
pub mod download;
pub mod dto;
pub mod error;
pub mod event;
pub mod flags;
pub mod migration;
pub mod ports;

pub use channel::{
    validate_channel_key, ChannelCategory, ChannelConfig, ChannelDriver, ChannelPack,
    ChannelRecord, ChannelRegistry, ChannelStore, FdroidDriver, GitHubDriver,
    InMemoryChannelDriver, InMemoryChannelRegistry, InMemoryChannelStore, InstalledPack,
    LocalDbDriver, PackError, PackIconSource, PackLimits, PackStore, SqliteChannelRegistry,
    SqliteChannelStore, VivoDriver,
};
pub use dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, ChannelMeta,
    ChannelState, DetailSection,
};
pub use error::Error;
pub use event::{CoreEvent, ScriptUiField};
pub use flags::{flags, reset_flags, set_flags, Flags, FlagsApi, FlagsPatch};
pub use ports::{
    Capability, CapabilitySet, CoreConfig, DownloadPort, FileSecretPort, HttpPort, MetadataPort,
    PlatformHost, RepoPort,
};
