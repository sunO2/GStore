package com.suno2.gstore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import rikka.shizuku.Shizuku
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * GStore 性能悬浮窗前台服务（HUD）。
 *
 * ## 职责边界
 * 本服务**自包含**：只在屏幕上叠加一个小的系统级悬浮视图，定时（~1s）从
 * `/proc`、`/sys` **原生读取** CPU 占用、内存占用与电池温度并刷新文本。不依赖
 * Flutter 引擎，因此 App 切到后台 / 被回收后仍持续显示。所有采集均为**只读**，
 * 无 root、无 shell、无写操作。
 *
 * ## 进程模型（钉死：与 App 同进程）
 * 不声明 `android:process`。与 `ProxyVpnService`、`flutter_foreground_task` 的
 * dataSync 服务共存于同一进程，因此 [isRunning] 用静态标志即可被
 * `MainActivity` 的 `gstore/perf_overlay` 通道直接读取，无需跨进程通信。
 *
 * ## 权限
 * 悬浮窗依赖 `SYSTEM_ALERT_WINDOW`（`Settings.canDrawOverlays`）。权限未授予时
 * **不添加视图**（`addView` 会抛 `BadTokenException`），立即拆除并停止服务，
 * 绝不崩溃。前台服务类型为 Android 14 的 `specialUse`，manifest 声明匹配的
 * `FOREGROUND_SERVICE_SPECIAL_USE` 权限与 `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`
 * 属性；进入前台仍需常驻通知。
 *
 * ## 采集口径
 * - CPU%：`/proc/stat` 首行 `cpu` 的 jiffies 差值；busy = total - (idle + iowait)。
 *   首次采样只建立基线（返回 null，显示 `--`），避免把开机至今的均值当成瞬时值。
 * - 内存%：`/proc/meminfo` 的 (MemTotal - MemAvailable) / MemTotal。
 * - 电池温度：优先 `/sys/class/power_supply/{battery,bms}/temperature`（十分之一
 *   摄氏度；异常大值按毫摄氏度处理），回退 `BatteryManager.EXTRA_TEMPERATURE`。
 */
class PerfOverlayService : Service() {

