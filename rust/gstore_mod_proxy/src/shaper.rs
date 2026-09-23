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

// ---------------------------------------------------------------------------
// PRNG (Todo 2)
// ---------------------------------------------------------------------------

/// Base seed mixed with injected entropy when no explicit seed is pinned.
///
/// Named (not an inline literal) so it is greppable and so tests can pin
/// `derive_seed(None, e)` exactly.
pub(crate) const FIXED_SEED_CONSTANT: u64 = 0x5DEE_CE66_D7A5_3F17;

/// Pareto shape parameter used by [`SplitMix64::jitter_offset`].
///
/// Fixed at `1.5`: heavy enough that a few packets get a long delay, but its
/// tail stays finite after the `[0, jitter_ms]` clamp. Deterministic across runs.
const PARETO_ALPHA: f64 = 1.5;

/// Deterministic SplitMix64 generator (Steele/Lea/Flood, 2014; public domain).
///
/// Hand-written rather than pulling `rand`/`fastrand`: the shaper only needs a
/// tiny reproducible stream of `u64`/`f64` decisions, and a dependency-free
/// generator keeps a given `ShaperConfig::seed` identical on every platform.
pub(crate) struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// Seed the generator; `seed` becomes the initial state verbatim.
    pub(crate) fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// Advance the state and return the next 64-bit output (canonical mixing).
    pub(crate) fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform `f64` in `[0, 1)` (53-bit mantissa scaling).
    pub(crate) fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// Bernoulli trial: `true` with probability `pct` percent.
    ///
    /// `pct <= 0.0` (including `-inf`) is always `false` and `pct >= 100.0`
    /// (including `+inf`) is always `true`. `NaN` fails both comparisons, so it
    /// takes the `false` branch — documented and panic-free.
    pub(crate) fn chance(&mut self, pct: f64) -> bool {
        if pct <= 0.0 {
            return false;
        }
        if pct >= 100.0 {
            return true;
        }
        self.next_f64() * 100.0 < pct
    }

    /// Sample a jitter offset in `[0, jitter_ms]` for `distribution`.
    ///
    /// The single place all jitter sampling lives; later todos call it. Every
    /// branch is clamped into `[0, jitter_ms]`, so the result can never exceed
    /// the configured amplitude and never panics. `jitter_ms == 0` short-circuits
    /// to `0` before any draw.
    pub(crate) fn jitter_offset(
        &mut self,
        distribution: JitterDistribution,
        jitter_ms: u32,
    ) -> u32 {
        if jitter_ms == 0 {
            return 0;
        }
        let span = jitter_ms as f64;
        let raw = match distribution {
            JitterDistribution::Uniform => self.next_f64() * span,
            JitterDistribution::Normal => {
                // Box-Muller, mean `span/2` and stddev `span/6`, so the ±3σ body
                // spans roughly `[0, jitter_ms]`. `u1` is nudged off 0 so `ln`
                // stays finite, then the drawn value is folded to non-negative.
                let u1 = self.next_f64().max(f64::MIN_POSITIVE);
                let u2 = self.next_f64();
                let radius = (-2.0 * u1.ln()).sqrt();
                let z = radius * (std::f64::consts::TAU * u2).cos();
                (span / 2.0 + (span / 6.0) * z).abs()
            }
            JitterDistribution::Pareto => {
                // Inverse-CDF of Pareto(α = 1.5, xm = 1), shifted so the support
                // starts at 0 and scaled to the amplitude. `u` is nudged off 0
                // (still finite: `u^(1/α)` stays well above underflow).
                let u = self.next_f64().max(f64::MIN_POSITIVE);
                let x = 1.0 / u.powf(1.0 / PARETO_ALPHA);
                (x - 1.0) * span
            }
        };
        raw.clamp(0.0, span).round() as u32
    }
}

/// Derive a PRNG seed from the config seed and injected entropy.
///
/// `Some(seed)` (tests, and any pinned config seed) wins verbatim so runs are
/// exact. `None` (production) yields `FIXED_SEED_CONSTANT ^ entropy`: the caller
/// injects a time-derived `entropy` because this function is deliberately pure
/// — it never reads the clock, so tests can pin `derive_seed(None, e)`.
pub(crate) fn derive_seed(seed: Option<u64>, entropy: u64) -> u64 {
    seed.unwrap_or(FIXED_SEED_CONSTANT ^ entropy)
}

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

#[cfg(test)]
mod prng_tests {
    use super::*;

    const TEST_SEED: u64 = 0x1234_5678_9ABC_DEF0;
    const ALL_DISTRIBUTIONS: [JitterDistribution; 3] = [
        JitterDistribution::Uniform,
        JitterDistribution::Normal,
        JitterDistribution::Pareto,
    ];

    fn u64_seq(seed: u64, n: usize) -> Vec<u64> {
        let mut rng = SplitMix64::new(seed);
        (0..n).map(|_| rng.next_u64()).collect()
    }

    #[test]
    fn shaper_prng_seed_is_deterministic() {
        let a = u64_seq(TEST_SEED, 1000);
        let b = u64_seq(TEST_SEED, 1000);
        assert_eq!(a, b, "same seed must replay the same u64 stream");
        assert_ne!(a, u64_seq(TEST_SEED ^ 1, 1000), "a different seed must differ");

        // The decision helpers replay identically too, interleaved so any hidden
        // state divergence is caught on the very next draw.
        let mut r1 = SplitMix64::new(7);
        let mut r2 = SplitMix64::new(7);
        for i in 0..1000 {
            let pct = (i % 101) as f64;
            assert_eq!(r1.chance(pct), r2.chance(pct));
            assert_eq!(r1.next_u64(), r2.next_u64());
            let dist = ALL_DISTRIBUTIONS[i % ALL_DISTRIBUTIONS.len()];
            let jitter_ms = (i % 30_001) as u32;
            assert_eq!(r1.jitter_offset(dist, jitter_ms), r2.jitter_offset(dist, jitter_ms));
            assert_eq!(r1.next_f64().to_bits(), r2.next_f64().to_bits());
        }
    }

    #[test]
    fn shaper_prng_boundaries() {
        let mut rng = SplitMix64::new(TEST_SEED);

        // Exact bounds and non-finite inputs never panic and obey the contract.
        assert!(!rng.chance(0.0));
        assert!(rng.chance(100.0));
        assert!(!rng.chance(-1.0));
        assert!(rng.chance(1e9));
        assert!(!rng.chance(f64::NAN), "NaN pct is documented as false");
        let _ = rng.chance(1e-9);
        let _ = rng.chance(99.9999999);

        for dist in ALL_DISTRIBUTIONS {
            assert_eq!(rng.jitter_offset(dist, 0), 0, "zero amplitude is always zero");
            for jitter_ms in [1u32, 7, 1500, 30_000] {
                for _ in 0..2_000 {
                    let v = rng.jitter_offset(dist, jitter_ms);
                    assert!(v <= jitter_ms, "{dist:?}: {v} exceeds {jitter_ms}");
                }
            }
        }
    }

