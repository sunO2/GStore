package com.suno2.gstore

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

/**
 * Dart-facing replacement for the retired JNI `PlatformHostBridge`.
 *
 * Every method returns a JSON `String` (inventory, device info, perf reads) or a
 * primitive (`exec`, `available`). Failures never reach Dart as a crash: they
 * are converted to the typed envelope
 * `{"ok":false,"code":"CORE_E_PLATFORM_<X>","message":...}`.
 *
 * The handler is registered from `configureFlutterEngine`, so it runs on the
 * platform (main) thread; no blocking work is started here — the perf reads are
 * the same cheap `readJson` statics the Rust bridges used. The one exception is
 * `listInstalled`, which enumerates every installed package with signatures
 * (~1.5 s on low-end devices, measured as `core-bootstrap: list-installed
 * elapsedMs=1568`) and is therefore dispatched to the single background thread
 * below, replying on the main thread.
 *
 * Inventory is re-read from `PackageManager` on every call (no cache), so the
 * old package-change broadcast invalidation hook was dropped together with
 * `PlatformHostBridge`; terminal install results arrive through
 * `gstore/install_events` instead.
 */
object PlatformChannel {

    const val CHANNEL = "gstore/platform"

    private const val TAG = "PlatformChannel"
    private const val EMPTY_COMPONENTS = """{"components":[],"permission_states":[]}"""

