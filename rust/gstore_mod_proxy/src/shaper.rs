//! Self-built weak-network simulation engine for the TUN data plane.
//!
//! Todo 1 of `.omo/plans/proxy-weak-network-sim.md`. This module owns the
//! persisted [`ShaperConfig`], its strict wire schema and validation. Later
//! todos append the PRNG, GCRA pacer, unified release scheduler, loss/reorder
//! core, bounded release heap and the `configure(data_dir)` watcher below the
//! `engine` section separator.
//!
//! The wire schema is fixed by the plan ("规范配置 Schema"): every field is
//! camelCase, `enabled=false` disables the whole simulation, and an unknown
//! field is a hard `PROXY_SHAPER_CONFIG_INVALID` (422) — never silently
//! accepted. Defaults are the plan's defaults, so `{}` deserialises to an
//! all-default, disabled config.
//!
//! This is a skeleton: [`ShaperConfig::apply_patch`] / [`ShaperConfig::validate`]
//! are the config plumbing later todos build on. The engine consumes the rest.

#![allow(dead_code)] // Todo 1 foundation: the engine consumes these in later todos.

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Deserializer, Serialize};

/// `net.shaper.set` payload / schema invalid (422, `rust/ERROR_CODES.md`).
pub(crate) const ERR_SHAPER_CONFIG_INVALID: &str = "PROXY_SHAPER_CONFIG_INVALID";

// ---------------------------------------------------------------------------
// Config model (schema)
// ---------------------------------------------------------------------------

/// Jitter sampling distribution (`jitterDistribution`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum JitterDistribution {
    #[default]
    Uniform,
    Normal,
    Pareto,
}

/// Packet-loss process (`lossModel`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LossModel {
    #[default]
    None,
    Random,
    /// Gilbert-Elliot two-state burst loss; spelled `gilbertElliot` on the wire.
    #[serde(rename = "gilbertElliot")]
    GilbertElliot,
}

/// Release order policy (`order`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum PacketOrder {
    #[default]
    Preserve,
    Reorder,
}

/// One direction's shaping parameters (`uplink` / `downlink`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct DirectionConfig {
    /// `0` = unlimited (pacer skipped); otherwise `[1000, 1_000_000_000]`.
    pub rate_bps: u64,
    /// Idle-credit ceiling; `[1500, 65535]`.
    pub burst_bytes: u32,
    /// Added delay; `[0, 60000]`.
    pub delay_ms: u32,
    /// Jitter amplitude; `[0, 30000]`.
    pub jitter_ms: u32,
    /// Jitter sampling distribution.
    pub jitter_distribution: JitterDistribution,
    /// Random loss percentage; `[0, 100]`.
    pub loss_pct: f64,
    /// Loss process.
    pub loss_model: LossModel,
    /// Gilbert-Elliot good→bad transition percentage; `[0, 100]`.
    pub loss_good_to_bad_pct: f64,
    /// Gilbert-Elliot bad→good transition percentage; `[0, 100]`.
    pub loss_bad_to_good_pct: f64,
    /// Duplication percentage; `[0, 100]`.
    pub duplicate_pct: f64,
    /// Reorder percentage; `[0, 100]`.
    pub reorder_pct: f64,
    /// Reorder hold in frames; `[0, 255]`.
    pub reorder_gap: u32,
    /// Release order policy.
    pub order: PacketOrder,
}

impl Default for DirectionConfig {
    fn default() -> Self {
        Self {
            rate_bps: 0,
            burst_bytes: 32_768,
            delay_ms: 0,
            jitter_ms: 0,
            jitter_distribution: JitterDistribution::Uniform,
            loss_pct: 0.0,
            loss_model: LossModel::None,
            loss_good_to_bad_pct: 0.0,
            loss_bad_to_good_pct: 0.0,
            duplicate_pct: 0.0,
            reorder_pct: 0.0,
            reorder_gap: 0,
            order: PacketOrder::Preserve,
        }
    }
}

/// The persisted weak-network simulation config. `enabled=false` disables all
/// simulation (the engine becomes an identity).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct ShaperConfig {
    /// Master switch. `false` = identity / no simulation.
    pub enabled: bool,
    /// Explicit PRNG seed for deterministic tests; `null` = derive in production.
    pub seed: Option<u64>,
    /// Uplink (device → proxy) parameters.
    pub uplink: DirectionConfig,
    /// Downlink (proxy → device) parameters.
    pub downlink: DirectionConfig,
}

