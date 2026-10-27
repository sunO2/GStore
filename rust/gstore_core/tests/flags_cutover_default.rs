//! Process-isolated proof of the Wave 6 durable closeout default.
//!
//! Integration-test binaries get their own process, so `flags()` starts from
//! `Flags::WAVE06_CLOSEOUT` with no in-crate test able to arm `core_writes`
//! concurrently. Keeping this assertion out of the library unit-test binary
//! avoids a race with `migration::tests::core_writes_guard`.

use gstore_core::flags::{flags, Flags};

#[test]
fn cutover_default_is_process_isolated() {
    let snapshot = flags();
    assert!(snapshot.channels, "channels must default to core-owned");
    assert!(snapshot.js_channel, "js_channel must default to core-owned");
    assert!(snapshot.catalog, "catalog must default to core-owned");
    assert!(snapshot.update, "update must default to core-owned");
    assert!(snapshot.download, "download must default to core-owned");
    assert!(snapshot.install, "install must default to core-owned");
    assert!(!snapshot.core_writes, "core_writes must stay unarmed");

    // The closeout snapshot IS the process default.
    assert_eq!(Flags::WAVE06_CLOSEOUT, Flags::default());
    assert_eq!(
        Flags::WAVE06_CLOSEOUT,
        Flags {
            channels: true,
            catalog: true,
            update: true,
            download: true,
            install: true,
            js_channel: true,
            core_writes: false,
        }
    );
    assert_eq!(snapshot, Flags::WAVE06_CLOSEOUT);

    // The all-off opt-out stays available for tests and the legacy world.
    assert_eq!(
        Flags::DISABLED,
        Flags {
            channels: false,
            catalog: false,
            update: false,
            download: false,
            install: false,
            js_channel: false,
            core_writes: false,
        }
    );
    assert_ne!(Flags::DISABLED, Flags::default());
}
