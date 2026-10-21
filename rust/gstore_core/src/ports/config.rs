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
}

impl std::fmt::Debug for CoreConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let proxy = self.proxy_url.as_deref().map(redact_proxy);
        let token = self.github_token.as_ref().map(|_| "<redacted>");
        f.debug_struct("CoreConfig")
            .field("proxy_url", &proxy)
            .field("github_token", &token)
            .field("fdroid_sources", &self.fdroid_sources)
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