    #[test]
    fn shaper_derive_seed() {
        // An explicit seed is returned verbatim regardless of entropy.
        assert_eq!(derive_seed(Some(7), 0), 7);
        assert_eq!(derive_seed(Some(7), 0xDEAD_BEEF), 7);

        // No seed = fixed constant ^ entropy, and pure/deterministic.
        let e = 0x0123_4567_89AB_CDEF;
        assert_eq!(derive_seed(None, e), derive_seed(None, e));
        assert_eq!(derive_seed(None, e), FIXED_SEED_CONSTANT ^ e);
        assert_ne!(derive_seed(None, e), derive_seed(None, e ^ 1));
    }
}

// ---------------------------------------------------------------------------
// GCRA pacer (Todo 3)
// ---------------------------------------------------------------------------

// Imported here rather than at the file head so the Todo 1/2 sections above stay
// byte-for-byte untouched; the pacer is the first section that needs wall time.
use std::time::{Duration, Instant};

/// Byte-rate pacer: a token bucket expressed as a GCRA (Generic Cell Rate
/// Algorithm). 3GPP RP-020108 notes a token bucket is equivalent to a GCRA, and
/// `tc-netem(8)`'s TBF is the same shape — one theoretical-arrival-time (`tat`)
/// register per direction is enough, so no per-byte counter is needed.
///
/// One [`Pacer`] lives per direction per pump (task-local, never shared). All
/// timing is injected via `now: Instant`, so the core is a pure function that is
/// unit-testable without sleeping or reading the clock internally.
///
/// # Debt model (D15)
/// `tat` is the earliest instant the byte we just accepted may be released.
/// Each accepted frame advances it by `len / rate`. When a frame is larger than
/// the burst, `tat` is simply further in the future — the bucket goes into
/// *debt* rather than dropping the frame, so a frame is **never black-holed**.
/// `burst_bytes` only caps how much idle credit may accrue: an idle period lets
/// `tat` fall no earlier than `now - burst_credit`.
pub(crate) struct Pacer {
    /// Configured byte rate in bits per second; `0` = unlimited.
    rate_bps: u64,
    /// Idle-credit ceiling in bytes; never a hard frame-size limit.
    burst_bytes: u32,
    /// Theoretical arrival time of the next conforming byte.
    tat: Instant,
}

/// Time it takes `len` bytes to arrive at `rate_bps`, as a `Duration`.
///
/// Integer math (nanoseconds) throughout so repeated `+=` stays exact and never
/// drifts the way floating-point seconds would. Only called with `rate_bps > 0`;
/// `len` is a TUN frame bounded by `tun::READ_BUFFER_SIZE` (65535), so the
/// `u128` product divided by the rate always fits back into `u64` nanoseconds.
///
/// `pub(crate)` because the Todo 4 [`ReleaseScheduler`] reuses it verbatim to
/// size the reorder hold (`reorderGap × len/rate`); the maths must stay here so
/// the pacer and the hold agree on one definition of "one frame interval".
pub(crate) fn bytes_interval(rate_bps: u64, len: usize) -> Duration {
    Duration::from_nanos((len as u128 * 1_000_000_000u128 / rate_bps as u128) as u64)
}

/// Idle credit a full empty bucket accrues, as a `Duration`: the time to send
/// `burst_bytes` at `rate_bps`. Integer nanoseconds, same reasoning as
/// [`bytes_interval`]; only called with `rate_bps > 0`.
fn burst_credit(rate_bps: u64, burst_bytes: u32) -> Duration {
    Duration::from_nanos((burst_bytes as u128 * 1_000_000_000u128 / rate_bps as u128) as u64)
}

/// `now - burst_credit`, saturating back to `now` when that would underflow the
/// clock's representable range. Factored out (not inlined) so the `checked_sub`
/// `None` branch is unit-testable. This is the **only** permitted subtraction of
/// a `Duration` from an `Instant` in the pacer (F2).
fn credit_floor(now: Instant, burst_credit: Duration) -> Instant {
    now.checked_sub(burst_credit).unwrap_or(now)
}

impl Pacer {
    /// Create a pacer for `rate_bps`/`burst_bytes` whose `tat` starts at `now`.
    pub(crate) fn new(rate_bps: u64, burst_bytes: u32, now: Instant) -> Self {
        Self { rate_bps, burst_bytes, tat: now }
    }

    /// `true` when shaping is disabled (`rateBps == 0`): [`Pacer::schedule`] is
    /// then the identity and never divides by zero.
    pub(crate) fn is_unlimited(&self) -> bool {
        self.rate_bps == 0
    }

    /// Accept a `len`-byte frame arriving at `now` and return its release time.
    ///
    /// `now` is the **arrival** instant (not the previous release). The returned
    /// `Instant` is the new `tat`: `now` when unlimited, otherwise the earlier of
    /// the accumulated debt and the burst floor plus this frame's interval. The
    /// interval added per frame is `len / rate`, a known-small addition
    /// (`<= 65.535 s` for `len <= 65535`, `rate >= 1000`), so the bare `+` is
    /// safe; every subtraction goes through [`credit_floor`].
    pub(crate) fn schedule(&mut self, now: Instant, len: usize) -> Instant {
        if self.rate_bps == 0 {
            // Identity: never divide, never advance `tat`.
            return now;
        }
        let floor = credit_floor(now, burst_credit(self.rate_bps, self.burst_bytes));
        self.tat = self.tat.max(floor) + bytes_interval(self.rate_bps, len);
        self.tat
    }

    /// D14: called when the configured rate is raised. Drains any *debt* forward
    /// to `now` (`tat = min(tat, now)`) so the previously-owed backlog does not
    /// keep throttling at the new, faster rate — while legitimate idle credit
    /// (a `tat` in the past) is left untouched.
    pub(crate) fn reconcile_on_rate_increase(&mut self, now: Instant) {
        self.tat = self.tat.min(now);
    }

    /// Apply a hot rate/burst change (D14), used by
    /// [`ReleaseScheduler::reconfigure`].
    ///
    /// Raising the rate drains the old backlog first via
    /// [`Pacer::reconcile_on_rate_increase`] so the next frame is paced by the
    /// new rate, not the stale debt. Lowering the rate (or switching to
    /// unlimited) leaves `tat` alone. `burst_bytes` is only a credit ceiling, so
    /// it is stored unconditionally.
    pub(crate) fn apply_rate_change(&mut self, rate_bps: u64, burst_bytes: u32, now: Instant) {
        if rate_bps > self.rate_bps {
            self.reconcile_on_rate_increase(now);
        }
        self.rate_bps = rate_bps;
        self.burst_bytes = burst_bytes;
    }

    /// Configured byte rate in bits per second; `0` = unlimited.
    pub(crate) fn rate_bps(&self) -> u64 {
        self.rate_bps
    }
}

#[cfg(test)]
mod pacer_tests {
    use super::*;

    #[test]
    fn pacer_enforces_byte_rate() {
        // Feed `frames` back-to-back frames that all arrive at the SAME instant:
        // the pacer alone must spread them out, one `len/rate` interval apart.
        let base = Instant::now();
        let rate_bps = 1_000_000u64;
        let len = 1000usize;
        let frames = 1000u32;
        let mut pacer = Pacer::new(rate_bps, 1_500, base);

        let mut release = base;
        for _ in 0..frames {
            release = pacer.schedule(base, len);
        }

        // Integer math is exact: expected final `tat` is `base + frames*len/rate`.
        let interval = bytes_interval(rate_bps, len);
        let expected = base + interval * frames;
        let diff = release
            .saturating_duration_since(expected)
            .max(expected.saturating_duration_since(release));
        // Tolerance is half a frame interval — smaller than one frame interval.
        assert!(diff < interval / 2, "release {release:?} vs expected {expected:?}");

        // No `delayMs` exists on the pacer at all, so 1000 frames x 1ms = ~1s of
        // rate delay is never clamped by any delay value; it would hold for any
        // run length. (`direction.delayMs` is applied later, in the scheduler.)
        assert!(release.saturating_duration_since(base) >= Duration::from_millis(999));
    }

