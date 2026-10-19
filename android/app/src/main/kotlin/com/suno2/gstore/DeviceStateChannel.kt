package com.suno2.gstore

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.net.TrafficStats
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.WindowManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * 批量设备状态 JNI 数据源（`DeviceStateChannel`）。
 *
 * 供 Rust 宿主（`libgstore_host.so`）在已 attach 的线程上**一次 JNI 静态调用**
 * 取回电池扩展 / 电源 / 显示模式 / 内存 / 流量 / 热状态，避免 Dart↔平台通道
 * 多处往返。所有字段**免权限**可读；读取失败的字段被省略（JSON 无此键）。
 *
 * - 每个字段 / 每个子对象独立 try/catch：**绝不抛出 / 绝不崩溃**；
 * - `supportedModes` 依赖 API 23（[Display.getSupportedModes]）；
 * - `thermal.status` 依赖 API 29，`thermal.headroom` 依赖 API 30；
 * - 顶层异常降级为 `"{}"`，由 Dart 侧容错解析为 `null`。
 *
 * 单位原样透传 Android 原生单位（mV / 0.1℃ / µA / µAh / nWh / ms / bytes），
 * 归一化在 Dart 侧完成。
 */
object DeviceStateChannel {
    private const val TAG = "DeviceStateChannel"

    /** JNI 直调入口：批量设备状态 JSON 字符串。任何异常 → `"{}"`。 */
    @JvmStatic
    fun readJson(context: Context): String = try {
        val root = JSONObject()
        root.put("battery", section("battery") { battery(context) })
        root.put("display", section("display") { display(context) })
        root.put("memory", section("memory") { memory(context) })
        root.put("traffic", section("traffic") { traffic() })
        root.put("thermal", section("thermal") { thermal(context) })
        root.toString()
    } catch (e: Exception) {
        Log.w(TAG, "readJson 失败: ${e.message}")
        "{}"
    }

    /** 子对象级兜底：任一子对象异常 → 空对象（其余子对象仍保留）。 */
    private inline fun section(name: String, block: () -> JSONObject): JSONObject = try {
        block()
    } catch (e: Exception) {
        Log.w(TAG, "读取 $name 失败: ${e.message}")
        JSONObject()
    }

    // ==================== 电池（ACTION_BATTERY_CHANGED + BatteryManager）====================