impl Default for ShaperConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            seed: None,
            uplink: DirectionConfig::default(),
            downlink: DirectionConfig::default(),
        }
    }
}

// ---------------------------------------------------------------------------
// Patch / validation
// ---------------------------------------------------------------------------

/// Deserialize any present value (including JSON `null`) as `Some(..)`, so an
/// explicit `null` is distinguishable from an absent field. This is the
/// `serde_with::rust::double_option` idiom, needed because a plain
/// `Option<Option<T>>` maps `null` to the *outer* `None` and so cannot clear.
fn deserialize_some<'de, T, D>(deserializer: D) -> Result<Option<T>, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    T::deserialize(deserializer).map(Some)
}

/// Partial update for [`ShaperConfig`]; absent fields keep the current value.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShaperPatch {
    enabled: Option<bool>,
    /// `Some(None)` clears the seed (explicit JSON `null`); absent keeps it.
    #[serde(default, deserialize_with = "deserialize_some")]
    seed: Option<Option<u64>>,
    uplink: Option<DirectionPatch>,
    downlink: Option<DirectionPatch>,
}

/// Partial update for one [`DirectionConfig`]; absent fields keep the current value.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DirectionPatch {
    rate_bps: Option<u64>,
    burst_bytes: Option<u32>,
    delay_ms: Option<u32>,
    jitter_ms: Option<u32>,
    jitter_distribution: Option<JitterDistribution>,
    loss_pct: Option<f64>,
    loss_model: Option<LossModel>,
    loss_good_to_bad_pct: Option<f64>,
    loss_bad_to_good_pct: Option<f64>,
    duplicate_pct: Option<f64>,
    reorder_pct: Option<f64>,
    reorder_gap: Option<u32>,
    order: Option<PacketOrder>,
}

impl DirectionPatch {
    /// Merge this patch's present fields over `target`.
    fn merge_into(self, target: &mut DirectionConfig) {
        if let Some(v) = self.rate_bps {
            target.rate_bps = v;
        }
        if let Some(v) = self.burst_bytes {
            target.burst_bytes = v;
        }
        if let Some(v) = self.delay_ms {
            target.delay_ms = v;
        }
        if let Some(v) = self.jitter_ms {
            target.jitter_ms = v;
        }
        if let Some(v) = self.jitter_distribution {
            target.jitter_distribution = v;
        }
        if let Some(v) = self.loss_pct {
            target.loss_pct = v;
        }
        if let Some(v) = self.loss_model {
            target.loss_model = v;
        }
        if let Some(v) = self.loss_good_to_bad_pct {
            target.loss_good_to_bad_pct = v;
        }
        if let Some(v) = self.loss_bad_to_good_pct {
            target.loss_bad_to_good_pct = v;
        }
        if let Some(v) = self.duplicate_pct {
            target.duplicate_pct = v;
        }
        if let Some(v) = self.reorder_pct {
            target.reorder_pct = v;
        }
        if let Some(v) = self.reorder_gap {
            target.reorder_gap = v;
        }
        if let Some(v) = self.order {
            target.order = v;
        }
    }
}

fn invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_SHAPER_CONFIG_INVALID, message)
}

impl DirectionConfig {
    /// Validate one direction, prefixing every message with `direction` so the
    /// offending field is unambiguous. Never panics.
    fn validate(&self, direction: &str) -> Result<(), ModuleError> {
        if self.rate_bps != 0 && !(1_000..=1_000_000_000).contains(&self.rate_bps) {
            return Err(invalid(format!(
                "{direction}.rateBps must be 0 or within [1000, 1000000000] (got {})",
                self.rate_bps
            )));
        }
        if !(1_500..=65_535).contains(&self.burst_bytes) {
            return Err(invalid(format!(
                "{direction}.burstBytes must be within [1500, 65535] (got {})",
                self.burst_bytes
            )));
        }
        if self.delay_ms > 60_000 {
            return Err(invalid(format!(
                "{direction}.delayMs must be <= 60000 (got {})",
                self.delay_ms
            )));
        }
        if self.jitter_ms > 30_000 {
            return Err(invalid(format!(
                "{direction}.jitterMs must be <= 30000 (got {})",
                self.jitter_ms
            )));
        }
        for (field, value) in [
            ("lossPct", self.loss_pct),
            ("lossGoodToBadPct", self.loss_good_to_bad_pct),
            ("lossBadToGoodPct", self.loss_bad_to_good_pct),
            ("duplicatePct", self.duplicate_pct),
            ("reorderPct", self.reorder_pct),
        ] {
            // `RangeInclusive::contains` is false for NaN and infinities, so this
            // rejects them along with out-of-range finite values.
            if !(0.0..=100.0).contains(&value) {
                return Err(invalid(format!(
                    "{direction}.{field} must be within [0, 100] (got {value})"
                )));
            }
        }
        if self.reorder_gap > 255 {
            return Err(invalid(format!(
                "{direction}.reorderGap must be <= 255 (got {})",
                self.reorder_gap
            )));
        }
        // Cross-field: reordering needs a rate to compute the hold; a zero rate
        // would divide by zero in the pacer. Reject at config time (422).
        if self.order == PacketOrder::Reorder && self.reorder_pct > 0.0 && self.rate_bps == 0 {
            return Err(invalid(format!(
                "{direction}.order=reorder with reorderPct>0 requires rateBps>0"
            )));
        }
        Ok(())
    }
}

