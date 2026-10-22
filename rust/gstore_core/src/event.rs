//! Core → Flutter events.
//!
//! Serde emits the event name in the `event` field using the stable wire
//! strings below. Consumers must match on those strings, not Rust variant names.

use serde::{Deserialize, Serialize};

use crate::dto::{AppUpdate, ChannelKey, ChannelKind};
use crate::error::Error;
use crate::facts::InstallRequest;

/// Wire name for [`CoreEvent::ChannelChanged`].
pub const EVT_CHANNEL_CHANGED: &str = "channel.changed";
/// Wire name for [`CoreEvent::CatalogChanged`].
pub const EVT_CATALOG_CHANGED: &str = "catalog.changed";
/// Wire name for [`CoreEvent::UpdateFound`].
pub const EVT_UPDATE_FOUND: &str = "update.found";
/// Wire name for [`CoreEvent::DownloadProgress`].
pub const EVT_DOWNLOAD_PROGRESS: &str = "download.progress";
/// Wire name for [`CoreEvent::DownloadDone`].
pub const EVT_DOWNLOAD_DONE: &str = "download.done";
/// Wire name for [`CoreEvent::InstallResult`].
pub const EVT_INSTALL_RESULT: &str = "install.result";
/// Wire name for [`CoreEvent::ScriptUiRequest`].
pub const EVT_SCRIPT_UI_REQUEST: &str = "script.ui_request";
/// Wire name for [`CoreEvent::InventoryChanged`].
pub const EVT_INVENTORY_CHANGED: &str = "inventory.changed";
/// Wire name for [`CoreEvent::InstallUnknown`].
pub const EVT_INSTALL_UNKNOWN: &str = "install.unknown";
/// Wire name for [`CoreEvent::InstallRequested`].
pub const EVT_INSTALL_REQUESTED: &str = "install.requested";

/// One field requested by a channel script UI form.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScriptUiField {
    /// Machine name used in the result payload.
    pub name: String,
    /// Display label.
    pub label: String,
    /// Input kind (`text`, `password`, `select`, `confirm`, ...).
    pub kind: String,
    /// Whether the field is required.
    #[serde(default)]
    pub required: bool,
    /// Pre-filled value.
    pub value: Option<String>,
    /// Allowed options for `select`-like inputs.
    #[serde(default)]
    pub options: Vec<String>,
}

/// Event emitted by the Rust core.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", content = "payload")]
pub enum CoreEvent {
    /// A channel's metadata/state changed.
    #[serde(rename = "channel.changed")]
    ChannelChanged {
        /// Channel identity.
        key: ChannelKey,
        /// Channel kind.
        kind: ChannelKind,
    },
    /// A channel's catalog changed (app added/removed/updated).
    #[serde(rename = "catalog.changed")]
    CatalogChanged {
        /// Channel identity.
        key: ChannelKey,
        /// Affected app id; `None` means the whole catalog changed.
        app_id: Option<String>,
        /// Whether the app was removed from the catalog.
        removed: bool,
    },
    /// A newer version was found for an app.
    #[serde(rename = "update.found")]
    UpdateFound {
        /// Channel identity.
        key: ChannelKey,
        /// Channel-scoped app id.
        app_id: String,
        /// Full update payload.
        update: Box<AppUpdate>,
    },
    /// Download progress advanced.
    #[serde(rename = "download.progress")]
    DownloadProgress {
        /// Task id assigned by the download subsystem.
        task_id: String,
        /// App id associated with the download.
        app_id: Option<String>,
        /// Bytes downloaded so far.
        bytes_done: u64,
        /// Total bytes; `0` when unknown.
        total: u64,
        /// Progress fraction in `0.0..=1.0` (`0.0` when total is unknown).
        fraction: f64,
    },
    /// A download finished (successfully or not).
    #[serde(rename = "download.done")]
    DownloadDone {
        /// Task id assigned by the download subsystem.
        task_id: String,
        /// App id associated with the download.
        app_id: Option<String>,
        /// Whether the download succeeded.
        success: bool,
        /// Final local path on success.
        path: Option<String>,
        /// Error message on failure.
        error: Option<String>,
    },
    /// An install attempt finished.
    #[serde(rename = "install.result")]
    InstallResult {
        /// Channel-scoped app id.
        app_id: String,
        /// Installed package name, when known.
        package_name: Option<String>,
        /// Whether the install succeeded.
        success: bool,
        /// Additional result message.
        message: Option<String>,
    },
    /// A channel script requested user input.
    #[serde(rename = "script.ui_request")]
    ScriptUiRequest {
        /// Channel identity.
        key: ChannelKey,
        /// App id associated with the request, when applicable.
        app_id: Option<String>,
        /// Correlation id for the eventual UI response.
        request_id: String,
        /// Request kind (`form`, `confirm`, `alert`, ...).
        kind: String,
        /// Dialog title.
        title: String,
        /// Dialog body.
        message: Option<String>,
        /// Requested fields.
        fields: Vec<ScriptUiField>,
    },
    /// An accepted inventory snapshot changed the stored app set.
    #[serde(rename = "inventory.changed")]
    InventoryChanged {
        /// Inventory source identity.
        source_id: String,
        /// Accepted sequence number.
        seq: i64,
        /// Number of distinct packages stored for the source.
        count: usize,
    },
    /// A pending install exhausted its timeout window.
    #[serde(rename = "install.unknown")]
    InstallUnknown {
        /// Installer session id that never reported.
        session_id: String,
        /// Download task id, when known.
        module_task_id: Option<String>,
    },
    /// The frontend must execute this install request.
    #[serde(rename = "install.requested")]
    InstallRequested {
        /// Durable install request.
        request: InstallRequest,
    },
}

impl CoreEvent {
    /// Stable wire name for this event.
    pub const fn wire_name(&self) -> &'static str {
        match self {
            Self::ChannelChanged { .. } => EVT_CHANNEL_CHANGED,
            Self::CatalogChanged { .. } => EVT_CATALOG_CHANGED,
            Self::UpdateFound { .. } => EVT_UPDATE_FOUND,
            Self::DownloadProgress { .. } => EVT_DOWNLOAD_PROGRESS,
            Self::DownloadDone { .. } => EVT_DOWNLOAD_DONE,
            Self::InstallResult { .. } => EVT_INSTALL_RESULT,
            Self::ScriptUiRequest { .. } => EVT_SCRIPT_UI_REQUEST,
            Self::InventoryChanged { .. } => EVT_INVENTORY_CHANGED,
            Self::InstallUnknown { .. } => EVT_INSTALL_UNKNOWN,
            Self::InstallRequested { .. } => EVT_INSTALL_REQUESTED,
        }
    }

    /// Serializes this event to JSON.
    pub fn to_json(&self) -> Result<String, Error> {
        serde_json::to_string(self).map_err(Error::from)
    }

    /// Deserializes an event, returning a typed error for malformed or unknown
    /// event payloads (never panics).
    pub fn from_json(json: &str) -> Result<Self, Error> {
        serde_json::from_str(json).map_err(Error::from)
    }
}
