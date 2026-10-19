// 宿主 JNI 桥：Rust（gstore_host）→ Kotlin 薄壳 `ShizukuExecBridge` → Shizuku。
//
// 统一「特权 shell 执行」门面：Dart → FRB（`bridge::shizuku_exec`）→ 本模块
// → JNI 静态调用 `ShizukuExecBridge.exec(String): String` → rikka.shizuku
// `Shizuku.newProcess`。宿主不直接依赖 Shizuku / UserService / AIDL，私有且
// 易变的 Shizuku 细节只留在 Kotlin 薄壳一处。
//
// 范式完全照 `jni_bridge.rs`（唯一 JNI 范本）：
// - 进程内唯一 `JavaVM`（`nativeInit` 由 Kotlin 在 app 线程调用时缓存；线程
//   为 app 线程，classloader 正确）。
// - `ShizukuExecBridge` 的 `GlobalRef`（静态 native 方法的第二参即该类
//   `jclass`，无需 `find_class`）。`GlobalRef` 跨线程安全且防 GC。
// - 绝不让 panic 越过 `extern "system"` 边界（宿主 release `panic = "abort"`，
//   一次 panic 会杀掉整个 App）；`exec`/`is_available` 亦用 `catch_unwind` 包裹。
//
// 契约（Kotlin 侧已完成并经 javap 实测，冻结，勿改）：
// - 类 FQN：`com.suno2.gstore.ShizukuExecBridge`
// - 静态方法：`exec(Ljava/lang/String;)Ljava/lang/String;`
//             `isAvailable()Z`
//             `nativeInit()V`（JNI 名
//             `Java_com_suno2_gstore_ShizukuExecBridge_nativeInit`）

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use jni::objects::{GlobalRef, JClass, JString, JValue};
use jni::{JNIEnv, JavaVM};

/// 进程内唯一的 `JavaVM`（Kotlin `ensureInit` 首次调用 `nativeInit` 时缓存）。
static SHIZUKU_VM: OnceLock<JavaVM> = OnceLock::new();

/// `ShizukuExecBridge` 类的全局引用（静态 native 方法的 `jclass`）。
static BRIDGE_CLASS: OnceLock<GlobalRef> = OnceLock::new();

/// Kotlin 契约：静态方法名与 JVM 签名（冻结，勿改）。
const EXEC_METHOD: &str = "exec";
const EXEC_SIG: &str = "(Ljava/lang/String;)Ljava/lang/String;";
const IS_AVAILABLE_METHOD: &str = "isAvailable";
const IS_AVAILABLE_SIG: &str = "()Z";

/// 把 JNI 导出体包进 `catch_unwind`：panic 绝不越过 `extern "system"` 边界
/// （未捕获的 unwind 跨 FFI 是 UB）。与 `jni_bridge::guard_jni` 同策略，panic
/// 时记一条日志并返回安全默认值；release 构建仍以 `panic = "abort"` 兜底。
fn guard_jni<F: FnOnce()>(export: &str, body: F) {
    if catch_unwind(AssertUnwindSafe(body)).is_err() {
        crate::log_bridge::push_host_log(
            3,
            format!("{export}: JNI 边界捕获 panic（已返回安全默认值）"),
        );
    }
}

/// 检查并清除待决的 JNI 异常，返回是否发生过。异常绝不跨 FFI 泄漏。
fn take_pending_exception(env: &JNIEnv, context: &str) -> bool {
    if !env.exception_check().unwrap_or(false) {
        return false;
    }
    env.exception_describe().ok();
    env.exception_clear().ok();
    crate::log_bridge::push_host_log(
        3,
        format!("ShizukuExecBridge: {context} 抛出 JNI 异常（已清除）"),
    );
    true
}