impl ShaperConfig {
    /// Merge a partial JSON object over this config and validate the result.
    ///
    /// An empty payload validates the current config (the `lan.rs` convention);
    /// anything that is not a JSON object, or carries an unknown field, is a
    /// structured 422.
    pub(crate) fn apply_patch(&mut self, payload: &[u8]) -> Result<(), ModuleError> {
        if payload.is_empty() {
            return self.validate();
        }
        let value: serde_json::Value = serde_json::from_slice(payload)
            .map_err(|e| invalid(format!("payload must be a JSON object: {e}")))?;
        if !value.is_object() {
            return Err(invalid("payload must be a JSON object"));
        }
        let patch: ShaperPatch = serde_json::from_value(value)
            .map_err(|e| invalid(format!("invalid shaper config: {e}")))?;
        if let Some(enabled) = patch.enabled {
            self.enabled = enabled;
        }
        if let Some(seed) = patch.seed {
            self.seed = seed;
        }
        if let Some(uplink) = patch.uplink {
            uplink.merge_into(&mut self.uplink);
        }
        if let Some(downlink) = patch.downlink {
            downlink.merge_into(&mut self.downlink);
        }
        self.validate()
    }

    /// Validate every field of both directions against the schema. Never panics.
    pub(crate) fn validate(&self) -> Result<(), ModuleError> {
        self.uplink.validate("uplink")?;
        self.downlink.validate("downlink")?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Engine (Todos 2+): SplitMix64 PRNG, GCRA pacer, unified release scheduler,
// loss/duplicate/reorder core, bounded release heap + `buffer_stats()`, and
// `configure(data_dir)`. Append below this separator.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn err_of(payload: &[u8]) -> ModuleError {
        let mut cfg = ShaperConfig::default();
        cfg.apply_patch(payload)
            .expect_err("expected invalid shaper config")
    }

