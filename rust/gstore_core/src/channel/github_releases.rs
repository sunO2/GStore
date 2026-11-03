//! Shared GitHub REST fetcher (releases + README).
//!
//! Both the GitHub channel driver and the LocalDb driver's GitHub-repository
//! apps read `GET /repos/{owner}/{repo}/releases?per_page=1` and
//! `GET /repos/{owner}/{repo}/contents/README.md`. Dart does the same: both
//! `GitHubChannel.getAppDetail` and `LocalDbChannel.getAppDetail` call
//! `GithubRestClient.releases`. The HTTP + JSON handling therefore lives here
//! once instead of being duplicated across the two drivers.
//!
//! Network access goes exclusively through [`HttpPort`]; this crate never links
//! an HTTP client. `CoreConfig` supplies the proxy and token. Tokens and proxy
//! credentials are never interpolated into an error message.

use std::sync::Arc;

use serde_json::{Map, Value};

use crate::dto::{AppDownload, insert_info_tag};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::{HttpOptions, HttpPort, HttpResponse};

const GITHUB_API: &str = "https://api.github.com";
const ACCEPT: &str = "application/vnd.github+json";
const USER_AGENT: &str = "GStore-App/1.0";

/// Copies GitHub repository metadata that both the GitHub channel and the
/// GStore catalog fallback expose through the generic detail `extra` map.
pub(crate) fn apply_repo_extra(
    extra: &mut Map<String, Value>,
    repo: &Map<String, Value>,
) {
    let mut api_data = Map::new();
    for key in ["stargazers_count", "watchers_count", "forks_count"] {
        if let Some(value) = repo.get(key) {
            api_data.insert(key.to_string(), value.clone());
        }
    }
    if !api_data.is_empty() {
        extra.insert("apiData".to_string(), Value::Object(api_data));
    }
    if let Some(license) = repo
        .get("license")
        .and_then(|value| value.get("spdx_id"))
        .and_then(Value::as_str)
    {
        insert_info_tag(extra, "license", "许可证", license);
    }
    if let Some(language) = repo.get("language").and_then(Value::as_str) {
        insert_info_tag(extra, "language", "语言", language);
    }
    if let Some(pushed_at) = repo.get("pushed_at").and_then(Value::as_str) {
        extra.insert(
            "pushedAt".to_string(),
            Value::String(pushed_at.to_string()),
        );
    }
    if let Some(issues) = repo.get("open_issues_count").and_then(Value::as_i64) {
        insert_info_tag(extra, "openIssues", "Issues", issues.to_string());
    }
    if let Some(topics) = repo.get("topics").and_then(Value::as_array) {
        let topics = topics
            .iter()
            .filter_map(Value::as_str)
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>()
            .join(" / ");
        insert_info_tag(extra, "topics", "主题", topics);
    }
}

/// GitHub REST fetcher bound to a [`CoreConfig`] and [`HttpPort`].
pub struct GitHubReleases {
    config: CoreConfig,
    http: Arc<dyn HttpPort>,
}

impl GitHubReleases {
    /// Creates a fetcher.
    pub fn new(config: CoreConfig, http: Arc<dyn HttpPort>) -> Self {
        Self { config, http }
    }

    fn http_options(&self) -> HttpOptions {
        let mut options = HttpOptions::new()
            .with_header("Accept", ACCEPT)
            .with_header("User-Agent", USER_AGENT);
        if let Some(token) = self.config.github_token() {
            options = options.with_header("Authorization", format!("Bearer {token}"));
        }
        if let Some(proxy) = self.config.proxy_url() {
            options = options.with_proxy(proxy);
        }
        options
    }

    pub(crate) fn get_value(&self, url: &str) -> Result<(u16, Value), Error> {
        let options = self.http_options();
        let response = self.http.get(url, &options)?;
        let status = response.status;
        if !response.is_success() {
            return Err(map_status_error(status, &response, url));
        }
        let text = response.text()?;
        let value = serde_json::from_str(text)
            .map_err(|error| api_error(status, url, format!("malformed JSON: {error}")))?;
        Ok((status, value))
    }

    /// `GET /repos/{owner}/{repo}`.
    pub fn repo_url(owner: &str, repo: &str) -> String {
        format!("{GITHUB_API}/repos/{owner}/{repo}")
    }

    /// `GET /repos/{owner}/{repo}/releases?per_page=1`.
    pub fn releases_url(owner: &str, repo: &str) -> String {
        format!("{GITHUB_API}/repos/{owner}/{repo}/releases?per_page=1")
    }

    /// `GET /repos/{owner}/{repo}/contents/README.md`.
    pub fn readme_url(owner: &str, repo: &str) -> String {
        format!("{GITHUB_API}/repos/{owner}/{repo}/contents/README.md")
    }

