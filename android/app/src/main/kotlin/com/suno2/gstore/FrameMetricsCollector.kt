package com.suno2.gstore

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.FrameMetrics
import android.view.Window
import org.json.JSONObject
import java.util.ArrayDeque
import kotlin.math.ceil

/**
 * 本应用自身帧耗时 / jank 采集器（公共 API，替代 / 补充 Flutter FrameTiming）。
 *
 * 通过 `Window.addOnFrameMetricsAvailableListener`（API 24+）接收系统逐帧
 * `FrameMetrics`，把 `TOTAL_DURATION`（ns）写入有界环形缓冲（最近
 * [MAX_FRAMES] 帧），并计算：
 * - `count`：窗口内帧数；
 * - `avgMs` / `p90Ms` / `p99Ms` / `lastMs`（毫秒）；
 * - `jankPercent`：耗时 > 1.5 × 标称帧间隔（`Display.getRefreshRate`）的帧占比
 *   （0–100）。
 *
 * 生命周期由 `MainActivity.onResume/onPause` 驱动；[attach] / [detach] 幂等,
 * 全程 try/catch，任何异常都不崩溃（返回空摘要）。
 */
object FrameMetricsCollector {
    private const val TAG = "FrameMetrics"

    /** 环形缓冲容量（约 5s @60Hz）。 */
    private const val MAX_FRAMES = 300

    /** 默认刷新率（Hz）：无法读取 `Display.getRefreshRate` 时使用。 */
    private const val DEFAULT_REFRESH_RATE = 60.0

    private val lock = Any()
    private val durationsNs = ArrayDeque<Long>(MAX_FRAMES)

    private var attachedActivity: Activity? = null
    private var attachedWindow: Window? = null
    private var listener: Window.OnFrameMetricsAvailableListener? = null

    /** 最近一次 attach 时读取的标称刷新率（Hz）。 */
    @Volatile
    private var refreshRate: Double = DEFAULT_REFRESH_RATE

    /**
     * 开始采集 [activity] 的窗口帧指标。幂等：同一 Activity 重复调用无操作；
     * 切换 Activity 时先解绑旧的监听。
     */
    @JvmStatic
    fun attach(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        try {
            synchronized(lock) {
                if (attachedActivity === activity && attachedWindow != null) return
                detachLocked()
                val window = activity.window ?: return
                refreshRate = readRefreshRate(activity)
                val newListener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
                    try {
                        val total = metrics.getMetric(FrameMetrics.TOTAL_DURATION)
                        if (total > 0) {
                            synchronized(lock) {
                                if (durationsNs.size >= MAX_FRAMES) {
                                    durationsNs.removeFirst()
                                }
                                durationsNs.addLast(total)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "帧回调失败（忽略）: ${e.message}")
                    }
                }
                window.addOnFrameMetricsAvailableListener(
                    newListener,
                    Handler(Looper.getMainLooper())
                )
                attachedActivity = activity
                attachedWindow = window
                listener = newListener
            }
        } catch (e: Exception) {
            Log.w(TAG, "attach 失败（忽略）: ${e.message}")
        }
    }

    /** 解绑 [activity] 的窗口监听（幂等；Activity 不匹配时无操作）。 */
    @JvmStatic
    fun detach(activity: Activity) {
        try {
            synchronized(lock) {
                if (attachedActivity !== activity) return
                detachLocked()
            }
        } catch (e: Exception) {
            Log.w(TAG, "detach 失败（忽略）: ${e.message}")
        }
    }

    /** 清空环形缓冲（刷新率与监听状态不变）。 */
    @JvmStatic
    fun reset() {
        synchronized(lock) {
            durationsNs.clear()
        }
    }

    /**
     * JNI 直读入口：当前窗口的帧指标摘要 JSON。
     *
     * `{"count":int,"avgMs":double,"p90Ms":double,"p99Ms":double,
     *   "jankPercent":double,"lastMs":double,"refreshRate":double,
     *   "windowSize":int}`；任何异常 → `{}`。
     */
    @JvmStatic
    fun readJson(): String = try {
        val frames = synchronized(lock) { durationsNs.toLongArray() }
        val rate = refreshRate.takeIf { it.isFinite() && it > 0 } ?: DEFAULT_REFRESH_RATE
        JSONObject().apply {
            put("count", frames.size)
            put("windowSize", MAX_FRAMES)
            put("refreshRate", rate)
            if (frames.isEmpty()) {
                put("avgMs", 0.0)
                put("p90Ms", 0.0)
                put("p99Ms", 0.0)
                put("jankPercent", 0.0)
                put("lastMs", 0.0)
            } else {
                val sorted = frames.clone().also { it.sort() }
                put("avgMs", frames.average() / NS_PER_MS)
                put("p90Ms", percentileMs(sorted, 90.0))
                put("p99Ms", percentileMs(sorted, 99.0))
                put("lastMs", frames.last() / NS_PER_MS)
                val jankThresholdNs = 1.5 * (NS_PER_SECOND / rate)
                val jankCount = frames.count { it > jankThresholdNs }
                put("jankPercent", jankCount * 100.0 / frames.size)
            }
        }.toString()
    } catch (e: Exception) {
        Log.w(TAG, "readJson 失败: ${e.message}")
        "{}"
    }

    private fun detachLocked() {
        val window = attachedWindow
        val current = listener
        if (window != null && current != null) {
            try {
                window.removeOnFrameMetricsAvailableListener(current)
            } catch (e: Exception) {
                Log.w(TAG, "removeOnFrameMetricsAvailableListener 失败（忽略）: ${e.message}")
            }
        }
        attachedActivity = null
        attachedWindow = null
        listener = null
    }

    private fun readRefreshRate(activity: Activity): Double = try {
        val rate = activity.windowManager.defaultDisplay.refreshRate.toDouble()
        if (rate.isFinite() && rate > 0) rate else DEFAULT_REFRESH_RATE
    } catch (e: Exception) {
        DEFAULT_REFRESH_RATE
    }

    /** 最近秩（nearest-rank）百分位，输入已升序。 */
    private fun percentileMs(sortedNs: LongArray, percentile: Double): Double {
        if (sortedNs.isEmpty()) return 0.0
        val rank = ceil(percentile / 100.0 * sortedNs.size).toInt()
        val index = rank.coerceIn(1, sortedNs.size) - 1
        return sortedNs[index] / NS_PER_MS
    }

    private const val NS_PER_MS = 1_000_000.0
    private const val NS_PER_SECOND = 1_000_000_000.0
}