    companion object {
        private const val TAG = "PerfOverlayService"
        private const val CHANNEL_ID = "gstore_perf_overlay"
        private const val NOTIFICATION_ID = 0x5052
        private const val REFRESH_INTERVAL_MS = 1000L

        const val ACTION_STOP = "com.suno2.gstore.perf_overlay.STOP"
        private const val ACTION_SET_MODE = "com.suno2.gstore.perf_overlay.SET_MODE"
        private const val EXTRA_MODE = "mode"

        /** 目标第三方应用：设置 / 清除（运行中实时刷新；未运行仅持久化）。 */
        private const val ACTION_SET_TARGET = "com.suno2.gstore.perf_overlay.SET_TARGET"
        private const val ACTION_CLEAR_TARGET = "com.suno2.gstore.perf_overlay.CLEAR_TARGET"
        private const val EXTRA_TARGET = "target"

        /** 当前生效的性能档案名：Dart 推送（运行中实时刷新；未运行仅持久化）。 */
        private const val ACTION_SET_PROFILE = "com.suno2.gstore.perf_overlay.SET_PROFILE"
        private const val EXTRA_PROFILE = "profile"

        /**
         * 悬浮窗模式：
         * - `compact` = 单行系统紧凑（CPU/MEM/温度）；
         * - `expanded` = 多行系统（网络/压力/温度）+ 目标行；
         * - `target` = 目标专注，仅显示所选第三方应用（CPU/FPS/jank/MEM）；
         * - `live` = 前台应用 + 当前生效档案（均带刷新时间戳 / 过期指示）。
         */
        const val MODE_COMPACT = "compact"
        const val MODE_EXPANDED = "expanded"
        const val MODE_TARGET = "target"
        const val MODE_LIVE = "live"

        /** 长按停止悬浮窗的判定时长（ms）。 */
        private const val LONG_PRESS_MS = 500L

        /** 持久化（位置 / 模式 / 目标 / 档案）文件与键；服务未运行时亦可供读取。 */
        private const val PREFS = "gstore_perf_overlay"
        private const val KEY_MODE = "mode"
        private const val KEY_POS_X = "pos_x"
        private const val KEY_POS_Y = "pos_y"
        private const val KEY_TARGET = "target_package"
        private const val KEY_PROFILE = "profile_name"
        private const val KEY_PROFILE_TS = "profile_updated_ms"

        /** 第三方目标指标刷新间隔（与系统指标 1s 刷新的**独立**节流）。 */
        private const val TARGET_REFRESH_INTERVAL_MS = 2000L

        /** 前台应用读取刷新间隔（live 模式；dumpsys 较慢，独立节流）。 */
        private const val FOREGROUND_REFRESH_INTERVAL_MS = 2000L

        /** 读数超过该秒数即标记为可能过期（⚠ 前缀），避免把陈旧值当实时值展示。 */
        private const val STALE_AFTER_SECONDS = 10L

        /** `dumpsys cpuinfo` 行：`12.3% 1234/pkg.name: ...` → (percent, pid, name)。 */
        private val CPU_LINE_RE = Regex("""^([0-9]+(?:\.[0-9]+)?)%\s+(\d+)/(\S+):""")

        /** `dumpsys gfxinfo` 汇总：`Total frames rendered: N`。 */
        private val GFX_TOTAL_FRAMES_RE = Regex("""Total frames rendered:\s*(\d+)""")

        /** `dumpsys gfxinfo` 汇总：`Janky frames: M (X%)` → 百分比。 */
        private val GFX_JANK_RE = Regex("""Janky frames:\s*(\d+)\s*\(([0-9]+(?:\.[0-9]+)?)%\)""")

        /** `dumpsys activity activities` 的 `<pkg>/<activity>` 令牌（取包名分组）。 */
        private val RESUMED_ACTIVITY_RE = Regex("""([A-Za-z][A-Za-z0-9_.]*)/[^\s}]+""")

        /** 视图首次添加的位置缺省值（无持久化记录时使用）。 */
        private const val DEFAULT_X = 24
        private const val DEFAULT_Y = 160

        /** 服务是否正在运行（视图已添加）。同进程，`MainActivity` 直接读取。 */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** 规范化模式：非法值一律回退 `compact`。 */
        fun normalizeMode(mode: String?): String = when (mode) {
            MODE_EXPANDED -> MODE_EXPANDED
            MODE_TARGET -> MODE_TARGET
            MODE_LIVE -> MODE_LIVE
            else -> MODE_COMPACT
        }

        /** 读取持久化的模式（服务未运行时亦可读，供 `getMode` 使用）。 */
        fun readMode(context: Context): String {
            val raw = runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_MODE, MODE_COMPACT)
            }.getOrNull()
            return normalizeMode(raw)
        }

        /** 设置并持久化模式；服务运行中时经 ACTION_SET_MODE 实时刷新 HUD。 */
        fun setMode(context: Context, mode: String) {
            val normalized = normalizeMode(mode)
            runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().putString(KEY_MODE, normalized).apply()
            }
            if (isRunning) {
                runCatching {
                    // 仅服务运行中投递；未运行时绝不启动（避免凭空弹出悬浮窗）。
                    context.startService(
                        Intent(context, PerfOverlayService::class.java)
                            .setAction(ACTION_SET_MODE)
                            .putExtra(EXTRA_MODE, normalized)
                    )
                }.onFailure { Log.w(TAG, "实时切换模式失败（忽略）: ${it.message}") }
            }
        }

        /** 读取持久化的监控目标包名；无记录返回 null（服务未运行时亦可读）。 */
        fun readTarget(context: Context): String? {
            val raw = runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_TARGET, null)
            }.getOrNull()
            return raw?.takeIf { it.isNotEmpty() }
        }

        /** 设置并持久化监控目标；服务运行中时经 ACTION_SET_TARGET 实时刷新。 */
        fun setTarget(context: Context, packageName: String) {
            val pkg = packageName.trim()
            if (pkg.isEmpty()) {
                clearTarget(context)
                return
            }
            runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().putString(KEY_TARGET, pkg).apply()
            }
            if (isRunning) {
                runCatching {
                    context.startService(
                        Intent(context, PerfOverlayService::class.java)
                            .setAction(ACTION_SET_TARGET)
                            .putExtra(EXTRA_TARGET, pkg)
                    )
                }.onFailure { Log.w(TAG, "实时设置目标失败（忽略）: ${it.message}") }
            }
        }

        /** 清除持久化的监控目标；服务运行中时经 ACTION_CLEAR_TARGET 实时移除。 */
        fun clearTarget(context: Context) {
            runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().remove(KEY_TARGET).apply()
            }
            if (isRunning) {
                runCatching {
                    context.startService(
                        Intent(context, PerfOverlayService::class.java)
                            .setAction(ACTION_CLEAR_TARGET)
                    )
                }.onFailure { Log.w(TAG, "实时清除目标失败（忽略）: ${it.message}") }
            }
        }

        /** 读取当前生效档案名；无记录返回 null（服务未运行时亦可读）。 */
        fun readProfile(context: Context): String? {
            val raw = runCatching {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_PROFILE, null)
            }.getOrNull()
            return raw?.takeIf { it.isNotEmpty() }
        }

        /** 读取档案名最近一次更新时间戳（ms）；无记录返回 0。 */
        fun readProfileUpdatedMs(context: Context): Long = runCatching {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(KEY_PROFILE_TS, 0L)
        }.getOrDefault(0L)

        /** 设置并持久化当前生效档案名（空白清除）；运行中经 ACTION_SET_PROFILE 实时刷新。 */
        fun setProfile(context: Context, name: String?) {
            val trimmed = name?.trim().orEmpty()
            val now = System.currentTimeMillis()
            runCatching {
                val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                if (trimmed.isEmpty()) {
                    editor.remove(KEY_PROFILE).remove(KEY_PROFILE_TS)
                } else {
                    editor.putString(KEY_PROFILE, trimmed).putLong(KEY_PROFILE_TS, now)
                }
                editor.apply()
            }
            if (isRunning) {
                runCatching {
                    context.startService(
                        Intent(context, PerfOverlayService::class.java)
                            .setAction(ACTION_SET_PROFILE)
                            .putExtra(EXTRA_PROFILE, trimmed)
                    )
                }.onFailure { Log.w(TAG, "实时设置档案失败（忽略）: ${it.message}") }
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: TextView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var dragListener: DragTouchListener? = null

    /** 目标应用一次采样的四元指标（后台线程产出，主线程渲染）。 */
    private data class TargetSnapshot(
        val cpu: Double?,
        val pssMb: Long?,
        val fps: Double?,
        val jankPct: Double?,
    )

    /** `dumpsys gfxinfo` 汇总：累计帧数 + jank 百分比。 */
    private data class Gfxinfo(val frames: Long?, val jankPct: Double?)

    /** 前台应用一次采样的结果（后台线程产出，主线程渲染）。 */
    private data class ForegroundSnapshot(val packageName: String?)

    private val handler = Handler(Looper.getMainLooper())

    /** 当前模式（compact / expanded / target / live），启动时从 SharedPreferences 恢复。 */
    private var mode: String = MODE_COMPACT

    /** CPU 上一次采样的总 jiffies 与空闲 jiffies（含 iowait）。 */
    private var lastCpuTotal = 0L
    private var lastCpuIdle = 0L

    /** 网络上一次采样的累计 rx/tx 字节与时间戳（用于计算 KB/s 差值）。 */
    private var lastNetRx = -1L
    private var lastNetTx = -1L
    private var lastNetTimeMs = 0L

    /** 监控目标包名（null = 未设置）；启动时从 SharedPreferences 恢复。 */
    private var targetPackage: String? = null

    /** 目标指标缓存（后台线程读取，主线程渲染）。 */
    private var targetCpuPercent: Double? = null
    private var targetPssMb: Long? = null
    private var targetFps: Double? = null
    private var targetJankPct: Double? = null

    /** `dumpsys gfxinfo` FPS 差值基线（后台线程独占写入；换目标时重置）。 */
    private var lastGfxPackage: String? = null
    private var lastGfxFrames: Long? = null
    private var lastGfxTimeMs: Long = 0L

    /** 目标读取节流与在途标记（避免重入 / 阻塞主线程）。 */
    private var lastTargetMs = 0L
    private var targetPending = false

    /** 前台应用（live 模式）当前包名与最近成功读取时间戳。 */
    private var foregroundPackage: String? = null
    private var foregroundUpdatedMs = 0L

    /** 前台读取节流与在途标记（独立于目标读取）。 */
    private var lastForegroundMs = 0L
    private var foregroundPending = false

    /** 当前生效档案名及其推送时间戳（由 Dart 推送；null = 未应用）。 */
    private var profileName: String? = null
    private var profileUpdatedMs = 0L

    /** Shizuku 读取专用后台线程（dumpsys 较慢，绝不占用主线程）。 */
    private var shizukuThread: HandlerThread? = null
    private var shizukuHandler: Handler? = null

    private val refreshRunnable = object : Runnable {
        override fun run() {
            updateOverlayText()
            handler.postDelayed(this, REFRESH_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopOverlay()
            return START_NOT_STICKY
        }

        // 运行中实时切换模式：仅刷新文本，绝不重复 addView / 重新进前台。
        if (intent?.action == ACTION_SET_MODE) {
            mode = normalizeMode(intent.getStringExtra(EXTRA_MODE))
            if (overlayView == null) return START_NOT_STICKY
            updateOverlayText()
            return START_STICKY
        }

        // 运行中实时设置 / 清除监控目标：仅更新字段 + 刷新文本。
        if (intent?.action == ACTION_SET_TARGET) {
            targetPackage = intent.getStringExtra(EXTRA_TARGET)?.takeIf { it.isNotEmpty() }
            resetTargetMetrics()
            if (overlayView == null) return START_NOT_STICKY
            renderOverlayText()
            return START_STICKY
        }
        if (intent?.action == ACTION_CLEAR_TARGET) {
            targetPackage = null
            resetTargetMetrics()
            if (overlayView == null) return START_NOT_STICKY
            renderOverlayText()
            return START_STICKY
        }

        // 运行中实时设置 / 清除当前档案：仅更新字段 + 刷新文本。
        if (intent?.action == ACTION_SET_PROFILE) {
            profileName = intent.getStringExtra(EXTRA_PROFILE)?.takeIf { it.isNotEmpty() }
            profileUpdatedMs = if (profileName != null) System.currentTimeMillis() else 0L
            if (overlayView == null) return START_NOT_STICKY
            renderOverlayText()
            return START_STICKY
        }

        // 必须 5s 内进入前台（startForegroundService 拉起时否则系统崩溃）。
        startForegroundCompat()

        // 无悬浮窗权限：不添加视图（addView 会抛），直接拆除不崩溃。
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "无 SYSTEM_ALERT_WINDOW 权限，停止悬浮窗服务")
            stopOverlay()
            return START_NOT_STICKY
        }

        // 已在运行：仅确保前台存活，绝不重复 addView。
        if (overlayView != null) {
            isRunning = true
            Log.i(TAG, "悬浮窗已存在，忽略重复启动")
            return START_STICKY
        }

        // 恢复持久化的模式（位置在 addOverlayView 内读取）。
        mode = readMode(this)
        // 恢复持久化的监控目标（服务重启后仍生效）。
        targetPackage = readTarget(this)
        // 恢复持久化的当前档案名与时间戳。
        profileName = readProfile(this)
        profileUpdatedMs = readProfileUpdatedMs(this)

        try {
            addOverlayView()
            isRunning = true
            handler.removeCallbacks(refreshRunnable)
            handler.post(refreshRunnable)
        } catch (t: Throwable) {
            Log.e(TAG, "添加悬浮窗失败: ${t.message}", t)
            stopOverlay()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopOverlay()
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // 悬浮视图
    // ---------------------------------------------------------------------

    private fun addOverlayView() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            ?: throw IllegalStateException("WindowManager 不可用")
        windowManager = wm

        val view = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 12f
            setPadding(30, 18, 30, 18)
            // 圆角半透明深色背景，保证在任何应用上均可读（原生 HUD，非 Flutter 主题域）。
            background = GradientDrawable().apply {
                setColor(0xCC000000.toInt())
                cornerRadius = 24f
            }
        }

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            legacyOverlayType()
        }

        val restored = runCatching {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }.getOrNull()
        val startX = restored?.getInt(KEY_POS_X, DEFAULT_X) ?: DEFAULT_X
        val startY = restored?.getInt(KEY_POS_Y, DEFAULT_Y) ?: DEFAULT_Y

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = startX
            y = startY
        }

        view.setOnTouchListener(DragTouchListener().also { dragListener = it })
        wm.addView(view, params)
        overlayView = view
        layoutParams = params
        updateOverlayText()
    }

    @Suppress("DEPRECATION")
    private fun legacyOverlayType(): Int = WindowManager.LayoutParams.TYPE_PHONE

    /**
     * 悬浮窗手势：
     * - 拖动（位移超阈值 ~10dp）：移动并持久化位置；
     * - 轻点（无显著位移，500ms 内抬起）：循环切换显示模式；
     * - 长按（500ms 无位移）：停止悬浮窗（`stopSelf` + 移除视图）。
     */
    private inner class DragTouchListener : View.OnTouchListener {
        private var startX = 0
        private var startY = 0
        private var touchX = 0f
        private var touchY = 0f
        private var dragging = false
        private var longPressFired = false
        private val moveThresholdPx = 10f * resources.displayMetrics.density

        private val longPressRunnable = Runnable {
            longPressFired = true
            stopOverlay()
        }

        fun cancelPending() {
            handler.removeCallbacks(longPressRunnable)
        }

        override fun onTouch(v: View, event: MotionEvent): Boolean {
            val params = layoutParams ?: return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = event.rawX
                    touchY = event.rawY
                    dragging = false
                    longPressFired = false
                    handler.postDelayed(longPressRunnable, LONG_PRESS_MS)
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - touchX
                    val dy = event.rawY - touchY
                    if (!dragging && (abs(dx) > moveThresholdPx || abs(dy) > moveThresholdPx)) {
                        dragging = true
                        handler.removeCallbacks(longPressRunnable)
                    }
                    if (dragging) {
                        val metrics = resources.displayMetrics
                        params.x = (startX + dx).toInt().coerceIn(0, metrics.widthPixels)
                        params.y = (startY + dy).toInt().coerceIn(0, metrics.heightPixels)
                        runCatching { windowManager?.updateViewLayout(v, params) }
                    }
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(longPressRunnable)
                    when {
                        dragging -> savePosition(params.x, params.y)
                        !longPressFired -> cycleMode()
                    }
                    return true
                }
                MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(longPressRunnable)
                    return true
                }
            }
            return false
        }
    }

    /** 轻点循环：`compact → expanded → target → live → compact`，并持久化当前模式。 */
    private fun cycleMode() {
        mode = when (mode) {
            MODE_COMPACT -> MODE_EXPANDED
            MODE_EXPANDED -> MODE_TARGET
            MODE_TARGET -> MODE_LIVE
            else -> MODE_COMPACT
        }
        runCatching {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_MODE, mode).apply()
        }
        renderOverlayText()
    }

    /** 持久化悬浮窗位置（拖动结束 / 服务停止时调用），跨启动恢复。 */
    private fun savePosition(x: Int, y: Int) {
        runCatching {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putInt(KEY_POS_X, x)
                .putInt(KEY_POS_Y, y)
                .apply()
        }
    }

    // ---------------------------------------------------------------------
    // 指标采集（原生只读）
    // ---------------------------------------------------------------------

    private fun updateOverlayText() {
        maybeRefreshTargetMetrics()
        maybeRefreshForegroundMetrics()
        renderOverlayText()
    }

    private fun renderOverlayText() {
        val view = overlayView ?: return
        val cpu = readCpuPercent()
        val mem = readMemoryPercent()
        val batTemp = readBatteryTempC()
        val cpuText = cpu?.let { "${it.roundToInt()}%" } ?: "--"
        val memText = mem?.let { "${it.roundToInt()}%" } ?: "--"
        val batText = batTemp?.let { "${it.roundToInt()}°C" } ?: "--"

        view.text = when (mode) {
            MODE_TARGET -> targetFocusedText()
            MODE_LIVE -> liveFocusedText()
            MODE_EXPANDED -> {
                val net = readNetRateKbs()
                val psi = readPsiSomeAvg10()
                val thermal = readMaxThermalC()
                val netText = net?.let {
                    "↓${fmt1(it.first)} ↑${fmt1(it.second)} KB/s"
                } ?: "--"
                val psiText = psi?.let { "${fmt1(it)}%" } ?: "--"
                val thermalText = thermal?.let { "${fmt1(it)}°C" } ?: "--"
                buildString {
                    append("CPU $cpuText   MEM $memText   BAT ")
                    append(batTemp?.let { String.format(Locale.US, "%.1f°C", it) } ?: "--")
                    append('\n')
                    append("NET $netText")
                    append('\n')
                    append("PSI $psiText   THM $thermalText")
                    targetLine()?.let { append('\n').append(it) }
                }
            }
            else -> "CPU $cpuText  MEM $memText  $batText"
        }
    }

    /** 展开模式的第三方目标行；目标未设置 / 指标缺失时返回 null（优雅省略）。 */
    private fun targetLine(): String? {
        val pkg = targetPackage ?: return null
        val parts = targetParts(separator = " · ")
        if (parts.isEmpty()) return null
        return "▸ ${shortPackage(pkg)} $parts"
    }

    /**
     * 目标专注模式文本：仅显示所选目标的 `CPU / FPS / jank / MEM`。
     * 无目标时回退提示 [未选择目标]；有目标但首帧指标未就绪时提示等待。
     */
    private fun targetFocusedText(): String {
        val pkg = targetPackage ?: return "未选择目标"
        val parts = targetParts(
            includeMemLast = true,
            separator = "  ",
        )
        if (parts.isEmpty()) return "▸ ${shortPackage(pkg)}  等待数据..."
        return "▸ ${shortPackage(pkg)}  $parts"
    }

    /**
     * 前台模式文本：当前前台应用 + 当前生效档案，各附刷新时间戳。
     * 未知值回退清晰占位（`前台 --` / `档案 未应用`）；读数过期加 `⚠` 前缀，
     * 绝不把陈旧数据当作实时值静默展示。
     */
    private fun liveFocusedText(): String {
        val now = System.currentTimeMillis()
        val fgLine = foregroundPackage?.let {
            "前台 ${shortPackage(it)}  (${ageIndicator(foregroundUpdatedMs, now)})"
        } ?: "前台 --"
        val profileLine = profileName?.let {
            "档案 $it  (${ageIndicator(profileUpdatedMs, now)})"
        } ?: "档案 未应用"
        return "▸ $fgLine\n   $profileLine"
    }

    /** 相对时间指示：`刚刚` / `Ns前`；超 [STALE_AFTER_SECONDS] 追加 `⚠`；无时间戳返回提示。 */
    private fun ageIndicator(updatedMs: Long, now: Long): String {
        if (updatedMs <= 0L) return "无时间戳"
        val seconds = ((now - updatedMs) / 1000L).coerceAtLeast(0L)
        val relative = if (seconds <= 2L) "刚刚" else "${seconds}s前"
        return if (seconds > STALE_AFTER_SECONDS) "⚠$relative" else relative
    }

    /**
     * 目标指标片段串（缺失项省略）；全缺失返回空串。
     * [includeMemLast] = true 时列为 `CPU / FPS / jank / MEM`，否则 `CPU / MEM / FPS / jank`。
     */
    private fun targetParts(
        includeMemLast: Boolean = false,
        separator: String = " · ",
    ): String {
        val mem = targetPssMb?.let { "MEM ${it}MB" }
        val cpu = targetCpuPercent?.let { "CPU ${it.roundToInt()}%" }
        val fps = targetFps?.let { "${it.roundToInt()}fps" }
        val jank = targetJankPct?.let { "jank ${fmt1(it)}%" }
        val parts = if (includeMemLast) {
            listOfNotNull(cpu, fps, jank, mem)
        } else {
            listOfNotNull(cpu, mem, fps, jank)
        }
        return parts.joinToString(separator)
    }

    /** 包名短名（取最后一个 `.` 之后的段）；无 `.` 时原样返回。 */
    private fun shortPackage(pkg: String): String {
        val idx = pkg.lastIndexOf('.')
        return if (idx in 0 until pkg.length - 1) pkg.substring(idx + 1) else pkg
    }

    private fun resetTargetMetrics() {
        targetCpuPercent = null
        targetPssMb = null
        targetFps = null
        targetJankPct = null
        lastTargetMs = 0L
    }

    // ---------------------------------------------------------------------
    // 第三方目标指标（Shizuku，后台线程）
    // ---------------------------------------------------------------------

    /**
     * 目标指标刷新节流 + 调度：每 [TARGET_REFRESH_INTERVAL_MS] 一次、单飞在途，
     * 实际读取投递到 [shizukuThread]（dumpsys 较慢，绝不阻塞主线程），
     * 结果经主线程 Handler 回写并重渲染。目标未设置时不读取。
     */
    private fun maybeRefreshTargetMetrics() {
        val pkg = targetPackage
        if (pkg == null) {
            resetTargetMetrics()
            return
        }
        val now = System.currentTimeMillis()
        if (targetPending || now - lastTargetMs < TARGET_REFRESH_INTERVAL_MS) return
        val bgHandler = ensureShizukuHandler() ?: return
        targetPending = true
        lastTargetMs = now
        bgHandler.post {
            val result = runCatching { readTargetMetrics(pkg) }.getOrNull()
            handler.post {
                targetPending = false
                if (result != null) {
                    targetCpuPercent = result.cpu
                    targetPssMb = result.pssMb
                    targetFps = result.fps
                    targetJankPct = result.jankPct
                }
                renderOverlayText()
            }
        }
    }

    private fun ensureShizukuHandler(): Handler? {
        shizukuHandler?.let { return it }
        return runCatching {
            val thread = HandlerThread("perf-overlay-shizuku").also { it.start() }
            shizukuThread = thread
            Handler(thread.looper).also { shizukuHandler = it }
        }.getOrNull()
    }

    /**
     * 前台应用刷新节流 + 调度（仅 `live` 模式）：每 [FOREGROUND_REFRESH_INTERVAL_MS]
     * 一次、单飞在途，读取投递到 [shizukuThread]，结果经主线程回写并重渲染。
     * 读取失败保留旧值（由时间戳标记陈旧），不把失败当作“无前台应用”。
     */
    private fun maybeRefreshForegroundMetrics() {
        if (mode != MODE_LIVE) return
        val now = System.currentTimeMillis()
        if (foregroundPending || now - lastForegroundMs < FOREGROUND_REFRESH_INTERVAL_MS) return
        val bgHandler = ensureShizukuHandler() ?: return
        foregroundPending = true
        lastForegroundMs = now
        bgHandler.post {
            val result = runCatching { readForegroundPackage() }.getOrNull()
            handler.post {
                foregroundPending = false
                if (result != null) {
                    foregroundPackage = result.packageName
                    foregroundUpdatedMs = System.currentTimeMillis()
                }
                renderOverlayText()
            }
        }
    }

    /** 经 Shizuku 读取当前前台包名（后台线程调用）；不可用 / 无法判定返回 null（不抛）。 */
    private fun readForegroundPackage(): ForegroundSnapshot? {
        if (!shizukuUsable()) return null
        val output = execShizuku("dumpsys activity activities") ?: return null
        return ForegroundSnapshot(parseForegroundPackage(output))
    }

    /**
     * 从 `dumpsys activity activities` 文本解析前台包名：含 RESUMED 标记
     * （`ResumedActivity` / `mResumedActivity` / `topResumedActivity`）的行里，
     * 取首个 `<pkg>/<activity>` 令牌的包名分组。多窗口出现多个不同包名时判为
     * 歧义 → null（fail-closed）；无标记 / 无令牌同样 null，绝不猜测。
     */
    private fun parseForegroundPackage(dumpsys: String): String? {
        val packages = LinkedHashSet<String>()
        for (raw in dumpsys.split('\n')) {
            if (!raw.contains("ResumedActivity")) continue
            val pkg = RESUMED_ACTIVITY_RE.find(raw)?.groupValues?.get(1) ?: continue
            if (pkg.isNotEmpty()) packages.add(pkg)
        }
        return if (packages.size == 1) packages.first() else null
    }

    /** Shizuku 是否可用：Binder 存活且已授权（任何异常视为不可用）。 */
    private fun shizukuUsable(): Boolean = runCatching {
        Shizuku.pingBinder() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    /**
     * 经 Shizuku 读取目标应用指标（后台线程调用）。
     * 返回 CPU% / PSS MB / FPS / jank%；Shizuku 不可用或全部解析失败返回 null（不抛）。
     */
    private fun readTargetMetrics(pkg: String): TargetSnapshot? {
        if (!shizukuUsable()) return null
        val cpuOut = execShizuku("dumpsys cpuinfo")
        val memOut = execShizuku("dumpsys meminfo $pkg")
        val gfxOut = execShizuku("dumpsys gfxinfo $pkg")
        val cpu = cpuOut?.let { parseCpuPercent(it, pkg) }
        val pssKb = memOut?.let { parseTotalPssKb(it) }
        val gfx = gfxOut?.let { parseGfxinfo(it) }
        val fps = gfx?.frames?.let { computeFps(pkg, it) }
        val jankPct = gfx?.jankPct
        if (cpu == null && pssKb == null && fps == null && jankPct == null) return null
        return TargetSnapshot(cpu, pssKb?.let { it / 1024 }, fps, jankPct)
    }

    /** 经 Shizuku 执行 shell 命令（`sh -c`），stderr 合并进 stdout；失败返回 null。 */
    private fun execShizuku(command: String): String? = runCatching {
        val process = Shizuku.newProcess(
            arrayOf("sh", "-c", "$command 2>&1"), null, "/"
        )
        val output = StringBuilder()
        process.inputStream.bufferedReader().use { reader ->
            var line = reader.readLine()
            while (line != null) {
                output.append(line).append('\n')
                line = reader.readLine()
            }
        }
        process.waitFor()
        process.destroy()
        output.toString()
    }.onFailure { Log.w(TAG, "Shizuku 命令失败（忽略）: ${it.message}") }.getOrNull()

    /**
     * 从 `dumpsys cpuinfo` 求和目标应用各进程占用。
     * 行形如 `12.3% 1234/com.example.app:service: 5% user + 7% kernel`；
     * 进程名等于包名或以 `包名:` 开头才计入；无命中返回 null。
     */
    private fun parseCpuPercent(cpuinfo: String, pkg: String): Double? {
        var sum = 0.0
        var found = false
        for (raw in cpuinfo.split('\n')) {
            val line = raw.trim()
            if (line.isEmpty() || !line.contains(pkg)) continue
            val match = CPU_LINE_RE.find(line) ?: continue
            val name = match.groupValues[3]
            if (name != pkg && !name.startsWith("$pkg:")) continue
            val percent = match.groupValues[1].toDoubleOrNull() ?: continue
            sum += percent
            found = true
        }
        return if (found) sum else null
    }

    /**
     * 从 `dumpsys meminfo <pkg>` 解析 TOTAL PSS（KB）。
     * 优先 `TOTAL PSS:` 行，回退旧式 `TOTAL <n>` 行（跳过 TOTAL RSS/SWAP）；
     * 千分位逗号忽略；无命中返回 null。
     */
    private fun parseTotalPssKb(meminfo: String): Long? {
        val lines = meminfo.split('\n')
        for (raw in lines) {
            val trimmed = raw.trim()
            if (trimmed.startsWith("TOTAL PSS:")) {
                firstInt(trimmed.substringAfter("TOTAL PSS:"))?.let { return it }
            }
        }
        for (raw in lines) {
            val trimmed = raw.trim()
            if (!trimmed.startsWith("TOTAL")) continue
            val rest = trimmed.removePrefix("TOTAL").trimStart()
            if (rest.isNotEmpty() && rest[0].isDigit()) {
                firstInt(rest)?.let { return it }
            }
        }
        return null
    }

    /**
     * 从 `dumpsys gfxinfo <pkg>` 解析汇总指标（后台线程调用）。
     * `Total frames rendered` 为累计帧数（供 FPS 差值），`Janky frames` 的百分比直接取用；
     * 任一行缺失对应字段为 null。
     */
    private fun parseGfxinfo(gfxinfo: String): Gfxinfo? {
        val frames = GFX_TOTAL_FRAMES_RE.find(gfxinfo)?.groupValues?.get(1)?.toLongOrNull()
        val jankPct = GFX_JANK_RE.find(gfxinfo)?.groupValues?.get(2)?.toDoubleOrNull()
        if (frames == null && jankPct == null) return null
        return Gfxinfo(frames, jankPct)
    }

    /**
     * 由两次 `Total frames rendered` 采样差值推导交付 FPS：
     * `fps = Δframes * 1000 / Δt_ms`。首帧 / 换目标 / 帧计数回退（重启重置）→ null。
     * 仅后台线程调用（基线字段独占）。
     */
    private fun computeFps(pkg: String, frames: Long): Double? {
        val now = System.currentTimeMillis()
        if (lastGfxPackage != pkg || lastGfxFrames == null || lastGfxTimeMs == 0L) {
            lastGfxPackage = pkg
            lastGfxFrames = frames
            lastGfxTimeMs = now
            return null
        }
        val prevFrames = lastGfxFrames ?: return null
        val dtMs = now - lastGfxTimeMs
        lastGfxFrames = frames
        lastGfxTimeMs = now
        val deltaFrames = frames - prevFrames
        if (deltaFrames < 0L || dtMs <= 0L) return null
        return deltaFrames.toDouble() * 1000.0 / dtMs.toDouble()
    }

    /** 文本中首个整数（忽略千分位逗号）；无数字返回 null。 */
    private fun firstInt(text: String): Long? {
        val digits = StringBuilder()
        for (c in text) {
            when {
                c.isDigit() -> digits.append(c)
                c == ',' -> continue
                digits.isNotEmpty() -> break
            }
        }
        return digits.toString().toLongOrNull()
    }

    private fun fmt1(value: Double): String = String.format(Locale.US, "%.1f", value)

    /**
     * `/proc/net/dev` 累计 rx/tx 字节（跳过 `lo` 回环）→ 与上次采样的差值换算 KB/s。
     * 首次采样只建立基线（返回 null，显示 `--`）。接口消失导致计数回退时按 0 处理。
     */
    private fun readNetRateKbs(): Pair<Double, Double>? {
        val lines = runCatching { File("/proc/net/dev").readLines() }.getOrNull() ?: return null
        var rx = 0L
        var tx = 0L
        var found = false
        for (line in lines) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
            if (line.substring(0, colon).trim() == "lo") continue
            val cols = line.substring(colon + 1).trim().split(Regex("\\s+"))
            if (cols.size < 16) continue
            val rxBytes = cols[0].toLongOrNull() ?: continue
            val txBytes = cols[8].toLongOrNull() ?: continue
            rx += rxBytes
            tx += txBytes
            found = true
        }
        if (!found) return null

        val now = System.currentTimeMillis()
        if (lastNetRx < 0L || lastNetTimeMs == 0L) {
            lastNetRx = rx
            lastNetTx = tx
            lastNetTimeMs = now
            return null
        }
        val seconds = (now - lastNetTimeMs).coerceAtLeast(1L) / 1000.0
        val rxRate = (rx - lastNetRx).coerceAtLeast(0L) / 1024.0 / seconds
        val txRate = (tx - lastNetTx).coerceAtLeast(0L) / 1024.0 / seconds
        lastNetRx = rx
        lastNetTx = tx
        lastNetTimeMs = now
        return rxRate to txRate
    }

    /** `/proc/pressure/cpu` 的 `some avg10`（CPU 停顿百分比）；文件缺失返回 null。 */
    private fun readPsiSomeAvg10(): Double? {
        val line = runCatching {
            File("/proc/pressure/cpu").readLines().firstOrNull { it.startsWith("some") }
        }.getOrNull() ?: return null
        for (token in line.trim().split(Regex("\\s+"))) {
            if (token.startsWith("avg10=")) {
                return token.removePrefix("avg10=").toDoubleOrNull()
            }
        }
        return null
    }

    /**
     * `/sys/class/thermal/thermal_zoneN/temp` 的最大值（℃）。
     * 数值 > 1000 视为毫摄氏度（÷1000），否则按摄氏度；无有效温区返回 null。
     */
    private fun readMaxThermalC(): Double? {
        val zones = runCatching {
            File("/sys/class/thermal").listFiles { f -> f.name.startsWith("thermal_zone") }
        }.getOrNull() ?: return null
        var max: Double? = null
        for (zone in zones) {
            val raw = runCatching { File(zone, "temp").readText().trim().toDouble() }.getOrNull()
                ?: continue
            if (raw <= 0.0) continue
            val celsius = if (abs(raw) > 1000.0) raw / 1000.0 else raw
            if (max == null || celsius > max) max = celsius
        }
        return max
    }

    /** `/proc/stat` 首行差值 → CPU 占用百分比；首次采样仅建基线返回 null。 */
    private fun readCpuPercent(): Double? {
        val line = runCatching {
            File("/proc/stat").readLines().firstOrNull { it.startsWith("cpu ") }
        }.getOrNull() ?: return null
        val parts = line.trim().split(Regex("\\s+"))
        if (parts.size < 5) return null

        // parts[0]="cpu", [1]=user [2]=nice [3]=system [4]=idle [5]=iowait ...
        var total = 0L
        var idle = 0L
        for (i in 1 until parts.size) {
            val value = parts[i].toLongOrNull() ?: continue
            total += value
            if (i == 4 || i == 5) idle += value // idle + iowait
        }
        if (lastCpuTotal == 0L) {
            lastCpuTotal = total
            lastCpuIdle = idle
            return null
        }
        val totalDelta = total - lastCpuTotal
        val idleDelta = idle - lastCpuIdle
        lastCpuTotal = total
        lastCpuIdle = idle
        if (totalDelta <= 0L) return null
        val busy = totalDelta - idleDelta
        return (busy.toDouble() / totalDelta.toDouble()) * 100.0
    }

    /** `/proc/meminfo` → 已用内存百分比。 */
    private fun readMemoryPercent(): Double? {
        val lines = runCatching { File("/proc/meminfo").readLines() }.getOrNull() ?: return null
        var totalKb = -1L
        var availableKb = -1L
        for (line in lines) {
            when {
                line.startsWith("MemTotal:") -> totalKb = firstNumber(line)
                line.startsWith("MemAvailable:") -> availableKb = firstNumber(line)
            }
            if (totalKb > 0L && availableKb >= 0L) break
        }
        if (totalKb <= 0L || availableKb < 0L) return null
        return (totalKb - availableKb).toDouble() / totalKb.toDouble() * 100.0
    }

    /** 首个连续数字（忽略千分位/单位），无则 -1。 */
    private fun firstNumber(line: String): Long {
        val digits = StringBuilder()
        for (c in line) {
            if (c.isDigit()) {
                digits.append(c)
            } else if (digits.isNotEmpty()) {
                break
            }
        }
        return digits.toString().toLongOrNull() ?: -1L
    }

    /** 电池温度（℃）：sysfs 优先，回退 BatteryManager；均不可用返回 null。 */
    private fun readBatteryTempC(): Double? {
        val paths = listOf(
            "/sys/class/power_supply/battery/temperature",
            "/sys/class/power_supply/bms/temperature",
        )
        for (path in paths) {
            val raw = runCatching { File(path).readText().trim().toDouble() }.getOrNull()
                ?: continue
            // sysfs 通常为十分之一摄氏度（305 = 30.5℃）；异常大值按毫摄氏度处理。
            return if (abs(raw) > 1000.0) raw / 1000.0 else raw / 10.0
        }
        val intent = runCatching {
            registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull() ?: return null
        val tenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        if (tenths == Int.MIN_VALUE) return null
        return tenths / 10.0
    }

    private fun stopOverlay() {
        isRunning = false
        handler.removeCallbacks(refreshRunnable)
        dragListener?.cancelPending()
        dragListener = null
        shizukuHandler?.removeCallbacksAndMessages(null)
        shizukuHandler = null
        shizukuThread?.quitSafely()
        shizukuThread = null
        targetPending = false
        layoutParams?.let { savePosition(it.x, it.y) }
        val view = overlayView
        overlayView = null
        if (view != null) {
            runCatching { windowManager?.removeView(view) }
                .onFailure { Log.w(TAG, "移除悬浮窗失败（忽略）: ${it.message}") }
        }
        windowManager = null
        layoutParams = null
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    // ---------------------------------------------------------------------
    // 通知 / 前台服务
    // ---------------------------------------------------------------------

    private fun startForegroundCompat() {
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.perf_overlay_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        channel.description = getString(R.string.perf_overlay_channel_desc)
        channel.setShowBadge(false)
        channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        manager.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        // 通知栏「停止」快捷键：复用 ACTION_STOP，落回 onStartCommand 的拆除路径。
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, PerfOverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopAction = Notification.Action.Builder(
            0,
            getString(R.string.perf_overlay_notification_action_stop),
            stopIntent
        ).build()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setContentTitle(getString(R.string.perf_overlay_notification_title))
            .setContentText(getString(R.string.perf_overlay_notification_text))
            .setSmallIcon(R.drawable.ic_stat_proxy_vpn)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(stopAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }
}
