//! Bus acceptance tests (delivery matrix, masking, ownership,
//! reentrancy). Split out of `bus.rs` to keep the production file under the
//! 250 pure-LOC ceiling.
//!
//! allow: SIZE_OK — one table-driven acceptance matrix for C7/C18; splitting
//! the cases would duplicate the recorder/subscriber fixtures.

use std::panic;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use serde_json::json;

use super::*;
use crate::config::model::ConfigSource;

type Log = Arc<Mutex<Vec<ConfigChangePayload>>>;

    fn listen(
        bus: &ConfigBus,
        caller: ConfigCaller,
        filter: ConfigFilter,
    ) -> (ConfigToken, Log) {
        let log: Log = Arc::new(Mutex::new(Vec::new()));
        let sink = log.clone();
        let token = bus.subscribe(caller, filter, move |payload| {
            sink.lock().unwrap_or_else(PoisonError::into_inner).push(payload.clone());
        });
        (token, log)
    }

    fn seen(log: &Log) -> Vec<(String, String, Option<Value>)> {
        log.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|payload| {
                (
                    payload.module.clone(),
                    payload.key.clone(),
                    payload.value.clone(),
                )
            })
            .collect()
    }

    fn change(module: &str, key: &str, value: Value, revision: u64) -> ConfigChange {
        ConfigChange {
            module: module.to_string(),
            key: key.to_string(),
            old_json: None,
            new_json: Some(value),
            revision,
            source: ConfigSource::Module,
            actor: Some("test".to_string()),
        }
    }

    fn secret_change(
        module: &str,
        key: &str,
        old: Value,
        new: Value,
        revision: u64,
    ) -> ConfigChange {
        ConfigChange {
            module: module.to_string(),
            key: key.to_string(),
            old_json: Some(old),
            new_json: Some(new),
            revision,
            source: ConfigSource::User,
            actor: None,
        }
    }

    #[test]
    fn whole_module_subscriber_receives_download_only() {
        let bus = ConfigBus::new();
        let (_token, log) = listen(
            &bus,
            ConfigCaller::module("download"),
            ConfigFilter::whole_module("download"),
        );

        bus.publish(&change("theme", "mode", json!(1), 1)).unwrap();
        bus.publish(&change("download", "max_concurrent", json!(5), 2))
            .unwrap();
        bus.publish(&change("download", "wifi_only", json!(false), 3))
            .unwrap();

        assert_eq!(
            seen(&log),
            vec![
                (
                    "download".to_string(),
                    "max_concurrent".to_string(),
                    Some(json!(5))
                ),
                (
                    "download".to_string(),
                    "wifi_only".to_string(),
                    Some(json!(false))
                ),
            ],
            "theme changes must never reach a download-only subscriber"
        );
    }

    #[test]
    fn exact_key_subscriber_receives_only_that_key() {
        let bus = ConfigBus::new();
        let (_token, log) = listen(
            &bus,
            ConfigCaller::module("download"),
            ConfigFilter::exact_key("download", "max_retries"),
        );

        bus.publish(&change("download", "max_concurrent", json!(5), 1))
            .unwrap();
        bus.publish(&change("download", "max_retries", json!(2), 2))
            .unwrap();
        bus.publish(&change("download", "wifi_only", json!(true), 3))
            .unwrap();

        assert_eq!(
            seen(&log),
            vec![(
                "download".to_string(),
                "max_retries".to_string(),
                Some(json!(2))
            )]
        );
    }

    #[test]
    fn public_read_cross_module_change_is_delivered() {
        let bus = ConfigBus::new();
        let (_token, log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("network"),
        );

        bus.publish(&change(
            "network",
            "proxy_url",
            json!("https://proxy.example/"),
            1,
        ))
        .unwrap();

        assert_eq!(
            seen(&log),
            vec![(
                "network".to_string(),
                "proxy_url".to_string(),
                Some(json!("https://proxy.example/"))
            )],
            "PublicRead is readable/subscribable across modules"
        );
    }

    #[test]
    fn foreign_whole_module_subscription_never_leaks_owner_or_secret() {
        let bus = ConfigBus::new();
        // Registered BEFORE any download change: this is the stale-state /
        // "later Owner key appears" case (C7).
        let (_download_token, download_log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("download"),
        );
        let (_webdav_token, webdav_log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("webdav"),
        );

        bus.publish(&change("download", "max_concurrent", json!(5), 1))
            .unwrap();
        bus.publish(&change("download", "wifi_only", json!(false), 2))
            .unwrap();
        bus.publish(&secret_change(
            "webdav",
            "password",
            json!("old-secret"),
            json!("new-secret"),
            3,
        ))
        .unwrap();
        bus.publish(&change("webdav", "url", json!("https://dav.example"), 4))
            .unwrap();

        assert!(
            seen(&download_log).is_empty(),
            "key=None must not authorize Owner keys in a foreign module"
        );
        assert!(
            seen(&webdav_log).is_empty(),
            "key=None must not authorize Secret/Owner entries in a foreign module"
        );
    }

    #[test]
    fn dart_receives_all_changes_and_secrets_are_masked() {
        let bus = ConfigBus::new();
        let (_download_token, download_log) = listen(
            &bus,
            ConfigCaller::Dart,
            ConfigFilter::whole_module("download"),
        );
        let (_webdav_token, webdav_log) = listen(
            &bus,
            ConfigCaller::Dart,
            ConfigFilter::whole_module("webdav"),
        );

        bus.publish(&change("download", "max_concurrent", json!(5), 1))
            .unwrap();
        bus.publish(&change("download", "wifi_only", json!(true), 2))
            .unwrap();
        bus.publish(&secret_change(
            "webdav",
            "password",
            json!("old-plain"),
            json!("new-plain"),
            3,
        ))
        .unwrap();

        assert_eq!(
            seen(&download_log),
            vec![
                (
                    "download".to_string(),
                    "max_concurrent".to_string(),
                    Some(json!(5))
                ),
                (
                    "download".to_string(),
                    "wifi_only".to_string(),
                    Some(json!(true))
                ),
            ],
            "trusted Dart sees every non-secret change in the module"
        );
        assert_eq!(
            seen(&webdav_log),
            vec![(
                "webdav".to_string(),
                "password".to_string(),
                Some(json!(MASKED_VALUE))
            )],
            "trusted Dart still receives only the masked secret"
        );
        let serialized = {
            let log = webdav_log.lock().unwrap_or_else(PoisonError::into_inner);
            serde_json::to_string(&*log).unwrap()
        };
        assert!(!serialized.contains("new-plain"), "{serialized}");
        assert!(!serialized.contains("old-plain"), "{serialized}");
        assert!(!serialized.contains("\"value\":\"\""), "{serialized}");
    }

    #[test]
    fn host_receives_all_change_entries_with_masked_secrets() {
        let bus = ConfigBus::new();
        let mut logs = Vec::new();
        for module in ["download", "theme", "network", "webdav"] {
            let (_token, log) = listen(&bus, ConfigCaller::Host, ConfigFilter::whole_module(module));
            logs.push(log);
        }

        bus.publish(&change("download", "max_retries", json!(1), 1))
            .unwrap();
        bus.publish(&change("theme", "mode", json!(2), 2)).unwrap();
        bus.publish(&change("network", "proxy_url", json!("prox"), 3))
            .unwrap();
        bus.publish(&secret_change(
            "webdav",
            "password",
            json!("old"),
            json!("new"),
            4,
        ))
        .unwrap();

        assert_eq!(seen(&logs[0]).len(), 1);
        assert_eq!(seen(&logs[1]).len(), 1);
        assert_eq!(seen(&logs[2]).len(), 1);
        assert_eq!(
            seen(&logs[3]),
            vec![(
                "webdav".to_string(),
                "password".to_string(),
                Some(json!(MASKED_VALUE))
            )]
        );
    }

    #[test]
    fn unsubscribe_stops_delivery_and_rejects_another_callers_token() {
        let bus = ConfigBus::new();
        let (download_token, download_log) = listen(
            &bus,
            ConfigCaller::module("download"),
            ConfigFilter::whole_module("download"),
        );
        let (theme_token, theme_log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("theme"),
        );

        assert_eq!(
            bus.unsubscribe_for(&ConfigCaller::module("download"), &theme_token),
            Err(ConfigBusError::NotOwner),
            "one caller cannot unsubscribe another caller's token"
        );
        assert_eq!(
            bus.unsubscribe(&theme_token).unwrap(),
            (),
            "the owner may still unsubscribe its own token"
        );
        bus.publish(&change("theme", "mode", json!(1), 1)).unwrap();
        assert!(seen(&theme_log).is_empty());

        bus.publish(&change("download", "max_concurrent", json!(5), 2))
            .unwrap();
        assert_eq!(seen(&download_log).len(), 1);

        bus.unsubscribe(&download_token).unwrap();
        bus.publish(&change("download", "wifi_only", json!(false), 3))
            .unwrap();
        assert_eq!(
            seen(&download_log).len(),
            1,
            "unsubscribed token receives nothing further"
        );

        let other_bus = ConfigBus::new();
        assert_eq!(
            other_bus.unsubscribe(&download_token),
            Err(ConfigBusError::UnknownToken),
            "a token from another bus is not accepted"
        );
    }

    #[test]
    fn clear_module_removes_only_that_modules_subscriptions() {
        let bus = ConfigBus::new();
        let (_download_wide, download_wide_log) = listen(
            &bus,
            ConfigCaller::module("download"),
            ConfigFilter::whole_module("download"),
        );
        let (_download_exact, _download_exact_log) = listen(
            &bus,
            ConfigCaller::module("download"),
            ConfigFilter::exact_key("download", "max_retries"),
        );
        let (_theme_own, theme_own_log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("theme"),
        );
        let (_theme_foreign, theme_foreign_log) = listen(
            &bus,
            ConfigCaller::module("theme"),
            ConfigFilter::whole_module("network"),
        );
        let (_host_download, host_download_log) = listen(
            &bus,
            ConfigCaller::Host,
            ConfigFilter::whole_module("download"),
        );

        assert_eq!(bus.clear_module("download"), 2);
        assert_eq!(bus.subscription_count(), 3);

        bus.publish(&change("download", "max_concurrent", json!(5), 1))
            .unwrap();
        bus.publish(&change("theme", "mode", json!(1), 2)).unwrap();
        bus.publish(&change("network", "proxy_url", json!("p"), 3))
            .unwrap();

        assert!(
            seen(&download_wide_log).is_empty(),
            "download's own whole-module subscription was removed"
        );
        assert_eq!(seen(&theme_own_log).len(), 1);
        assert_eq!(seen(&theme_foreign_log).len(), 1);
        assert_eq!(
            seen(&host_download_log).len(),
            1,
            "Host's subscription is not owned by the download module"
        );
    }

    #[test]
    fn invalid_change_is_never_emitted() {
        let bus = ConfigBus::new();
        let (_token, log) = listen(
            &bus,
            ConfigCaller::Host,
            ConfigFilter::whole_module("download"),
        );

        let out_of_range = bus.publish(&change("download", "max_concurrent", json!(99), 1));
        assert!(matches!(
            out_of_range,
            Err(ConfigBusError::InvalidChange(ConfigError::Validation { .. }))
        ));
        let wrong_type = bus.publish(&change("download", "max_concurrent", json!("five"), 2));
        assert!(matches!(
            wrong_type,
            Err(ConfigBusError::InvalidChange(ConfigError::TypeMismatch { .. }))
        ));
        let unknown = bus.publish(&change("download", "not_a_key", json!(1), 3));
        assert!(matches!(
            unknown,
            Err(ConfigBusError::InvalidChange(ConfigError::UnknownKey { .. }))
        ));
        let secret_wrong_type =
            bus.publish(&change("webdav", "password", json!(42), 4));
        assert!(matches!(
            secret_wrong_type,
            Err(ConfigBusError::InvalidChange(ConfigError::TypeMismatch { .. }))
        ));

        assert!(
            seen(&log).is_empty(),
            "a change rejected by validation must emit nothing"
        );
    }

    #[test]
    fn reentrant_publish_and_self_unsubscribe_do_not_deadlock() {
        let bus = Arc::new(ConfigBus::new());
        let self_log: Log = Arc::new(Mutex::new(Vec::new()));
        let nested_log: Log = Arc::new(Mutex::new(Vec::new()));
        let token_slot: Arc<Mutex<Option<ConfigToken>>> = Arc::new(Mutex::new(None));
        let fired = Arc::new(AtomicBool::new(false));

        {
            let nested = nested_log.clone();
            bus.subscribe(
                ConfigCaller::module("theme"),
                ConfigFilter::whole_module("theme"),
                move |payload| {
                    nested
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .push(payload.clone());
                },
            );
        }

        let bus_for_callback = bus.clone();
        let token_slot_for_callback = token_slot.clone();
        let log_for_callback = self_log.clone();
        let fired_for_callback = fired.clone();
        let token = bus.subscribe(
            ConfigCaller::module("download"),
            ConfigFilter::whole_module("download"),
            move |payload| {
                log_for_callback
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(payload.clone());
                if !fired_for_callback.swap(true, Ordering::SeqCst) {
                    // Reentrant publish: theme's subscription must receive it.
                    bus_for_callback
                        .publish(&change("theme", "mode", json!(1), 10))
                        .unwrap();
                    // Self-unsubscribe while still inside the outer publish.
                    let token = token_slot_for_callback
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .clone();
                    if let Some(token) = token {
                        bus_for_callback.unsubscribe(&token).unwrap();
                    }
                }
            },
        );
        *token_slot
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(token);

        bus.publish(&change("download", "max_concurrent", json!(5), 1))
            .unwrap();
        assert_eq!(seen(&self_log).len(), 1);
        assert_eq!(seen(&nested_log).len(), 1);

        // The callback removed itself, so a later download change is silent.
        bus.publish(&change("download", "wifi_only", json!(true), 2))
            .unwrap();
        assert_eq!(seen(&self_log).len(), 1, "self-unsubscribe took effect");
    }

    #[test]
    fn panicking_callback_is_dropped_without_blocking_others() {
        let bus = ConfigBus::new();
        let panics = Arc::new(AtomicUsize::new(0));
        let panics_for_callback = panics.clone();
        let (_boom_token, _) = listen(
            &bus,
            ConfigCaller::Host,
            ConfigFilter::whole_module("download"),
        );
        // Replace the recording callback with a panicking one by subscribing a
        // second Host listener; the first listener proves delivery continues.
        let _boom = {
            let panics = panics_for_callback;
            bus.subscribe(
                ConfigCaller::Host,
                ConfigFilter::whole_module("download"),
                move |_payload| {
                    panics.fetch_add(1, Ordering::SeqCst);
                    panic!("callback failure");
                },
            )
        };

        let (_, log) = listen(
            &bus,
            ConfigCaller::Host,
            ConfigFilter::whole_module("download"),
        );
        let previous_hook = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));
        let delivered = bus.publish(&change("download", "max_concurrent", json!(5), 1));
        panic::set_hook(previous_hook);
        assert_eq!(delivered.unwrap(), 2);
        assert_eq!(seen(&log).len(), 1);
        assert_eq!(panics.load(Ordering::SeqCst), 1);

        let delivered = bus.publish(&change("download", "wifi_only", json!(true), 2));
        assert_eq!(
            delivered.unwrap(),
            2,
            "the panic subscriber was dropped; both healthy listeners remain"
        );
        assert_eq!(
            panics.load(Ordering::SeqCst),
            1,
            "a failed callback is never invoked again"
        );
        assert_eq!(seen(&log).len(), 2);
    }
