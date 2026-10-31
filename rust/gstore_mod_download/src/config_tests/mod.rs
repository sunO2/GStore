//! ABI v5 config-vtable tests for the download module.
//!
//! Each test mounts the real module through its C ABI with a mock host vtable
//! that implements the committed ABI v5 contract (get/set/list/subscribe/
//! unsubscribe/free_buf). No network and no device are required.

mod basic;
mod harness;
mod lifecycle;
mod mock;
