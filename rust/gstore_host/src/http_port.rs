//! Reqwest-backed [`HttpPort`] implementation.
//!
//! Lives in `gstore_host` because reqwest (and its blocking runtime) must not
//! leak into `gstore_core`. The core trait is synchronous; every request builds
//! a bounded client from the validated [`HttpOptions`].
//!
//! # Script lane
//!
//! The script host does not use the unbounded [`HttpPort`] methods. It goes
//! through [`ScriptHttp`], which carries the two bounds the sandbox promises:
//!
//! - a per-request redirect cap (`ScriptHttpLimits::max_redirects`) applied with
//!   a custom policy that **stops** at the cap and returns the last `3xx`
//!   response, rather than erroring like `reqwest::redirect::Policy::limited`;
//! - a streaming response-body cap (`ScriptHttpLimits::max_response_bytes`)
//!   enforced while reading, so an oversized body is never fully buffered.
//!
//! Non-script callers keep using [`HttpPort`] unchanged: its redirect policy is
//! still `Policy::limited(10)` and its body is still buffered in full, exactly
//! as before. The two surfaces are separate impls on the same type, so the
//! script caps cannot change catalog/other transport behaviour.

use std::io::Read;
#[cfg(test)]
use std::sync::Arc;
use std::time::Duration;

use gstore_core::ports::{validate_http_url, HttpOptions, HttpPort, HttpResponse};
use gstore_core::Error;

/// Synchronous reqwest transport.
#[derive(Debug, Default, Clone, Copy)]
#[flutter_rust_bridge::frb(opaque)]
pub struct ReqwestHttpPort;

impl ReqwestHttpPort {
    /// Creates the transport.
    pub const fn new() -> Self {
        Self
    }

    fn execute(request: reqwest::blocking::RequestBuilder) -> Result<HttpResponse, Error> {
        let response = request.send().map_err(core_network_error)?;
        let status = response.status().as_u16();
        let headers = collect_headers(&response);
        let body = response.bytes().map_err(core_network_error)?.to_vec();
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }

    fn execute_bounded(
        request: reqwest::blocking::RequestBuilder,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        let response = request.send().map_err(transport_network_error)?;
        let status = response.status().as_u16();
        let headers = collect_headers(&response);
        let body = read_body_bounded(response, limits.max_response_bytes)?;
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

/// Per-request bounds used only by the script host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScriptHttpLimits {
    /// Maximum redirects to follow before returning the last `3xx` response.
    pub max_redirects: u32,
    /// Maximum response body bytes to read before aborting.
    pub max_response_bytes: usize,
}

/// Failure of a bounded script-lane request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TransportError {
    /// The caller supplied an unusable URL/option set.
    InvalidArgument(String),
    /// Connection, TLS, timeout, or body-read failure.
    Network(String),
    /// The response body exceeded the streamed limit; `read` is what had been
    /// accumulated when the abort happened (always `limit + 1` at most).
    ResponseTooLarge { limit: usize, read: usize },
}

impl TransportError {
    pub(crate) fn message(&self) -> String {
        match self {
            Self::InvalidArgument(message) | Self::Network(message) => message.clone(),
            Self::ResponseTooLarge { limit, read } => {
                format!("response body exceeded {limit} bytes (aborted after {read})")
            }
        }
    }
}