    #[test]
    fn pacer_never_blackholes_large_frame() {
        // burst_bytes=1500 but a 3000-byte frame: allowed, just goes into debt.
        let base = Instant::now();
        let mut pacer = Pacer::new(1_000, 1_500, base);
        let deadline = pacer.schedule(base, 3_000);
        assert_eq!(deadline, base + Duration::from_secs(3));
        assert!(deadline > base, "a large frame still gets a finite release time");
    }

    #[test]
    fn pacer_handles_uptime_below_burst_credit() {
        let now = Instant::now();

        // `1 << 40` seconds exceeds any real uptime. On Linux `Instant` is a
        // signed timespec, so this subtraction yields a representable *negative*
        // instant rather than `None`; the contract is only that it never panics
        // and never moves forward.
        let huge = Duration::from_secs(1 << 40);
        let floored = credit_floor(now, huge);
        assert!(floored <= now, "credit floor must never move forward");

        // `Duration::MAX` genuinely overflows the subtraction, so this exercises
        // the `checked_sub(..).unwrap_or(now)` `None` branch and returns `now`.
        assert_eq!(credit_floor(now, Duration::MAX), now);

        // A full schedule with a huge burst and a low rate must not panic.
        let mut pacer = Pacer::new(1_000, u32::MAX, now);
        let _ = pacer.schedule(now, 100);
    }

    #[test]
    fn pacer_zero_rate_is_identity() {
        let base = Instant::now();
        let mut pacer = Pacer::new(0, 1_500, base);
        assert!(pacer.is_unlimited());
        // Identity: returns `now` verbatim and never divides by zero.
        assert_eq!(pacer.schedule(base, 3_000), base);
        for _ in 0..100 {
            assert_eq!(pacer.schedule(base, 65_535), base);
        }
    }

    #[test]
    fn pacer_huge_frame_is_safe() {
        // 65535 bytes at 1000 bps = 65535 s of debt, no overflow/panic.
        let base = Instant::now();
        let mut pacer = Pacer::new(1_000, 1_500, base);
        let deadline = pacer.schedule(base, 65_535);
        assert_eq!(deadline, base + Duration::from_millis(65_535));
        assert_eq!(deadline.saturating_duration_since(base), Duration::from_millis(65_535));
    }

    #[test]
    fn pacer_idle_credit_is_bounded() {
        // Idle for an hour, then send one frame. Idle credit must be capped at
        // `burst_bytes`, so the release can be at most `burst_credit + interval`
        // ahead of `now` — never the full idle period.
        let base = Instant::now();
        let rate_bps = 1_000u64;
        let burst_bytes = 1_500u32;
        let mut pacer = Pacer::new(rate_bps, burst_bytes, base);
        let now = base + Duration::from_secs(3_600);
        let deadline = pacer.schedule(now, 2_000);

        assert!(deadline >= now, "a frame is never released before it arrives");
        let credit = burst_credit(rate_bps, burst_bytes);
        let interval = bytes_interval(rate_bps, 2_000);
        assert!(
            deadline.saturating_duration_since(now) <= credit + interval,
            "idle credit {} exceeded burst_credit + interval {}",
            deadline.saturating_duration_since(now).as_secs_f64(),
            (credit + interval).as_secs_f64()
        );
    }
}

// ---------------------------------------------------------------------------
// Unified release scheduler (Todo 4)
// ---------------------------------------------------------------------------

/// Normalise a jitter distribution against the configured amplitude.
///
/// `tc-netem(8)` treats a zero-width jitter as "no jitter", and
/// [`SplitMix64::jitter_offset`] short-circuits any distribution to `0` when
/// `jitter_ms == 0`. Illegal/degenerate parameters therefore fall back to
/// [`JitterDistribution::Uniform`], so a `normal`/`pareto` config carrying no
/// amplitude still reports a well-defined distribution instead of a shape that
/// can never be sampled. Any non-zero amplitude keeps `dist`.
pub(crate) fn effective_distribution(
    dist: JitterDistribution,
    jitter_ms: u32,
) -> JitterDistribution {
    if jitter_ms == 0 {
        JitterDistribution::Uniform
    } else {
        dist
    }
}

/// Unified release scheduler implementing plan decision D6.
///
/// One instance lives per direction per pump (task-local, never shared) and owns
/// the direction's [`Pacer`] plus the last release time. All timing is injected
/// through `now: Instant`; nothing here reads the clock or sleeps, so the core
/// is deterministic and unit-testable.
///
/// # D6 branch formulas
/// With `pacer_deadline = pacer.schedule(now, len)` (where `now` is the
/// **arrival** instant, not the previous release) and `jitter ∈ [0, jitter_ms]`:
///
/// ```text
/// natural = max(pacer_deadline, now + base + jitter)
/// order = preserve:  release = max(prev_release, natural); prev_release = release
/// order = reorder:   release = natural + (selected ? hold : 0)
///                    hold    = reorderGap × len/rate   (FRAMES; pacer untouched)
///                    prev_release tracks ONLY pacer_deadline
/// ```
///
/// `preserve` therefore never regresses a release. `reorder` may, bounded by the
/// hold: the in-flight window is `≤ max(hold, jitter_ms)` and `≤ reorderGap`
/// frames. A frame that D5 exempts from reordering (`reorder_exempt`) still
/// receives bandwidth, delay and jitter but never the reorder hold. The
/// effective latency upper bound is `base + maxJitter` (single-sided max, a D6
/// fidelity limitation): pure delay is never below `now + base` nor above
/// `now + base + jitter_ms`.
pub(crate) struct ReleaseScheduler {
    /// Byte-rate pacer for this direction; identity when `rate_bps == 0`.
    pacer: Pacer,
    /// Last release time. The `preserve` branch keeps it non-decreasing; the
    /// `reorder` branch only ever stores the pacer deadline here.
    prev_release: Instant,
    /// Added delay (`delayMs`), always non-negative.
    base: Duration,
    /// Jitter amplitude (`jitterMs`); samples are in `[0, jitter_ms]`.
    jitter_ms: u32,
    /// Sampling shape, already normalised by [`effective_distribution`].
    distribution: JitterDistribution,
    /// Percentage of frames selected for the reorder hold; `[0, 100]`.
    reorder_pct: f64,
    /// Reorder hold in FRAMES; `[0, 255]`.
    reorder_gap: u32,
    /// Release order policy.
    order: PacketOrder,
    /// Deterministic decision stream (reorder selection + jitter sampling).
    rng: SplitMix64,
}

