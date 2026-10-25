package com.suno2.gstore

import android.app.Activity
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import kotlin.math.abs

/**
 * 高刷新率（120Hz 等）请求通道（`gstore/display_refresh`）。
 *
 * 目标：让 App 窗口跑在**该设备支持的最高刷新率**上（不硬编码 120——90/144Hz
 * 设备同样受益）。启动时由 Dart 调用一次（幂等），原生侧：
 *
 *  1. 读 `Display.getSupportedModes()`（API 23+，本项目 minSdk 24 恒可用），
 *     选取 **fps 最高**的模式（同 fps 时优先与当前分辨率一致、再取较小 modeId）；
 *  2. 写入 `WindowManager.LayoutParams.preferredDisplayModeId` +
 *     `preferredRefreshRate`（API 23/21，老设备唯一的切换手段）；
 *  3. Android 11+（API 30）额外在窗口内首个 [SurfaceView] 的 Surface 上调用
 *     `Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)`
 *     ——部分 Android 15/16 设备忽略 `preferredDisplayModeId`，必须以
 *     Surface 帧率作为权威请求。Surface 尚未创建时按固定间隔有界重试。
 *
 * 健壮性：所有分支均 try/catch，**任何设备/时序异常都不会抛出到 Dart**，
 * 更不会崩溃启动；失败时返回带 `ok=false` 的 JSON 信封。
 */
object DisplayRefreshChannel {

    const val CHANNEL = "gstore/display_refresh"

    private const val TAG = "DisplayRefresh"

    /** Surface 未就绪时的有界重试次数（≈ 1s @50ms）。 */
    private const val SURFACE_RETRY_LIMIT = 20

    /** 重试间隔。 */
    private const val SURFACE_RETRY_DELAY_MS = 50L

    /** fps 视为相等的容差（`dumpsys` 中 120.00001 vs 120.0）。 */
    private const val FPS_EPSILON = 0.01f

