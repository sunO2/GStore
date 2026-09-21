package com.suno2.gstore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * GStore 内置代理的 TUN 承载服务（greenfield）。
 *
 * ## 职责边界
 * 本服务**只负责 Android 侧的 TUN 生命周期**：请求/建立 TUN、把它交给 Rust
 * 宿主、作为前台服务存活、并在拆除时释放 fd。所有网络/解析/路由逻辑都在 Rust
 * （`gstore_mod_proxy` 模块）。本类不读取 TUN 数据。
 *
 * ## 进程模型（钉死：与 App 同进程）
 * 不声明 `android:process`。Rust 引擎、`gstore_mod_proxy` 模块与宿主
 * `libgstore_host.so` 的 JNI 静态状态都活在 Flutter 主进程；把本服务放进
 * `:vpn` 独立进程会得到第二份宿主状态，fd 与 protect 桥将无法与引擎对接。
 * 因此与 `flutter_foreground_task` 的 dataSync 服务共存于同一进程。
 *
 * ## 两个前台服务共存
 * App 已运行 `flutter_foreground_task`（`dataSync`）。本服务是独立的第二个前台
 * 服务，使用 `FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED`（Android 14 的 VPN 适用
 * 类型；系统没有 `FOREGROUND_SERVICE_TYPE_VPN`），manifest 声明匹配的
 * `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` 权限。两者类型/权限互不相同，可并存。
 * 备选 `specialUse` 需要额外 `<property ...PROPERTY_SPECIAL_USE_FGS_SUBTYPE>`，
 * 是更差的回退，故不采用。
 *
 * ## 隧道路由模式（产品决策）
 * - `full`（默认）：不调用 addAllowed/addDisallowed；全设备流量入隧道。此时 App
 *   自身的出站 socket **也会**被捕获，必须靠 `protect_fd` -> `VpnService.protect`
 *   放行（防路由环路）。**不使用 `addDisallowedApplication(self)` 修环路。**
 * - `allow`：仅白名单 App 入隧道（`addAllowedApplication`）。
 * - `disallow`：黑名单 App 绕过，其余入隧道（`addDisallowedApplication`）。
 * allow 与 disallow 互斥，不能混用。
 *
 * ## always-on
 * 服务声明 `SUPPORTS_ALWAYS_ON`；用户开启系统"始终开启的 VPN"后由**系统**在开机
 * 后重启本服务（传入 null Intent），因此不申请 `RECEIVE_BOOT_COMPLETED`、也不写
 * 重启广播接收器——广播无法在无用户同意时启动 VPN，且系统 always-on 框架已覆盖。
 * 为支持 null-Intent 重启，配置 JSON 会持久化到 SharedPreferences。
 *
 * ## fd 所有权规则（钉死）
 * - Kotlin 持有 `ParcelFileDescriptor` 作为唯一所有者；**不** detachFd，只把
 *   `pfd.fd` 的原始整数交给 Rust。
 * - Rust 只读该 fd；如需独立生命周期必须 `dup()`，并自行设置 `O_NONBLOCK`；
 *   永不 close Kotlin 的 fd。
 * - 拆除顺序：模块停止读取循环 → join 线程 → 宿主 `nativeClear()` → Kotlin 关闭
 *   `ParcelFileDescriptor`。本类在 `stopVpn()` 里先 `nativeClear()` 再 `close()`。
 */
class ProxyVpnService : VpnService() {

    companion object {
        private const val TAG = "ProxyVpnService"
        private const val CHANNEL_ID = "gstore_proxy_vpn"
        private const val NOTIFICATION_ID = 0x5650

        const val ACTION_START = "com.suno2.gstore.proxy.vpn.START"
        const val ACTION_STOP = "com.suno2.gstore.proxy.vpn.STOP"
        const val EXTRA_CONFIG = "config"

        private const val PREFS = "gstore_proxy_vpn"
        private const val KEY_CONFIG = "config"

        @Volatile
        var isRunning: Boolean = false
            private set

        init {
            System.loadLibrary("gstore_host")
        }

        /** 缓存 VpnService 实例并安装 protect 实现（JNI 名见 Rust `jni_bridge.rs`）。 */
        @JvmStatic
        external fun nativeSetService(service: VpnService)

        /** 把 TUN fd 原始整数交给宿主（Kotlin 仍持有 ParcelFileDescriptor）。 */
        @JvmStatic
        external fun nativeSetTunFd(fd: Int)

        /** 清空宿主缓存的服务引用与 fd（不关闭 fd；Kotlin 随后自行关闭）。 */
        @JvmStatic
        external fun nativeClear()

        /** 启动流程：持久化配置并以前台服务拉起（调用前须已获得 VPN 同意）。 */
        fun start(context: Context, configJson: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_CONFIG, configJson).apply()
            val intent = Intent(context, ProxyVpnService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, configJson)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ProxyVpnService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    private var conn: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }

