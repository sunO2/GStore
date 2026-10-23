//! gstore_core — spike skeleton (channels/catalog/update land in the main migration plan).

pub mod added;
pub mod aggregate;
pub mod catalog;
pub mod channel;
pub mod channel_migration;
pub mod db;
pub mod download;
pub mod dto;
pub mod error;
pub mod event;
pub mod facts;
pub mod flags;
pub mod install;
pub mod inventory;
pub mod migration;
pub mod ports;
pub mod rules;
pub mod update;

pub use channel::{
    validate_channel_key, BuildHistoryQuery, ChannelCategory, ChannelConfig, ChannelDriver,
    ChannelPack, ChannelRecord, ChannelRegistry, ChannelStore, DetailAction, FdroidDriver,
    GitHubDriver, InMemoryChannelDriver, InMemoryChannelRegistry, InMemoryChannelStore,
    InstalledPack, LocalDbDriver, PackError, PackIconSource, PackLimits, PackStore, ScriptChannel,
    ScriptChannelConfig, ScriptDetail, ScriptDetailConfig, SqliteChannelRegistry,
    SqliteChannelStore, SwitchVersionQuery, VersionOptionsQuery, VivoDriver,
};
pub use dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, ChannelMeta,
    ChannelState, DetailSection,
};
pub use error::Error;
pub use event::{CoreEvent, ScriptUiField};
pub use facts::{
    CorePaths, DeviceFacts, FactStore, InstallReport, InstallReportStatus, InstallRequest,
    InstallResultAck, InstallRules, InstallStart, InstalledApp, InventoryPushResult,
    InventorySnapshot, PlatformFacts, UpdateRules, VariantChoice,
};
pub use flags::{flags, reset_flags, set_flags, Flags, FlagsApi, FlagsPatch};
pub use install::{
    InstallRecord, InstallService, INSTALL_STATUS_DENIED, INSTALL_STATUS_FAILED,
    INSTALL_STATUS_INSTALLED, INSTALL_STATUS_NONE, INSTALL_STATUS_PENDING, INSTALL_STATUS_TIMEOUT,
    INSTALL_STATUS_UNKNOWN,
};
pub use inventory::InventoryStore;
pub use ports::{CoreConfig, DownloadPort, FileSecretPort, HttpPort, MetadataPort, RepoPort};
pub use rules::{
    RuleStore, RULES_VERSION, SIGNATURE_POLICY_OFF, SIGNATURE_POLICY_STRICT, SIGNATURE_POLICY_WARN,
};
