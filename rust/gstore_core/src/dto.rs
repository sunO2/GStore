//! Core DTOs shared with the Flutter layer.
//!
//! Field names and optionality mirror the observable Dart models
//! (`ChannelInfo`, `AppSummary`, `AppDetailInfo`, `AppUpdateCheckResult`,
//! `DownloadInfo`). `DateTime?` is represented as epoch milliseconds in
//! `Option<i64>`, and Dart maps are represented as JSON maps.

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// Stable identity of a channel (`local_db`, `js_pingan`, ...).
///
/// Ordering, equality, and hashing are derived from the inner string so a
/// `BTreeMap<ChannelKey, _>` or `HashSet<ChannelKey>` is deterministic.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ChannelKey(String);

impl ChannelKey {
    /// Creates a key, rejecting the empty string.
    pub fn new(value: impl Into<String>) -> Result<Self, Error> {
        let value = value.into();
        if value.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "channel key must not be empty".to_string(),
            ));
        }
        Ok(Self(value))
    }

    /// Borrows the key as a string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ChannelKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Channel implementation type. Wire values match Dart `ChannelType.code`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelKind {
    /// Local SQLite-backed channel.
    LocalDb,
    /// GitHub API channel.
    Github,
    /// Generic HTTP API channel.
    Http,
    /// vivo app store channel.
    Vivo,
    /// F-Droid channel.
    Fdroid,
    /// Custom channel.
    Custom,
    /// Local JavaScript channel (`assets/channels`, user packs).
    JsLocal,
}

impl ChannelKind {
    /// Parses a Dart `ChannelType.code` (or `js_local`) into a kind.
    pub fn from_code(code: &str) -> Result<Self, Error> {
        match code {
            "local_db" => Ok(Self::LocalDb),
            "github" => Ok(Self::Github),
            "http" => Ok(Self::Http),
            "vivo" => Ok(Self::Vivo),
            "fdroid" => Ok(Self::Fdroid),
            "custom" => Ok(Self::Custom),
            "js_local" => Ok(Self::JsLocal),
            other => Err(Error::InvalidArgument(format!(
                "unknown channel kind: {other}"
            ))),
        }
    }

    /// Wire code for this kind.
    pub const fn as_code(self) -> &'static str {
        match self {
            Self::LocalDb => "local_db",
            Self::Github => "github",
            Self::Http => "http",
            Self::Vivo => "vivo",
            Self::Fdroid => "fdroid",
            Self::Custom => "custom",
            Self::JsLocal => "js_local",
        }
    }
}

/// Channel metadata (mirrors Dart `ChannelInfo`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelMeta {
    /// Channel implementation type (Dart field `type`).
    #[serde(rename = "type")]
    pub kind: ChannelKind,
    /// Display name.
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// Whether the channel is enabled.
    pub enabled: bool,
    /// Priority; smaller means higher priority.
    pub priority: i32,
    /// Whether the channel supports offline use.
    pub support_offline: bool,
    /// Last update time (epoch milliseconds).
    pub last_update_time: Option<i64>,
    /// Channel version string.
    pub version: Option<String>,
}

/// Runtime state of a channel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelState {
    /// Stable channel identity.
    pub key: ChannelKey,
    /// Channel implementation type.
    pub kind: ChannelKind,
    /// Whether the channel is enabled.
    pub enabled: bool,
    /// Whether the channel is loaded and usable.
    pub ready: bool,
    /// Last successful refresh (epoch milliseconds).
    pub last_refresh_at: Option<i64>,
    /// Number of apps currently exposed by the channel.
    pub app_count: u64,
    /// Last load/refresh error, if any.
    pub last_error: Option<String>,
}

/// App summary (mirrors Dart `AppSummary`, which is structurally `AppInfo`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppSummary {
    /// Channel-scoped app id (`owner/repo`, package name, or numeric id).
    pub app_id: String,
    /// Real package name; `None` when unknown.
    pub package_name: Option<String>,
    /// Display name.
    pub name: String,
    /// Owner/user.
    pub user: String,
    /// Repository name.
    pub repositories: String,
    /// Icon URL.
    pub icon: String,
    /// Short description.
    pub des: String,
    /// README content (markdown).
    pub readme: Option<String>,
    /// Category list.
    pub category: Option<Vec<String>>,
    /// Channel-specific extension data (JSON object).
    pub extra: Option<serde_json::Map<String, serde_json::Value>>,
}

/// Detail-page section kinds (mirrors Dart `DetailSection`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetailSection {
    /// Version information.
    Version,
    /// Statistics (stars/forks/downloads/rating).
    Statistics,
    /// Screenshots.
    Screenshots,
    /// README/description text.
    Readme,
    /// Download links.
    Downloads,
    /// Rating information.
    Rating,
    /// Developer information.
    Developer,
    /// Changelog.
    Changelog,
    /// Permissions.
    Permissions,
}

/// One downloadable artifact (mirrors Dart `DownloadInfo`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppDownload {
    /// Download URL.
    pub url: String,
    /// File name.
    pub name: String,
    /// File size in bytes.
    pub size: Option<i64>,
    /// Download count.
    pub download_count: Option<i64>,
    /// Version label.
    pub version: Option<String>,
    /// Numeric version code.
    pub version_code: Option<i64>,
    /// Publication time (epoch milliseconds).
    pub published_at: Option<i64>,
    /// Platform tag (`android`, `universal`, `arm64-v8a`, ...).
    pub platform: Option<String>,
    /// File hash.
    pub hash: Option<String>,
    /// Hash algorithm (`sha256`, `md5`, ...).
    pub hash_type: Option<String>,
    /// Whether the artifact can be downloaded.
    pub downloadable: bool,
    /// Reason it cannot be downloaded.
    pub note: Option<String>,
    /// Extra tag data (JSON object).
    pub extra: Option<serde_json::Map<String, serde_json::Value>>,
}

/// Full app detail (mirrors Dart `AppDetailInfo` / `IDetailInfo`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppDetail {
    /// Channel-scoped app id.
    pub app_id: String,
    /// Display name.
    pub name: String,
    /// Icon URL.
    pub icon: String,
    /// Short description.
    pub description: String,
    /// Version string.
    pub version: Option<String>,
    /// Developer/author.
    pub developer: Option<String>,
    /// Real package name.
    pub package_name: Option<String>,
    /// Project home page.
    pub project_url: Option<String>,
    /// Source channel kind.
    pub channel: ChannelKind,
    /// Sections the detail page can show.
    pub sections: Vec<DetailSection>,
    /// Download candidates.
    pub downloads: Vec<AppDownload>,
    /// Channel-specific extension data.
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// Result of checking one app for updates (mirrors Dart `AppUpdateCheckResult`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppUpdate {
    /// Channel-scoped app id.
    pub app_id: String,
    /// Real package name.
    pub package_name: String,
    /// Display name.
    pub name: String,
    /// Icon URL.
    pub icon: Option<String>,
    /// Latest version label.
    pub latest_version: Option<String>,
    /// Latest downloadable artifact.
    pub latest_download: Option<AppDownload>,
    /// Full detail used by download strategy and the detail page.
    pub detail: AppDetail,
}
