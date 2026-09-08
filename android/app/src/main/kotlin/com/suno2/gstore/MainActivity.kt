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
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "gstore/system_intent"
        private const val APK_INFO_CHANNEL = "gstore/apk_info"
        private const val APK_SOURCE_CHANNEL = "gstore/apk_source"

        /// 管理空间入口通道：Dart 侧启动/恢复时查询是否有待处理的"管理空间"请求
        private const val MANAGE_SPACE_CHANNEL = "gstore/manage_space"

        /// ManageSpaceActivity 携带的 action：用于识别"系统管理空间入口"
        const val ACTION_MANAGE_SPACE = "com.suno2.gstore.action.MANAGE_SPACE"

        private const val TAG = "MainActivity"
    }

    /// 待处理的"管理空间"请求标记（冷启动 onCreate / 热启动 onNewIntent 置位，
    /// Dart 侧查询消费后清除）。@Volatile 保证跨线程可见。
    @Volatile
    private var pendingManageSpace = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == ACTION_MANAGE_SPACE) {
            pendingManageSpace = true
            Log.i(TAG, "onCreate: 收到管理空间入口请求")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_MANAGE_SPACE) {
            pendingManageSpace = true
            Log.i(TAG, "onNewIntent: 收到管理空间入口请求")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                            PackageManager.GET_SIGNATURES or PackageManager.GET_META_DATA
                        )

                        // 签名列表：每张证书解析 X509，提取 Subject DN 与 SHA-256/SHA-1 指纹
                        val signatures = mutableListOf<Map<String, String>>()
                        packageInfo.signatures?.let { sigs ->
                            for (sig in sigs) {
                                var algorithm = "SHA256withRSA"
                                var subject = ""
                                var sha256 = ""
                                var sha1 = ""
                                try {
                                    val cert = CertificateFactory.getInstance("X509")
                                        .generateCertificate(ByteArrayInputStream(sig.toByteArray()))
                                        as X509Certificate
                                    subject = cert.subjectDN.name
                                    algorithm = cert.sigAlgName?.ifEmpty { "SHA256withRSA" }
                                        ?: "SHA256withRSA"
                                    sha256 = MessageDigest.getInstance("SHA-256")
                                        .digest(sig.toByteArray())
                                        .joinToString(":") { "%02x".format(it.toInt() and 0xFF) }
                                    sha1 = MessageDigest.getInstance("SHA-1")
                                        .digest(sig.toByteArray())
                                        .joinToString(":") { "%02x".format(it.toInt() and 0xFF) }
                                } catch (e: Exception) {
                                    // 单张证书解析失败：降级为空字段，不影响其余证书
                                }
                                signatures.add(mapOf(
                                    "algorithm" to algorithm,
                                    "subject" to subject,
                                    "sha256" to sha256,
                                    "sha1" to sha1,
                                ))
                            }
                        }

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
                        var installer = ""
                        try {
                            installer = pm.getInstallerPackageName(packageName) ?: ""
                        } catch (e: Exception) {
                            installer = ""
                        }
                        val isSystemApp = (appInfo?.flags?.and(ApplicationInfo.FLAG_SYSTEM) != 0)
                        val isDebuggable = (appInfo?.flags?.and(ApplicationInfo.FLAG_DEBUGGABLE) != 0)
                        val dataDir = appInfo?.dataDir ?: ""

                        result.success(mapOf(
                            "signatures" to signatures,
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
