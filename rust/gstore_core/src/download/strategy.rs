//! Download strategy seam: resolves save paths and builds `DownloadRequest`s.
//!
//! Mirrors the Dart rule in `lib/core/download/download_paths.dart`: an
//! absolute `save_file_name` (leading `/`) wins verbatim, otherwise the
//! configured downloads dir (or the docs dir fallback) is joined with the
//! server-provided `file_name`.

use std::path::{Path, PathBuf};

use super::port::{DownloadRequest, PortError};

/// Resolves the destination path for a download.
///
/// * `save_file_name` starting with `/` is an absolute override and is used
///   verbatim. A relative `save_file_name` is *not* absolute and is ignored.
/// * Otherwise `<downloads_dir ?? docs_dir>/<file_name>` is returned.
pub fn resolve_save_path(
    downloads_dir: Option<&Path>,
    docs_dir: &Path,
    save_file_name: Option<&str>,
    file_name: &str,
) -> PathBuf {
    if let Some(name) = save_file_name {
        if name.starts_with('/') {
            return PathBuf::from(name);
        }
    }
    downloads_dir.unwrap_or(docs_dir).join(file_name)
}

/// Everything a strategy needs to build a download request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StrategyInput {
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub save_file_name: Option<String>,
    pub downloads_dir: Option<PathBuf>,
    pub docs_dir: PathBuf,
    pub expected_sha256: Option<String>,
    pub install_after_download: bool,
}

/// Turns a resolved [`StrategyInput`] into a [`DownloadRequest`].
pub trait DownloadStrategy {
    fn build(&self, input: &StrategyInput) -> Result<DownloadRequest, PortError>;
}

/// Strategy for apps backed by the local (Db) source.
pub struct LocalDbStrategy;

impl DownloadStrategy for LocalDbStrategy {
    fn build(&self, input: &StrategyInput) -> Result<DownloadRequest, PortError> {
        let dest_path = resolve_save_path(
            input.downloads_dir.as_deref(),
            &input.docs_dir,
            input.save_file_name.as_deref(),
            &input.file_name,
        )
        .to_string_lossy()
        .into_owned();

        Ok(DownloadRequest {
            app_id: input.app_id.clone(),
            app_name: input.app_name.clone(),
            version: input.version.clone(),
            file_name: input.file_name.clone(),
            url: input.url.clone(),
            dest_path,
            kind: "app".to_string(),
            resource_id: input.app_id.clone(),
            resource_version: input.version.clone(),
            dedup_key: format!("app:{}:{}:{}", input.app_id, input.version, input.file_name),
            expected_sha256: input.expected_sha256.clone(),
            install_after_download: input.install_after_download,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    struct PathCase {
        name: String,
        save_file_name: Option<String>,
        file_name: String,
        downloads_dir: Option<String>,
        docs_dir: String,
        expected: String,
    }

    fn fixture_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../test/fixtures/download_path_cases.json")
    }

    fn load_cases() -> Vec<PathCase> {
        let raw = std::fs::read_to_string(fixture_path())
            .expect("read test/fixtures/download_path_cases.json");
        serde_json::from_str(&raw).expect("parse download_path_cases.json")
    }

    fn resolve(case: &PathCase) -> String {
        let downloads = case.downloads_dir.as_deref().map(Path::new);
        resolve_save_path(
            downloads,
            Path::new(&case.docs_dir),
            case.save_file_name.as_deref(),
            &case.file_name,
        )
        .to_string_lossy()
        .into_owned()
    }

    fn localdb_input(case: &PathCase) -> StrategyInput {
        StrategyInput {
            app_id: "com.example.app".to_string(),
            app_name: "Example".to_string(),
            version: "1.2.3".to_string(),
            file_name: case.file_name.clone(),
            url: "https://example.com/app.apk".to_string(),
            save_file_name: case.save_file_name.clone(),
            downloads_dir: case.downloads_dir.as_deref().map(PathBuf::from),
            docs_dir: PathBuf::from(&case.docs_dir),
            expected_sha256: Some("abc123".to_string()),
            install_after_download: true,
        }
    }

    #[test]
    fn download_localdb_strategy_path() {
        let cases = load_cases();
        assert!(!cases.is_empty(), "fixture must contain cases");

        for case in &cases {
            let resolved = resolve(case);
            assert_eq!(
                resolved, case.expected,
                "resolve_save_path mismatch for case {:?}",
                case.name
            );

            let input = localdb_input(case);
            let req = LocalDbStrategy
                .build(&input)
                .expect("LocalDbStrategy build");

            assert_eq!(
                req.dest_path, case.expected,
                "dest_path mismatch for case {:?}",
                case.name
            );
            assert_eq!(req.kind, "app");
            assert_eq!(req.resource_id, "com.example.app");
            assert_eq!(req.resource_version, "1.2.3");
            assert_eq!(
                req.dedup_key,
                format!("app:com.example.app:1.2.3:{}", case.file_name)
            );
            assert_eq!(req.expected_sha256.as_deref(), Some("abc123"));
            assert!(req.install_after_download);
            assert_eq!(req.app_id, "com.example.app");
            assert_eq!(req.app_name, "Example");
            assert_eq!(req.version, "1.2.3");
            assert_eq!(req.file_name, case.file_name);
            assert_eq!(req.url, "https://example.com/app.apk");
        }
    }

    #[test]
    fn path_resolution_matches_shared_fixture() {
        let cases = load_cases();
        assert!(!cases.is_empty(), "fixture must contain cases");

        for case in &cases {
            assert_eq!(
                resolve(case),
                case.expected,
                "shared fixture mismatch for case {:?}",
                case.name
            );
        }
    }

    #[test]
    fn relative_save_file_name_is_not_absolute() {
        // Adversarial: a relative save_file_name must NOT be treated as
        // absolute — it falls back to <downloads_dir>/<file_name>.
        let resolved = resolve_save_path(
            Some(Path::new("/downloads")),
            Path::new("/docs"),
            Some("relative/name.apk"),
            "fallback.apk",
        );
        assert_eq!(resolved, PathBuf::from("/downloads/fallback.apk"));

        // Without a downloads dir it falls back to docs_dir.
        let resolved = resolve_save_path(
            None,
            Path::new("/docs"),
            Some("relative/name.apk"),
            "fallback.apk",
        );
        println!("docs-dir fallback resolved {resolved:?}");
        assert_eq!(resolved, PathBuf::from("/docs/fallback.apk"));
    }
}
