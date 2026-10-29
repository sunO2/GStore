//! Public repository DTOs.

use serde::Serialize;

/// One registered catalog database in the repository.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepoEntry {
    pub file: String,
    pub version: String,
    pub sha256: String,
    pub source: String,
    pub kind: String,
    pub added_at: i64,
    pub apps: usize,
}

/// Snapshot of the repository state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepoStatus {
    pub current_version: Option<String>,
    pub current_file: Option<String>,
    pub apps: usize,
    pub categories: usize,
    pub entries: Vec<RepoEntry>,
}

/// Successful download result. `changed` means `current` switched to this file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepoDownloadReport {
    pub version: Option<String>,
    pub changed: bool,
    pub entries: Vec<RepoEntry>,
}

/// Result of a materialization attempt into the core database.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CatalogMaterializeReport {
    pub materialized: bool,
    pub version: Option<String>,
    pub apps: usize,
    pub categories: usize,
}