/// `nativeInit()` 实体：缓存 `JavaVM` 与 `ShizukuExecBridge` 的 `GlobalRef`。
/// 幂等（VM 进程内恒定；重复调用 `OnceLock::set` 失败即忽略）。
pub(crate) fn init(env: &JNIEnv, class: &JClass) {
    match env.get_java_vm() {
        Ok(jvm) => {
            let _ = SHIZUKU_VM.set(jvm);
        }
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.nativeInit: get_java_vm 失败: {e}"),
            );
        }
    }
    match env.new_global_ref(class) {
        Ok(global) => {
            let _ = BRIDGE_CLASS.set(global);
            crate::log_bridge::push_host_log(
                1,
                "ShizukuExecBridge: 已缓存 JavaVM + ShizukuExecBridge 类引用（特权 shell 门面就绪）"
                    .to_string(),
            );
        }
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.nativeInit: new_global_ref 失败: {e}"),
            );
        }
    }
}

/// 经 JNI 调 Kotlin `ShizukuExecBridge.exec`。
///
/// 无 VM / 无类引用、attach 失败、JNI 调用失败、抛出异常、返回 null → `None`。
/// 用 `catch_unwind` 包裹：绝不 panic（宿主 release 为 `panic = "abort"`）。
pub fn exec(command: &str) -> Option<String> {
    catch_unwind(AssertUnwindSafe(|| exec_inner(command))).unwrap_or(None)
}

fn exec_inner(command: &str) -> Option<String> {
    let jvm = SHIZUKU_VM.get()?;
    let class = BRIDGE_CLASS.get()?;

    // 每个（可能未附加的）Rust 线程在调用 JNI 前显式 attach；AttachGuard drop
    // 时自动 detach。
    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.exec: JNI attach 失败: {e}"),
            );
            return None;
        }
    };

    let jcommand = match env.new_string(command) {
        Ok(s) => s,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.exec: new_string 失败: {e}"),
            );
            return None;
        }
    };

    let value = match env.call_static_method(
        class,
        EXEC_METHOD,
        EXEC_SIG,
        &[JValue::Object(&jcommand)],
    ) {
        Ok(v) => v,
        Err(e) => {
            take_pending_exception(&env, "exec");
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.exec JNI 调用失败: {e}"),
            );
            return None;
        }
    };

    // 即使 `Ok` 也可能伴随未决异常（JNI 语义）。
    if take_pending_exception(&env, "exec") {
        return None;
    }

    let obj = value.l().ok()?;
    if obj.is_null() {
        return None;
    }
    let jstr: JString = obj.into();
    env.get_string(&jstr).map(|s| s.into()).ok()
}

/// 经 JNI 调 Kotlin `ShizukuExecBridge.isAvailable`（`Shizuku.pingBinder() &&
/// checkSelfPermission() == GRANTED`）。无 VM / 无类引用、attach 失败、调用
/// 失败、异常 → `false`。绝不 panic。
pub fn is_available() -> bool {
    catch_unwind(AssertUnwindSafe(is_available_inner)).unwrap_or(false)
}

fn is_available_inner() -> bool {
    let Some(jvm) = SHIZUKU_VM.get() else {
        return false;
    };
    let Some(class) = BRIDGE_CLASS.get() else {
        return false;
    };
    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.isAvailable: JNI attach 失败: {e}"),
            );
            return false;
        }
    };
    match env.call_static_method(class, IS_AVAILABLE_METHOD, IS_AVAILABLE_SIG, &[]) {
        Ok(v) => v.z().unwrap_or(false),
        Err(e) => {
            take_pending_exception(&env, "isAvailable");
            crate::log_bridge::push_host_log(
                3,
                format!("ShizukuExecBridge.isAvailable JNI 调用失败: {e}"),
            );
            false
        }
    }
}

// ---------------------------------------------------------------------------
// JNI 导出（Kotlin `ShizukuExecBridge.ensureInit` 调用的 `nativeInit`）
// ---------------------------------------------------------------------------

/// Kotlin: `external fun nativeInit()`（静态方法）。在该调用（app 线程）中缓存
/// `JavaVM` 与 `ShizukuExecBridge` 的 `GlobalRef`；静态 native 方法的第二参即
/// 该类 `jclass`，无需 `find_class`。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ShizukuExecBridge_nativeInit(
    env: JNIEnv,
    class: JClass,
) {
    guard_jni("ShizukuExecBridge.nativeInit", || init(&env, &class));
}
