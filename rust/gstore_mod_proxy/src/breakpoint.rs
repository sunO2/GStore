//! `captures.breakpoint.*` — request/response intercept breakpoints (Todo 34).
//!
//! **CONTRACT SKETCH ONLY.** The wire shape is frozen in `API.md` §2.20 so a
//! later dataplane wave can implement it without a second contract change. The
//! MITM pause/resume path is deliberately **not** implemented here: every
//! method returns [`ERR_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED`]. The feature is
//! **default OFF** and, until implemented, no method can change traffic
//! behaviour or block the dataplane.
//!
//! Frozen constants below pin the shape the future dataplane wave must honour:
//! `enabled` defaults to `false`, and a paused flow is auto-released with its
//! original content once `timeoutMs` elapses.

use gstore_contract::error::{ModuleError, StatusCode};

/// Error code returned by every `captures.breakpoint.*` method in this wave.
pub(crate) const ERR_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED: &str =
    "PROXY_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED";

/// Frozen default: breakpoints are **OFF** (no traffic behaviour change).
#[allow(dead_code)]
pub(crate) const DEFAULT_BREAKPOINT_ENABLED: bool = false;

/// Frozen default pause ceiling: 15 s.
#[allow(dead_code)]
pub(crate) const DEFAULT_BREAKPOINT_TIMEOUT_MS: u64 = 15_000;

/// Frozen lower clamp for `timeoutMs`.
#[allow(dead_code)]
pub(crate) const MIN_BREAKPOINT_TIMEOUT_MS: u64 = 1_000;

/// Frozen upper clamp for `timeoutMs`; a paused flow can never block the
/// dataplane past this.
#[allow(dead_code)]
pub(crate) const MAX_BREAKPOINT_TIMEOUT_MS: u64 = 120_000;

/// Frozen contract sketch: the MITM pause/resume dataplane path is not
/// implemented in this wave. Returns a structured 500 (`&str` code) so the
/// client sees an explicit "not implemented" instead of a misleading
/// `METHOD_NOT_FOUND`.
pub(crate) fn stub_arm(method: &str) -> Result<Vec<u8>, ModuleError> {
    Err(ModuleError::new(
        StatusCode::InternalError,
        ERR_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED,
        format!(
            "{method}: request/response intercept breakpoints are a frozen contract sketch; \
             the MITM pause/resume dataplane path is not implemented in this wave"
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every `captures.breakpoint.*` method must return the explicit
    /// NOT_IMPLEMENTED domain code (never `METHOD_NOT_FOUND`), so the frozen
    /// sketch is honest about its state.
    #[test]
    fn breakpoint_stub_returns_not_implemented() {
        for method in [
            "captures.breakpoint.get",
            "captures.breakpoint.set",
            "captures.breakpoint.list",
            "captures.breakpoint.resume",
            "captures.breakpoint.cancel",
        ] {
            let err = stub_arm(method).expect_err("stub must never succeed");
            assert_eq!(
                err.code.as_ref(),
                ERR_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED,
                "{method}"
            );
            assert_eq!(err.status, StatusCode::InternalError, "{method}");
            assert!(
                err.message.contains(method),
                "message must name the method: {}",
                err.message
            );
        }
    }

    /// The frozen default is OFF and the timeout is bounded.
    #[test]
    fn breakpoint_defaults_are_off_and_bounded() {
        assert!(!DEFAULT_BREAKPOINT_ENABLED, "breakpoints must default OFF");
        assert_eq!(DEFAULT_BREAKPOINT_TIMEOUT_MS, 15_000);
        assert!(MIN_BREAKPOINT_TIMEOUT_MS >= 1);
        assert!(DEFAULT_BREAKPOINT_TIMEOUT_MS >= MIN_BREAKPOINT_TIMEOUT_MS);
        assert!(MAX_BREAKPOINT_TIMEOUT_MS <= 120_000);
        assert!(MAX_BREAKPOINT_TIMEOUT_MS >= DEFAULT_BREAKPOINT_TIMEOUT_MS);
    }
}
