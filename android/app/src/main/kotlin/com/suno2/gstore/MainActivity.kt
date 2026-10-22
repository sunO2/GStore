package com.suno2.gstore

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "gstore/system_intent"
        private const val APK_INFO_CHANNEL = "gstore/apk_info"
        private const val APK_SOURCE_CHANNEL = "gstore/apk_source"

        /// 管理空间入口通道：Dart 侧启动/恢复时查询是否有待处理的"管理空间"请求
        private const val MANAGE_SPACE_CHANNEL = "gstore/manage_space"

        /// 代理 VPN 触发通道：只负责转发到 ProxyVpnService / VpnConsentActivity，
        /// 不在本 Activity 内承载任何 VPN 逻辑。
        private const val PROXY_VPN_CHANNEL = "gstore/proxy_vpn"

        /// 性能悬浮窗触发通道：负责 SYSTEM_ALERT_WINDOW 授权引导与
        /// PerfOverlayService 的启停（悬浮窗逻辑在 Service 内）。
        private const val PERF_OVERLAY_CHANNEL = "gstore/perf_overlay"

        /// 安装终端事件通道（EventChannel）：InstallerBridge 的唯一结果出口。
        private const val INSTALL_EVENTS_CHANNEL = "gstore/install_events"

        /// ManageSpaceActivity 携带的 action：用于识别"系统管理空间入口"
        const val ACTION_MANAGE_SPACE = "com.suno2.gstore.action.MANAGE_SPACE"

        /// QS 磁贴「连接」请求 action：磁贴拉起 MainActivity 时携带，
        /// Dart 侧经 `consumeProxyConnect` 查询消费后编排连接。
        const val ACTION_PROXY_CONNECT = "com.suno2.gstore.action.PROXY_CONNECT"

        /// QS 磁贴「长按」请求 action（系统标准值）：磁贴长按由系统解析到声明该
        /// action 的 Activity（本 Manifest 中为 MainActivity）。Dart 侧经
        /// `consumeProxyOpen` 查询消费后跳转应用内代理页。
        const val ACTION_QS_TILE_PREFERENCES =
            "android.service.quicksettings.action.QS_TILE_PREFERENCES"

        /// `prepare` 启动 VpnConsentActivity 的请求码，结果经 onActivityResult 回填。
        private const val REQUEST_PREPARE_VPN = 0x5652

        private const val TAG = "MainActivity"
    }

    /// 待处理的"管理空间"请求标记（冷启动 onCreate / 热启动 onNewIntent 置位，
    /// Dart 侧查询消费后清除）。@Volatile 保证跨线程可见。
    @Volatile
    private var pendingManageSpace = false

    /// 待处理的 QS 磁贴「连接」请求标记（冷启动/热启动置位，Dart 消费后清除）。
    /// @Volatile 保证跨线程可见。
    @Volatile
    private var pendingProxyConnect = false

    /// 待处理的 QS 磁贴「长按」请求标记（冷启动/热启动置位，Dart 消费后清除）。
    /// 长按命中后 Dart 跳转应用内代理页。@Volatile 保证跨线程可见。
    @Volatile
    private var pendingProxyOpen = false

    /// 正在等待 VpnConsentActivity 返回的 `prepare` Result（主线程访问）。
    /// 非 null 时拒绝并发的 prepare，避免覆盖挂起 Result 造成 Dart 侧永久挂起。
    private var pendingPrepareResult: MethodChannel.Result? = null

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PREPARE_VPN) return
        val pending = pendingPrepareResult ?: return
        pendingPrepareResult = null
        // RESULT_OK = 用户已同意**且** TUN fd 已安装（VpnConsentActivity 保证）；
        // 拒绝 / 超时均为 RESULT_CANCELED → false（Dart 映射 PROXY_VPN_CONSENT_DENIED）。
        pending.success(resultCode == RESULT_OK)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 平台能力通道（清单/设备/性能读数/Shizuku 执行）：只缓存 applicationContext，
        // 方法处理器在 configureFlutterEngine 中注册。
        PlatformChannel.init(applicationContext)
        // 安装执行层：缓存 applicationContext（终端结果经 gstore/install_events 回传）。
        runCatching { InstallerBridge.init(applicationContext) }
            .onFailure { Log.w(TAG, "InstallerBridge.init 失败（忽略）: ${it.message}") }
        // 通知 / 前台服务：创建渠道并跟踪前台 Activity，供 Dart 通道发布通知。
        runCatching { NotificationBridge.init(applicationContext) }
            .onFailure { Log.w(TAG, "NotificationBridge.init 失败（忽略）: ${it.message}") }
        if (intent?.action == ACTION_MANAGE_SPACE) {
            pendingManageSpace = true
            Log.i(TAG, "onCreate: 收到管理空间入口请求")
        }
        if (intent?.action == ACTION_PROXY_CONNECT) {
            pendingProxyConnect = true
            Log.i(TAG, "onCreate: 收到 QS 磁贴连接请求")
        }
        if (intent?.action == ACTION_QS_TILE_PREFERENCES) {
            pendingProxyOpen = true
            Log.i(TAG, "onCreate: 收到 QS 磁贴长按打开代理页请求")
        }
    }

    override fun onResume() {
        super.onResume()
        // 本应用自身帧指标（FrameMetrics，API 24+）：前台期间采集，供
        // `gstore/platform.readFrameMetrics` 读取。幂等；失败静默。
        FrameMetricsCollector.attach(this)
    }

    override fun onPause() {
        FrameMetricsCollector.detach(this)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_MANAGE_SPACE) {
            pendingManageSpace = true
            Log.i(TAG, "onNewIntent: 收到管理空间入口请求")
        }
        if (intent.action == ACTION_PROXY_CONNECT) {
            pendingProxyConnect = true
            Log.i(TAG, "onNewIntent: 收到 QS 磁贴连接请求")
        }
        if (intent.action == ACTION_QS_TILE_PREFERENCES) {
            pendingProxyOpen = true
            Log.i(TAG, "onNewIntent: 收到 QS 磁贴长按打开代理页请求")
        }
    }

    /// 绑定 `gstore/install_events`：listen 时接上 sink，cancel 时清空（热重启安全）。
    private fun registerInstallEvents(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    InstallerBridge.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    InstallerBridge.clearEventSink()
                }
            })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 免权限电池数据源兜底（SELinux 拒绝 sysfs current_now/voltage_now 时）。
        BatteryChannel.register(flutterEngine, applicationContext)
        // 平台能力 / 通知 / 安装终端事件：Dart 侧的行为入口（替代已删除的 JNI 桥）。
        PlatformChannel.register(flutterEngine.dartExecutor.binaryMessenger)
        NotificationBridge.register(flutterEngine.dartExecutor.binaryMessenger)
        registerInstallEvents(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUninstall" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName"))
                    startActivity(intent)
                    result.success(true)
                }
                "openAppDetails" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                    startActivity(intent)
                    result.success(true)
                }
                // 分享纯文本（性能报告导出等）：ACTION_SEND text/plain。
                "shareText" -> {
                    val text = call.argument<String>("text")
                    if (text.isNullOrEmpty()) {
                        result.error("ARG", "text required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                            call.argument<String>("subject")?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                        }
                        startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "分享"))
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "shareText 失败: ${e.message}")
                        result.error("SHARE_TEXT", "分享文本失败: ${e.message}", null)
                    }
                }
                // 分享文件（性能报告导出等）：ACTION_SEND + FileProvider Uri。
                // 注意：FileProvider 的 file_paths 仅覆盖 external-files/downloads，
                // 若目标路径未被覆盖会抛 IllegalArgumentException，此处转 result.error
                // 由 Dart 侧降级为分享纯文本。
                "shareFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path required", null)
                        return@setMethodCallHandler
                    }
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("NOTFOUND", "文件不存在: $path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.fileProvider", file)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = call.argument<String>("mimeType") ?: "application/octet-stream"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            call.argument<String>("subject")?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                        }
                        startActivity(Intent.createChooser(send, call.argument<String>("title") ?: "分享"))
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "shareFile 失败: ${e.message}")
                        result.error("SHARE_FILE", "分享文件失败: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 管理空间入口查询：Dart 探测/恢复时调用。返回是否存在待处理请求并消费。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MANAGE_SPACE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeManageSpace" -> {
                        result.success(pendingManageSpace)
                        pendingManageSpace = false
                    }
                    else -> result.notImplemented()
                }
            }

        // 代理 VPN 触发通道：仅转发，VPN 逻辑在 ProxyVpnService / VpnConsentActivity。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROXY_VPN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val config = call.argument<String>("config") ?: "{}"
                        // 并发 prepare：直接失败，绝不覆盖仍在等待的 Result。
                        if (pendingPrepareResult != null) {
                            result.error("PREPARE_IN_PROGRESS", "已有 prepare 正在等待 VPN 授权", null)
                            return@setMethodCallHandler
                        }
                        pendingPrepareResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(
                            Intent(this, VpnConsentActivity::class.java)
                                .putExtra(VpnConsentActivity.EXTRA_CONFIG, config),
                            REQUEST_PREPARE_VPN
                        )
                    }
                    "start" -> {
                        val config = call.argument<String>("config") ?: "{}"
                        ProxyVpnService.start(this, config)
                        result.success(true)
                    }
                    "stop" -> {
                        ProxyVpnService.stop(this)
                        result.success(true)
                    }
                    // 引导用户到系统「VPN」设置开启「始终开启的 VPN」（App 无法直接改系统设置）。
                    "alwaysOnSettings" -> {
                        ProxyVpnService.openAlwaysOnSettings(this)
                        result.success(true)
                    }
                    "isRunning" -> result.success(ProxyVpnService.isRunning)
                    // QS 磁贴「连接」请求：查询并消费 pending 标志（与
                    // consumeManageSpace 同构，poll 契约固定）。
                    "consumeProxyConnect" -> {
                        result.success(pendingProxyConnect)
                        pendingProxyConnect = false
                    }
                    // QS 磁贴「长按」请求：查询并消费 pending 标志，Dart 侧据此
                    // 跳转应用内代理页（与 consumeProxyConnect 同构，poll 契约固定）。
                    "consumeProxyOpen" -> {
                        result.success(pendingProxyOpen)
                        pendingProxyOpen = false
                    }
                    // TUN fd 是否已交给 Rust 宿主：isRunning 不足以判断（它在 fd 安装
                    // 之前就为 true）。
                    "hasTunFd" -> result.success(ProxyVpnService.tunFdInstalled)
                    // 抓包 MITM CA（todo 18）：仅新增方法，委托给 CaInstaller（todo 17）。
                    // 返回值均为可序列化的结构化 Map（ok/code/installed/...）；证书字节
                    // 绝不写入日志，异常一律转 result.error 不崩溃。
                    "installUserCa" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.error("ARG", "bytes required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(CaInstaller.installUserCa(this, bytes))
                        } catch (e: Exception) {
                            Log.w(TAG, "installUserCa 失败: ${e.message}")
                            result.error("CA_INSTALL_USER", "用户证书安装失败: ${e.message}", null)
                        }
                    }
                    "installSystemCa" -> {
                        val pem = call.argument<String>("pem")
                        if (pem.isNullOrEmpty()) {
                            result.error("ARG", "pem required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(CaInstaller.installSystemCa(pem))
                        } catch (e: Exception) {
                            Log.w(TAG, "installSystemCa 失败: ${e.message}")
                            result.error("CA_INSTALL_SYSTEM", "系统证书安装失败: ${e.message}", null)
                        }
                    }
                    "detectRoot" -> {
                        try {
                            result.success(CaInstaller.isRooted())
                        } catch (e: Exception) {
                            Log.w(TAG, "detectRoot 失败: ${e.message}")
                            result.error("CA_DETECT_ROOT", "root 检测失败: ${e.message}", null)
                        }
                    }
                    "systemCaInstalled" -> {
                        // pem 可选：缺省用最近一次成功写入的文件名（CaInstaller 内部）。
                        val pem = call.argument<String>("pem")
                        try {
                            result.success(CaInstaller.systemCaInstalled(pem?.encodeToByteArray()))
                        } catch (e: Exception) {
                            Log.w(TAG, "systemCaInstalled 失败: ${e.message}")
                            result.error("CA_SYSTEM_STATUS", "系统证书状态检测失败: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 性能悬浮窗触发通道：授权引导 + PerfOverlayService 启停，悬浮窗逻辑在 Service 内。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERF_OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPermissionGranted" -> result.success(Settings.canDrawOverlays(this))
                    "requestPermission" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            Log.w(TAG, "requestPermission 失败: ${e.message}")
                            result.error("OVERLAY_PERMISSION", "无法打开悬浮窗权限设置: ${e.message}", null)
                        }
                    }
                    "start" -> {
                        // 无权限时 addView 必抛 BadTokenException，直接返回 false 不启动。
                        if (!Settings.canDrawOverlays(this)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            // 启动前写入目标（持久化，Service 启动时恢复）。
                            call.argument<String>("targetPackage")
                                ?.takeIf { it.isNotEmpty() }
                                ?.let { PerfOverlayService.setTarget(this, it) }
                            val intent = Intent(this, PerfOverlayService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.w(TAG, "启动悬浮窗服务失败: ${e.message}")
                            result.error("OVERLAY_START", "启动悬浮窗失败: ${e.message}", null)
                        }
                    }
                    "stop" -> {
                        try {
                            stopService(Intent(this, PerfOverlayService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            Log.w(TAG, "停止悬浮窗服务失败: ${e.message}")
                            result.error("OVERLAY_STOP", "停止悬浮窗失败: ${e.message}", null)
                        }
                    }
                    "isRunning" -> result.success(PerfOverlayService.isRunning)
                    // 悬浮窗模式（compact | expanded | target | live）：持久化 + 运行中实时刷新。
                    "setMode" -> {
                        val mode = call.argument<String>("mode")
                        if (mode != PerfOverlayService.MODE_COMPACT &&
                            mode != PerfOverlayService.MODE_EXPANDED &&
                            mode != PerfOverlayService.MODE_TARGET &&
                            mode != PerfOverlayService.MODE_LIVE
                        ) {
                            result.error("ARG", "mode must be compact|expanded|target|live", null)
                            return@setMethodCallHandler
                        }
                        PerfOverlayService.setMode(this, mode)
                        result.success(true)
                    }
                    "getMode" -> result.success(PerfOverlayService.readMode(this))
                    // 当前生效档案名（由 Dart 推送）：持久化 + 运行中实时刷新 HUD。
                    "setProfile" -> {
                        PerfOverlayService.setProfile(this, call.argument<String>("name"))
                        result.success(true)
                    }
                    "getProfile" -> result.success(PerfOverlayService.readProfile(this))
                    // 悬浮窗监控目标（第三方应用包名）：持久化 + 运行中实时刷新。
                    "setTarget" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg.isNullOrEmpty()) {
                            result.error("ARG", "package required", null)
                            return@setMethodCallHandler
                        }
                        PerfOverlayService.setTarget(this, pkg)
                        result.success(true)
                    }
                    "clearTarget" -> {
                        PerfOverlayService.clearTarget(this)
                        result.success(true)
                    }
                    "getTarget" -> result.success(PerfOverlayService.readTarget(this))
                    else -> result.notImplemented()
                }
            }

        // APK 信息解析：通过 PackageManager.getPackageArchiveInfo 提取包名/应用名/版本/图标
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APK_INFO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "parseApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath == null || apkPath.isEmpty()) {
                        result.error("ARG", "apkPath required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val pm = packageManager
                        val packageInfo = pm.getPackageArchiveInfo(apkPath, PackageManager.GET_META_DATA)
                            ?: run {
                                result.error("PARSE", "无法解析 APK: $apkPath", null)
                                return@setMethodCallHandler
                            }
                        val appInfo = packageInfo.applicationInfo
                        if (appInfo != null) {
                            // 设置 sourceDir 以便 loadLabel/loadIcon 正常工作
                            appInfo.sourceDir = apkPath
                            appInfo.publicSourceDir = apkPath
                        }

                        val appName = appInfo?.loadLabel(pm)?.toString() ?: ""
                        val iconBytes = appInfo?.let { drawableToPngBytes(it.loadIcon(pm)) }

                        result.success(mapOf(
                            "packageName" to (packageInfo.packageName ?: ""),
                            "versionName" to (packageInfo.versionName ?: ""),
                            "versionCode" to (packageInfo.versionCode ?: 0),
                            "appName" to appName,
                            "iconBytes" to (iconBytes ?: ByteArray(0)),
                        ))
                    } catch (e: Exception) {
                        result.error("PARSE", "解析 APK 失败: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 已安装应用 APK 路径（sourceDir）：供 SDK 分析（lib/<abi>/*.so 枚举）使用
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APK_SOURCE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSourceDir" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val appInfo = packageManager.getApplicationInfo(packageName, 0)
                        result.success(appInfo.sourceDir)
                    } catch (e: Exception) {
                        result.error("SOURCE", "获取 sourceDir 失败: ${e.message}", null)
                    }
                }
                // 获取全部 APK 源路径（base + split，split APK 分发时原生库
                // 位于 split_config.*.apk，单独读 base 会漏掉 .so）。
                "getSourceDirs" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val appInfo = packageManager.getApplicationInfo(packageName, 0)
                        val dirs = mutableListOf<String>()
                        appInfo.sourceDir?.let(dirs::add)
                        appInfo.splitSourceDirs?.let { dirs.addAll(it) }
                        result.success(dirs)
                    } catch (e: Exception) {
                        result.error("SOURCE", "获取 sourceDirs 失败: ${e.message}", null)
                    }
                }
                // 本应用 nativeLibraryDir：内置可下载模块 .so 所在目录
                // （jniLibs 中的 libgstore_mod_*.so 解压后位于此；Dart 侧检索并交给宿主 dlopen）
                "getSelfNativeLibraryDir" -> {
                    try {
                        result.success(applicationInfo.nativeLibraryDir ?: "")
                    } catch (e: Exception) {
                        result.error("SOURCE", "获取 self nativeLibraryDir 失败: ${e.message}", null)
                    }
                }
                // 从 APK 提取模块 .so 到应用私有目录（useLegacyPackaging=false 时
                // nativeLibraryDir 无物理文件，须显式解压 jniLibs 后 dlopen）。
                // ABI 匹配：优先用传入 abi，失败则遍历 Build.SUPPORTED_ABIS 自动定位
                //（适配 armv7/x86_64 设备，避免 Dart 侧硬编码）。返回提取后的绝对路径。
                "extractModule" -> {
                    val module = call.argument<String>("module")
                    if (module == null) {
                        result.error("ARG", "module required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val target = extractModuleFile(module, call.argument<String>("abi"), allowWrite = true)
                        if (target != null) {
                            result.success(target.absolutePath)
                        } else {
                            result.error("NOTFOUND", "APK 无 libgstore_mod_$module.so（ABI=${call.argument<String>("abi")}）", null)
                        }
                    } catch (e: Exception) {
                        result.error("EXTRACT", "提取模块 .so 失败: ${e.message}", null)
                    }
                }
                // 只读查询：模块 .so 是否已解压（绝不写入，供状态查询用）
                "moduleSoPath" -> {
                    val module = call.argument<String>("module")
                    if (module == null) {
                        result.error("ARG", "module required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val target = extractModuleFile(module, call.argument<String>("abi"), allowWrite = false)
                        result.success(target?.absolutePath)
                    } catch (e: Exception) {
                        result.error("EXTRACT", "查询模块 .so 失败: ${e.message}", null)
                    }
                }
                // 只读探测：模块是否可用（APK 内含 或 已解压），供 UI 决定是否显示入口
                "hasModule" -> {
                    val module = call.argument<String>("module")
                    if (module == null) {
                        result.error("ARG", "module required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(hasModule(module, call.argument<String>("abi")))
                    } catch (e: Exception) {
                        result.error("PROBE", "探测模块失败: ${e.message}", null)
                    }
                }
                // 当前设备首选 ABI：Build.SUPPORTED_ABIS 首位（运行时真实解析，
                // 修正 Dart 侧硬编码 arm64-v8a，适配 armv7/x86/x86_64）。
                // 失败返回 null（Dart 侧自行回退），不抛。
                "currentAbi" -> {
                    try {
                        result.success(Build.SUPPORTED_ABIS.firstOrNull())
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                // 系统解压后的原生库目录（nativeLibraryDir）：已安装应用
                // .so 的第三层兜底来源（LibChecker getNativeDirLibs）。
                "getNativeLibraryDir" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val appInfo = packageManager.getApplicationInfo(packageName, 0)
                        result.success(appInfo.nativeLibraryDir ?: "")
                    } catch (e: Exception) {
                        result.error("SOURCE", "获取 nativeLibraryDir 失败: ${e.message}", null)
                    }
                }
                "getPermissions" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val packageInfo = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
                        result.success(packageInfo.requestedPermissions?.toList() ?: emptyList<String>())
                    } catch (e: Exception) {
                        result.error("PERMS", "获取权限列表失败: ${e.message}", null)
                    }
                }
                // 组件详情（LibChecker 风格）：四类组件的 exported/enabled/processName 状态
                // + 权限授权状态（granted 与 maxSdkVersion 限制）。
                "getComponentsDetail" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val pm = packageManager
                        val report = InventoryInspector.components(pm, packageName)
                        val components = report.components.map {
                            mapOf(
                                "type" to it.kind,
                                "name" to it.name,
                                "exported" to it.exported,
                                "enabled" to it.enabled,
                                "processName" to (it.processName ?: "")
                            )
                        }
                        val permissionStates = report.permissionStates.map {
                            mapOf(
                                "name" to it.name,
                                "granted" to it.granted,
                                "neverForLocation" to it.neverForLocation
                            )
                        }
                        result.success(mapOf(
                            "components" to components,
                            "permissionStates" to permissionStates
                        ))
                    } catch (e: Exception) {
                        result.error("COMPONENTS", "获取组件详情失败: ${e.message}", null)
                    }
                }
                "getInstalledAppDetail" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null || packageName.isEmpty()) {
                        result.error("ARG", "packageName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val pm = packageManager
                        val packageInfo = pm.getPackageInfo(
                            packageName,
                            PackageManager.GET_META_DATA
                        )

                        val signatureReport = InventoryInspector.signatures(pm, packageName)
                        val signatures = signatureReport.entries.map {
                            mapOf(
                                "algorithm" to it.algorithm,
                                "subject" to it.subject,
                                "sha256" to it.sha256,
                                "sha1" to it.sha1,
                                "kind" to it.kind
                            )
                        }
                        val signingShape = signatureReport.shape

                        // meta-data：Bundle → Map<String, String>（跳过 null 值）
                        val metaData = mutableMapOf<String, String>()
                        packageInfo.applicationInfo?.metaData?.let { bundle ->
                            for (key in bundle.keySet()) {
                                val value = bundle.get(key)?.toString()
                                if (value != null) metaData[key] = value
                            }
                        }

                        // 主 Activity：优先查 MAIN/LAUNCHER intent；失败回退到第一个非空 activity
                        var mainActivity = ""
                        try {
                            val launchIntent = Intent(Intent.ACTION_MAIN)
                                .addCategory(Intent.CATEGORY_LAUNCHER)
                                .setPackage(packageName)
                            mainActivity = pm.resolveActivity(launchIntent, 0)
                                ?.activityInfo?.name ?: ""
                        } catch (e: Exception) {
                            mainActivity = ""
                        }
                        if (mainActivity.isEmpty()) {
                            packageInfo.activities?.firstOrNull { it.name != null }
                                ?.let { mainActivity = it.name ?: "" }
                        }

                        // APK 大小（sourceDir 文件字节数）
                        var apkSize = 0L
                        try {
                            packageInfo.applicationInfo?.sourceDir?.let {
                                apkSize = File(it).length()
                            }
                        } catch (e: Exception) {
                            apkSize = 0L
                        }

                        // minSdk 仅 API 24+ 提供；两者均按可空返回
                        var minSdk: Int? = null
                        try {
                            minSdk = packageInfo.applicationInfo?.minSdkVersion
                        } catch (e: Exception) {
                            minSdk = null
                        }
                        val targetSdk = packageInfo.applicationInfo?.targetSdkVersion

                        // 系统信息字段（LibChecker 风格详情展示）
                        val appInfo = packageInfo.applicationInfo
                        val uid = appInfo?.uid ?: 0
                        val sharedUserId = packageInfo.sharedUserId ?: ""
                        // 安装来源：优先 installer 包名 → 解析来源应用名与图标
                        //（如 com.android.vending → Google Play），资源图标转 PNG base64。
                        var installer = ""
                        var installerAppName = ""
                        var installerIconPng = ""
                        try {
                            installer = pm.getInstallerPackageName(packageName) ?: ""
                            if (installer.isNotEmpty()) {
                                runCatching {
                                    val installerInfo = pm.getApplicationInfo(
                                        installer,
                                        PackageManager.GET_META_DATA
                                    )
                                    installerAppName = pm.getApplicationLabel(installerInfo)
                                        ?.toString() ?: ""
                                    pm.getApplicationIcon(installerInfo)?.let {
                                        drawableToPngBytes(it)?.let { bytes ->
                                            installerIconPng =
                                                Base64.encodeToString(bytes, Base64.NO_WRAP)
                                        }
                                    }
                                }.onFailure {
                                    // 来源应用已卸载或不可达：保留包名，名称为空
                                }
                            }
                        } catch (e: Exception) {
                            installer = ""
                        }
                        val isSystemApp = (appInfo?.flags?.and(ApplicationInfo.FLAG_SYSTEM) != 0)
                        val isDebuggable = (appInfo?.flags?.and(ApplicationInfo.FLAG_DEBUGGABLE) != 0)
                        val dataDir = appInfo?.dataDir ?: ""

                        result.success(mapOf(
                            "signatures" to signatures,
                            // single / multiple（并列多签名者）/ rotation（含轮换历史）
                            "signingShape" to signingShape,
                            "metaData" to metaData,
                            "mainActivity" to mainActivity,
                            "apkSize" to apkSize,
                            "firstInstallTime" to packageInfo.firstInstallTime,
                            "lastUpdateTime" to packageInfo.lastUpdateTime,
                            "minSdk" to minSdk,
                            "targetSdk" to targetSdk,
                            "uid" to uid,
                            "sharedUserId" to sharedUserId,
                            "installer" to installer,
                            "installerAppName" to installerAppName,
                            "installerIconPng" to installerIconPng,
                            "isSystemApp" to isSystemApp,
                            "isDebuggable" to isDebuggable,
                            "dataDir" to dataDir,
                        ))
                    } catch (e: Exception) {
                        result.error("DETAIL", "获取应用详情失败: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 模块是否可用：APK 内含该 .so，或已解压到私有目录（只读：不解压、不写入）。
    private fun hasModule(module: String, requestedAbi: String?): Boolean {
        val abis = if (!requestedAbi.isNullOrEmpty()) {
            listOf(requestedAbi) + Build.SUPPORTED_ABIS.toList()
        } else {
            Build.SUPPORTED_ABIS.toList()
        }
        java.util.zip.ZipFile(File(applicationInfo.sourceDir)).use { zip ->
            for (abi in abis) {
                if (zip.getEntry("lib/$abi/libgstore_mod_$module.so") != null) return true
                if (File(File(filesDir, "gstore_mods/$abi"), "libgstore_mod_$module.so").exists()) return true
            }
        }
        return false
    }

    /// 解压模块 .so 到私有目录并返回目标文件（供 extractModule / moduleSoPath 复用）。
    ///
    /// 关键：**绝不原地覆写已解压的 .so**。该文件可能已被 dlopen 映射，而宿主 mount-once
    /// 永不 dlclose，原地截断重写会让已映射的代码页失效（二次启动 SIGSEGV 的根因）。
    /// 因此：
    ///  - 已存在且大小与 APK 内条目一致 → 直接复用，不写入；
    ///  - 需要更新时写临时文件后原子 rename（生成新 inode，旧映射不受影响）；
    ///  - [allowWrite] = false 时只查存在，绝不写入（状态查询专用）。
    private fun extractModuleFile(module: String, requestedAbi: String?, allowWrite: Boolean): File? {
        val apkFile = File(applicationInfo.sourceDir)
        java.util.zip.ZipFile(apkFile).use { zipFile ->
            val abis = if (!requestedAbi.isNullOrEmpty()) {
                listOf(requestedAbi) + Build.SUPPORTED_ABIS.toList()
            } else {
                Build.SUPPORTED_ABIS.toList()
            }
            for (abi in abis) {
                val entry = zipFile.getEntry("lib/$abi/libgstore_mod_$module.so") ?: continue
                val targetDir = File(filesDir, "gstore_mods/$abi")
                val target = File(targetDir, "libgstore_mod_$module.so")

                // 已存在且**内容一致**才复用：只比尺寸会漏掉"改了但大小恰好相同"的更新。
                // 实测踩坑：原生模块重编后 .so 尺寸常不变 → 设备一直跑第一次解压的旧库，
                // Rust 侧改动"编译进包了却没生效"（表现像代码没改对）。
                val crcMarker = File(targetDir, "${target.name}.crc")
                val cachedCrc = if (crcMarker.exists()) crcMarker.readText().trim() else null
                if (target.exists() && target.length() == entry.size &&
                    cachedCrc == entry.crc.toString()
                ) {
                    return target
                }
                if (!allowWrite) return if (target.exists()) target else null

                targetDir.mkdirs()
                val tmp = File(targetDir, "${target.name}.tmp-${System.nanoTime()}")
                zipFile.getInputStream(entry).use { input ->
                    tmp.outputStream().use { output -> input.copyTo(output) }
                }
                // 原子替换：rename 到目标路径；失败则回退为覆盖写并清理临时文件
                if (!tmp.renameTo(target)) {
                    tmp.copyTo(target, overwrite = true)
                    tmp.delete()
                }
                // 记下本次解压的内容指纹，下次据此判断是否需要重新解压
                runCatching { crcMarker.writeText(entry.crc.toString()) }
                return target
            }
        }
        return null
    }

    /// 将 Drawable 图标转为 PNG 字节数组
    private fun drawableToPngBytes(drawable: Drawable): ByteArray? {
        try {
            val bitmap = drawableToBitmap(drawable) ?: return null
            val baos = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
            return baos.toByteArray()
        } catch (e: Exception) {
            return null
        }
    }

    /// 将 Drawable（含自适应图标）转为 Bitmap
    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        return when (drawable) {
            is BitmapDrawable -> drawable.bitmap
            else -> {
                try {
                    val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96
                    val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bitmap)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    bitmap
                } catch (e: Exception) {
                    null
                }
            }
        }
    }
}