    /// Fetches the latest release as `(downloads, version)`.
    ///
    /// The version is the release `name`, falling back to `tag_name`; downloads
    /// are the latest release's assets with their platform tag derived from the
    /// file name. An empty release list yields `(vec![], None)`.
    pub fn fetch_releases(
        &self,
        owner: &str,
        repo: &str,
    ) -> Result<(Vec<AppDownload>, Option<String>), Error> {
        let url = Self::releases_url(owner, repo);
        let (status, value) = self.get_value(&url)?;
        let releases = value.as_array().ok_or_else(|| {
            api_error(
                status,
                &url,
                "expected a JSON array of releases".to_string(),
            )
        })?;
        let Some(latest) = releases.first().and_then(Value::as_object) else {
            return Ok((Vec::new(), None));
        };
        let version = optional_string(latest, "name", status, &url)?
            .or(optional_string(latest, "tag_name", status, &url)?);
        let mut downloads = Vec::new();
        if let Some(assets) = latest.get("assets") {
            let assets = assets.as_array().ok_or_else(|| {
                api_error(status, &url, "release assets must be an array".to_string())
            })?;
            for asset in assets {
                let asset = asset.as_object().ok_or_else(|| {
                    api_error(status, &url, "release asset must be an object".to_string())
                })?;
                let name = optional_string(asset, "name", status, &url)?.unwrap_or_default();
                let download_url = optional_string(asset, "browser_download_url", status, &url)?
                    .unwrap_or_default();
                let size = optional_i64(asset, "size", status, &url)?;
                let download_count = optional_i64(asset, "download_count", status, &url)?;
                downloads.push(AppDownload {
                    url: download_url,
                    platform: parse_platform(&name),
                    name,
                    size,
                    download_count,
                    version: version.clone(),
                    version_code: None,
                    published_at: None,
                    hash: None,
                    hash_type: None,
                    downloadable: true,
                    note: None,
                    extra: None,
                });
            }
        }
        Ok((downloads, version))
    }

    /// Fetches and decodes the repository README (base64 body).
    ///
    /// A non-2xx response or malformed payload yields `None`, letting callers
    /// fall back to stored text exactly as Dart does.
    pub fn fetch_readme(&self, owner: &str, repo: &str) -> Result<Option<String>, Error> {
        let url = Self::readme_url(owner, repo);
        let response = self.http.get(&url, &self.http_options())?;
        if !response.is_success() {
            return Ok(None);
        }
        let value: Value = match serde_json::from_slice(&response.body) {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        let Some(content) = value.get("content").and_then(Value::as_str) else {
            return Ok(None);
        };
        let encoding = value
            .get("encoding")
            .and_then(Value::as_str)
            .unwrap_or("base64");
        if encoding != "base64" {
            return Ok(Some(content.to_string()));
        }
        Ok(decode_base64(content).and_then(|bytes| String::from_utf8(bytes).ok()))
    }
}

/// Builds a typed API error that never interpolates credentials.
pub(crate) fn api_error(status: u16, url: &str, details: String) -> Error {
    Error::Serialization(format!("GitHub API status {status} from {url}: {details}"))
}

pub(crate) fn map_status_error(status: u16, response: &HttpResponse, url: &str) -> Error {
    let message = format!("GitHub API returned status {status} for {url}");
    match status {
        401 => Error::Unauthorized(message),
        403 => {
            let body = String::from_utf8_lossy(&response.body).to_ascii_lowercase();
            if body.contains("rate limit") {
                Error::RateLimited(message)
            } else {
                Error::Forbidden(message)
            }
        }
        404 => Error::NotFound(message),
        429 => Error::RateLimited(message),
        _ => Error::Network(message),
    }
}

pub(crate) fn optional_string(
    object: &Map<String, Value>,
    key: &str,
    status: u16,
    url: &str,
) -> Result<Option<String>, Error> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(api_error(
            status,
            url,
            format!("field {key:?} must be a string"),
        )),
    }
}

fn optional_i64(
    object: &Map<String, Value>,
    key: &str,
    status: u16,
    url: &str,
) -> Result<Option<i64>, Error> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| api_error(status, url, format!("field {key:?} must be an integer"))),
        Some(_) => Err(api_error(
            status,
            url,
            format!("field {key:?} must be an integer"),
        )),
    }
}

fn parse_platform(file_name: &str) -> Option<String> {
    let lower = file_name.to_ascii_lowercase();
    for (needle, platform) in [
        ("universal", "universal"),
        ("arm64-v8a", "arm64-v8a"),
        ("arm64", "arm64-v8a"),
        ("armeabi-v7a", "armeabi-v7a"),
        ("x86_64", "x86_64"),
        ("x86", "x86"),
        ("windows", "windows"),
        ("linux", "linux"),
        ("macos", "macos"),
    ] {
        if lower.contains(needle) {
            return Some(platform.to_string());
        }
    }
    None
}

/// Minimal standard/URL-safe base64 decoder (README contents only).
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let mut clean: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .map(|byte| match byte {
            b'-' => b'+',
            b'_' => b'/',
            other => other,
        })
        .collect();
    while !clean.len().is_multiple_of(4) {
        clean.push(b'=');
    }
    let mut output = Vec::with_capacity(clean.len() / 4 * 3);
    for chunk in clean.chunks(4) {
        let mut values = [0_u8; 4];
        let mut padding = 0;
        for (index, byte) in chunk.iter().enumerate() {
            values[index] = match byte {
                b'A'..=b'Z' => byte - b'A',
                b'a'..=b'z' => byte - b'a' + 26,
                b'0'..=b'9' => byte - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' => {
                    padding += 1;
                    0
                }
                _ => return None,
            };
        }
        output.push((values[0] << 2) | (values[1] >> 4));
        if padding < 2 {
            output.push((values[1] << 4) | (values[2] >> 2));
        }
        if padding < 1 {
            output.push((values[2] << 6) | values[3]);
        }
    }
    Some(output)
}
