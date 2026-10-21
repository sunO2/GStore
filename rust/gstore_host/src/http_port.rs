//! Reqwest-backed [`HttpPort`] implementation.
//!
//! Lives in `gstore_host` because reqwest (and its blocking runtime) must not
//! leak into `gstore_core`. The core trait is synchronous; every request builds
//! a bounded client from the validated [`HttpOptions`].

use std::time::Duration;

use gstore_core::ports::{validate_http_url, HttpOptions, HttpPort, HttpResponse};
use gstore_core::Error;

/// Synchronous reqwest transport.
#[derive(Debug, Default, Clone, Copy)]
pub struct ReqwestHttpPort;

impl ReqwestHttpPort {
    /// Creates the transport.
    pub const fn new() -> Self {
        Self
    }

    fn execute(request: reqwest::blocking::RequestBuilder) -> Result<HttpResponse, Error> {
        let response = request.send().map_err(network_error)?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_string(),
                    value.to_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let body = response.bytes().map_err(network_error)?.to_vec();
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

impl HttpPort for ReqwestHttpPort {
    fn get(&self, url: &str, options: &HttpOptions) -> Result<HttpResponse, Error> {
        validate_http_url(url)?;
        let client = build_client(options)?;
        let request = client.get(url).headers(header_map(options)?);
        Self::execute(request)
    }

    fn post(&self, url: &str, body: &[u8], options: &HttpOptions) -> Result<HttpResponse, Error> {
        validate_http_url(url)?;
        let client = build_client(options)?;
        let request = client
            .post(url)
            .headers(header_map(options)?)
            .body(body.to_vec());
        Self::execute(request)
    }
}

fn build_client(options: &HttpOptions) -> Result<reqwest::blocking::Client, Error> {
    options.validate()?;
    let mut builder = reqwest::blocking::Client::builder()
        .timeout(options.timeout)
        .connect_timeout(options.timeout.min(Duration::from_secs(30)))
        .redirect(reqwest::redirect::Policy::limited(10));
    if let Some(proxy) = &options.proxy {
        let proxy = reqwest::Proxy::all(proxy)
            .map_err(|_| Error::InvalidArgument("invalid proxy url".to_string()))?;
        builder = builder.proxy(proxy);
    }
    if let Some(ca) = &options.ca_pem {
        if !looks_like_pem_certificate(ca) {
            return Err(Error::InvalidArgument("invalid CA override".to_string()));
        }
        let certificate = reqwest::Certificate::from_pem(ca)
            .map_err(|_| Error::InvalidArgument("invalid CA override".to_string()))?;
        builder = builder.add_root_certificate(certificate);
    }
    builder
        .build()
        .map_err(|_| Error::Network("build http client failed".to_string()))
}

fn looks_like_pem_certificate(pem: &[u8]) -> bool {
    let text = String::from_utf8_lossy(pem);
    text.contains("-----BEGIN CERTIFICATE-----") && text.contains("-----END CERTIFICATE-----")
}

fn header_map(options: &HttpOptions) -> Result<reqwest::header::HeaderMap, Error> {
    let mut headers = reqwest::header::HeaderMap::new();
    for (name, value) in &options.headers {
        let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| Error::InvalidArgument("invalid http header name".to_string()))?;
        let value = reqwest::header::HeaderValue::from_str(value)
            .map_err(|_| Error::InvalidArgument("invalid http header value".to_string()))?;
        headers.append(name, value);
    }
    Ok(headers)
}

fn network_error(error: reqwest::Error) -> Error {
    // `without_url` keeps the error free of request URLs (which may carry query
    // tokens) and proxy credentials; no secret is ever interpolated here.
    Error::Network(format!("http request failed: {}", error.without_url()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_proxy_fails_before_any_request() {
        let options = HttpOptions::new().with_proxy("not a proxy url");
        let error = ReqwestHttpPort::new()
            .get("https://example.test/nope", &options)
            .unwrap_err();
        assert_eq!(error.code(), "invalid_argument");
    }

    #[test]
    fn malformed_ca_fails_before_any_request() {
        let options = HttpOptions::new().with_ca_pem(b"not a certificate".to_vec());
        let error = ReqwestHttpPort::new()
            .get("https://example.test/nope", &options)
            .unwrap_err();
        assert_eq!(error.code(), "invalid_argument");
    }

    #[test]
    fn malformed_url_is_rejected() {
        let error = ReqwestHttpPort::new()
            .get("not a url", &HttpOptions::new())
            .unwrap_err();
        assert_eq!(error.code(), "invalid_argument");
    }
}
