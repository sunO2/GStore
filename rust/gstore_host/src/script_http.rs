//! `host.network.*` transport for the production script host.
//!
//! The Dart prefix accepts `{params, headers, body|json}`; this module applies
//! them to the core [`HttpOptions`] seam and decodes the body the way Dart's
//! `_decodeData` does (JSON when parseable, otherwise the UTF-8 string). Status
//! passthrough is the bridge's job: a non-2xx response still returns its body.

use std::sync::Arc;

use gstore_core::ports::{HttpOptions, HttpPort};
use gstore_script::{HttpMethod, HttpRequest, HttpResponse as HostHttpResponse, ScriptError};
use serde_json::Value as JsonValue;

pub(crate) fn perform(
    port: &Arc<dyn HttpPort>,
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
    let response = match request.method {
        HttpMethod::Get => port
            .get(&url, &options)
            .map_err(|error| host_error("http", error))?,
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
            port.post(&url, &body, &options)
                .map_err(|error| host_error("http", error))?
        }
    };
    Ok(HostHttpResponse::new(
        response.status,
        decode(&response.body),
    ))
}

fn host_error(context: &str, error: impl std::fmt::Display) -> ScriptError {
    ScriptError::host(format!("CORE_E_SCRIPT_HOST: {context}: {error}"))
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
    use serde_json::json;

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
}