/// Bounded transport used by the script bridge.
pub(crate) trait ScriptHttp: Send + Sync {
    fn get_bounded(
        &self,
        url: &str,
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError>;

    fn post_bounded(
        &self,
        url: &str,
        body: &[u8],
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError>;
}

impl ScriptHttp for ReqwestHttpPort {
    fn get_bounded(
        &self,
        url: &str,
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        validate_http_url(url)
            .map_err(|error| TransportError::InvalidArgument(error.to_string()))?;
        let client = build_client(options, script_redirect_policy(limits.max_redirects))?;
        let request = client
            .get(url)
            .headers(header_map(options).map_err(TransportError::InvalidArgument)?);
        Self::execute_bounded(request, limits)
    }

    fn post_bounded(
        &self,
        url: &str,
        body: &[u8],
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        validate_http_url(url)
            .map_err(|error| TransportError::InvalidArgument(error.to_string()))?;
        let client = build_client(options, script_redirect_policy(limits.max_redirects))?;
        let request = client
            .post(url)
            .headers(header_map(options).map_err(TransportError::InvalidArgument)?)
            .body(body.to_vec());
        Self::execute_bounded(request, limits)
    }
}

/// Adapter for the test/dependency-injection seam: any core [`HttpPort`] can be
/// used by `ScriptApiInner::init_with_ports`, including `FakeHttpPort`.
///
/// A buffered port cannot stream, so the cap is applied to the already-returned
/// body. Production uses [`ReqwestHttpPort`] directly and gets the streaming
/// abort; the adapter keeps the existing test seam unchanged.
#[cfg(test)]
pub(crate) struct BufferedScriptHttp {
    inner: Arc<dyn HttpPort>,
}

#[cfg(test)]
impl BufferedScriptHttp {
    pub(crate) fn new(inner: Arc<dyn HttpPort>) -> Self {
        Self { inner }
    }

    fn enforce(
        response: HttpResponse,
        max_response_bytes: usize,
    ) -> Result<HttpResponse, TransportError> {
        let read = response.body.len();
        if read > max_response_bytes {
            return Err(TransportError::ResponseTooLarge {
                limit: max_response_bytes,
                read,
            });
        }
        Ok(response)
    }
}

#[cfg(test)]
impl ScriptHttp for BufferedScriptHttp {
    fn get_bounded(
        &self,
        url: &str,
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        let response = self.inner.get(url, options).map_err(buffered_error)?;
        Self::enforce(response, limits.max_response_bytes)
    }

    fn post_bounded(
        &self,
        url: &str,
        body: &[u8],
        options: &HttpOptions,
        limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        let response = self
            .inner
            .post(url, body, options)
            .map_err(buffered_error)?;
        Self::enforce(response, limits.max_response_bytes)
    }
}

#[cfg(test)]
fn buffered_error(error: Error) -> TransportError {
    match error {
        Error::InvalidArgument(message) => TransportError::InvalidArgument(message),
        other => TransportError::Network(other.to_string()),
    }
}

impl HttpPort for ReqwestHttpPort {
    fn get(&self, url: &str, options: &HttpOptions) -> Result<HttpResponse, Error> {
        validate_http_url(url)?;
        let client =
            build_client(options, reqwest::redirect::Policy::limited(10)).map_err(core_error)?;
        let request = client
            .get(url)
            .headers(header_map(options).map_err(Error::InvalidArgument)?);
        Self::execute(request)
    }

    fn post(&self, url: &str, body: &[u8], options: &HttpOptions) -> Result<HttpResponse, Error> {
        validate_http_url(url)?;
        let client =
            build_client(options, reqwest::redirect::Policy::limited(10)).map_err(core_error)?;
        let request = client
            .post(url)
            .headers(header_map(options).map_err(Error::InvalidArgument)?)
            .body(body.to_vec());
        Self::execute(request)
    }
}

/// Script redirect policy: follow `max_redirects` hops, then **stop** so the
/// last `3xx` response is returned (non-2xx passthrough).
///
/// `previous` includes the initial URL, so `len > max` means the cap was
/// reached. This is the same hop count as `Policy::limited(max)` but returns the
/// redirect response instead of a `too many redirects` error.
fn script_redirect_policy(max_redirects: u32) -> reqwest::redirect::Policy {
    let max = usize::try_from(max_redirects).unwrap_or(usize::MAX);
    reqwest::redirect::Policy::custom(move |attempt| {
        if attempt.previous().len() > max {
            attempt.stop()
        } else {
            attempt.follow()
        }
    })
}

fn build_client(
    options: &HttpOptions,
    redirect: reqwest::redirect::Policy,
) -> Result<reqwest::blocking::Client, TransportError> {
    options
        .validate()
        .map_err(|error| TransportError::InvalidArgument(error.to_string()))?;
    let mut builder = reqwest::blocking::Client::builder()
        .timeout(options.timeout)
        .connect_timeout(options.timeout.min(Duration::from_secs(30)))
        .redirect(redirect);
    if let Some(proxy) = &options.proxy {
        let proxy = reqwest::Proxy::all(proxy)
            .map_err(|_| TransportError::InvalidArgument("invalid proxy url".to_string()))?;
        builder = builder.proxy(proxy);
    }
    if let Some(ca) = &options.ca_pem {
        if !looks_like_pem_certificate(ca) {
            return Err(TransportError::InvalidArgument(
                "invalid CA override".to_string(),
            ));
        }
        let certificate = reqwest::Certificate::from_pem(ca)
            .map_err(|_| TransportError::InvalidArgument("invalid CA override".to_string()))?;
        builder = builder.add_root_certificate(certificate);
    }
    builder
        .build()
        .map_err(|_| TransportError::Network("build http client failed".to_string()))
}

fn looks_like_pem_certificate(pem: &[u8]) -> bool {
    let text = String::from_utf8_lossy(pem);
    text.contains("-----BEGIN CERTIFICATE-----") && text.contains("-----END CERTIFICATE-----")
}

fn header_map(options: &HttpOptions) -> Result<reqwest::header::HeaderMap, String> {
    let mut headers = reqwest::header::HeaderMap::new();
    for (name, value) in &options.headers {
        let name = reqwest::header::HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| "invalid http header name".to_string())?;
        let value = reqwest::header::HeaderValue::from_str(value)
            .map_err(|_| "invalid http header value".to_string())?;
        headers.append(name, value);
    }
    Ok(headers)
}

fn collect_headers(response: &reqwest::blocking::Response) -> Vec<(String, String)> {
    response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect()
}

fn core_network_error(error: reqwest::Error) -> Error {
    // `without_url` keeps the error free of request URLs (which may carry query
    // tokens) and proxy credentials; no secret is ever interpolated here.
    Error::Network(format!("http request failed: {}", error.without_url()))
}

fn transport_network_error(error: reqwest::Error) -> TransportError {
    TransportError::Network(format!("http request failed: {}", error.without_url()))
}

fn core_error(error: TransportError) -> Error {
    match error {
        TransportError::InvalidArgument(message) => Error::InvalidArgument(message),
        other => Error::Network(other.message()),
    }
}

/// Reads the body incrementally and aborts as soon as it exceeds `limit`.
///
/// `take(limit + 1)` bounds both the allocation and the bytes pulled off the
/// socket, so a 25 MB (or unbounded) response never lands in memory in full.
fn read_body_bounded(
    response: reqwest::blocking::Response,
    limit: usize,
) -> Result<Vec<u8>, TransportError> {
    let cap = u64::try_from(limit).unwrap_or(u64::MAX).saturating_add(1);
    let mut reader = response.take(cap);
    let mut body = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let read = reader
            .read(&mut chunk)
            .map_err(|error| TransportError::Network(format!("read response body: {error}")))?;
        if read == 0 {
            return Ok(body);
        }
        body.extend_from_slice(&chunk[..read]);
        if body.len() > limit {
            return Err(TransportError::ResponseTooLarge {
                limit,
                read: body.len(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::thread::{self, JoinHandle};
    use std::time::Instant;

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

    /// Loopback HTTP/1.1 server that answers every request identically until
    /// stopped. Hermetic: 127.0.0.1:0, short read timeout, joined on drop.
    struct Loopback {
        addr: SocketAddr,
        requests: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        handle: Option<JoinHandle<()>>,
    }

    impl Loopback {
        fn spawn<F>(respond: F) -> Self
        where
            F: Fn(&mut TcpStream, usize) + Send + 'static,
        {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            let addr = listener.local_addr().expect("loopback addr");
            listener
                .set_nonblocking(true)
                .expect("nonblocking listener");
            let requests = Arc::new(AtomicUsize::new(0));
            let stop = Arc::new(AtomicBool::new(false));
            let count = Arc::clone(&requests);
            let halt = Arc::clone(&stop);
            let handle = thread::spawn(move || {
                while !halt.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
                            let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
                            let index = count.fetch_add(1, Ordering::SeqCst);
                            read_request(&mut stream);
                            respond(&mut stream, index);
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(1));
                        }
                        Err(_) => break,
                    }
                }
            });
            Self {
                addr,
                requests,
                stop,
                handle: Some(handle),
            }
        }

        fn url(&self, path: &str) -> String {
            format!("http://{}{path}", self.addr)
        }

        fn count(&self) -> usize {
            self.requests.load(Ordering::SeqCst)
        }
    }

    impl Drop for Loopback {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    fn read_request(stream: &mut TcpStream) {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(read) => {
                    buffer.extend_from_slice(&chunk[..read]);
                    if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }

    fn write_redirect(stream: &mut TcpStream, location: &str) {
        let response = format!(
            "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let _ = stream.write_all(response.as_bytes());
    }

    fn limits(max_redirects: u32, max_response_bytes: usize) -> ScriptHttpLimits {
        ScriptHttpLimits {
            max_redirects,
            max_response_bytes,
        }
    }

    #[test]
    fn script_redirect_policy_stops_after_five_follows_and_returns_the_302() {
        // Every request redirects to the same URL: an unbounded follower loops
        // forever, and a fixed policy(10) reaches the 11th hop.
        let server = Loopback::spawn(|stream, _index| {
            let addr = stream.local_addr().expect("server addr");
            write_redirect(stream, &format!("http://{addr}/loop"));
        });
        let response = ReqwestHttpPort::new()
            .get_bounded(
                &server.url("/loop"),
                &HttpOptions::new().with_timeout(Duration::from_secs(5)),
                limits(5, 1024 * 1024),
            )
            .expect("bounded GET returns the last redirect");
        assert_eq!(response.status, 302, "redirect response is passed through");
        assert_eq!(
            server.count(),
            6,
            "initial request + exactly 5 followed redirects"
        );
        println!(
            "PASS | redirect cap | max=5 -> requests={} status={}",
            server.count(),
            response.status
        );
    }

    #[test]
    fn script_redirect_policy_zero_does_not_follow() {
        let server = Loopback::spawn(|stream, _index| {
            let addr = stream.local_addr().expect("server addr");
            write_redirect(stream, &format!("http://{addr}/loop"));
        });
        let response = ReqwestHttpPort::new()
            .get_bounded(
                &server.url("/loop"),
                &HttpOptions::new().with_timeout(Duration::from_secs(5)),
                limits(0, 1024 * 1024),
            )
            .expect("zero-hop GET returns the 302");
        assert_eq!(response.status, 302);
        assert_eq!(server.count(), 1, "zero follows");
        println!(
            "PASS | redirect cap | max=0 -> requests={} status={}",
            server.count(),
            response.status
        );
    }

    #[test]
    fn non_script_get_keeps_the_ten_redirect_policy() {
        let server = Loopback::spawn(|stream, _index| {
            let addr = stream.local_addr().expect("server addr");
            write_redirect(stream, &format!("http://{addr}/loop"));
        });
        let error = ReqwestHttpPort::new()
            .get(
                &server.url("/loop"),
                &HttpOptions::new().with_timeout(Duration::from_secs(5)),
            )
            .expect_err("the core policy errors after ten follows");
        let message = error.to_string();
        assert!(message.contains("redirect"), "unexpected error: {message}");
        assert_eq!(
            server.count(),
            11,
            "core HttpPort still follows ten then errors"
        );
        println!(
            "PASS | redirect cap | non-script -> requests={} error={message}",
            server.count()
        );
    }

    #[test]
    fn streaming_response_cap_aborts_before_buffering_the_whole_body() {
        const LIMIT: usize = 20 * 1024 * 1024;
        // Far beyond the limit + any plausible loopback TCP buffering, so the
        // server provably cannot finish writing if the client aborts at 20 MB.
        const TOTAL: usize = 128 * 1024 * 1024;
        let written = Arc::new(AtomicU64::new(0));
        let counter = Arc::clone(&written);
        let server = Loopback::spawn(move |stream, _index| {
            let header =
                format!("HTTP/1.1 200 OK\r\nContent-Length: {TOTAL}\r\nConnection: close\r\n\r\n");
            if stream.write_all(header.as_bytes()).is_err() {
                return;
            }
            let chunk = vec![b'x'; 256 * 1024];
            let mut sent = 0usize;
            while sent < TOTAL {
                let take = (TOTAL - sent).min(chunk.len());
                match stream.write_all(&chunk[..take]) {
                    Ok(()) => {
                        sent += take;
                        counter.store(sent as u64, Ordering::SeqCst);
                    }
                    // The client aborted: expected once the cap is crossed.
                    Err(_) => break,
                }
            }
        });
        let started = Instant::now();
        let error = ReqwestHttpPort::new()
            .get_bounded(
                &server.url("/big"),
                &HttpOptions::new().with_timeout(Duration::from_secs(10)),
                limits(5, LIMIT),
            )
            .expect_err("oversized body must abort with a typed limit error");
        let elapsed = started.elapsed();
        let sent = written.load(Ordering::SeqCst);
        assert!(
            matches!(
                error,
                TransportError::ResponseTooLarge { limit, read }
                    if limit == LIMIT && read > LIMIT
            ),
            "unexpected error: {error:?}"
        );
        assert!(
            sent < TOTAL as u64,
            "client read the whole body: server wrote {sent} of {TOTAL} bytes"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "streaming abort took {elapsed:?}"
        );
        println!(
            "PASS | streaming cap | limit={LIMIT} bytes, server_written={sent}/{TOTAL}, elapsed={elapsed:?}, error={error:?}"
        );
    }
}