    private fun battery(context: Context): JSONObject {
        val out = JSONObject()

        val sticky: Intent? = try {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (e: Exception) {
            Log.w(TAG, "读取 ACTION_BATTERY_CHANGED 失败: ${e.message}")
            null
        }

        val level = sticky?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = sticky?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val voltageMv = sticky?.intExtraOrNull(BatteryManager.EXTRA_VOLTAGE)
        val temperatureTenthsC = sticky?.intExtraOrNull(BatteryManager.EXTRA_TEMPERATURE)
        val status = sticky?.intExtraOrNull(BatteryManager.EXTRA_STATUS)
        val health = sticky?.intExtraOrNull(BatteryManager.EXTRA_HEALTH)
        val technology = sticky
            ?.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY)
            ?.takeIf { it.isNotBlank() }

        val batteryManager = try {
            context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        } catch (e: Exception) {
            Log.w(TAG, "BatteryManager 不可用: ${e.message}")
            null
        }

        val capacityPercent = batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val currentUa = batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        val chargeCounterUah =
            batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        val energyCounterNwh =
            batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_ENERGY_COUNTER)
        val chargeTimeRemainingMs = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                batteryManager?.computeChargeTimeRemaining()?.takeIf { it > 0 }
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }

        val powerManager = try {
            context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        } catch (e: Exception) {
            Log.w(TAG, "PowerManager 不可用: ${e.message}")
            null
        }

        out.putIfNotNull("present", sticky != null || level >= 0 || capacityPercent != null)
        out.putIfNotNull("level", level.takeIf { it >= 0 })
        out.putIfNotNull("scale", scale.takeIf { it > 0 })
        out.putIfNotNull("voltageMv", voltageMv)
        out.putIfNotNull("temperatureTenthsC", temperatureTenthsC)
        out.putIfNotNull("status", status)
        out.putIfNotNull("health", health)
        out.putIfNotNull("technology", technology)
        out.putIfNotNull("currentUa", currentUa)
        out.putIfNotNull("chargeCounterUah", chargeCounterUah)
        out.putIfNotNull("energyCounterNwh", energyCounterNwh)
        out.putIfNotNull("chargeTimeRemainingMs", chargeTimeRemainingMs)
        out.putIfNotNull("powerSave", powerSaveMode(powerManager))
        out.putIfNotNull("deviceIdle", deviceIdleMode(powerManager))
        out.putIfNotNull("interactive", interactive(powerManager))
        return out
    }

    // ==================== 电源 ====================

    private fun powerSaveMode(manager: PowerManager?): Boolean? = try {
        manager?.isPowerSaveMode
    } catch (e: Exception) {
        null
    }

    private fun deviceIdleMode(manager: PowerManager?): Boolean? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) manager?.isDeviceIdleMode else null
    } catch (e: Exception) {
        null
    }

    private fun interactive(manager: PowerManager?): Boolean? = try {
        manager?.isInteractive
    } catch (e: Exception) {
        null
    }

    // ==================== 显示（当前刷新率 + 支持模式）====================

    private fun display(context: Context): JSONObject {
        val out = JSONObject()
        val display = currentDisplay(context) ?: return out

        val currentModeRefreshRate = try {
            display.mode?.refreshRate
        } catch (e: Exception) {
            null
        }
        val refreshRate = (currentModeRefreshRate ?: display.refreshRate).takeIf { it.isFinite() }
        out.putIfNotNull("refreshRate", refreshRate?.toDouble())

        val modes = JSONArray()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                for (mode in display.supportedModes) {
                    val entry = JSONObject()
                    entry.put("mode", mode.modeId)
                    entry.put("width", mode.physicalWidth)
                    entry.put("height", mode.physicalHeight)
                    entry.put("refreshRate", mode.refreshRate.toDouble())
                    modes.put(entry)
                }
            } catch (e: Exception) {
                Log.w(TAG, "读取 supportedModes 失败: ${e.message}")
            }
        }
        out.put("supportedModes", modes)
        return out
    }

    /** `DisplayManager` 优先；不可用时回退 `WindowManager.defaultDisplay`。 */
    @Suppress("DEPRECATION")
    private fun currentDisplay(context: Context): Display? {
        val fromManager = try {
            (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
                ?.getDisplay(Display.DEFAULT_DISPLAY)
        } catch (e: Exception) {
            Log.w(TAG, "DisplayManager 不可用: ${e.message}")
            null
        }
        if (fromManager != null) return fromManager
        return try {
            (context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
                ?.defaultDisplay
        } catch (e: Exception) {
            Log.w(TAG, "WindowManager.defaultDisplay 不可用: ${e.message}")
            null
        }
    }

    // ==================== 内存 ====================

    private fun memory(context: Context): JSONObject {
        val out = JSONObject()
        val activityManager = try {
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        } catch (e: Exception) {
            Log.w(TAG, "ActivityManager 不可用: ${e.message}")
            null
        } ?: return out
        val info = ActivityManager.MemoryInfo()
        return try {
            activityManager.getMemoryInfo(info)
            out.put("totalMem", info.totalMem)
            out.put("availMem", info.availMem)
            out.put("threshold", info.threshold)
            out.put("lowMemory", info.lowMemory)
            out
        } catch (e: Exception) {
            Log.w(TAG, "getMemoryInfo 失败: ${e.message}")
            JSONObject()
        }
    }

    // ==================== 流量 ====================

    private fun traffic(): JSONObject {
        val out = JSONObject()
        val uid = try {
            Process.myUid()
        } catch (e: Exception) {
            -1
        }
        out.putIfNotNull("totalRx", supportedBytes(TrafficStats.getTotalRxBytes()))
        out.putIfNotNull("totalTx", supportedBytes(TrafficStats.getTotalTxBytes()))
        out.putIfNotNull("mobileRx", supportedBytes(TrafficStats.getMobileRxBytes()))
        out.putIfNotNull("mobileTx", supportedBytes(TrafficStats.getMobileTxBytes()))
        if (uid >= 0) {
            out.putIfNotNull("uidRx", supportedBytes(TrafficStats.getUidRxBytes(uid)))
            out.putIfNotNull("uidTx", supportedBytes(TrafficStats.getUidTxBytes(uid)))
        }
        return out
    }

    private fun supportedBytes(value: Long): Long? =
        if (value == TrafficStats.UNSUPPORTED.toLong() || value < 0) null else value

    // ==================== 热状态 ====================

    private fun thermal(context: Context): JSONObject {
        val out = JSONObject()
        val powerManager = try {
            context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        } catch (e: Exception) {
            Log.w(TAG, "PowerManager 不可用: ${e.message}")
            null
        } ?: return out

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            out.putIfNotNull("status", try {
                powerManager.currentThermalStatus
            } catch (e: Exception) {
                null
            })
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            out.putIfNotNull("headroom", try {
                // 0 → 当前（最快）时间范围；NaN 不可写入 JSON。
                powerManager.getThermalHeadroom(0).takeIf { it.isFinite() }?.toDouble()
            } catch (e: Exception) {
                null
            })
        }
        return out
    }
}

/** 读一个 int extra：缺失（默认 `-1`）返回 `null`。 */
private fun Intent.intExtraOrNull(key: String): Int? {
    val value = getIntExtra(key, -1)
    return if (value >= 0) value else null
}

/**
 * 读一个 `BatteryManager` int 属性：不支持 / 异常 / 哨兵值（`Int.MIN_VALUE` /
 * `Int.MAX_VALUE`）→ `null`。
 */
private fun BatteryManager?.safeProperty(property: Int): Int? {
    val manager = this ?: return null
    return try {
        val value = manager.getIntProperty(property)
        if (value == Int.MIN_VALUE || value == Int.MAX_VALUE) null else value
    } catch (e: Exception) {
        null
    }
}

/** 仅在非 null 时写入键；写入异常静默忽略（绝不破坏整体 JSON）。 */
private fun JSONObject.putIfNotNull(key: String, value: Any?) {
    if (value == null) return
    try {
        put(key, value)
    } catch (e: Exception) {
        // 非法数值（NaN / Infinity）等：跳过该字段。
    }
}
