package com.suno2.gstore

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Kotlin side of the Rust `PlatformHost` inventory. Every method returns JSON
 * whose keys match the core DTOs (`snake_case`); `SecurityException` is allowed
 * to propagate so the Rust bridge can map it to `CORE_E_PACKAGE_INVENTORY_DENIED`.
 */
object PlatformHostBridge {

    private const val TAG = "PlatformHostBridge"

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var initialized = false

    @JvmStatic
    external fun nativeInitContext(context: Context)

    @JvmStatic
    external fun nativeInvalidateInventory()

    @JvmStatic
    fun init(context: Context) {
        val application = context.applicationContext ?: context
        appContext = application
        if (initialized) return
        runCatching { nativeInitContext(application) }
            .onSuccess { initialized = true }
            .onFailure { Log.w(TAG, "nativeInitContext 失败（忽略）: ${it.message}") }
    }

    @JvmStatic
    fun invalidateCache() {
        runCatching { nativeInvalidateInventory() }
            .onFailure { Log.w(TAG, "nativeInvalidateInventory 失败（忽略）: ${it.message}") }
    }

    @JvmStatic
    fun listInstalledJson(): String {
        val pm = packageManager() ?: return "[]"
        val apps = InventoryInspector.installedApps(pm)
        val array = JSONArray()
        for (app in apps) {
            array.put(InventoryInspector.installedAppJson(app))
        }
        return array.toString()
    }

    @JvmStatic
    fun getInstalledJson(packageName: String): String? {
        val pm = packageManager() ?: return null
        return try {
            InventoryInspector.installedAppJson(
                InventoryInspector.installedApp(pm, packageName)
            ).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    @JvmStatic
    fun getSourceDir(packageName: String): String? {
        val pm = packageManager() ?: return null
        return try {
            InventoryInspector.sourceDir(pm, packageName)
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    @JvmStatic
    fun getSignaturesJson(packageName: String): String {
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

    @JvmStatic
    fun getPermissionsJson(packageName: String): String {
        val pm = packageManager() ?: return "[]"
        return try {
            JSONArray(InventoryInspector.permissions(pm, packageName)).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            "[]"
        }
    }

    @JvmStatic
    fun getComponentsJson(packageName: String): String {
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

    @JvmStatic
    fun deviceInfoJson(): String {
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

    private fun packageManager(): PackageManager? = appContext?.packageManager

    private const val EMPTY_COMPONENTS = """{"components":[],"permission_states":[]}"""
}
