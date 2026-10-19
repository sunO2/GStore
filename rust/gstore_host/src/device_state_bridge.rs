// 批量设备状态 JNI 桥：Rust 宿主 → Kotlin `DeviceStateChannel.readJson`。
//
// 复用 `battery_bridge` 缓存的 `JavaVM` / `applicationContext`；`DeviceStateChannel`
// 类在 Kotlin `nativeInitContext`（app 线程）时解析并缓存 `GlobalRef`，后续 Rust
// 线程不再 `find_class`（app 线程 classloader 才正确）。
//
// 硬约束：绝不 panic（宿主 release `panic = "abort"`）；JNI 异常一律清除；
// 未初始化 / attach 失败 / 调用失败 → `None`。

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use jni::objects::{GlobalRef, JString, JValue};
use jni::JNIEnv;

static DEVICE_STATE_CLASS: OnceLock<GlobalRef> = OnceLock::new();

const CLASS_NAME: &str = "com/suno2/gstore/DeviceStateChannel";
const READ_JSON_METHOD: &str = "readJson";
const READ_JSON_SIG: &str = "(Landroid/content/Context;)Ljava/lang/String;";

/// 在 app 线程解析 `DeviceStateChannel` 并缓存全局引用（幂等）。
pub(crate) fn init_class(env: &mut JNIEnv) {
    if DEVICE_STATE_CLASS.get().is_some() {
        return;
    }
    match env.find_class(CLASS_NAME) {
        Ok(class) => match env.new_global_ref(&class) {
            Ok(global) => {
                let _ = DEVICE_STATE_CLASS.set(global);
                crate::log_bridge::push_host_log(
                    1,
                    "DeviceStateChannel: 已缓存类引用（JNI 批量设备状态就绪）".to_string(),
                );
            }
            Err(e) => {
                crate::log_bridge::push_host_log(
                    3,
                    format!("DeviceStateChannel: 类 GlobalRef 失败: {e}"),
                );
            }
        },
        Err(e) => {
            let _ = env.exception_clear();
            crate::log_bridge::push_host_log(
                3,
                format!("DeviceStateChannel: find_class 失败: {e}"),
            );
        }
    }
}

/// 读取批量设备状态 JSON（Kotlin `DeviceStateChannel.readJson`）。
///
/// 未初始化 / attach 失败 / 调用失败 / 异常 / null → `None`。绝不 panic。
pub fn read_json() -> Option<String> {
    catch_unwind(AssertUnwindSafe(read_json_inner)).unwrap_or(None)
}

fn read_json_inner() -> Option<String> {
    let jvm = crate::battery_bridge::jvm()?;
    let class = DEVICE_STATE_CLASS.get()?;
    let context = crate::battery_bridge::context()?;

    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("DeviceStateChannel.readJson: JNI attach 失败: {e}"),
            );
            return None;
        }
    };

    let value = match env.call_static_method(
        class,
        READ_JSON_METHOD,
        READ_JSON_SIG,
        &[JValue::Object(context.as_obj())],
    ) {
        Ok(v) => v,
        Err(e) => {
            take_pending_exception(&env, "readJson");
            crate::log_bridge::push_host_log(
                3,
                format!("DeviceStateChannel.readJson JNI 调用失败: {e}"),
            );
            return None;
        }
    };

    if take_pending_exception(&env, "readJson") {
        return None;
    }

    let obj = value.l().ok()?;
    if obj.is_null() {
        return None;
    }
    let jstr: JString = obj.into();
    env.get_string(&jstr).map(|s| s.into()).ok()
}

fn take_pending_exception(env: &JNIEnv, context: &str) -> bool {
    if !env.exception_check().unwrap_or(false) {
        return false;
    }
    env.exception_describe().ok();
    env.exception_clear().ok();
    crate::log_bridge::push_host_log(
        3,
        format!("DeviceStateChannel: {context} 抛出 JNI 异常（已清除）"),
    );
    true
}