    #[test]
    fn shaper_config_defaults_and_patch() {
        // Happy path from the plan: a partial object deserialises over defaults.
        let cfg: ShaperConfig =
            serde_json::from_slice(br#"{"enabled":true,"uplink":{"rateBps":1000000}}"#).unwrap();
        assert!(cfg.enabled);
        assert_eq!(cfg.uplink.rate_bps, 1_000_000);
        assert_eq!(cfg.downlink, DirectionConfig::default());
        assert_eq!(cfg.seed, None);

        // `{}` (and any absent field) yields the all-default, disabled config.
        let empty: ShaperConfig = serde_json::from_slice(b"{}").unwrap();
        assert_eq!(empty, ShaperConfig::default());
        assert!(!empty.enabled);

        // `apply_patch` merges partial nested objects over the current values.
        let mut cfg = ShaperConfig::default();
        cfg.apply_patch(br#"{"enabled":true,"uplink":{"rateBps":1000000}}"#)
            .unwrap();
        assert!(cfg.enabled);
        assert_eq!(cfg.uplink.rate_bps, 1_000_000);
        assert_eq!(cfg.uplink.burst_bytes, 32_768); // untouched sibling keeps its default
        assert_eq!(cfg.downlink, DirectionConfig::default());

        // An explicit seed sets it; explicit JSON `null` clears it back to None.
        cfg.apply_patch(br#"{"seed":7}"#).unwrap();
        assert_eq!(cfg.seed, Some(7));
        cfg.apply_patch(br#"{"seed":null}"#).unwrap();
        assert_eq!(cfg.seed, None);
    }

    #[test]
    fn shaper_validation_rejects_out_of_range() {
        for payload in [
            br#"{"uplink":{"rateBps":999}}"#.as_slice(),
            br#"{"downlink":{"delayMs":60001}}"#.as_slice(),
            br#"{"uplink":{"lossPct":101}}"#.as_slice(),
            br#"{"uplink":{"bogusField":1}}"#.as_slice(),
            br#"{"unknown":true}"#.as_slice(),
        ] {
            let err = err_of(payload);
            assert_eq!(
                err.status,
                StatusCode::InvalidArgument,
                "payload: {:?}",
                std::str::from_utf8(payload)
            );
            assert_eq!(err.code, ERR_SHAPER_CONFIG_INVALID);
        }

        // A zero-byte body fails the raw schema parse. The RPC layer maps that
        // failure to this same structured 422 code.
        let empty = serde_json::from_slice::<ShaperConfig>(b"")
            .map_err(|e| invalid(format!("payload must be a JSON object: {e}")))
            .unwrap_err();
        assert_eq!(empty.status, StatusCode::InvalidArgument);
        assert_eq!(empty.code, ERR_SHAPER_CONFIG_INVALID);

        // The `lan.rs` convention still holds: `b""` means "validate current",
        // so an empty body against a valid config is a no-op Ok.
        let mut fresh = ShaperConfig::default();
        assert!(fresh.apply_patch(b"").is_ok());
    }

    #[test]
    fn shaper_reorder_requires_rate() {
        let mut cfg = ShaperConfig::default();
        let err = cfg
            .apply_patch(br#"{"uplink":{"order":"reorder","reorderPct":1.0,"rateBps":0}}"#)
            .expect_err("reorder with reorderPct>0 and rateBps=0 must be rejected");
        assert_eq!(err.status, StatusCode::InvalidArgument);
        assert_eq!(err.code, ERR_SHAPER_CONFIG_INVALID);

        // Supplying a positive rate makes the same reorder config valid, and the
        // earlier rejected patch left the config untouched.
        cfg.apply_patch(br#"{"uplink":{"rateBps":1000}}"#).unwrap();
        assert_eq!(cfg.uplink.rate_bps, 1000);
        assert_eq!(cfg.uplink.order, PacketOrder::Reorder);
        assert_eq!(cfg.uplink.reorder_pct, 1.0);
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn shaper_schema_round_trips_camel_case_keys() {
        let cfg = ShaperConfig {
            enabled: true,
            seed: Some(42),
            uplink: DirectionConfig {
                rate_bps: 1_000_000,
                burst_bytes: 16_384,
                delay_ms: 50,
                jitter_ms: 10,
                jitter_distribution: JitterDistribution::Normal,
                loss_pct: 1.5,
                loss_model: LossModel::GilbertElliot,
                loss_good_to_bad_pct: 2.0,
                loss_bad_to_good_pct: 3.0,
                duplicate_pct: 0.5,
                reorder_pct: 0.25,
                reorder_gap: 4,
                order: PacketOrder::Reorder,
            },
            downlink: DirectionConfig::default(),
        };

        let value = serde_json::to_value(&cfg).unwrap();
        let top = value.as_object().unwrap();
        let top_keys: BTreeSet<&str> = top.keys().map(|k| k.as_str()).collect();
        assert_eq!(top_keys, BTreeSet::from(["enabled", "seed", "uplink", "downlink"]));

        let dir = top["uplink"].as_object().unwrap();
        let dir_keys: BTreeSet<&str> = dir.keys().map(|k| k.as_str()).collect();
        assert_eq!(
            dir_keys,
            BTreeSet::from([
                "rateBps",
                "burstBytes",
                "delayMs",
                "jitterMs",
                "jitterDistribution",
                "lossPct",
                "lossModel",
                "lossGoodToBadPct",
                "lossBadToGoodPct",
                "duplicatePct",
                "reorderPct",
                "reorderGap",
                "order",
            ])
        );

        // Every enum variant spelling matches the schema exactly.
        assert_eq!(dir["jitterDistribution"], "normal");
        assert_eq!(dir["lossModel"], "gilbertElliot");
        assert_eq!(dir["order"], "reorder");
        let default_dir = serde_json::to_value(DirectionConfig::default()).unwrap();
        assert_eq!(default_dir["jitterDistribution"], "uniform");
        assert_eq!(default_dir["lossModel"], "none");
        assert_eq!(default_dir["order"], "preserve");

        // Full round trip is lossless.
        let back: ShaperConfig = serde_json::from_value(value).unwrap();
        assert_eq!(back, cfg);
    }
}
