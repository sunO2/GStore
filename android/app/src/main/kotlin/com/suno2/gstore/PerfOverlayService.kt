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
import android.system.Os
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
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
 * - CPU%：`/proc/stat` 首行 `cpu` 的 jiffies 差值；busy = total - idle（**仅 idle 列，不含 iowait**，
 *   对齐 Rust `gstore_mod_perf`）。首次采样只建立基线（返回 null，显示 `--`）。
 * - 内存%：`/proc/meminfo` 的 (MemTotal - MemAvailable) / MemTotal。
 * - 电池温度：优先 `/sys/class/power_supply/{battery,bms}/temp`，回退 `temperature`（十分之一
 *   摄氏度，**恒 ÷10**），再回退 `BatteryManager.EXTRA_TEMPERATURE`。
 * - 网络：`/proc/net/dev` 全接口（含 `lo`）累计字节差值 → KB/s。
 * - 扩展 reader（per-core 频率/governor、GPU 频率忙率、电池电压/电流/功率/健康、热区 Top-N、
 *   进程数/最高 CPU 进程、存储、系统帧率）全部**只读**，任一失败返回 null 优雅降级。
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

        /** `dumpsys SurfaceFlinger --timestats -dump` 的层名 / 平均帧率 / 累计帧数行。 */
        private val SYSTEM_FPS_LAYER_RE = Regex("""layerName\s*=\s*(.+)""")
        private val SYSTEM_FPS_AVG_RE = Regex("""averageFPS\s*=\s*([0-9]+(?:\.[0-9]+)?)""")
        private val SYSTEM_FPS_FRAMES_RE = Regex("""totalFrames\s*=\s*(\d+)""")

        /** 系统帧率选层黑名单：层名含其一即为系统层，剔除（对齐 WS1 启发式）。 */
        private val SYSTEM_FPS_BLACKLIST = listOf(
            "com.android.systemui", "StatusBar", "NavigationBar",
            "Wallpaper", "InputMethod", "Background for",
        )

        /**
         * GPU 频率探测路径（回退顺序，对齐 Rust `gpu.rs::FREQ_PATHS`）。
         * 缩放启发式：`v>1e6 → /1e6`；`v>1000 → /1000`；否则原值（kHz/MHz 通用）。
         */
        private val GPU_FREQ_PATHS = listOf(
            "/sys/class/kgsl/kgsl-3d0/gpuclk",
            "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq",
            "/sys/kernel/gpu/gpu_clock",
            "/sys/class/devfreq/gpufreq/cur_freq",
            "/sys/class/devfreq/5000000.gpu/cur_freq",
            "/sys/class/mali/misc/gpu_clock",
            "/sys/kernel/debug/mali/clock",
        )

        /** GPU 忙率探测路径（回退顺序，去尾部 `%` 取首 token，clamp 0..100）。 */
        private val GPU_BUSY_PATHS = listOf(
            "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/class/kgsl/kgsl-3d0/utilization",
            "/sys/kernel/gpu/gpu_busy",
        )

        /** 存储汇报的真实文件系统白名单（对齐 Rust `storage.rs::is_real_fs`；伪 fs 一律跳过）。 */
        private val REAL_FS_TYPES = setOf(
            "ext2", "ext3", "ext4", "f2fs", "xfs", "btrfs", "jfs", "nilfs2", "reiserfs",
            "ufs", "minix", "vfat", "msdos", "exfat", "ntfs", "ntfs3", "fuseblk",
            "squashfs", "erofs", "iso9660", "udf", "hfsplus",
        )

        /** 内核节拍频率（`sysconf(_SC_CLK_TCK)`，Android 恒为 100）。 */
        private const val CLK_TCK = 100L

        /** 系统帧率（SurfaceFlinger timestats）刷新节流；dumpsys 较慢，独立于 1s 系统指标。 */
        private const val SYSTEM_FPS_REFRESH_INTERVAL_MS = 1000L

        /** expanded 模式展示的热区 Top-N 条数。 */
        private const val THERMAL_TOP_N = 3

        /**
         * 视图首次添加的缺省位置（**dp**，使用时乘 `displayMetrics.density` 得 px，
         * 保证各屏幕密度下物理尺寸一致；配合可用区 clamp 落在状态栏之下）。
         */
        private const val DEFAULT_X_DP = 16f
        private const val DEFAULT_Y_DP = 64f

        /**
         * 恢复坐标的「最小可见」兜底尺寸（dp）。视图为 `WRAP_CONTENT`，布局前尺寸未知，
         * 先用该值做一次即时 clamp，避免非法坐标把窗口闪到屏外。
         */
        private const val MIN_VISIBLE_DP = 48f

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

    /**
     * 电池一次采样的结果（对齐 Rust `battery.rs`：电流仅 `|raw|>10000` ÷1000，
     * 电压 `|v|>1e6→/1e6`、`|v|>1000→/1000`，温度恒 ÷10）。缺省字段为 null。
     */
    private data class BatteryInfo(
        val voltageV: Double?,
        val currentMa: Double?,
        val powerW: Double?,
        val temperatureC: Double?,
        val capacityPercent: Double?,
        val chargeFullUah: Long?,
        val chargeFullDesignUah: Long?,
        val cycleCount: Long?,
        val status: String?,
        val health: String?,
    )

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

    /** 进程 CPU 增量基线：pid→(utime+stime) ticks 与采样时间戳；两次刷新取差，绝不 sleep。 */
    private var lastProcBaseline: MutableMap<Int, Long> = HashMap()
    private var lastProcBaselineMs = 0L

    /** 系统帧率（SurfaceFlinger timestats）缓存：后台线程产出，主线程渲染。 */
    private var systemFps: Double? = null
    private var systemFpsLayer: String? = null
    private var systemFpsFrames: Int? = null
    private var lastSystemFpsMs = 0L
    private var systemFpsPending = false
    private var systemFpsEnabled = false

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

        val density = resources.displayMetrics.density
        val defaultX = (DEFAULT_X_DP * density).roundToInt()
        val defaultY = (DEFAULT_Y_DP * density).roundToInt()
        val minVisible = (MIN_VISIBLE_DP * density).roundToInt()

        val bounds = computeUsableBounds()
        val restored = runCatching {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }.getOrNull()
        val rawX = restored?.getInt(KEY_POS_X, defaultX) ?: defaultX
        val rawY = restored?.getInt(KEY_POS_Y, defaultY) ?: defaultY

        // 越界/非法（负值、超出屏幕、落入状态栏/刘海）一律回退默认位置，再按最小可见尺寸即时 clamp。
        val x0 = if (rawX < bounds.left || rawX > bounds.right) defaultX else rawX
        val y0 = if (rawY < bounds.top || rawY > bounds.bottom) defaultY else rawY
        val startX = x0.coerceIn(bounds.left, (bounds.right - minVisible).coerceAtLeast(bounds.left))
        val startY = y0.coerceIn(bounds.top, (bounds.bottom - minVisible).coerceAtLeast(bounds.top))

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

        // 视图为 WRAP_CONTENT，真实尺寸布局后才确定：用实测宽高再做一次兜底 clamp 并持久化。
        view.post {
            if (overlayView !== view) return@post
            val current = layoutParams ?: return@post
            val clamped = clampToUsableBounds(current, view.width, view.height) ?: return@post
            if (clamped.first != current.x || clamped.second != current.y) {
                current.x = clamped.first
                current.y = clamped.second
                runCatching { windowManager?.updateViewLayout(view, current) }
                    .onFailure { Log.w(TAG, "悬浮窗位置兜底修正失败（忽略）: ${it.message}") }
                savePosition(clamped.first, clamped.second)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun legacyOverlayType(): Int = WindowManager.LayoutParams.TYPE_PHONE

    /** 屏幕可用区域（物理像素坐标，已剔除系统栏 / 显示刘海）。 */
    private data class UsableBounds(val left: Int, val top: Int, val right: Int, val bottom: Int)

    /**
     * 计算屏幕可用矩形（物理像素坐标）。
     * - API 30+：优先 `WindowManager.currentWindowMetrics`（`bounds` + `windowInsets`）；
     * - 回退（<30，或 insets 不可得如非 Activity context）：用 `displayMetrics` 全屏尺寸
     *   减去系统资源里的状态栏 / 导航栏高度估算。
     * 本窗口带 `FLAG_LAYOUT_NO_LIMITS`，坐标原点为物理左上，故显式加 inset 主动避开状态栏/刘海。
     */
    private fun computeUsableBounds(): UsableBounds {
        val dm = resources.displayMetrics
        val wm = windowManager ?: (getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && wm != null) {
            runCatching {
                val m = wm.currentWindowMetrics
                val b = m.bounds
                val ins = m.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                )
                if (ins.left + ins.top + ins.right + ins.bottom > 0) {
                    return UsableBounds(
                        b.left + ins.left,
                        b.top + ins.top,
                        b.right - ins.right,
                        b.bottom - ins.bottom,
                    )
                }
            }.onFailure { Log.w(TAG, "读取 WindowMetrics/Insets 失败，回退资源估算: ${it.message}") }
        }
        val top = dimenPx("status_bar_height")
        val bottom = (dm.heightPixels - dimenPx("navigation_bar_height")).coerceAtLeast(top + 1)
        return if (bottom > top) UsableBounds(0, top, dm.widthPixels, bottom)
        else UsableBounds(0, 0, dm.widthPixels, dm.heightPixels)
    }

    /** 读取 android 系统 dimension 资源（如 `status_bar_height`）；缺失/失败返回 0。 */
    private fun dimenPx(name: String): Int = runCatching {
        resources.getIdentifier(name, "dimen", "android")
            .takeIf { it > 0 }
            ?.let { resources.getDimensionPixelSize(it) }
            ?: 0
    }.getOrDefault(0)

    /** 把窗口坐标 clamp 回可用区（保证视图完整可见）；视图尺寸未知或区域非法返回 null。 */
    private fun clampToUsableBounds(
        params: WindowManager.LayoutParams,
        viewWidth: Int,
        viewHeight: Int,
    ): Pair<Int, Int>? {
        if (viewWidth <= 0 || viewHeight <= 0) return null
        val b = computeUsableBounds()
        if (b.right <= b.left || b.bottom <= b.top) return null
        val x = params.x.coerceIn(b.left, (b.right - viewWidth).coerceAtLeast(b.left))
        val y = params.y.coerceIn(b.top, (b.bottom - viewHeight).coerceAtLeast(b.top))
        return x to y
    }

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
        private var minX = 0
        private var minY = 0
        private var maxX = 0
        private var maxY = 0
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
                    val b = computeUsableBounds()
                    minX = b.left
                    minY = b.top
                    maxX = (b.right - v.width).coerceAtLeast(b.left)
                    maxY = (b.bottom - v.height).coerceAtLeast(b.top)
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
                        params.x = (startX + dx).toInt().coerceIn(minX, maxX)
                        params.y = (startY + dy).toInt().coerceIn(minY, maxY)
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
        maybeRefreshSystemFps()
        renderOverlayText()
    }

    private fun renderOverlayText() {
        val view = overlayView ?: return
        if (mode == MODE_EXPANDED) {
            view.text = expandedText()
            return
        }
        val cpu = readCpuPercent()
        val mem = readMemoryPercent()
        val batTemp = readBatteryTempC()
        val cpuText = cpu?.let { "${it.roundToInt()}%" } ?: "--"
        val memText = mem?.let { "${it.roundToInt()}%" } ?: "--"
        val batText = batTemp?.let { "${it.roundToInt()}°C" } ?: "--"

        view.text = when (mode) {
            MODE_TARGET -> targetFocusedText()
            MODE_LIVE -> liveFocusedText()
            else -> "CPU $cpuText  MEM $memText  $batText"
        }
    }

    /**
     * 展开模式富 HUD：多段多行（CPU/GPU/BAT/MEM/NET/THM/PROC/STO/FPS + 目标行）。
     * 所有采集只读；缺失段以 `--` 或整体省略优雅降级；目标行沿用 [targetLine]。
     */
    private fun expandedText(): String {
        val cpu = readCpuPercent()
        val mem = readMemoryPercent()
        val bat = readBattery()
        val batTemp = bat?.temperatureC ?: readBatteryTempC()
        val coreCount = readCoreCount()
        val freqs = readPerCoreCpuFreqs()
        val governor = readGovernor()
        val gpu = readGpu()
        val zones = readThermalZones(THERMAL_TOP_N)
        val proc = readProcessStats()
        val storage = readStorage()

        return buildString {
            append("CPU ")
            append(cpu?.let { "${it.roundToInt()}%" } ?: "--")
            if (coreCount > 0) {
                append(" · ${coreCount}核")
                freqBand(freqs)?.let { append(" $it") }
            }
            if (!governor.isNullOrEmpty()) append(" · governor $governor")

            if (gpu != null) {
                append('\n').append("GPU ")
                append(gpu.first?.let { "${it.roundToInt()}MHz" } ?: "--")
                append(" · ")
                append(gpu.second?.let { "${it.roundToInt()}%" } ?: "--")
            }

            val batParts = ArrayList<String>(5)
            bat?.voltageV?.let { batParts.add(String.format(Locale.US, "%.2fV", it)) }
            bat?.currentMa?.let { batParts.add("${it.roundToInt()}mA") }
            bat?.powerW?.let { batParts.add(String.format(Locale.US, "%.1fW", it)) }
            batTemp?.let { batParts.add("${it.roundToInt()}°C") }
            bat?.capacityPercent?.let { batParts.add("健康 ${it.roundToInt()}%") }
            if (batParts.isNotEmpty()) append('\n').append("BAT ").append(batParts.joinToString(" · "))

            append('\n').append("MEM ")
            append(mem?.let { "${it.roundToInt()}%" } ?: "--")

            val net = readNetRateKbs()
            append('\n').append("NET ")
            append(net?.let { "↓${fmt1(it.first)} ↑${fmt1(it.second)} KB/s" } ?: "--")

            if (!zones.isNullOrEmpty()) {
                append('\n').append("THM ").append(zones.joinToString(" · "))
            }

            append('\n').append("PROC ${proc.first} 个")
            proc.second?.let { append(" · 最高 $it") }

            if (!storage.isNullOrEmpty()) {
                append('\n').append("STO ").append(storage.joinToString(" · "))
            }

            systemFps?.let {
                append('\n').append("FPS 屏幕 ${fmt1(it)}")
                systemFpsLayer?.let { layer -> append(" (${shortLayer(layer)})") }
            }

            targetLine()?.let { append('\n').append(it) }
        }
    }

    /** 每核频率区间 `[0.6-2.8GHz]`；无频率数据返回 null。 */
    private fun freqBand(freqs: List<Double>?): String? {
        if (freqs.isNullOrEmpty()) return null
        val min = freqs.minOrNull() ?: return null
        val max = freqs.maxOrNull() ?: return null
        return String.format(Locale.US, "[%.1f-%.1fGHz]", min / 1000.0, max / 1000.0)
    }

    /** 系统帧率层短名：去掉尾部 `#序号`，过长截断。 */
    private fun shortLayer(layer: String): String {
        val clean = layer.substringBefore('#').trim()
        return if (clean.length <= 32) clean else clean.take(31) + "…"
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

    /**
     * 系统帧率刷新节流 + 调度（仅 `expanded` 模式）：每 [SYSTEM_FPS_REFRESH_INTERVAL_MS]
     * 一次、单飞在途，读取投递到 [shizukuThread]（dumpsys 较慢，绝不阻塞主线程），
     * 结果经主线程回写并重渲染。Shizuku 不可用时不读取。
     */
    private fun maybeRefreshSystemFps() {
        if (mode != MODE_EXPANDED) return
        val now = System.currentTimeMillis()
        if (systemFpsPending || now - lastSystemFpsMs < SYSTEM_FPS_REFRESH_INTERVAL_MS) return
        if (!shizukuUsable()) return
        val bgHandler = ensureShizukuHandler() ?: return
        systemFpsPending = true
        lastSystemFpsMs = now
        bgHandler.post {
            val result = runCatching { readSystemFps() }.getOrNull()
            handler.post {
                systemFpsPending = false
                systemFps = result?.first
                systemFpsLayer = result?.second
                systemFpsFrames = result?.third
                if (overlayView != null) renderOverlayText()
            }
        }
    }

    /**
     * 经 Shizuku 读取系统交付帧率（`dumpsys SurfaceFlinger --timestats`）。
     * 首次调用先 best-effort `-enable`；按 `layerName` 分段解析，选层启发式与 WS1 一致：
     * 剔黑名单 → 优先含 `SurfaceView`/`BLAST` → 并列取 `totalFrames` 最大。
     * 返回 (averageFPS, layer, totalFrames)；无层 / 失败 → null。绝不抛。
     */
    private fun readSystemFps(): Triple<Double?, String?, Int?>? {
        if (!shizukuUsable()) return null
        if (!systemFpsEnabled) {
            execShizuku("dumpsys SurfaceFlinger --timestats -enable")
            systemFpsEnabled = true
        }
        val output = execShizuku(
            "dumpsys SurfaceFlinger --timestats -dump -clear -maxlayers 32"
        ) ?: return null
        val matches = SYSTEM_FPS_LAYER_RE.findAll(output).toList()
        if (matches.isEmpty()) return null

        data class Layer(val name: String, val fps: Double?, val frames: Int?)
        val layers = ArrayList<Layer>(matches.size)
        for ((idx, m) in matches.withIndex()) {
            val start = m.range.first
            val end = if (idx + 1 < matches.size) matches[idx + 1].range.first else output.length
            val segment = output.substring(start, end)
            val name = m.groupValues[1].trim()
            if (name.isEmpty()) continue
            val fps = SYSTEM_FPS_AVG_RE.find(segment)?.groupValues?.get(1)?.toDoubleOrNull()
            val frames = SYSTEM_FPS_FRAMES_RE.find(segment)?.groupValues?.get(1)?.toIntOrNull()
            layers.add(Layer(name, fps, frames))
        }
        if (layers.isEmpty()) return null

        val filtered = layers.filter { l -> SYSTEM_FPS_BLACKLIST.none { l.name.contains(it) } }
        val candidates = filtered.ifEmpty { layers }
        val preferred = candidates.filter { it.name.contains("SurfaceView") || it.name.contains("BLAST") }
        val pool = preferred.ifEmpty { candidates }
        val best = pool.maxByOrNull { it.frames ?: 0 } ?: return null
        return Triple(best.fps, best.name, best.frames)
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
     * `/proc/net/dev` 累计 rx/tx 字节 → 与上次采样的差值换算 KB/s。
     * 对齐 Rust `network.rs`：**包含全部接口（不跳过 `lo`）**，内部速率为 bytes/s，展示时 ÷1024
     * 转 KB/s。首次采样只建立基线（返回 null，显示 `--`）；计数回退用 `coerceAtLeast(0)` 防回绕。
     */
    private fun readNetRateKbs(): Pair<Double, Double>? {
        val lines = runCatching { File("/proc/net/dev").readLines() }.getOrNull() ?: return null
        var rx = 0L
        var tx = 0L
        var found = false
        for (line in lines) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
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

    /**
     * `/proc/stat` 首行差值 → CPU 占用百分比；首次采样仅建基线返回 null。
     * 对齐 Rust `cpu.rs`：`total = Σfields[1..]`，`idle = fields[4]`（**仅 idle 列，不含 iowait**），
     * `usage% = 100 - Δidle*100/Δtotal`。由调用方保存基线取增量，绝不 sleep。
     */
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
            if (i == 4) idle += value // 仅 idle（对齐 Rust fields[4]；不计 iowait）
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

    /**
     * 电池温度（℃）：sysfs 优先，回退 BatteryManager；均不可用返回 null。
     * 对齐 Rust `battery.rs`：属性顺序 `temp` → `temperature`，**恒 ÷10**（十分之一摄氏度）。
     */
    private fun readBatteryTempC(): Double? {
        val paths = listOf(
            "/sys/class/power_supply/battery/temp",
            "/sys/class/power_supply/bms/temp",
            "/sys/class/power_supply/battery/temperature",
            "/sys/class/power_supply/bms/temperature",
        )
        for (path in paths) {
            val raw = runCatching { File(path).readText().trim().toDouble() }.getOrNull()
                ?: continue
            return raw / 10.0
        }
        val intent = runCatching {
            registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull() ?: return null
        val tenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        if (tenths == Int.MIN_VALUE) return null
        return tenths / 10.0
    }

    // ---------------------------------------------------------------------
    // 扩展只读采集（对齐 Rust gstore_mod_perf；任一失败返回 null，绝不抛）
    // ---------------------------------------------------------------------

    /** 读取 sysfs/proc 文本并 trim；空 / 不存在返回 null。 */
    private fun readSysTrim(path: String): String? =
        runCatching { File(path).readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() }

    /** 首 token 解析为 Double；无数字返回 null。 */
    private fun firstTokenDouble(text: String): Double? =
        text.trim().split(Regex("\\s+")).firstOrNull()?.toDoubleOrNull()

    /** 首 token 解析为 Long；无数字返回 null。 */
    private fun firstTokenLong(text: String): Long? =
        text.trim().split(Regex("\\s+")).firstOrNull()?.toLongOrNull()

    /** `/proc/stat` 中 `cpuN` 行数（物理/逻辑核数）；读取失败返回 0。 */
    private fun readCoreCount(): Int {
        val lines = runCatching { File("/proc/stat").readLines() }.getOrNull() ?: return 0
        var count = 0
        for (line in lines) {
            if (line.length > 3 && line.startsWith("cpu") && line[3].isDigit()) count++
        }
        return count
    }

    /** `/proc/cpuinfo` 的 `cpu MHz` 列表（x86 常见；ARM 通常为空）。 */
    private fun readCpuinfoMhzList(): List<Double> {
        val lines = runCatching { File("/proc/cpuinfo").readLines() }.getOrNull() ?: return emptyList()
        val out = ArrayList<Double>()
        for (line in lines) {
            val trimmed = line.trim()
            if (!trimmed.startsWith("cpu MHz")) continue
            val value = trimmed.substringAfter(':', "").trim().toDoubleOrNull() ?: continue
            out.add(value)
        }
        return out
    }

    /**
     * 每核当前频率（MHz）：`scaling_cur_freq`（kHz）→ `cpuinfo_cur_freq` → `/proc/cpuinfo` `cpu MHz`。
     * 无任何可读频率返回 null（对齐 Rust `cpu.rs::core_freq_mhz`）。
     */
    private fun readPerCoreCpuFreqs(): List<Double>? {
        val coreCount = readCoreCount()
        if (coreCount <= 0) return null
        val cpuinfoMhz = readCpuinfoMhzList()
        val out = ArrayList<Double>(coreCount)
        for (i in 0 until coreCount) {
            val base = "/sys/devices/system/cpu/cpu$i/cpufreq"
            val khz = readSysTrim("$base/scaling_cur_freq")?.toLongOrNull()
                ?: readSysTrim("$base/cpuinfo_cur_freq")?.toLongOrNull()
            if (khz != null) {
                out.add(khz / 1000.0)
            } else {
                cpuinfoMhz.getOrNull(i)?.let { out.add(it) }
            }
        }
        return out.ifEmpty { null }
    }

    /** cpu0 当前调度器（`scaling_governor`）；缺失返回 null。 */
    private fun readGovernor(): String? =
        readSysTrim("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")

    /**
     * GPU（频率 MHz, 忙率 %）。频率按 [GPU_FREQ_PATHS] 回退并启发式缩放；
     * 忙率按 [GPU_BUSY_PATHS] 回退（去尾部 `%`、clamp 0..100）。两者皆无 → null。
     */
    private fun readGpu(): Pair<Double?, Double?>? {
        var freq: Double? = null
        for (path in GPU_FREQ_PATHS) {
            val raw = readSysTrim(path) ?: continue
            val v = firstTokenDouble(raw) ?: continue
            freq = when {
                v > 1_000_000.0 -> v / 1_000_000.0
                v > 1000.0 -> v / 1000.0
                else -> v
            }
            break
        }
        var busy: Double? = null
        for (path in GPU_BUSY_PATHS) {
            val raw = readSysTrim(path) ?: continue
            val token = raw.split(Regex("\\s+")).firstOrNull()?.removeSuffix("%") ?: continue
            val percent = token.toDoubleOrNull() ?: continue
            busy = percent.coerceIn(0.0, 100.0)
            break
        }
        if (freq == null && busy == null) return null
        return freq to busy
    }

    /**
     * 电池基准目录：优先 `/sys/class/power_supply/battery`，否则排序后首个电源子目录。
     * 无电源目录返回 null（对齐 Rust `battery.rs::pick_base`）。
     */
    private fun batteryBasePath(): String? {
        val preferred = File("/sys/class/power_supply/battery")
        if (preferred.isDirectory) return preferred.absolutePath
        val dirs = runCatching {
            File("/sys/class/power_supply").listFiles { f -> f.isDirectory }
        }.getOrNull() ?: return null
        return dirs.map { it.absolutePath }.sorted().firstOrNull()
    }

    /**
     * 电池扩展读数（对齐 Rust `battery.rs`）：电压 `|v|>1e6→/1e6`、`|v|>1000→/1000`；
     * 电流 `current_now`→`batt_current`→`batt_current_now`→`current_avg`，仅 `|raw|>10000` ÷1000；
     * 功率 W = V × mA / 1000；温度 `temp`→`temperature` 恒 ÷10；健康含容量% / 满充 / 循环 / 状态。
     * 无电池返回 null。
     */
    private fun readBattery(): BatteryInfo? {
        val base = batteryBasePath() ?: return null

        fun attr(vararg names: String): String? {
            for (name in names) readSysTrim("$base/$name")?.let { return it }
            return null
        }

        val voltageRaw = attr("voltage_now")?.let { firstTokenDouble(it) }
        val voltageV = voltageRaw?.let {
            val a = abs(it)
            when {
                a > 1_000_000.0 -> it / 1_000_000.0
                a > 1000.0 -> it / 1000.0
                else -> it
            }
        }
        val currentRaw = attr("current_now", "batt_current", "batt_current_now", "current_avg")
            ?.let { firstTokenDouble(it) }
        val currentMa = currentRaw?.let { if (abs(it) > 10_000.0) it / 1000.0 else it }
        val tempRaw = attr("temp", "temperature")?.let { firstTokenDouble(it) }
        val temperatureC = tempRaw?.let { it / 10.0 }
        val powerW = if (voltageV != null && currentMa != null) {
            voltageV * currentMa / 1000.0
        } else {
            null
        }

        val info = BatteryInfo(
            voltageV = voltageV,
            currentMa = currentMa,
            powerW = powerW,
            temperatureC = temperatureC,
            capacityPercent = attr("capacity")?.let { firstTokenDouble(it) }?.coerceIn(0.0, 100.0),
            chargeFullUah = attr("charge_full", "charge_full_design")?.let { firstTokenLong(it) },
            chargeFullDesignUah = attr("charge_full_design")?.let { firstTokenLong(it) },
            cycleCount = attr("cycle_count")?.let { firstTokenLong(it) },
            status = attr("status"),
            health = attr("health"),
        )
        val allNull = info.voltageV == null && info.currentMa == null &&
            info.powerW == null && info.temperatureC == null &&
            info.capacityPercent == null && info.chargeFullUah == null &&
            info.chargeFullDesignUah == null && info.cycleCount == null &&
            info.status == null && info.health == null
        return if (allNull) null else info
    }

    /**
     * 各热区温度 Top-N（默认 3）：枚举 thermal_zoneN 的 temp 与 hwmonN 的 tempM_input，
     * `|raw|>1000 → ÷1000`，按温度降序取前 N，每项 `名称 45.3°C`。无热区返回 null。
     */
    private fun readThermalZones(topN: Int = THERMAL_TOP_N): List<String>? {
        val entries = ArrayList<Pair<String, Double>>()

        val thermalRoot = File("/sys/class/thermal")
        runCatching {
            thermalRoot.listFiles { f -> f.name.startsWith("thermal_zone") }
        }.getOrNull()?.forEach { zone ->
            val raw = readSysTrim("${zone.absolutePath}/temp")?.let { firstTokenDouble(it) }
                ?: return@forEach
            val celsius = if (abs(raw) > 1000.0) raw / 1000.0 else raw
            val label = readSysTrim("${zone.absolutePath}/type") ?: zone.name
            entries.add(label to celsius)
        }

        val hwmonRoot = File("/sys/class/hwmon")
        runCatching {
            hwmonRoot.listFiles { f -> f.isDirectory && f.name.startsWith("hwmon") }
        }.getOrNull()?.forEach { hw ->
            val hwName = readSysTrim("${hw.absolutePath}/name")
            runCatching {
                hw.listFiles { f -> f.name.startsWith("temp") && f.name.endsWith("_input") }
            }.getOrNull()?.forEach { input ->
                val raw = readSysTrim(input.absolutePath)?.let { firstTokenDouble(it) }
                    ?: return@forEach
                val celsius = if (abs(raw) > 1000.0) raw / 1000.0 else raw
                val label = hwName ?: "${hw.name}/${input.name}"
                entries.add(label to celsius)
            }
        }

        if (entries.isEmpty()) return null
        return entries.sortedByDescending { it.second }.take(topN)
            .map { "${it.first} ${fmt1(it.second)}°C" }
    }

    /**
     * (进程总数, CPU 最高进程行)。进程数 = `/proc` 下数字目录数；CPU% 由各 pid
     * `/proc/<pid>/stat` 的 utime+stime（split 后 [11]+[12]）与上次基线取 Δticks/Δs/CLK_TCK。
     * 首轮无基线 → 只返回计数 + null（绝不 sleep）。对齐 Rust `processes.rs`。
     */
    private fun readProcessStats(): Pair<Int, String?> {
        val dirs = runCatching {
            File("/proc").listFiles { f -> f.isDirectory && f.name.all { it.isDigit() } }
        }.getOrNull() ?: return 0 to null

        val now = System.currentTimeMillis()
        val hasBaseline = lastProcBaselineMs != 0L && lastProcBaseline.isNotEmpty()
        val dtSec = if (hasBaseline) (now - lastProcBaselineMs).coerceAtLeast(1L) / 1000.0 else 0.0
        val newBaseline = HashMap<Int, Long>(dirs.size)

        var topName: String? = null
        var topPercent = -1.0
        for (dir in dirs) {
            val pid = dir.name.toIntOrNull() ?: continue
            val stat = runCatching { File(dir, "stat").readText() }.getOrNull() ?: continue
            val open = stat.indexOf('(')
            val close = stat.lastIndexOf(')')
            if (open < 0 || close <= open) continue
            val comm = stat.substring(open + 1, close)
            val fields = stat.substring(close + 1).trim().split(Regex("\\s+"))
            val utime = fields.getOrNull(11)?.toLongOrNull() ?: continue
            val stime = fields.getOrNull(12)?.toLongOrNull() ?: continue
            val ticks = utime + stime
            newBaseline[pid] = ticks
            if (!hasBaseline || dtSec <= 0.0) continue
            val prev = lastProcBaseline[pid] ?: continue
            val delta = (ticks - prev).coerceAtLeast(0L)
            val percent = delta.toDouble() / CLK_TCK / dtSec * 100.0
            if (percent > topPercent) {
                topPercent = percent
                topName = comm
            }
        }

        lastProcBaseline = newBaseline
        lastProcBaselineMs = now
        val topLine = topName?.let { "$it ${fmt1(topPercent)}%" }
        return dirs.size to topLine
    }

    /**
     * 存储占用：`/proc/mounts` 真实 fs（[REAL_FS_TYPES]）中只报 `/` 与 `/data`（存在时），
     * `android.system.Os.statvfs` 取块数（`frsize=f_frsize>0?:f_bsize`，`used=f_blocks-f_bfree`），
     * 行如 `/data 62% (128.5G/208.3G)`。对齐 Rust `storage.rs`。无匹配返回 null。
     */
    private fun readStorage(): List<String>? {
        val lines = runCatching { File("/proc/mounts").readLines() }.getOrNull() ?: return null
        val wanted = LinkedHashSet<String>()
        for (line in lines) {
            val cols = line.trim().split(Regex("\\s+"))
            if (cols.size < 3) continue
            if (cols[2] !in REAL_FS_TYPES) continue
            val mount = unescapeMount(cols[1])
            if (mount == "/" || mount == "/data") wanted.add(mount)
        }
        if (wanted.isEmpty()) return null

        val out = ArrayList<String>(wanted.size)
        for (mount in wanted) {
            val vfs = runCatching { Os.statvfs(mount) }.getOrNull() ?: continue
            val frsize = if (vfs.f_frsize > 0L) vfs.f_frsize else vfs.f_bsize
            if (frsize <= 0L) continue
            val totalKb = vfs.f_blocks * frsize / 1024L
            if (totalKb <= 0L) continue
            val usedKb = (vfs.f_blocks - vfs.f_bfree) * frsize / 1024L
            val usedPct = (usedKb * 100.0 / totalKb).coerceIn(0.0, 100.0)
            out.add("$mount ${usedPct.roundToInt()}% (${humanKb(usedKb)}/${humanKb(totalKb)})")
        }
        return out.ifEmpty { null }
    }

    /** `/proc/mounts` 八进制转义反转义（`\040` 空格等）；非转义原样保留。 */
    private fun unescapeMount(s: String): String {
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 3 < s.length) {
                val oct = s.substring(i + 1, i + 4)
                if (oct.all { it in '0'..'7' }) {
                    out.append(oct.toInt(8).toChar())
                    i += 4
                    continue
                }
            }
            out.append(c)
            i++
        }
        return out.toString()
    }

    /** KiB → 人类可读（`128.5G` / `512M` / `800K`）。 */
    private fun humanKb(kb: Long): String = when {
        kb >= 1024L * 1024L -> String.format(Locale.US, "%.1fG", kb / 1024.0 / 1024.0)
        kb >= 1024L -> "${kb / 1024}M"
        else -> "${kb}K"
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
        foregroundPending = false
        systemFpsPending = false
        lastProcBaseline.clear()
        lastProcBaselineMs = 0L
        systemFps = null
        systemFpsLayer = null
        systemFpsFrames = null
        lastSystemFpsMs = 0L
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