impl ReleaseScheduler {
    /// Build a scheduler for one direction. `now` is the scheduler's epoch:
    /// `prev_release` starts there so no frame is pulled before its creation.
    pub(crate) fn new(cfg: &DirectionConfig, rng: SplitMix64, now: Instant) -> Self {
        Self {
            pacer: Pacer::new(cfg.rate_bps, cfg.burst_bytes, now),
            prev_release: now,
            base: Duration::from_millis(cfg.delay_ms as u64),
            jitter_ms: cfg.jitter_ms,
            distribution: effective_distribution(cfg.jitter_distribution, cfg.jitter_ms),
            reorder_pct: cfg.reorder_pct,
            reorder_gap: cfg.reorder_gap,
            order: cfg.order,
            rng,
        }
    }

    /// Schedule a `len`-byte frame that arrived at `now`, returning its absolute
    /// release instant (D6).
    ///
    /// `reorder_exempt` is the D5 exemption flag: when `true` the frame never
    /// receives the reorder hold, but still receives bandwidth, delay and
    /// jitter. Bandwidth debt is delegated to the [`Pacer`] and the jitter draw
    /// to [`SplitMix64::jitter_offset`], so neither is reimplemented here.
    pub(crate) fn schedule(&mut self, now: Instant, len: usize, reorder_exempt: bool) -> Instant {
        let pacer_deadline = self.pacer.schedule(now, len);
        // Both increments are bounded (`base` ≤ 60 s, `jitter` ≤ 30 s), so a bare
        // `+` cannot overflow; F2 only forbids bare `Instant - Duration`.
        let jitter =
            Duration::from_millis(self.rng.jitter_offset(self.distribution, self.jitter_ms) as u64);
        let natural = pacer_deadline.max(now + self.base + jitter);

        match self.order {
            PacketOrder::Preserve => {
                let release = self.prev_release.max(natural);
                self.prev_release = release;
                release
            }
            PacketOrder::Reorder => {
                // Deliberately does NOT `max` against the previous release, so a
                // later frame can overtake a held one. Only the pacer deadline is
                // remembered (D6).
                self.prev_release = pacer_deadline;
                let selected = !reorder_exempt
                    && self.reorder_pct > 0.0
                    && self.pacer.rate_bps() > 0
                    && self.rng.chance(self.reorder_pct);
                if selected {
                    natural + self.hold(len)
                } else {
                    natural
                }
            }
        }
    }

    /// Reorder hold for `len`: `reorderGap × len/rate` (D6), i.e. the time
    /// `reorderGap` frames occupy at the configured rate. `reorderGap` is in
    /// FRAMES and the hold does not advance the pacer. Guarded by `rate_bps > 0`
    /// (also guaranteed by `validate()` for `order=reorder && reorderPct>0`) so
    /// the integer division can never trap.
    fn hold(&self, len: usize) -> Duration {
        let rate_bps = self.pacer.rate_bps();
        if rate_bps == 0 || self.reorder_gap == 0 {
            return Duration::ZERO;
        }
        bytes_interval(rate_bps, len) * self.reorder_gap
    }

    /// Apply a hot config change (D4/D14): snapshot delay/jitter/order params
    /// and hand the rate change to the [`Pacer`], which drains debt on a rate
    /// increase. `prev_release` is left intact (the pump re-evaluates in-flight
    /// frames per D14).
    pub(crate) fn reconfigure(&mut self, cfg: &DirectionConfig, now: Instant) {
        self.base = Duration::from_millis(cfg.delay_ms as u64);
        self.jitter_ms = cfg.jitter_ms;
        self.distribution = effective_distribution(cfg.jitter_distribution, cfg.jitter_ms);
        self.reorder_pct = cfg.reorder_pct;
        self.reorder_gap = cfg.reorder_gap;
        self.order = cfg.order;
        self.pacer
            .apply_rate_change(cfg.rate_bps, cfg.burst_bytes, now);
    }
}

#[cfg(test)]
mod scheduler_tests {
    use super::*;

    const ALL_DISTRIBUTIONS: [JitterDistribution; 3] = [
        JitterDistribution::Uniform,
        JitterDistribution::Normal,
        JitterDistribution::Pareto,
    ];

    /// A direction config carrying only what these tests vary; loss/duplicate
    /// stay disabled.
    fn dir(
        rate_bps: u64,
        delay_ms: u32,
        jitter_ms: u32,
        dist: JitterDistribution,
        order: PacketOrder,
        reorder_pct: f64,
        reorder_gap: u32,
    ) -> DirectionConfig {
        DirectionConfig {
            rate_bps,
            burst_bytes: 32_768,
            delay_ms,
            jitter_ms,
            jitter_distribution: dist,
            loss_pct: 0.0,
            loss_model: LossModel::None,
            loss_good_to_bad_pct: 0.0,
            loss_bad_to_good_pct: 0.0,
            duplicate_pct: 0.0,
            reorder_pct,
            reorder_gap,
            order,
        }
    }

    #[test]
    fn release_is_monotonic_and_steady_state() {
        // (a) preserve: with a positive delay and jitter, releases never regress.
        let cfg = dir(
            1_000_000,
            15,
            5,
            JitterDistribution::Uniform,
            PacketOrder::Preserve,
            0.0,
            0,
        );
        let t0 = Instant::now();
        let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(0xABCD), t0);
        let mut prev = t0;
        let mut now = t0;
        for _ in 0..500 {
            let release = sched.schedule(now, 1000, false);
            assert!(release >= prev, "preserve release went backwards");
            prev = release;
            now += Duration::from_millis(1);
        }