        // always-on / 系统重启会传 null Intent：回退到持久化配置。
        val configJson = intent?.getStringExtra(EXTRA_CONFIG)
            ?: getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_CONFIG, null)
        if (configJson.isNullOrEmpty()) {
            Log.w(TAG, "无配置，停止服务")
            // 仍须先进入前台：本服务可能经 startForegroundService 拉起，5s 内
            // 未调用 startForeground 会触发系统崩溃。
            startForegroundCompat()
            stopVpn()
            return START_NOT_STICKY
        }

        // 必须在 5s 内进入前台；先于 establish 调用。
        startForegroundCompat()

        try {
            startVpn(configJson)
            isRunning = true
        } catch (t: Throwable) {
            Log.e(TAG, "启动 VPN 失败: ${t.message}", t)
            stopVpn()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /** 另一个 VPN 抢占了 VPN 权限时系统回调（API 28-）。 */
    override fun onRevoke() {
        Log.i(TAG, "onRevoke: VPN 权限被撤销")
        stopVpn()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    private fun startVpn(configJson: String) {
        val cfg = parseConfig(configJson)

        // 1. 先缓存服务引用并安装 protect：保证 establish() 之后 Rust 打开的每个
        //    出站 socket 都已在 protect seam 之上。
        nativeSetService(this)

        val builder = Builder()
            .setSession(cfg.session)
            .setMtu(cfg.mtu)
        for ((ip, prefix) in cfg.addresses) builder.addAddress(ip, prefix)
        for ((ip, prefix) in cfg.routes) builder.addRoute(ip, prefix)
        for (dns in cfg.dns) builder.addDnsServer(dns)

        when (cfg.mode) {
            "allow" -> for (pkg in cfg.allowList) {
                runCatching { builder.addAllowedApplication(pkg) }
            }
            "disallow" -> for (pkg in cfg.disallowList) {
                runCatching { builder.addDisallowedApplication(pkg) }
            }
            else -> Unit // full tunnel：靠 protect_fd 防环路，见类文档
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(cfg.metered)
        }

        // setBlocking 不显式设置：Rust 侧会 set O_NONBLOCK（Todo 6）。
        // setUnderlyingNetworks 保持默认（系统默认网络）。
        val pfd = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() 返回 null")

        conn = pfd
        // 2. 只传原始 fd；Kotlin 继续持有 ParcelFileDescriptor。
        nativeSetTunFd(pfd.fd)
        Log.i(TAG, "VPN 已建立: session=${cfg.session} mtu=${cfg.mtu} fd=${pfd.fd}")
    }

    private fun stopVpn() {
        // 拆除顺序：宿主 nativeClear（通知模块可安全停止）→ Kotlin 关闭 fd。
        // Todo 6 的读取循环必须在此前已停止；此刻本类不 close 正在被 Rust 读取的 fd。
        runCatching { nativeClear() }
        runCatching { conn?.close() }
        conn = null
        isRunning = false
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
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
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
            getString(R.string.proxy_vpn_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        channel.description = getString(R.string.proxy_vpn_channel_desc)
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
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(getString(R.string.proxy_vpn_notification_title))
            .setContentText(getString(R.string.proxy_vpn_notification_text))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
    }

    // ---------------------------------------------------------------------
    // 配置
    // ---------------------------------------------------------------------

    private data class VpnConfig(
        val addresses: List<Pair<String, Int>>,
        val routes: List<Pair<String, Int>>,
        val dns: List<String>,
        val mtu: Int,
        val session: String,
        val mode: String,
        val allowList: List<String>,
        val disallowList: List<String>,
        val metered: Boolean,
    )

    private fun parseConfig(json: String): VpnConfig {
        val obj = JSONObject(json)
        val addresses = parseCidrs(obj.optJSONArray("addresses"))
            .ifEmpty { listOf("10.10.0.2" to 32, "fd00:1:fd00:1:fd00:1:fd00:1:fd00:1" to 128) }
        val routes = parseCidrs(obj.optJSONArray("routes"))
            .ifEmpty { listOf("0.0.0.0" to 0, "::" to 0) }
        val dns = parseStrings(obj.optJSONArray("dns"))
        val mode = obj.optString("mode", "full")
        return VpnConfig(
            addresses = addresses,
            routes = routes,
            dns = dns,
            mtu = obj.optInt("mtu", DEFAULT_MTU),
            session = obj.optString("session", "GStore Proxy"),
            mode = mode,
            allowList = parseStrings(obj.optJSONArray("allowedApps")),
            disallowList = parseStrings(obj.optJSONArray("disallowedApps")),
            metered = obj.optBoolean("metered", false),
        )
    }

    private fun parseCidrs(array: JSONArray?): List<Pair<String, Int>> {
        if (array == null) return emptyList()
        val out = ArrayList<Pair<String, Int>>(array.length())
        for (i in 0 until array.length()) {
            val entry = array.optString(i, "")
            val slash = entry.indexOf('/')
            if (slash <= 0) continue
            val ip = entry.substring(0, slash)
            val prefix = entry.substring(slash + 1).toIntOrNull() ?: continue
            out.add(ip to prefix)
        }
        return out
    }

    private fun parseStrings(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        val out = ArrayList<String>(array.length())
        for (i in 0 until array.length()) {
            val value = array.optString(i, "")
            if (value.isNotEmpty()) out.add(value)
        }
        return out
    }

    private val DEFAULT_MTU = 1500
}
