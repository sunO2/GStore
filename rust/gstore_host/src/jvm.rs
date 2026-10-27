//! The VM-only JNI seam for the two allowlisted packet-plane primitives.
//!
//! `gstore_mod_proxy` creates sockets and resolves packet UIDs inside Rust, so
//! `gstore_host` keeps exactly two module-level JNI exceptions:
//! `VpnService.protect(fd)` and `uid -> package` resolution. Both only need the
//! process `JavaVM`; no platform host, inventory cache, or class table lives
//! here.
//!
//! The `VpnService` global reference and TUN fd stay in [`crate::jni_bridge`];
//! this module owns the VM and nothing else.

use std::sync::OnceLock;

use jni::objects::JObject;
use jni::{JNIEnv, JavaVM};

/// Process-wide `JavaVM` (captured once by `JNI_OnLoad` or the service bridge).
static JVM: OnceLock<JavaVM> = OnceLock::new();

/// Cached `JavaVM` for the allowlisted proxy seams (`None` off-device).
pub fn platform_jvm() -> Option<&'static JavaVM> {
    JVM.get()
}

/// Stores the process VM (idempotent; a later capture is ignored).
pub(crate) fn set_vm(vm: JavaVM) {
    let _ = JVM.set(vm);
}

/// Caches the VM while attaching the `VpnService` bridge.
///
/// The service `GlobalRef`, TUN fd, and protect wiring stay in `jni_bridge`;
/// this function only owns the VM so the packet-plane seam has one owner.
pub(crate) fn init_vm(env: &JNIEnv, service: &JObject) -> Result<(), String> {
    if service.is_null() {
        return Err("service 引用为 null".to_string());
    }
    let jvm = env
        .get_java_vm()
        .map_err(|error| format!("get_java_vm 失败: {error}"))?;
    set_vm(jvm);
    Ok(())
}

/// Captures the VM for a non-service frontend handoff.
///
/// Retained for the Kotlin context-bootstrap seam; it deliberately performs no
/// native registration and touches no platform module.
#[allow(dead_code)]
pub(crate) fn capture_vm(env: &mut JNIEnv, context: &JObject) -> Result<(), String> {
    if context.is_null() {
        return Err("jvm: context 引用为 null".to_string());
    }
    let jvm = env
        .get_java_vm()
        .map_err(|error| format!("jvm: get_java_vm 失败: {error}"))?;
    set_vm(jvm);
    crate::log_bridge::push_host_log(
        1,
        format!("jvm: JavaVM 已缓存 (captured={})", platform_jvm().is_some()),
    );
    Ok(())
}
