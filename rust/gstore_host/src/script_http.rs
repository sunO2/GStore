//! `host.network.*` transport for the production script host.
//!
//! The Dart prefix accepts `{params, headers, body|json}`; this module applies
//! them to the core [`HttpOptions`] seam and decodes the body the way Dart's
//! `_decodeData` does (JSON when parseable, otherwise the UTF-8 string). Status
//! passthrough is the bridge's job: a non-2xx response still returns its body.
//!
//! # Sandbox bounds
//!
//! Production uses [`ScriptHttp`], not the unbounded [`HttpPort`] methods, so
//! both transport ceilings are enforced before the bridge sees a response:
//!
//! - redirects: `min(request.max_redirects, 5)`, with the last `3xx` returned
//!   once the cap is reached (never an error, never a 10th hop);
//! - response body: streamed up to the 20 MB contract limit, aborting with a
//!   typed [`ScriptError::limit`] (`CORE_E_SCRIPT_LIMIT`) before a large body is
//!   fully buffered. The error carries no `data`, so the bridge cannot emit a
//!   partial success envelope.

use std::sync::Arc;

use gstore_core::ports::HttpOptions;
use gstore_script::{
    HttpMethod, HttpRequest, HttpResponse as HostHttpResponse, ScriptError, DEFAULT_MAX_REDIRECTS,
    DEFAULT_MAX_RESPONSE_BYTES,
};
use serde_json::Value as JsonValue;

use crate::http_port::{ScriptHttp, ScriptHttpLimits, TransportError};

pub(crate) fn perform(
    port: &Arc<dyn ScriptHttp>,
    request: HttpRequest,
) -> Result<HostHttpResponse, ScriptError> {
    let url = build_url(&request.url, &request.opts)?;
    let mut options = HttpOptions::new();
    if let Some(headers) = request.opts.get("headers").and_then(JsonValue::as_object) {
        for (name, value) in headers {
            let value = match value {
                JsonValue::String(text) => text.clone(),
                other => other.to_string(),
            };
            options = options.with_header(name.clone(), value);
        }
    }
    let limits = ScriptHttpLimits {
        // The bridge already clamps the request; clamp again here so the
        // transport is safe even when called directly.
        max_redirects: request.max_redirects.min(DEFAULT_MAX_REDIRECTS),
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
    };
    let response = match request.method {
        HttpMethod::Get => port
            .get_bounded(&url, &options, limits)
            .map_err(|error| transport_error("http", error))?,
        HttpMethod::Post => {
            let body = request
                .opts
                .get("body")
                .or_else(|| request.opts.get("json"))
                .map(|value| match value {
                    JsonValue::String(text) => text.clone().into_bytes(),
                    other => other.to_string().into_bytes(),
                })
                .unwrap_or_default();
            port.post_bounded(&url, &body, &options, limits)
                .map_err(|error| transport_error("http", error))?
        }
    };
    Ok(HostHttpResponse::new(
        response.status,
        decode(&response.body),
    ))
}

fn transport_error(context: &str, error: TransportError) -> ScriptError {
    match error {
        TransportError::ResponseTooLarge { limit, read } => ScriptError::limit(format!(
            "{context}: response body exceeded {limit} bytes (aborted after {read})"
        )),
        other => ScriptError::host(format!(
            "CORE_E_SCRIPT_HOST: {context}: {}",
            other.message()
        )),
    }
}

fn decode(body: &[u8]) -> JsonValue {
    serde_json::from_slice::<JsonValue>(body)
        .unwrap_or_else(|_| JsonValue::String(String::from_utf8_lossy(body).into()))
}

fn build_url(raw: &str, opts: &JsonValue) -> Result<String, ScriptError> {
    let params = opts.get("params").and_then(JsonValue::as_object);
    if params.is_none_or(|params| params.is_empty()) {
        return Ok(raw.to_owned());
    }
    let mut url = reqwest::Url::parse(raw).map_err(|error| {
        ScriptError::host(format!(
            "CORE_E_SCRIPT_INVALID_ARGUMENT: invalid url: {error}"
        ))
    })?;
    {
        let mut query = url.query_pairs_mut();
        for (name, value) in params.into_iter().flatten() {
            let value = match value {
                JsonValue::String(text) => text.clone(),
                JsonValue::Null => continue,
                other => other.to_string(),
            };
            query.append_pair(name, &value);
        }
    }
    Ok(url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gstore_core::ports::HttpResponse;
    use gstore_script::{ScriptErrorKind, CODE_LIMIT};
    use serde_json::json;

    struct TooLargePort;

    impl ScriptHttp for TooLargePort {
        fn get_bounded(
            &self,
            _url: &str,
            _options: &HttpOptions,
            _limits: ScriptHttpLimits,
        ) -> Result<HttpResponse, TransportError> {
            Err(TransportError::ResponseTooLarge {
                limit: DEFAULT_MAX_RESPONSE_BYTES,
                read: DEFAULT_MAX_RESPONSE_BYTES + 1,
            })
        }

        fn post_bounded(
            &self,
            _url: &str,
            _body: &[u8],
            _options: &HttpOptions,
            _limits: ScriptHttpLimits,
        ) -> Result<HttpResponse, TransportError> {
            Err(TransportError::ResponseTooLarge {
                limit: DEFAULT_MAX_RESPONSE_BYTES,
                read: DEFAULT_MAX_RESPONSE_BYTES + 1,
            })
        }
    }

    #[test]
    fn query_params_are_appended_and_encoded() {
        let url = build_url(
            "https://example.test/a",
            &json!({"params": {"q": "a b", "n": 1}}),
        )
        .expect("url");
        assert_eq!(url, "https://example.test/a?n=1&q=a+b");
    }

    #[test]
    fn invalid_url_is_a_host_error() {
        let error = build_url("not a url", &json!({"params": {"a": "b"}})).unwrap_err();
        assert!(error.to_string().contains("CORE_E_SCRIPT_INVALID_ARGUMENT"));
    }

    #[test]
    fn oversized_streamed_body_is_a_typed_limit_without_data() {
        let port: Arc<dyn ScriptHttp> = Arc::new(TooLargePort);
        let request = HttpRequest {
            method: HttpMethod::Get,
            url: "http://127.0.0.1/too-big".to_string(),
            opts: json!({}),
            max_redirects: DEFAULT_MAX_REDIRECTS,
        };
        let error = perform(&port, request).expect_err("oversized body must fail");
        assert_eq!(error.kind(), ScriptErrorKind::Limit);
        assert_eq!(error.code(), CODE_LIMIT);
        assert!(error.to_string().contains("CORE_E_SCRIPT_LIMIT"), "{error}");
        assert!(
            error.to_string().contains("aborted after"),
            "the abort point is part of the typed error: {error}"
        );
    }
}
