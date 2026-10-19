// 免权限电池 JNI 桥：Rust 宿主 → Kotlin `BatteryChannel` 静态方法。
//
// Dart 侧电池采集原本经 Flutter `MethodChannel`（`gstore/battery`）往返；本模块
// 让 Rust 在已 attach 的线程上直接调 Kotlin 静态方法，Dart 只需一次 FRB 调用：
// - `nativeInitContext` 由 Kotlin 在 **app 线程**（`MainActivity.onCreate` →
//   `ShizukuExecBridge.ensureInit`）调用：缓存 `JavaVM`、`applicationContext`
//   的 `GlobalRef`，并在此处解析 `BatteryChannel` 类（app 线程 classloader 正确，
//   后续 Rust 线程不再 `find_class`）。
// - `read_json` / `is_interactive` 供 FRB `bridge::battery_*` 门面调用。
//
// 硬约束：绝不 panic（宿主 release `panic = "abort"`），JNI 异常一律清除；
// 未初始化 / attach 失败 / 调用失败 → `None`。

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::{JNIEnv, JavaVM};

/// 进程内唯一 `JavaVM`（Kotlin `nativeInitContext` 时缓存）。
static VM: OnceLock<JavaVM> = OnceLock::new();

/// `applicationContext` 的全局引用（跨线程安全、防 GC）。
static APP_CONTEXT: OnceLock<GlobalRef> = OnceLock::new();

/// `com.suno2.gstore.BatteryChannel` 的全局引用（静态方法的 `jclass`）。
static BATTERY_CLASS: OnceLock<GlobalRef> = OnceLock::new();

/// `com.suno2.gstore.ForegroundAccessibilityService` 的全局引用
/// （`readJson(Context)` 静态方法的 `jclass`）。
static FOREGROUND_A11Y_CLASS: OnceLock<GlobalRef> = OnceLock::new();

const BATTERY_CLASS_NAME: &str = "com/suno2/gstore/BatteryChannel";
const FOREGROUND_A11Y_CLASS_NAME: &str = "com/suno2/gstore/ForegroundAccessibilityService";
const READ_JSON_METHOD: &str = "readJson";
const READ_JSON_SIG: &str = "(Landroid/content/Context;)Ljava/lang/String;";
const IS_INTERACTIVE_METHOD: &str = "isInteractive";
const IS_INTERACTIVE_SIG: &str = "(Landroid/content/Context;)Z";

/// 已缓存的 `JavaVM`（未初始化 → `None`）。供其它 JNI 桥（如
/// `device_state_bridge`）复用，避免重复 attach 逻辑与全局态。
pub(crate) fn jvm() -> Option<&'static JavaVM> {
    VM.get()
}

/// 已缓存的 `applicationContext` 全局引用（未初始化 → `None`）。
pub(crate) fn context() -> Option<&'static GlobalRef> {
    APP_CONTEXT.get()
}

/// 把 JNI 导出体包进 `catch_unwind`：panic 绝不越过 `extern "system"` 边界。
fn guard_jni<F: FnOnce()>(export: &str, body: F) {
    if catch_unwind(AssertUnwindSafe(body)).is_err() {
        crate::log_bridge::push_host_log(
            3,
            format!("{export}: JNI 边界捕获 panic（已返回安全默认值）"),
        );
    }
}

/// 检查并清除待决 JNI 异常，返回是否发生过。
fn take_pending_exception(env: &JNIEnv, context: &str) -> bool {
    if !env.exception_check().unwrap_or(false) {
        return false;
    }
    env.exception_describe().ok();
    env.exception_clear().ok();
    crate::log_bridge::push_host_log(
        3,
        format!("BatteryChannel: {context} 抛出 JNI 异常（已清除）"),
    );
    true
}