        // (b) steady state: `base>0` must not compound into the release cadence.
        // Arrivals every 5 ms with delayMs=20 ms. An implementation that slept
        // `base` per frame would collapse to 5+20=25 ms/frame; absolute deadlines
        // keep the cadence at the arrival rate, independent of `base`.
        let cfg = dir(
            1_000_000_000,
            20,
            0,
            JitterDistribution::Uniform,
            PacketOrder::Preserve,
            0.0,
            0,
        );
        let t0 = Instant::now();
        let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(1), t0);
        let arrival = Duration::from_millis(5);
        let frames = 200u32;
        let first = sched.schedule(t0, 1000, false);
        let mut last = first;
        for i in 1..frames {
            last = sched.schedule(t0 + arrival * i, 1000, false);
        }
        let elapsed = last.saturating_duration_since(first);
        let expected = arrival * (frames - 1);
        let diff = elapsed.abs_diff(expected);
        assert!(
            diff <= Duration::from_millis(1),
            "steady-state elapsed {elapsed:?} vs expected {expected:?} (base must not compound)"
        );
    }

    #[test]
    fn jitter_within_bounds() {
        let t0 = Instant::now();
        for (idx, dist) in ALL_DISTRIBUTIONS.into_iter().enumerate() {
            // jitterMs = 0: release is exactly the pacer deadline.
            let cfg = dir(1_000_000, 0, 0, dist, PacketOrder::Preserve, 0.0, 0);
            let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(0x100 + idx as u64), t0);
            let mut reference = Pacer::new(1_000_000, 32_768, t0);
            let mut now = t0;
            for _ in 0..200 {
                let release = sched.schedule(now, 1000, false);
                assert_eq!(
                    release,
                    reference.schedule(now, 1000),
                    "{dist:?}: zero jitter must be identity vs the pacer deadline"
                );
                now += Duration::from_micros(50);
            }

            // jitterMs = max: the offset above the pacer deadline stays in
            // [0, 30_000 ms]. rateBps=0 makes the pacer deadline exactly `now`,
            // so `release - now` is the measured jitter.
            let cfg = dir(0, 0, 30_000, dist, PacketOrder::Preserve, 0.0, 0);
            let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(0x200 + idx as u64), t0);
            let mut now = t0;
            for _ in 0..500 {
                let release = sched.schedule(now, 1000, false);
                let delta = release.saturating_duration_since(now);
                assert!(
                    delta <= Duration::from_millis(30_000),
                    "{dist:?}: jitter {delta:?} exceeds 30_000 ms"
                );
                now += Duration::from_millis(1);
            }
        }
    }

    #[test]
    fn delay_zero_jitter_zero_is_identity() {
        let t0 = Instant::now();
        for rate in [0u64, 1_000_000] {
            let cfg = dir(rate, 0, 0, JitterDistribution::Uniform, PacketOrder::Preserve, 0.0, 0);
            let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(9), t0);
            let mut reference = Pacer::new(rate, 32_768, t0);
            let mut now = t0;
            for _ in 0..100 {
                assert_eq!(
                    sched.schedule(now, 1000, false),
                    reference.schedule(now, 1000),
                    "rate {rate}: zero delay and jitter must add nothing"
                );
                now += Duration::from_millis(1);
            }
        }
    }

    #[test]
    fn distribution_fallback_is_uniform() {
        for dist in ALL_DISTRIBUTIONS {
            assert_eq!(
                effective_distribution(dist, 0),
                JitterDistribution::Uniform,
                "{dist:?} with zero amplitude must fall back to uniform"
            );
            assert_eq!(effective_distribution(dist, 1), dist);
            assert_eq!(effective_distribution(dist, 30_000), dist);
        }
    }

    #[test]
    fn reorder_actually_reorders_within_gap() {
        // order=reorder, jitterMs=0, delayMs=0, reorderPct=100 (every non-exempt
        // frame selected), reorderGap=3. Two frames arrive back-to-back: the
        // first is a normal data frame (held), the second is D5-exempt (never
        // held), so its release overtakes the held frame.
        let rate = 1_000_000u64;
        let len = 1000usize;
        let interval = bytes_interval(rate, len);
        let cfg = dir(rate, 0, 0, JitterDistribution::Uniform, PacketOrder::Reorder, 100.0, 3);
        let t0 = Instant::now();
        let mut sched = ReleaseScheduler::new(&cfg, SplitMix64::new(42), t0);

        let held = sched.schedule(t0, len, false);
        let exempt = sched.schedule(t0, len, true);

        let expected_hold = interval * 3;
        assert_eq!(held, t0 + interval + expected_hold, "held = natural + hold");
        assert_eq!(exempt, t0 + interval * 2, "exempt = pacer deadline, no hold");
        assert!(exempt < held, "a later frame must be able to overtake a held one");

        let window = held.saturating_duration_since(exempt);
        assert!(window <= expected_hold, "window {window:?} exceeds reorderGap {expected_hold:?}");

        // Every frame exempt: the hold is never applied, release == pacer deadline.
        let mut plain = ReleaseScheduler::new(&cfg, SplitMix64::new(7), t0);
        assert_eq!(plain.schedule(t0, len, true), t0 + interval);
        assert_eq!(plain.schedule(t0, len, true), t0 + interval * 2);
    }

    #[test]
    fn reconfigure_rate_increase_drains_debt() {
        let old_rate = 1_000u64;
        let new_rate = 1_000_000u64;
        let len = 1500usize;
        let t0 = Instant::now();
        // Reorder order so `prev_release` cannot mask the pacer deadline.
        let old = dir(old_rate, 0, 0, JitterDistribution::Uniform, PacketOrder::Reorder, 0.0, 0);
        let mut sched = ReleaseScheduler::new(&old, SplitMix64::new(3), t0);

        // Saturate: back-to-back frames at 1000 bps accrue ~1.5 s of debt each.
        let mut last = t0;
        for _ in 0..50 {
            last = sched.schedule(t0, len, false);
        }
        let debt = last.saturating_duration_since(t0);
        assert!(debt >= Duration::from_secs(60), "expected deep debt, got {debt:?}");

        // Raise the rate; D14 drains the debt forward to `now`.
        let now = t0 + Duration::from_secs(1);
        let raised =
            dir(new_rate, 0, 0, JitterDistribution::Uniform, PacketOrder::Reorder, 0.0, 0);
        sched.reconfigure(&raised, now);

        // The next frame is paced by the NEW rate only, not the old backlog.
        let release = sched.schedule(now, len, false);
        assert_eq!(
            release,
            now + bytes_interval(new_rate, len),
            "rate increase must drain the old-rate debt"
        );
        assert!(release.saturating_duration_since(now) < Duration::from_secs(1));
    }
}

// ---------------------------------------------------------------------------
// Damage core (Todo 5): D5 dual-stack exemption + loss / duplicate decisions.
//
// D6 split: reorder selection and the reorder hold live in `ReleaseScheduler`
// (Todo 4). This module owns loss and duplicate only, plus the shared D5
// exemption predicate that the scheduler's `reorder_exempt` flag and the pump
// both consume. Per D5, loss / duplication / reordering share ONE predicate, so
// there is no second selector or RNG draw for reordering here.
// ---------------------------------------------------------------------------

/// IP protocol classification for the D5 exemption predicate. `Icmp6` is 58;
/// `Other` carries any protocol the predicate treats as non-exempt (including
/// ESP 50 / AH 51, whose transport cannot be parsed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IpProto {
    Tcp,
    Udp,
    Icmp,
    Icmp6,
    Other(u8),
}

/// The slice of a raw IP packet the D5 exemption cares about. A TUN frame
/// carries no Ethernet header, so `frame[0]` is the IP version/IHL nibble.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FrameInfo {
    pub version: u8,
    pub is_fragment: bool,
    pub proto: IpProto,
    pub src_port: u16,
    pub dst_port: u16,
    pub is_tcp_control: bool,
    pub is_pure_ack: bool,
}

/// TCP control bits (FIN 0x01 | SYN 0x02 | RST 0x04) in the flags byte.
const TCP_CONTROL_MASK: u8 = 0x07;
/// The TCP ACK flag.
const TCP_ACK_MASK: u8 = 0x10;

/// Map an IP protocol number to its [`IpProto`] classification.
fn proto_from_u8(value: u8) -> IpProto {
    match value {
        1 => IpProto::Icmp,
        6 => IpProto::Tcp,
        17 => IpProto::Udp,
        58 => IpProto::Icmp6,
        other => IpProto::Other(other),
    }
}

/// Parse a TCP header at `off`, returning `(src_port, dst_port, is_control,
/// is_pure_ack)`. `total_len` is the full IP packet length (header included) so
/// the TCP payload is `total_len - (off + data_offset)`. `None` when the frame
/// is too short for the 20-byte minimum header; never panics.
fn parse_tcp(frame: &[u8], off: usize, total_len: usize) -> Option<(u16, u16, bool, bool)> {
    if frame.len() < off + 20 {
        return None;
    }
    let src_port = u16::from_be_bytes([frame[off], frame[off + 1]]);
    let dst_port = u16::from_be_bytes([frame[off + 2], frame[off + 3]]);
    let flags = frame[off + 13];
    let data_offset = ((frame[off + 12] >> 4) as usize) * 4;
    let payload_len = total_len.saturating_sub(off + data_offset);
    let is_tcp_control = flags & TCP_CONTROL_MASK != 0;
    let is_pure_ack = (flags & TCP_ACK_MASK != 0) && (flags & TCP_CONTROL_MASK == 0) && payload_len == 0;
    Some((src_port, dst_port, is_tcp_control, is_pure_ack))
}

