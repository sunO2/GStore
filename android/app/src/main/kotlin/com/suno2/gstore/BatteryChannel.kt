package com.suno2.gstore

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 免权限电池数据源（`gstore/battery` 通道）。
 *
 * 背景：部分设备 SELinux 拒绝 App 读取
 * `/sys/class/power_supply/battery/{current_now,voltage_now}`，导致
 * Rust `perf.battery` 的电流 / 电压恒为 null。Android `BatteryManager` 与
 * `ACTION_BATTERY_CHANGED` 粘性广播**不需要任何权限**（不同于
 * `BATTERY_STATS` 签名权限，普通应用本就无法申请），因此作为兜底数据源。
 *
 * - [read] 方法返回 [Map]（`present/level/scale/voltageMv/temperatureTenthsC/
 *   status/health/technology/currentUa/capacityPercent`），字段不可得时为 `null`；
 * - `currentUa` 由 `BatteryManager.getIntProperty(BATTERY_PROPERTY_CURRENT_NOW)`
 *   读取（µA，可为负；设备不支持时返回 `Int.MIN_VALUE` → 归一为 `null`）；
 * - 每个属性读取独立 try/catch：**绝不崩溃**，任何异常降级为 `null`。
 *
 * 单位由 Dart 侧 (`lib/core/perf/battery_source.dart`) 归一（mV→V、µA→mA、
 * 十分之一℃→℃），本通道**原样透传** Android 原生单位。
 */
object BatteryChannel {
    private const val CHANNEL = "gstore/battery"
    private const val TAG = "BatteryChannel"

    /** 注册 `gstore/battery` 通道（幂等：Flutter 引擎仅配置一次）。 */
    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> {
                        try {
                            result.success(read(context))
                        } catch (e: Exception) {
                            // 兜底：任何异常都不崩溃，返回空（Dart 侧降级）。
                            Log.w(TAG, "read 失败: ${e.message}")
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 读取一次电池状态；失败字段为 `null`。 */
    private fun read(context: Context): Map<String, Any?> {
        // 粘性广播：registerReceiver(null, …) 立即返回最近一次
        // ACTION_BATTERY_CHANGED，无需权限、无需注销。
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
            null
        }

        val currentUa = batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        var capacityPercent =
            batteryManager.safeProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        // BatteryManager 电量不可得时用 level/scale 兜底。
        if (capacityPercent == null) {
            if (level >= 0 && scale > 0) {
                capacityPercent = level * 100 / scale
            }
        }

        val out = HashMap<String, Any?>()
        out["present"] = sticky != null || level >= 0 || capacityPercent != null
        out["level"] = if (level >= 0) level else null
        out["scale"] = if (scale > 0) scale else null
        out["voltageMv"] = voltageMv
        out["temperatureTenthsC"] = temperatureTenthsC
        out["status"] = status
        out["health"] = health
        out["technology"] = technology
        out["currentUa"] = currentUa
        out["capacityPercent"] = capacityPercent
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