/// `nativeInitContext` 实体：缓存 VM / applicationContext / BatteryChannel 类。
/// 幂等（`OnceLock::set` 失败即忽略）。
pub(crate) fn init_context(env: &mut JNIEnv, context: &JObject) {
    match env.get_java_vm() {
        Ok(jvm) => {
            let _ = VM.set(jvm);
        }
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("BatteryChannel.nativeInitContext: get_java_vm 失败: {e}"),
            );
        }
    }

    if APP_CONTEXT.get().is_none() {
        match env.new_global_ref(context) {
            Ok(global) => {
                let _ = APP_CONTEXT.set(global);
            }
            Err(e) => {
                crate::log_bridge::push_host_log(
                    3,
                    format!("BatteryChannel.nativeInitContext: context GlobalRef 失败: {e}"),
                );
            }
        }
    }

    if BATTERY_CLASS.get().is_none() {
        match env.find_class(BATTERY_CLASS_NAME) {
            Ok(class) => match env.new_global_ref(&class) {
                Ok(global) => {
                    let _ = BATTERY_CLASS.set(global);
                    crate::log_bridge::push_host_log(
                        1,
                        "BatteryChannel: 已缓存 applicationContext + BatteryChannel 类引用（JNI 电池数据源就绪）"
                            .to_string(),
                    );
                }
                Err(e) => {
                    crate::log_bridge::push_host_log(
                        3,
                        format!(
                            "BatteryChannel.nativeInitContext: 类 GlobalRef 失败: {e}"
                        ),
                    );
                }
            },
            Err(e) => {
                take_pending_exception(env, "nativeInitContext/find_class");
                crate::log_bridge::push_host_log(
                    3,
                    format!("BatteryChannel.nativeInitContext: find_class 失败: {e}"),
                );
            }
        }
    }

    crate::device_state_bridge::init_class(env);
    crate::frame_metrics_bridge::init_class(env);

    // 前台无障碍服务：同 app 线程解析类引用，后续 Rust 线程直接调静态 readJson。
    if FOREGROUND_A11Y_CLASS.get().is_none() {
        match env.find_class(FOREGROUND_A11Y_CLASS_NAME) {
            Ok(class) => match env.new_global_ref(&class) {
                Ok(global) => {
                    let _ = FOREGROUND_A11Y_CLASS.set(global);
                    crate::log_bridge::push_host_log(
                        1,
                        "ForegroundAccessibilityService: 已缓存类引用（JNI 前台事件源就绪）"
                            .to_string(),
                    );
                }
                Err(e) => {
                    crate::log_bridge::push_host_log(
                        3,
                        format!(
                            "ForegroundAccessibilityService: 类 GlobalRef 失败: {e}"
                        ),
                    );
                }
            },
            Err(e) => {
                take_pending_exception(env, "init_context/foreground_find_class");
                crate::log_bridge::push_host_log(
                    3,
                    format!("ForegroundAccessibilityService: find_class 失败: {e}"),
                );
            }
        }
    }
}

/// 读取前台无障碍服务缓存 JSON（Kotlin `ForegroundAccessibilityService.readJson`）。
///
/// 未初始化 / attach 失败 / 调用失败 / 异常 / null → `None`。绝不 panic。
pub fn foreground_read_json() -> Option<String> {
    catch_unwind(AssertUnwindSafe(foreground_read_json_inner)).unwrap_or(None)
}

fn foreground_read_json_inner() -> Option<String> {
    let jvm = VM.get()?;
    let class = FOREGROUND_A11Y_CLASS.get()?;
    let context = APP_CONTEXT.get()?;

    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ForegroundAccessibilityService.readJson: JNI attach 失败: {e}"),
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
            take_pending_exception(&env, "foreground_readJson");
            crate::log_bridge::push_host_log(
                3,
                format!("ForegroundAccessibilityService.readJson JNI 调用失败: {e}"),
            );
            return None;
        }
    };

    if take_pending_exception(&env, "foreground_readJson") {
        return None;
    }

    let obj = value.l().ok()?;
    if obj.is_null() {
        return None;
    }
    let jstr: JString = obj.into();
    env.get_string(&jstr).map(|s| s.into()).ok()
}

/// 读取电池 JSON（Kotlin `BatteryChannel.readJson`）。
///
/// 未初始化 / attach 失败 / 调用失败 / 异常 / null → `None`。绝不 panic。
pub fn read_json() -> Option<String> {
    catch_unwind(AssertUnwindSafe(read_json_inner)).unwrap_or(None)
}

fn read_json_inner() -> Option<String> {
    let jvm = VM.get()?;
    let class = BATTERY_CLASS.get()?;
    let context = APP_CONTEXT.get()?;

    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("BatteryChannel.readJson: JNI attach 失败: {e}"),
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
                format!("BatteryChannel.readJson JNI 调用失败: {e}"),
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

/// 屏幕是否点亮（Kotlin `BatteryChannel.isInteractive`）。
///
/// 未初始化 / attach 失败 / 调用失败 / 异常 → `None`。绝不 panic。
pub fn is_interactive() -> Option<bool> {
    catch_unwind(AssertUnwindSafe(is_interactive_inner)).unwrap_or(None)
}

fn is_interactive_inner() -> Option<bool> {
    let jvm = VM.get()?;
    let class = BATTERY_CLASS.get()?;
    let context = APP_CONTEXT.get()?;

    let mut env = jvm.attach_current_thread().ok()?;

    match env.call_static_method(
        class,
        IS_INTERACTIVE_METHOD,
        IS_INTERACTIVE_SIG,
        &[JValue::Object(context.as_obj())],
    ) {
        Ok(v) => {
            if take_pending_exception(&env, "isInteractive") {
                return None;
            }
            v.z().ok()
        }
        Err(e) => {
            take_pending_exception(&env, "isInteractive");
            crate::log_bridge::push_host_log(
                3,
                format!("BatteryChannel.isInteractive JNI 调用失败: {e}"),
            );
            None
        }
    }
}

// ---------------------------------------------------------------------------
// JNI 导出（Kotlin `ShizukuExecBridge.ensureInit` → `nativeInitContext`）
// ---------------------------------------------------------------------------

/// Kotlin: `external fun nativeInitContext(context: Context)`（静态方法）。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ShizukuExecBridge_nativeInitContext(
    mut env: JNIEnv,
    _class: JClass,
    context: JObject,
) {
    guard_jni("ShizukuExecBridge.nativeInitContext", || {
        init_context(&mut env, &context)
    });
}