/// Parse a UDP header at `off`, returning `(src_port, dst_port, false, false)`.
/// `None` when the frame is shorter than the 4 bytes needed for the ports.
fn parse_udp(frame: &[u8], off: usize) -> Option<(u16, u16, bool, bool)> {
    if frame.len() < off + 4 {
        return None;
    }
    let src_port = u16::from_be_bytes([frame[off], frame[off + 1]]);
    let dst_port = u16::from_be_bytes([frame[off + 2], frame[off + 3]]);
    Some((src_port, dst_port, false, false))
}

/// Inspect an IPv4 packet (first nibble `4`). Rejects a header shorter than 20
/// bytes or one that runs past the frame. Fragments return early with zeroed
/// transport fields: D5 exempts every fragment entirely, so its transport (which
/// may be absent on a non-first fragment) is never parsed.
fn inspect_ipv4(frame: &[u8]) -> Option<FrameInfo> {
    if frame.len() < 20 {
        return None;
    }
    let ihl = ((frame[0] & 0x0f) as usize) * 4;
    if ihl < 20 || ihl > frame.len() {
        return None;
    }
    let total_len = u16::from_be_bytes([frame[2], frame[3]]) as usize;
    let flags_frag = u16::from_be_bytes([frame[6], frame[7]]);
    // MF set OR a non-zero fragment offset (`0x1FFF` mask).
    let is_fragment = (flags_frag & 0x2000 != 0) || (flags_frag & 0x1FFF != 0);
    let proto = proto_from_u8(frame[9]);
    if is_fragment {
        return Some(FrameInfo {
            version: 4,
            is_fragment: true,
            proto,
            src_port: 0,
            dst_port: 0,
            is_tcp_control: false,
            is_pure_ack: false,
        });
    }
    let (src_port, dst_port, is_tcp_control, is_pure_ack) = match proto {
        IpProto::Tcp => parse_tcp(frame, ihl, total_len)?,
        IpProto::Udp => parse_udp(frame, ihl)?,
        _ => (0, 0, false, false),
    };
    Some(FrameInfo { version: 4, is_fragment, proto, src_port, dst_port, is_tcp_control, is_pure_ack })
}

/// Inspect an IPv6 packet (first nibble `6`). Walks the extension chain
/// (Hop-by-Hop 0, Routing 43, Dest-Options 60, Fragment 44); encountering a
/// Fragment header sets `is_fragment` and the packet is exempt regardless of
/// transport. Stops at ESP (50) / AH (51), which become `IpProto::Other`
/// (non-exempt — cannot parse).
fn inspect_ipv6(frame: &[u8]) -> Option<FrameInfo> {
    if frame.len() < 40 {
        return None;
    }
    let payload_len = u16::from_be_bytes([frame[4], frame[5]]) as usize;
    let mut next_header = frame[6];
    let mut offset = 40usize;
    let mut is_fragment = false;
    while matches!(next_header, 0 | 43 | 60 | 44) {
        // Need the full 8-byte extension header to read its next-header/length.
        if frame.len() < offset + 8 {
            return None;
        }
        if next_header == 44 {
            is_fragment = true;
        }
        let hdr = &frame[offset..];
        next_header = hdr[0];
        let hdr_len = (hdr[1] as usize + 1) * 8;
        offset += hdr_len;
        if offset > frame.len() {
            return None;
        }
    }
    let proto = proto_from_u8(next_header);
    if is_fragment {
        return Some(FrameInfo {
            version: 6,
            is_fragment: true,
            proto,
            src_port: 0,
            dst_port: 0,
            is_tcp_control: false,
            is_pure_ack: false,
        });
    }
    let total_len = 40 + payload_len;
    let (src_port, dst_port, is_tcp_control, is_pure_ack) = match proto {
        IpProto::Tcp => parse_tcp(frame, offset, total_len)?,
        IpProto::Udp => parse_udp(frame, offset)?,
        _ => (0, 0, false, false),
    };
    Some(FrameInfo { version: 6, is_fragment, proto, src_port, dst_port, is_tcp_control, is_pure_ack })
}

/// Classify a raw IP frame for the D5 exemption predicate. `None` for anything
/// unparseable or truncated (a malformed frame is NOT exempt). Never panics.
pub(crate) fn inspect(frame: &[u8]) -> Option<FrameInfo> {
    match frame.first().map(|b| b >> 4) {
        Some(4) => inspect_ipv4(frame),
        Some(6) => inspect_ipv6(frame),
        _ => None,
    }
}

/// D5 exemption predicate, shared by loss, duplication and reordering.
///
/// A frame is exempt (never dropped, duplicated or reordered) when it is any IP
/// fragment (IPv4 or IPv6), ICMPv4/ICMPv6 (incl. NDP/RA), DNS over UDP or TCP
/// (port 53), or a TCP control/pure-ACK segment. A malformed or truncated frame
/// is **not** exempt.
pub(crate) fn is_damage_exempt(frame: &[u8]) -> bool {
    let Some(info) = inspect(frame) else {
        return false;
    };
    if info.is_fragment {
        return true;
    }
    match info.proto {
        IpProto::Icmp | IpProto::Icmp6 => true,
        IpProto::Tcp | IpProto::Udp => {
            if info.src_port == 53 || info.dst_port == 53 {
                return true;
            }
            matches!(info.proto, IpProto::Tcp) && (info.is_tcp_control || info.is_pure_ack)
        }
        IpProto::Other(_) => false,
    }
}

/// The per-frame loss/duplication decision. Reordering is owned by
/// [`ReleaseScheduler`] (D6), so it does not appear here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DamageAction {
    Forward,
    Drop,
    Duplicate,
}

/// Loss + duplication core for one direction. Loss is either a flat random
/// probability or a Gilbert-Elliot two-state burst process; duplication is a
/// flat random probability. All randomness comes from a single [`SplitMix64`]
/// stream so a pinned seed replays exactly.
///
/// # Gilbert-Elliot semantics (tc-netem(8) `gemodel`-shaped)
/// The channel is in a Good or Bad state. Every non-exempt frame first performs
/// the state transition: Good → Bad with probability `lossGoodToBadPct`, Bad →
/// Good with probability `lossBadToGoodPct`. Then **every** frame in the Bad
/// state is dropped, so the two transition percentages drive the burst process
/// and `lossPct` is only used by [`LossModel::Random`]. (`ge_bad` is kept across
/// [`DamageCore::reconfigure`] so a hot config change does not reset the burst.)
///
/// # Decision order
/// Exempt frames short-circuit to [`DamageAction::Forward`] **without drawing
/// from the RNG**, so exempt traffic never perturbs the deterministic stream.
/// Loss is evaluated before duplication: a frame that would both be lost and
/// duplicated is dropped (loss wins).
pub(crate) struct DamageCore {
    rng: SplitMix64,
    ge_bad: bool,
    loss_pct: f64,
    loss_model: LossModel,
    good_to_bad: f64,
    bad_to_good: f64,
    duplicate_pct: f64,
}