    @JvmStatic
    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "applyHighestRefreshRate" -> result.success(applyHighestRefreshRate(activity))
                "currentRefreshRate" -> result.success(currentRefreshRateJson(activity))
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 请求设备支持的最高刷新率。返回结构化 JSON 字符串，**绝不抛出**。
     *
     * 成功（已应用或已排程重试）→ `{"ok":true,"modeId":..,"fps":..,"modeApplied":..,
     * "surfaceFrameRate":..,"method":"..","apiLevel":..}`；
     * 失败 → `{"ok":false,"code":"..","message":".."}`。
     */
    @JvmStatic
    fun applyHighestRefreshRate(activity: Activity): String {
        return try {
            val window = activity.window
                ?: return errorJson("NO_WINDOW", "activity window unavailable")
            val display = displayOf(activity)
                ?: return errorJson("NO_DISPLAY", "display unavailable")
            val modes = display.supportedModes
            if (modes.isNullOrEmpty()) {
                return errorJson("NO_MODES", "display reports no supported modes")
            }

            val current = try {
                display.mode
            } catch (t: Throwable) {
                null
            }
            val best = selectHighestFpsMode(modes, current)

            // (2) 老设备 / 部分新设备唯一的切换手段：窗口首选显示模式 + 刷新率。
            var modeApplied = false
            try {
                val attrs = window.attributes
                attrs.preferredDisplayModeId = best.modeId
                attrs.preferredRefreshRate = best.refreshRate
                window.attributes = attrs
                modeApplied = true
            } catch (t: Throwable) {
                Log.w(TAG, "preferredDisplayModeId 应用失败: ${t.message}")
            }

            // (3) Android 11+：在窗口 Surface 上显式请求固定源帧率（权威路径）。
            val surfaceFrameRate = applySurfaceFrameRate(activity, best.refreshRate, 0)

            val method = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                "preferredDisplayModeId+Surface.setFrameRate"
            } else {
                "preferredDisplayModeId"
            }
            JSONObject().apply {
                put("ok", true)
                put("modeApplied", modeApplied)
                put("surfaceFrameRate", surfaceFrameRate)
                put("modeId", best.modeId)
                put("fps", best.refreshRate.toDouble())
                put("width", best.physicalWidth)
                put("height", best.physicalHeight)
                put("apiLevel", Build.VERSION.SDK_INT)
                put("method", method)
            }.toString()
        } catch (t: Throwable) {
            Log.w(TAG, "applyHighestRefreshRate 失败: ${t.message}")
            errorJson("APPLY_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    /** 当前生效模式（供 Dart 侧日志 / 自检）。失败 → 错误信封。 */
    @JvmStatic
    fun currentRefreshRateJson(activity: Activity?): String {
        return try {
            val display = activity?.let { displayOf(it) }
                ?: return errorJson("NO_DISPLAY", "display unavailable")
            val mode = display.mode
            JSONObject().apply {
                put("ok", true)
                put("modeId", mode.modeId)
                put("fps", mode.refreshRate.toDouble())
                put("width", mode.physicalWidth)
                put("height", mode.physicalHeight)
                put("apiLevel", Build.VERSION.SDK_INT)
            }.toString()
        } catch (t: Throwable) {
            errorJson("READ_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    // ==================== 内部实现 ====================

    /** 选取 fps 最高的模式；同 fps 优先与当前分辨率一致，再取较小 modeId。 */
    private fun selectHighestFpsMode(modes: Array<Display.Mode>, current: Display.Mode?): Display.Mode {
        var best = modes[0]
        for (mode in modes) {
            if (mode.refreshRate > best.refreshRate + FPS_EPSILON) {
                best = mode
                continue
            }
            if (abs(mode.refreshRate - best.refreshRate) <= FPS_EPSILON) {
                val modeMatches = matchesResolution(current, mode)
                val bestMatches = matchesResolution(current, best)
                if (modeMatches && !bestMatches) {
                    best = mode
                } else if (modeMatches == bestMatches && mode.modeId < best.modeId) {
                    best = mode
                }
            }
        }
        return best
    }

    private fun matchesResolution(current: Display.Mode?, mode: Display.Mode): Boolean =
        current != null &&
            current.physicalWidth == mode.physicalWidth &&
            current.physicalHeight == mode.physicalHeight

    /**
     * 在窗口内首个 [SurfaceView] 的 Surface 上请求固定源帧率。
     *
     * @return true 表示已应用或已排程有界重试；false 表示当前 API 不支持 / 无
     *         SurfaceView（如 texture 渲染模式）。
     */
    private fun applySurfaceFrameRate(activity: Activity, fps: Float, attempt: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val root = try {
            activity.window?.decorView
        } catch (t: Throwable) {
            null
        } ?: return false
        val surfaceView = findSurfaceView(root) ?: return false
        val surface = try {
            surfaceView.holder?.surface
        } catch (t: Throwable) {
            null
        }
        if (surface != null && surface.isValid) {
            return try {
                surface.setFrameRate(fps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
                true
            } catch (t: Throwable) {
                Log.w(TAG, "Surface.setFrameRate 失败: ${t.message}")
                false
            }
        }
        // 首帧前 Surface 尚未创建：有界重试（绝不死循环）。
        if (attempt < SURFACE_RETRY_LIMIT) {
            return try {
                surfaceView.postDelayed(
                    { applySurfaceFrameRate(activity, fps, attempt + 1) },
                    SURFACE_RETRY_DELAY_MS
                )
                true
            } catch (t: Throwable) {
                false
            }
        }
        return false
    }

    /** 深度优先查找视图树中的首个 [SurfaceView]（Flutter 默认 surface 渲染模式）。 */
    private fun findSurfaceView(view: View?): SurfaceView? {
        if (view == null) return null
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findSurfaceView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    /** `Context.getDisplay()`（API 30+）优先；回退 `WindowManager.defaultDisplay`。 */
    @Suppress("DEPRECATION")
    private fun displayOf(activity: Activity): Display? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity.display
            } else {
                activity.windowManager?.defaultDisplay
            }
        } catch (t: Throwable) {
            Log.w(TAG, "读取 display 失败: ${t.message}")
            null
        }
    }

    private fun errorJson(code: String, message: String): String =
        JSONObject().apply {
            put("ok", false)
            put("code", code)
            put("message", message)
        }.toString()
}