    /**
     * 平台通道的后台执行器：只跑重活（全机包枚举），结果回主线程再 result。
     *
     * 原因：`getInstalledPackages(GET_SIGNING_CERTIFICATES)` 在主线程执行实测
     * 约 1.5s（core-bootstrap list-installed elapsedMs=1568），会卡住首帧后的 UI。
     * 单线程即可——这些请求本来就串行，也避免并发抢 PackageManager 锁。
     */
    private val ioExecutor: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { r ->
            Thread(r, "gstore-platform-io").apply { isDaemon = true }
        }
    }
    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    @Volatile
    private var appContext: Context? = null

    @JvmStatic
    fun init(context: Context) {
        appContext = context.applicationContext ?: context
    }

    @JvmStatic
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listInstalled" -> {
                        // getInstalledPackages(+签名) 在低端机可达 1.5s，必须离开主线程，
                        // 否则首帧后的 UI 会卡住。结果统一回主线程 result。
                        ioExecutor.execute {
                            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                            val payload = try {
                                listInstalledJson()
                            } catch (e: Throwable) {
                                Log.w(TAG, "listInstalled 失败: ${e.message}")
                                errorJson("CORE_E_PLATFORM_FAILED", e as? Exception ?: RuntimeException(e))
                            }
                            mainHandler.post { result.success(payload) }
                        }
                    }
                    "getInstalled" -> result.success(getInstalledJson(argument(call)))
                    "getSourceDir" -> result.success(getSourceDir(argument(call)))
                    "getSignatures" -> result.success(getSignaturesJson(argument(call)))
                    "getPermissions" -> result.success(getPermissionsJson(argument(call)))
                    "getComponents" -> result.success(getComponentsJson(argument(call)))
                    "deviceInfo" -> result.success(deviceInfoJson())
                    "readBattery" -> result.success(readBatteryJson())
                    "readDeviceState" -> result.success(readDeviceStateJson())
                    "readForeground" -> result.success(readForegroundJson())
                    "readFrameMetrics" -> result.success(FrameMetricsCollector.readJson())
                    "exec" -> result.success(ShizukuExecBridge.exec(argument(call)))
                    "available" -> result.success(ShizukuExecBridge.isAvailable())
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.success(errorJson("CORE_E_PLATFORM_DENIED", e))
            } catch (e: PackageManager.NameNotFoundException) {
                result.success(errorJson("CORE_E_PLATFORM_NOT_FOUND", e))
            } catch (e: RuntimeException) {
                Log.w(TAG, "${call.method} 失败: ${e.message}")
                result.success(errorJson("CORE_E_PLATFORM_FAILED", e))
            }
        }
    }

    private fun argument(call: MethodCall): String =
        (call.arguments as? String)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("${call.method} requires a string argument")

    private fun listInstalledJson(): String {
        val pm = packageManager() ?: return "[]"
        val array = JSONArray()
        for (app in InventoryInspector.installedApps(pm)) {
            array.put(InventoryInspector.installedAppJson(app))
        }
        return array.toString()
    }

    private fun getInstalledJson(packageName: String): String? {
        val pm = packageManager() ?: return null
        return try {
            InventoryInspector.installedAppJson(
                InventoryInspector.installedApp(pm, packageName)
            ).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun getSourceDir(packageName: String): String? {
        val pm = packageManager() ?: return null
        return try {
            InventoryInspector.sourceDir(pm, packageName)
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun getSignaturesJson(packageName: String): String {
        val pm = packageManager() ?: return "[]"
        return try {
            val report = InventoryInspector.signatures(pm, packageName)
            val array = JSONArray()
            for (entry in report.entries) {
                array.put(JSONObject().apply {
                    put("algorithm", entry.algorithm)
                    put("subject", entry.subject)
                    put("sha256", entry.sha256)
                    put("sha1", entry.sha1)
                    put("kind", entry.kind)
                })
            }
            array.toString()
        } catch (e: PackageManager.NameNotFoundException) {
            "[]"
        }
    }

    private fun getPermissionsJson(packageName: String): String {
        val pm = packageManager() ?: return "[]"
        return try {
            JSONArray(InventoryInspector.permissions(pm, packageName)).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            "[]"
        }
    }

    private fun getComponentsJson(packageName: String): String {
        val pm = packageManager() ?: return EMPTY_COMPONENTS
        return try {
            val report = InventoryInspector.components(pm, packageName)
            val components = JSONArray()
            for (entry in report.components) {
                components.put(JSONObject().apply {
                    put("kind", entry.kind)
                    put("name", entry.name)
                    put("exported", entry.exported)
                    put("enabled", entry.enabled)
                    put("process_name", entry.processName ?: JSONObject.NULL)
                })
            }
            val permissionStates = JSONArray()
            for (state in report.permissionStates) {
                permissionStates.put(JSONObject().apply {
                    put("name", state.name)
                    put("granted", state.granted)
                    put("never_for_location", state.neverForLocation)
                })
            }
            JSONObject().apply {
                put("components", components)
                put("permission_states", permissionStates)
            }.toString()
        } catch (e: PackageManager.NameNotFoundException) {
            EMPTY_COMPONENTS
        }
    }

    private fun deviceInfoJson(): String {
        val abis = JSONArray()
        for (abi in Build.SUPPORTED_ABIS) {
            abis.put(abi)
        }
        return JSONObject().apply {
            put("manufacturer", Build.MANUFACTURER)
            put("model", Build.MODEL)
            put("device", Build.DEVICE)
            put("android_version", Build.VERSION.RELEASE)
            put("sdk_int", Build.VERSION.SDK_INT)
            put("abis", abis)
        }.toString()
    }

    private fun readBatteryJson(): String {
        val context = appContext
            ?: return errorJson("CORE_E_PLATFORM_NOT_INITIALIZED", "PlatformChannel not initialized")
        return BatteryChannel.readJson(context)
    }

    private fun readDeviceStateJson(): String {
        val context = appContext
            ?: return errorJson("CORE_E_PLATFORM_NOT_INITIALIZED", "PlatformChannel not initialized")
        return DeviceStateChannel.readJson(context)
    }

    private fun readForegroundJson(): String {
        val context = appContext
            ?: return errorJson("CORE_E_PLATFORM_NOT_INITIALIZED", "PlatformChannel not initialized")
        return ForegroundAccessibilityService.readJson(context)
    }

    private fun packageManager(): PackageManager? = appContext?.packageManager

    private fun errorJson(code: String, error: Throwable): String =
        errorJson(code, error.message ?: error.javaClass.simpleName)

    private fun errorJson(code: String, message: String): String =
        JSONObject().apply {
            put("ok", false)
            put("code", code)
            put("message", message)
        }.toString()
}