impl DamageCore {
    /// Build a core for one direction, seeding the shared decision stream and
    /// starting the Gilbert-Elliot channel in the Good state.
    pub(crate) fn new(seed: u64, cfg: &DirectionConfig) -> Self {
        Self {
            rng: SplitMix64::new(seed),
            ge_bad: false,
            loss_pct: cfg.loss_pct,
            loss_model: cfg.loss_model,
            good_to_bad: cfg.loss_good_to_bad_pct,
            bad_to_good: cfg.loss_bad_to_good_pct,
            duplicate_pct: cfg.duplicate_pct,
        }
    }

    /// Apply a hot config change (D4): snapshot the loss/duplication parameters
    /// and keep the PRNG stream and the Gilbert-Elliot `ge_bad` state intact.
    pub(crate) fn reconfigure(&mut self, cfg: &DirectionConfig) {
        self.loss_pct = cfg.loss_pct;
        self.loss_model = cfg.loss_model;
        self.good_to_bad = cfg.loss_good_to_bad_pct;
        self.bad_to_good = cfg.loss_bad_to_good_pct;
        self.duplicate_pct = cfg.duplicate_pct;
    }

    /// Decide the fate of one frame: `Forward`, `Drop` or `Duplicate`.
    pub(crate) fn shape(&mut self, frame: &[u8]) -> DamageAction {
        // D5 exempt traffic never perturbs the RNG stream.
        if is_damage_exempt(frame) {
            return DamageAction::Forward;
        }
        match self.loss_model {
            LossModel::None => {}
            LossModel::Random => {
                if self.rng.chance(self.loss_pct) {
                    return DamageAction::Drop;
                }
            }
            LossModel::GilbertElliot => {
                // Transition first, then drop every frame in the Bad state.
                if self.ge_bad {
                    if self.rng.chance(self.bad_to_good) {
                        self.ge_bad = false;
                    }
                } else if self.rng.chance(self.good_to_bad) {
                    self.ge_bad = true;
                }
                if self.ge_bad {
                    return DamageAction::Drop;
                }
            }
        }
        // Loss wins over duplication when both would fire.
        if self.rng.chance(self.duplicate_pct) {
            return DamageAction::Duplicate;
        }
        DamageAction::Forward
    }
}

#[cfg(test)]
mod damage_tests {
    use super::*;

    /// A direction config carrying only what the damage tests vary.
    fn cfg(loss_pct: f64, loss_model: LossModel, g2b: f64, b2g: f64, dup: f64) -> DirectionConfig {
        DirectionConfig {
            rate_bps: 0,
            burst_bytes: 32_768,
            delay_ms: 0,
            jitter_ms: 0,
            jitter_distribution: JitterDistribution::Uniform,
            loss_pct,
            loss_model,
            loss_good_to_bad_pct: g2b,
            loss_bad_to_good_pct: b2g,
            duplicate_pct: dup,
            reorder_pct: 0.0,
            reorder_gap: 0,
            order: PacketOrder::Preserve,
        }
    }

    fn decisions(core: &mut DamageCore, frame: &[u8], n: usize) -> Vec<DamageAction> {
        (0..n).map(|_| core.shape(frame)).collect()
    }

    // --- IPv4 fixtures -----------------------------------------------------

    fn ipv4_tcp_frame(flags: u8, payload_len: usize, src_port: u16, dst_port: u16) -> Vec<u8> {
        let mut p = vec![0u8; 20];
        p[0] = 0x45; // IPv4, IHL 5
        let total = 20 + 20 + payload_len;
        p[2..4].copy_from_slice(&(total as u16).to_be_bytes());
        p[8] = 64; // TTL
        p[9] = 6; // TCP
        p[12..16].copy_from_slice(&[10, 0, 0, 1]);
        p[16..20].copy_from_slice(&[10, 0, 0, 2]);
        // TCP header (20 bytes)
        p.extend_from_slice(&src_port.to_be_bytes());
        p.extend_from_slice(&dst_port.to_be_bytes());
        p.extend_from_slice(&0u32.to_be_bytes()); // seq
        p.extend_from_slice(&0u32.to_be_bytes()); // ack
        p.push(0x50); // data offset 5
        p.push(flags);
        p.extend_from_slice(&0u16.to_be_bytes()); // window
        p.extend_from_slice(&0u16.to_be_bytes()); // checksum
        p.extend_from_slice(&0u16.to_be_bytes()); // urgent
        p.resize(p.len() + payload_len, 0);
        p
    }

    fn ipv4_udp_frame(src_port: u16, dst_port: u16) -> Vec<u8> {
        let mut p = vec![0u8; 20];
        p[0] = 0x45;
        p[2..4].copy_from_slice(&(20u16 + 8).to_be_bytes());
        p[8] = 64;
        p[9] = 17; // UDP
        p[12..16].copy_from_slice(&[10, 0, 0, 1]);
        p[16..20].copy_from_slice(&[10, 0, 0, 2]);
        p.extend_from_slice(&src_port.to_be_bytes());
        p.extend_from_slice(&dst_port.to_be_bytes());
        p.extend_from_slice(&8u16.to_be_bytes()); // UDP length
        p.extend_from_slice(&[0, 0]); // checksum
        p
    }

    fn ipv4_icmp_frame() -> Vec<u8> {
        let mut p = vec![0u8; 20];
        p[0] = 0x45;
        p[2..4].copy_from_slice(&(20u16 + 8).to_be_bytes());
        p[8] = 64;
        p[9] = 1; // ICMP
        p[12..16].copy_from_slice(&[10, 0, 0, 1]);
        p[16..20].copy_from_slice(&[10, 0, 0, 2]);
        p.extend_from_slice(&[8, 0, 0, 0]); // echo request, code 0, checksum
        p.extend_from_slice(&[0, 1, 0, 1]); // id, seq
        p
    }

    /// An IPv4 UDP fragment with the More-Fragments bit set (offset 0).
    fn ipv4_fragment_frame() -> Vec<u8> {
        let mut p = vec![0u8; 20];
        p[0] = 0x45;
        p[2..4].copy_from_slice(&(20u16 + 8).to_be_bytes());
        p[6..8].copy_from_slice(&0x2000u16.to_be_bytes()); // MF set
        p[8] = 64;
        p[9] = 17;
        p[12..16].copy_from_slice(&[10, 0, 0, 1]);
        p[16..20].copy_from_slice(&[10, 0, 0, 2]);
        p.extend_from_slice(&1234u16.to_be_bytes());
        p.extend_from_slice(&5678u16.to_be_bytes());
        p.extend_from_slice(&8u16.to_be_bytes());
        p.extend_from_slice(&[0, 0]);
        p
    }

    // --- IPv6 fixtures -----------------------------------------------------

    /// A 40-byte IPv6 header with `next_header` and the given payload length.
    fn ipv6_header(next_header: u8, payload_len: u16) -> Vec<u8> {
        let mut p = vec![0u8; 40];
        p[0] = 0x60; // IPv6
        p[4..6].copy_from_slice(&payload_len.to_be_bytes());
        p[6] = next_header;
        p[7] = 64; // hop limit
        p[8..24].copy_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
        p[24..40].copy_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
        p
    }

