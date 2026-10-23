//! Process-isolated proof of the Wave 6B cutover default.
//!
//! Integration-test binaries get their own process, so `flags()` starts from
//! `Flags::WAVE06B_CUTOVER` with no in-crate test able to arm `core_writes`
//! concurrently. Keeping this assertion out of the library unit-test binary
//! avoids a race with `migration::tests::core_writes_guard`.

use gstore_core::flags::{flags, Flags};

#[test]
fn cutover_default_is_process_isolated() {
    let snapshot = flags();
    assert!(snapshot.download, "download must default to core-owned");
    assert!(snapshot.install, "install must default to core-owned");
    assert!(!snapshot.channels, "channels must stay off");
    assert!(!snapshot.catalog, "catalog must stay off");
    assert!(!snapshot.update, "update must stay off");
    assert!(!snapshot.js_channel, "js_channel must stay off");
    assert!(!snapshot.core_writes, "core_writes must stay unarmed");

    // The opt-out path stays available and all-off.
    assert_eq!(Flags::DISABLED, Flags::default());
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
}
