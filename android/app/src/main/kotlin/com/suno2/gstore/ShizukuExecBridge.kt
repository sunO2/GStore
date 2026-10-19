package com.suno2.gstore

import android.content.pm.PackageManager
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.atomic.AtomicBoolean
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuRemoteProcess

/**
 * 特权 shell 执行的 Kotlin 薄壳（Shizuku 单一门面）。
 *
 * ## 职责边界
 * 本对象是 Rust 宿主（`libgstore_host.so`）执行特权 shell 的**唯一** Java 侧落点：
 * Rust 经 JNI 调用这里的静态方法 → [Shizuku.newProcess]（shell uid 2000）。Dart/Kotlin
 * 业务代码不再直接触碰 `Shizuku.newProcess`；私有/易变的 Shizuku 细节只留在此一处。
 *
 * ## 执行语义（逐字复刻 shizuku_api 插件 `ShizukuShell.execCommands`）
 * - `Shizuku.newProcess(arrayOf("sh", "-c", command), null, "/")`；
 * - 合并 stdout + stderr（各 `readLine()` 追加 `\n`）；
 * - `waitFor()`；**不返回退出码**（与既有语义一致）；返回 `.trim()`；
 * - 任何异常都不抛，把消息并入返回文本。
 *
 * ## 初始化
 * [ensureInit] 在应用启动（`MainActivity.onCreate`）即调用：`System.loadLibrary("gstore_host")`
 * （与 FRB `dlopen` 同一 .so，loader 去重）+ [nativeInit]（Rust 侧缓存 JavaVM 与本类 GlobalRef）。
 * 全程 best-effort，失败静默，**绝不崩溃**。
 *
 * ## 只读约束
 * 本层只执行调用方指定的命令，**不硬编码任何特权写操作**（写操作由调用方决定）。
 */
object ShizukuExecBridge {

    private const val TAG = "ShizukuExecBridge"

    /** 初始化一次性标记：`ensureInit` 只生效一次（并发安全）。 */
    private val initialized = AtomicBoolean(false)

    /**
     * Rust 宿主导出实现（JNI 名 `Java_com_suno2_gstore_ShizukuExecBridge_nativeInit`）。
     * 调用点捕获 `JavaVM` + 本类 `GlobalRef` + `exec`/`isAvailable` 方法 ID。
     */
    @JvmStatic
    external fun nativeInit()

    /**
     * 应用启动初始化（best-effort）：加载宿主 .so 并回调 Rust 侧 [nativeInit]。
     * 只执行一次；任何失败（库缺失 / native 未注册）都静默忽略，绝不崩溃。
     */
    @JvmStatic
    fun ensureInit() {
        if (initialized.compareAndSet(false, true)) {
            runCatching { System.loadLibrary("gstore_host") }
                .onFailure { Log.w(TAG, "loadLibrary(gstore_host) 失败（忽略）: ${it.message}") }
            runCatching { nativeInit() }
                .onFailure { Log.w(TAG, "nativeInit 失败（忽略）: ${it.message}") }
        }
    }

    /**
     * 经 Shizuku 执行 `sh -c <command>`（shell uid 2000）。
     *
     * 返回合并后的 stdout + stderr（`.trim()`）；**不含退出码**；任何异常都不抛出，
     * 异常消息并入返回文本（空命令返回 `Error: Command cannot be null or empty`）。
     */
    @JvmStatic
    fun exec(command: String): String {
        val outputBuilder = StringBuilder()
        var process: ShizukuRemoteProcess? = null
        try {
            if (command.isEmpty()) {
                throw IllegalArgumentException("Command cannot be null or empty")
            }

            val proc = Shizuku.newProcess(arrayOf("sh", "-c", command), null, "/")
            process = proc
            val mInput = BufferedReader(InputStreamReader(proc.inputStream))
            val mError = BufferedReader(InputStreamReader(proc.errorStream))

            var line: String?
            // 读取标准输出
            while (mInput.readLine().also { line = it } != null) {
                outputBuilder.append(line).append("\n")
            }
            // 读取标准错误
            while (mError.readLine().also { line = it } != null) {
                outputBuilder.append(line).append("\n")
            }

            proc.waitFor()
        } catch (e: IllegalArgumentException) {
            outputBuilder.append("Error: ").append(e.message)
        } catch (t: Throwable) {
            outputBuilder.append("Unexpected error: ").append(t.message)
            Log.w(TAG, "exec 失败（忽略）: ${t.message}")
        } finally {
            process?.destroy()
        }
        return outputBuilder.toString().trim()
    }

    /**
     * Shizuku 是否可用：Binder 存活且已授权（任何异常视为不可用）。
     */
    @JvmStatic
    fun isAvailable(): Boolean = runCatching {
        Shizuku.pingBinder() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)
}
