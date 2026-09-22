package com.suno2.gstore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

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

        /**
         * TUN fd 是否已真正交给 Rust 宿主（`nativeSetTunFd` 之后）。
         *
         * [isRunning] 在 `startVpn` **之前**就置 true（enter foreground 后立即），
         * 而 fd 要等 `establish()` + `nativeSetTunFd()` 才安装，因此**不能**用
         * `isRunning` 判断 fd 是否就绪。`core.start(mode=vpn)` 要求宿主已有
         * pending fd（否则 422 PROXY_TUN_FD_INVALID），Dart 侧 `prepare` 必须等本
         * 标志为 true 才能放行到 `coreStart`。@Volatile 保证跨线程可见。
         */
        @Volatile
        var tunFdInstalled: Boolean = false
            private set

        /** 最近一次启动来源：`user` / `always_on`（进程死亡后系统重启）。 */
        @Volatile
        var lastStartReason: String = "user"
            private set

        /** always-on / 系统重启累计次数（诊断用）。 */
        @Volatile
        var restartCount: Int = 0
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

        /** 上报生命周期事件（revoked / network_changed / start_failed / always_on_restart）。 */
        @JvmStatic
        external fun nativeVpnEvent(kind: String, detail: String)

        /**
         * Kotlin 主动拆除：广播 `vpn.stop` → 有界等待模块 `proxy.tun.released`
         * （停循环 → join → 宿主清缓存）→ 之后 Kotlin 才能安全关闭 fd。
         */
        @JvmStatic
        external fun nativeStopTunnel()

        /** 打开系统「VPN」设置，引导用户开启「始终开启的 VPN」。 */
        fun openAlwaysOnSettings(context: Context) {
            val intent = Intent(Settings.ACTION_VPN_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(intent) }
        }

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
            // Android 8+ 后台启动限制：应用不在前台时 startService 可能抛
            // IllegalStateException（API 31+ 为 BackgroundServiceStartNotAllowedException），
            // 旧版本也可能静默返回 null。ACTION_STOP 拆除是尽力而为，绝不能因此崩溃调用方。
            //
            // 首选经 onStartCommand 投递 ACTION_STOP（保留 user_stop 语义）；不可用时
            // 回退 stopService()——停止服务不受后台启动限制，会直接触发 onDestroy()
            // → stopVpn()，同样完成 TUN 释放。已停止时 stopService 返回 false，无副作用。
            val started = runCatching { context.startService(intent) }
                .onFailure {
                    Log.w(TAG, "ACTION_STOP startService 失败，回退 stopService: ${it.message}")
                }
                .getOrNull()
            if (started == null) {
                val stopped = runCatching { context.stopService(intent) }
                    .onFailure { Log.w(TAG, "stopService 回退失败（忽略）: ${it.message}") }
                    .getOrDefault(false)
                Log.i(TAG, "stop 经 stopService 回退，stopped=$stopped")
            }
        }
    }

    private var conn: ParcelFileDescriptor? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * 拆除幂等守卫：同一生命周期内只真正拆除一次。用户连点断开、ACTION_STOP 之后
     * 系统紧跟的 onDestroy() 都不会重复调用 nativeStopTunnel()/stopForeground()。
     * [startVpn] 每次启动重置为 `false`。
     */
    @Volatile
    private var tornDown = false

    /**
     * 拆除工作线程：`nativeStopTunnel()` 在宿主侧有界等待 ≤800ms（停循环→join），
     * 直接在主线程调用会造成明显卡顿/潜在 ANR。所有 native 拆除与 fd close 都
     * 放到单线程执行器串行执行，绝不阻塞 main。
     */
    private val teardownExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "gstore-vpn-teardown")
    }

    /** 生命周期代数：每次 start 递增，用于丢弃被新一轮 start 取代的过期拆除。 */
    private val lifecycleGen = AtomicInteger(0)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopVpn("user_stop")
            return START_NOT_STICKY
        }

        // always-on / 系统重启会传 null Intent：回退到持久化配置。
        val explicitConfig = intent?.getStringExtra(EXTRA_CONFIG)
        val configJson = explicitConfig
            ?: getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_CONFIG, null)
        if (configJson.isNullOrEmpty()) {
            Log.w(TAG, "无配置，停止服务")
            // 仍须先进入前台：本服务可能经 startForegroundService 拉起，5s 内
            // 未调用 startForeground 会触发系统崩溃。
            startForegroundCompat()
            runCatching { nativeVpnEvent("start_failed", "no persisted config available") }
            stopVpn("no_config")
            return START_NOT_STICKY
        }

        // 已在运行：仅确保前台存活，绝不重复 establish（否则旧 PFD 泄漏）。
        if (isRunning && conn != null) {
            startForegroundCompat()
            Log.i(TAG, "已在运行，忽略重复启动")
            return START_STICKY
        }

        // 必须在 5s 内进入前台；先于 establish 调用。
        startForegroundCompat()

        if (explicitConfig == null) {
            lastStartReason = "always_on"
            restartCount += 1
            runCatching {
                nativeVpnEvent("always_on_restart", "null-intent restart #$restartCount")
            }
        } else {
            lastStartReason = "user"
        }

        try {
            startVpn(configJson)
            isRunning = true
        } catch (t: Throwable) {
            Log.e(TAG, "启动 VPN 失败: ${t.message}", t)
            runCatching { nativeVpnEvent("start_failed", t.message ?: t.toString()) }
            stopVpn("start_failed")
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /** 另一个 VPN 抢占了 VPN 权限时系统回调（API 28-）。 */
    override fun onRevoke() {
        Log.i(TAG, "onRevoke: VPN 权限被撤销")
        runCatching { nativeVpnEvent("revoked", "VPN permission revoked") }
        stopVpn("revoked")
        super.onRevoke()
    }

    override fun onDestroy() {
        stopVpn("on_destroy")
        super.onDestroy()
    }

    private fun startVpn(configJson: String) {
        val cfg = parseConfig(configJson)
        // 新一轮启动：使任何仍在执行的旧拆除失效。
        lifecycleGen.incrementAndGet()
        // 新一轮启动：解除拆除幂等守卫，允许后续 stop。
        tornDown = false
        // 新一轮启动：fd 尚未安装，等待方必须看到 false 直到 nativeSetTunFd 返回。
        tunFdInstalled = false

        // 1. 先缓存服务引用并安装 protect：保证 establish() 之后 Rust 打开的每个
        //    出站 socket 都已在 protect seam 之上。
        nativeSetService(this)

        val builder = Builder()
            .setSession(cfg.session)
            .setMtu(cfg.mtu)
        if (cfg.addresses.isEmpty()) {
            throw IllegalStateException("VpnService 配置未提供任何有效地址（addresses 为空或全部非法）")
        }
        for ((ip, prefix) in cfg.addresses) {
            runCatching { builder.addAddress(ip, prefix) }
                .onFailure { Log.w(TAG, "addAddress 失败，跳过 $ip/$prefix: ${it.message}") }
        }
        for ((ip, prefix) in cfg.routes) {
            runCatching { builder.addRoute(ip, prefix) }
                .onFailure { Log.w(TAG, "addRoute 失败，跳过 $ip/$prefix: ${it.message}") }
        }
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
        // nativeSetTunFd 返回后宿主已持有 pending fd，core.start(vpn) 才可成功。
        tunFdInstalled = true
        registerNetworkCallback()
        Log.i(TAG, "VPN 已建立: session=${cfg.session} mtu=${cfg.mtu} fd=${pfd.fd}")
    }

    /**
     * 底层网络变化（Wi-Fi↔蜂窝、飞行模式切换）：`setUnderlyingNetworks(null)`
     * 让接口重新跟随系统默认网络（重建默认接口），无需重建隧道或重读 fd。
     * 事件驱动，无轮询、无重试循环。
     */
    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetworkChanged("available")
            override fun onLost(network: Network) = onNetworkChanged("lost")
        }
        runCatching { cm.registerDefaultNetworkCallback(callback) }
            .onSuccess { networkCallback = callback }
    }

    private fun unregisterNetworkCallback() {
        val callback = networkCallback ?: return
        networkCallback = null
        runCatching {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(callback)
        }
    }

    private fun onNetworkChanged(event: String) {
        runCatching { setUnderlyingNetworks(null) }
        runCatching { nativeVpnEvent("network_changed", event) }
        Log.i(TAG, "底层网络变化($event)：已重建默认接口")
    }

    private fun stopVpn(reason: String) {
        // 幂等：ACTION_STOP → onDestroy 常成对到达；已拆除时后续 stop 为 no-op，
        // 避免重复 nativeStopTunnel()/stopForeground()。startVpn 会重置该标志。
        if (tornDown) {
            Log.i(TAG, "已拆除，忽略重复 stop：$reason")
            return
        }
        tornDown = true
        unregisterNetworkCallback()
        isRunning = false
        // fd 随拆除失效：等待方不得再认为 fd 可用。
        tunFdInstalled = false
        val gen = lifecycleGen.get()
        val pfd = conn
        conn = null
        // 拆除顺序：广播 vpn.stop → 模块停循环并 join → 宿主清缓存（有界等待
        // proxy.tun.released）→ Kotlin 关闭 fd。全部放到工作线程，main 线程
        // 立即返回（避免 ≤800ms 阻塞造成卡顿/ANR）。gen 守卫确保：若期间已发生
        // 新一轮 start，则不再对新的宿主状态调用 nativeStopTunnel。
        teardownExecutor.execute {
            if (gen == lifecycleGen.get()) {
                runCatching { nativeStopTunnel() }
            }
            runCatching { pfd?.close() }
            Log.i(TAG, "VPN 已停止：$reason")
        }
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
            Intent(this, ProxyVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopAction = Notification.Action.Builder(
            0,
            getString(R.string.proxy_vpn_notification_action_stop),
            stopIntent
        ).build()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setContentTitle(getString(R.string.proxy_vpn_notification_title))
            .setContentText(getString(R.string.proxy_vpn_notification_text))
            .setSubText(getString(R.string.proxy_vpn_notification_subtext))
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
            .ifEmpty { DEFAULT_ADDRESSES }
        val routes = parseCidrs(obj.optJSONArray("routes"))
            .ifEmpty { DEFAULT_ROUTES }
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
            val cidr = parseCidr(entry)
            if (cidr == null) {
                // 非法 CIDR 会令 Builder.addAddress/addRoute 抛
                // IllegalArgumentException；此处过滤掉，绝不让坏配置崩溃服务。
                Log.w(TAG, "忽略非法 CIDR: $entry")
                continue
            }
            out.add(cidr)
        }
        return out
    }

    /** 严格解析 `ip/prefix`；非法（含前缀越界）返回 null，绝不抛出。 */
    private fun parseCidr(entry: String): Pair<String, Int>? {
        val slash = entry.indexOf('/')
        if (slash <= 0 || slash == entry.length - 1) return null
        val ip = entry.substring(0, slash)
        val prefix = entry.substring(slash + 1).toIntOrNull() ?: return null
        val maxBits = when {
            isValidIpv4(ip) -> 32
            isValidIpv6(ip) -> 128
            else -> return null
        }
        if (prefix < 0 || prefix > maxBits) return null
        return ip to prefix
    }

    /** 点分十进制 IPv4 严格校验（4 段，每段 0..255，禁止前导零）。 */
    private fun isValidIpv4(ip: String): Boolean {
        val parts = ip.split('.')
        if (parts.size != 4) return false
        for (part in parts) {
            if (part.isEmpty() || part.length > 3) return false
            if (part.length > 1 && part[0] == '0') return false
            val octet = part.toIntOrNull() ?: return false
            if (octet !in 0..255) return false
        }
        return true
    }

    /**
     * IPv6 字面量严格校验：至多一个 `::` 压缩段，每组 1..4 个十六进制位，
     * 不含 zone id / 内嵌 IPv4。压缩时总组数 ≤ 7，否则必须恰好 8 组。
     */
    private fun isValidIpv6(ip: String): Boolean {
        if (ip.isEmpty() || !ip.contains(':')) return false
        if (ip.contains('%')) return false
        val compressAt = ip.indexOf("::")
        if (compressAt >= 0 && ip.indexOf("::", compressAt + 2) >= 0) return false

        fun isHexGroup(group: String): Boolean =
            group.isNotEmpty() && group.length <= 4 &&
                group.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }

        fun parseSide(side: String): List<String>? {
            if (side.isEmpty()) return emptyList()
            val groups = side.split(':')
            if (groups.any { !isHexGroup(it) }) return null
            return groups
        }

        if (compressAt < 0) {
            return parseSide(ip)?.size == 8
        }
        val left = parseSide(ip.substring(0, compressAt)) ?: return false
        val right = parseSide(ip.substring(compressAt + 2)) ?: return false
        return left.size + right.size <= 7
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
    private val DEFAULT_ADDRESSES = listOf("10.10.0.2" to 32, "fd00::1" to 128)
    private val DEFAULT_ROUTES = listOf("0.0.0.0" to 0, "::" to 0)
}