    fn ipv6_tcp_frame(flags: u8, payload_len: usize, src_port: u16, dst_port: u16) -> Vec<u8> {
        let tcp_len = 20 + payload_len;
        let mut p = ipv6_header(6, tcp_len as u16);
        p.extend_from_slice(&src_port.to_be_bytes());
        p.extend_from_slice(&dst_port.to_be_bytes());
        p.extend_from_slice(&0u32.to_be_bytes());
        p.extend_from_slice(&0u32.to_be_bytes());
        p.push(0x50);
        p.push(flags);
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&0u16.to_be_bytes());
        p.resize(p.len() + payload_len, 0);
        p
    }

    fn ipv6_udp_frame(src_port: u16, dst_port: u16) -> Vec<u8> {
        let mut p = ipv6_header(17, 8);
        p.extend_from_slice(&src_port.to_be_bytes());
        p.extend_from_slice(&dst_port.to_be_bytes());
        p.extend_from_slice(&8u16.to_be_bytes());
        p.extend_from_slice(&[0, 0]);
        p
    }

    /// An ICMPv6 frame carrying `icmpv6_type` (135 = Neighbor Solicitation,
    /// 134 = Router Advertisement). The body length is irrelevant to D5.
    fn ipv6_icmpv6_frame(icmpv6_type: u8) -> Vec<u8> {
        let mut p = ipv6_header(58, 8);
        p.push(icmpv6_type);
        p.push(0); // code
        p.extend_from_slice(&[0, 0]); // checksum
        p.extend_from_slice(&[0, 0, 0, 0]); // body
        p
    }

    /// An IPv6 packet with a Fragment extension header (44) followed by UDP.
    fn ipv6_fragment_frame(src_port: u16, dst_port: u16) -> Vec<u8> {
        let mut p = ipv6_header(44, 8 + 8);
        // Fragment header (8 bytes): next header UDP, reserved, offset/flags, id.
        p.push(17);
        p.push(0);
        p.extend_from_slice(&0u16.to_be_bytes());
        p.extend_from_slice(&0xABCD_1234u32.to_be_bytes());
        // UDP header.
        p.extend_from_slice(&src_port.to_be_bytes());
        p.extend_from_slice(&dst_port.to_be_bytes());
        p.extend_from_slice(&8u16.to_be_bytes());
        p.extend_from_slice(&[0, 0]);
        p
    }

    // --- Tests -------------------------------------------------------------

    #[test]
    fn gilbert_elliot_bursts() {
        let cfg = cfg(0.0, LossModel::GilbertElliot, 50.0, 5.0, 0.0);
        let frame = ipv4_udp_frame(1234, 5678);
        assert!(!is_damage_exempt(&frame), "fixture must be non-exempt");

        let mut core = DamageCore::new(0xC0FFEE, &cfg);
        let seq = decisions(&mut core, &frame, 2000);
        let drops = seq.iter().filter(|d| **d == DamageAction::Drop).count();
        let forwards = seq.iter().filter(|d| **d == DamageAction::Forward).count();
        assert!(drops > 0, "GE must drop some frames");
        assert!(forwards > 0, "GE must forward some frames");

        let mut run = 0usize;
        let mut max_run = 0usize;
        for d in &seq {
            if *d == DamageAction::Drop {
                run += 1;
                max_run = max_run.max(run);
            } else {
                run = 0;
            }
        }
        assert!(max_run >= 2, "GE must produce a burst of >= 2 consecutive drops (got {max_run})");

        let mut replay = DamageCore::new(0xC0FFEE, &cfg);
        assert_eq!(seq, decisions(&mut replay, &frame, 2000), "same seed must replay identically");
    }

    #[test]
    fn damage_decisions_are_deterministic() {
        let cfg = cfg(50.0, LossModel::Random, 0.0, 0.0, 0.0);
        let frame = ipv4_udp_frame(1234, 5678);
        let mut a = DamageCore::new(0x1111, &cfg);
        let mut b = DamageCore::new(0x1111, &cfg);
        let mut c = DamageCore::new(0x2222, &cfg);
        let sa = decisions(&mut a, &frame, 1000);
        let sb = decisions(&mut b, &frame, 1000);
        let sc = decisions(&mut c, &frame, 1000);
        assert_eq!(sa, sb, "same seed must be bit-identical");
        assert_ne!(sa, sc, "a different seed must differ");
    }

    #[test]
    fn ipv6_ack_is_exempt_from_loss() {
        let cfg = cfg(100.0, LossModel::Random, 0.0, 0.0, 0.0);
        let frame = ipv6_tcp_frame(0x10, 0, 33333, 443); // pure ACK
        assert!(is_damage_exempt(&frame));
        let mut core = DamageCore::new(7, &cfg);
        for _ in 0..200 {
            assert_eq!(core.shape(&frame), DamageAction::Forward);
        }
    }

    #[test]
    fn icmpv6_ndp_is_exempt() {
        let cfg = cfg(100.0, LossModel::Random, 0.0, 0.0, 0.0);
        for ty in [135u8, 134u8] {
            let frame = ipv6_icmpv6_frame(ty);
            assert!(is_damage_exempt(&frame), "ICMPv6 type {ty} must be exempt");
            let mut core = DamageCore::new(11, &cfg);
            for _ in 0..50 {
                assert_eq!(core.shape(&frame), DamageAction::Forward);
            }
        }
    }

    #[test]
    fn ipv4_ack_and_dns_tcp_and_icmp_exempt() {
        let cfg = cfg(100.0, LossModel::Random, 0.0, 0.0, 0.0);
        let exempt = [
            ipv4_tcp_frame(0x10, 0, 40000, 443), // pure ACK
            ipv4_tcp_frame(0x18, 20, 40000, 53), // TCP:53 data
            ipv4_udp_frame(40000, 53),           // UDP:53
            ipv4_icmp_frame(),                   // ICMP(1)
            ipv4_tcp_frame(0x02, 0, 40000, 443), // SYN control
        ];
        let mut core = DamageCore::new(3, &cfg);
        for frame in &exempt {
            assert!(is_damage_exempt(frame), "frame must be exempt: {frame:?}");
            for _ in 0..20 {
                assert_eq!(core.shape(frame), DamageAction::Forward);
            }
        }

        // Selectivity: a plain UDP data frame is NOT exempt and is dropped.
        let data = ipv4_udp_frame(1234, 1234);
        assert!(!is_damage_exempt(&data));
        assert_eq!(core.shape(&data), DamageAction::Drop, "plain data must be dropped at lossPct=100");
    }

    #[test]
    fn ip_fragments_are_exempt() {
        let cfg = cfg(100.0, LossModel::Random, 0.0, 0.0, 100.0);
        let v4 = ipv4_fragment_frame();
        let v6 = ipv6_fragment_frame(1234, 5678);
        assert!(is_damage_exempt(&v4), "IPv4 fragment must be exempt");
        assert!(is_damage_exempt(&v6), "IPv6 fragment must be exempt");
        let mut core = DamageCore::new(5, &cfg);
        for _ in 0..100 {
            assert_eq!(core.shape(&v4), DamageAction::Forward);
            assert_eq!(core.shape(&v6), DamageAction::Forward);
        }
    }
}
