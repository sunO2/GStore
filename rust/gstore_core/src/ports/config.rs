//! Driver configuration.
//!
//! Accessors only: the fields are private so the token cannot be mutated or
//! accidentally serialized. `Debug` intentionally redacts the GitHub token and
//! proxy credentials.

use crate::error::Error;
use crate::ports::http::validate_http_url;
use crate::ports::http::validate_proxy_url;

/// Configuration consumed by the GitHub / LocalDb / F-Droid drivers.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct CoreConfig {
    proxy_url: Option<String>,
    github_token: Option<String>,
    fdroid_sources: Vec<String>,
    /// Every base URL whose prefix an F-Droid icon may carry: the configured
    /// source URLs plus their mirrors. A stored absolute icon written under
    /// one of these bases is re-based onto the row's current source.
    fdroid_asset_bases: Vec<String>,
}


impl CoreConfig {
    /// Creates a configuration.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for a malformed proxy URL or an empty
    /// GitHub token.
    pub fn new(proxy_url: Option<String>, github_token: Option<String>) -> Result<Self, Error> {
        if let Some(proxy) = &proxy_url {
            if proxy.trim().is_empty() {
                return Err(Error::InvalidArgument(
                    "proxy_url must not be empty".to_string(),
                ));
            }
            validate_proxy_url(proxy)?;
        }
        if let Some(token) = &github_token {
            if token.trim().is_empty() {
                return Err(Error::InvalidArgument(
                    "github_token must not be empty".to_string(),
                ));
            }
        }
        Ok(Self {
            proxy_url,
            github_token,
            fdroid_sources: Vec::new(),
            fdroid_asset_bases: Vec::new(),
        })
    }

    /// Sets the F-Droid source URLs.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for an empty source or a malformed
    /// HTTP(S) URL.
    pub fn with_fdroid_sources(mut self, sources: Vec<String>) -> Result<Self, Error> {
        for source in &sources {
            if source.trim().is_empty() {
                return Err(Error::InvalidArgument(
                    "fdroid source must not be empty".to_string(),
                ));
            }
            validate_http_url(source)?;
        }
        self.fdroid_sources = sources;
        Ok(self)
    }

    /// Sets the base URLs (configured sources plus mirrors) a stored F-Droid
    /// icon may be prefixed with.
    ///
    /// Entries are trimmed and de-duplicated; an empty entry is ignored so a
    /// caller can pass a mixed source/mirror list without pre-filtering.
    pub fn with_fdroid_asset_bases(mut self, bases: Vec<String>) -> Self {
        let mut seen = std::collections::HashSet::new();
        self.fdroid_asset_bases = bases
            .into_iter()
            .map(|base| base.trim().trim_end_matches('/').to_string())
            .filter(|base| !base.is_empty())
            .filter(|base| seen.insert(base.clone()))
            .collect();
        self
    }

    /// Configured proxy URL, if any.
    pub fn proxy_url(&self) -> Option<&str> {
        self.proxy_url.as_deref()
    }

    /// Configured GitHub token, if any.
    pub fn github_token(&self) -> Option<&str> {
        self.github_token.as_deref()
    }

    /// Whether a GitHub token is configured.
    pub fn has_github_token(&self) -> bool {
        self.github_token.is_some()
    }

    /// Configured F-Droid sources.
    pub fn fdroid_sources(&self) -> &[String] {
        &self.fdroid_sources
    }

    /// Configured F-Droid icon bases: source URLs plus mirrors.
    pub fn fdroid_asset_bases(&self) -> &[String] {
        &self.fdroid_asset_bases
    }
}

impl std::fmt::Debug for CoreConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let proxy = self.proxy_url.as_deref().map(redact_proxy);
        let token = self.github_token.as_ref().map(|_| "<redacted>");
        f.debug_struct("CoreConfig")
            .field("proxy_url", &proxy)
            .field("github_token", &token)
            .field("fdroid_sources", &self.fdroid_sources)
            .field("fdroid_asset_bases", &self.fdroid_asset_bases)
            .finish()
    }
}

fn redact_proxy(proxy: &str) -> String {
    let Some((scheme, rest)) = proxy.split_once("://") else {
        return "<redacted>".to_string();
    };
    if let Some((_, host)) = rest.rsplit_once('@') {
        format!("{scheme}://<redacted>@{host}")
    } else {
        proxy.to_string()
    }
}
