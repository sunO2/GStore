//! Synchronous HTTP port shared by the channel drivers.
//!
//! `gstore_core` intentionally stays free of an async runtime. The production
//! implementation lives in `gstore_host` (reqwest) and core tests use the
//! recording fake, which exposes the exact proxy/CA/timeout values that were
//! applied.

use std::time::Duration;

use crate::error::Error;

/// Default request timeout.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Validated per-request HTTP options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpOptions {
    /// Additional request headers (name/value), applied in order.
    pub headers: Vec<(String, String)>,
    /// Total request timeout. Must be non-zero.
    pub timeout: Duration,
    /// Optional HTTP(S) proxy URL.
    pub proxy: Option<String>,
    /// Optional PEM-encoded CA override.
    pub ca_pem: Option<Vec<u8>>,
}

impl Default for HttpOptions {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpOptions {
    /// Default options (30s timeout, no proxy, no CA override).
    pub fn new() -> Self {
        Self {
            headers: Vec::new(),
            timeout: DEFAULT_TIMEOUT,
            proxy: None,
            ca_pem: None,
        }
    }

    /// Adds one header.
    #[must_use]
    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    /// Replaces the timeout.
    #[must_use]
    pub const fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Sets the proxy URL.
    #[must_use]
    pub fn with_proxy(mut self, proxy: impl Into<String>) -> Self {
        self.proxy = Some(proxy.into());
        self
    }

    /// Sets the PEM CA override.
    #[must_use]
    pub fn with_ca_pem(mut self, ca_pem: impl Into<Vec<u8>>) -> Self {
        self.ca_pem = Some(ca_pem.into());
        self
    }

    /// Validates this option set.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for a zero timeout, a malformed proxy
    /// URL, an empty CA override, or an invalid header.
    pub fn validate(&self) -> Result<(), Error> {
        if self.timeout.is_zero() {
            return Err(Error::InvalidArgument(
                "http timeout must be greater than zero".to_string(),
            ));
        }
        if let Some(proxy) = &self.proxy {
            validate_proxy_url(proxy)?;
        }
        if let Some(ca) = &self.ca_pem {
            if ca.is_empty() {
                return Err(Error::InvalidArgument(
                    "CA override must not be empty".to_string(),
                ));
            }
        }
        for (name, value) in &self.headers {
            validate_header(name, value)?;
        }
        Ok(())
    }
}

/// HTTP response returned by an [`HttpPort`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// Status code.
    pub status: u16,
    /// Response headers.
    pub headers: Vec<(String, String)>,
    /// Raw response body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    /// Whether the status is in the 2xx range.
    pub const fn is_success(&self) -> bool {
        self.status >= 200 && self.status < 300
    }

    /// Decodes the body as UTF-8.
    ///
    /// # Errors
    /// Returns [`Error::Serialization`] when the body is not valid UTF-8.
    pub fn text(&self) -> Result<&str, Error> {
        std::str::from_utf8(&self.body)
            .map_err(|error| Error::Serialization(format!("response body is not UTF-8: {error}")))
    }
}

/// Synchronous HTTP transport.
pub trait HttpPort {
    /// Performs a GET request.
    fn get(&self, url: &str, options: &HttpOptions) -> Result<HttpResponse, Error>;

    /// Performs a POST request with a raw body.
    fn post(&self, url: &str, body: &[u8], options: &HttpOptions) -> Result<HttpResponse, Error>;
}

fn validate_header(name: &str, value: &str) -> Result<(), Error> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "!#$%&'*+-.^_`|~".contains(c))
    {
        return Err(Error::InvalidArgument(format!(
            "invalid http header name: {name:?}"
        )));
    }
    if value.contains('\r') || value.contains('\n') {
        return Err(Error::InvalidArgument(format!(
            "invalid http header value for {name}"
        )));
    }
    Ok(())
}

/// Validates an absolute HTTP(S) URL without pulling in a URL parser.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] for a malformed URL.
pub fn validate_http_url(url: &str) -> Result<(), Error> {
    validate_scheme_and_authority(url, &["http", "https"], "http url")
}

/// Validates an HTTP(S) proxy URL.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] for a malformed proxy URL.
pub fn validate_proxy_url(url: &str) -> Result<(), Error> {
    validate_scheme_and_authority(url, &["http", "https"], "proxy url")
}

fn validate_scheme_and_authority(url: &str, schemes: &[&str], label: &str) -> Result<(), Error> {
    if url.is_empty() || url.trim() != url {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: empty or padded"
        )));
    }
    let Some((scheme, rest)) = url.split_once("://") else {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: missing scheme"
        )));
    };
    if !schemes.contains(&scheme.to_ascii_lowercase().as_str()) {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: unsupported scheme {scheme}"
        )));
    }
    let authority = rest.split('/').next().unwrap_or_default();
    if authority.is_empty() || authority.starts_with('@') {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: missing host"
        )));
    }
    if authority
        .chars()
        .any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: whitespace in authority"
        )));
    }
    let host_port = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    if host_port.is_empty() {
        return Err(Error::InvalidArgument(format!(
            "invalid {label}: missing host"
        )));
    }
    // Reject a clearly non-numeric port (IPv6 literals with brackets are left
    // to the transport, which has a full URL parser).
    if !host_port.starts_with('[') {
        if let Some((host, port)) = host_port.rsplit_once(':') {
            if host.is_empty() || (!port.is_empty() && !port.chars().all(|c| c.is_ascii_digit())) {
                return Err(Error::InvalidArgument(format!(
                    "invalid {label}: malformed host or port"
                )));
            }
        }
    }
    Ok(())
}
