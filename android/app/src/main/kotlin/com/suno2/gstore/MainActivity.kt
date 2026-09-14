package com.suno2.gstore

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
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
                        val packageInfo = pm.getPackageInfo(
                            packageName,
                            PackageManager.GET_ACTIVITIES or
                                PackageManager.GET_SERVICES or
                                PackageManager.GET_RECEIVERS or
                                PackageManager.GET_PROVIDERS or
                                PackageManager.GET_PERMISSIONS
                        )

                        // 组件状态：完整类名 → map(type × name → exported/enabled/processName)
                        fun componentStates(
                            name: String?,
                            type: String,
                            exported: Boolean,
                            enabled: Boolean,
                            processName: String?
                        ): Map<String, Any>? {
                            if (name.isNullOrEmpty()) return null
                            return mapOf(
                                "type" to type,
                                "name" to name,
                                "exported" to exported,
                                "enabled" to enabled,
                                "processName" to (processName ?: "")
                            )
                        }

                        val components = mutableListOf<Map<String, Any>>()
                        packageInfo.activities?.forEach {
                            componentStates(it.name, "ACTIVITY", it.exported, it.enabled, it.processName)
                                ?.let(components::add)
                        }
                        packageInfo.services?.forEach {
                            componentStates(it.name, "SERVICE", it.exported, it.enabled, it.processName)
                                ?.let(components::add)
                        }
                        packageInfo.receivers?.forEach {
                            componentStates(it.name, "RECEIVER", it.exported, it.enabled, it.processName)
                                ?.let(components::add)
                        }
                        packageInfo.providers?.forEach {
                            componentStates(it.name, "PROVIDER", it.exported, it.enabled, it.processName)
                                ?.let(components::add)
                        }

                        // 权限状态：granted + maxSdkVersion（requestedPermissions/requestedPermissionsFlags）
                        val permissionStates = mutableListOf<Map<String, Any>>()
                        val perms = packageInfo.requestedPermissions ?: emptyArray()
                        val permFlags = packageInfo.requestedPermissionsFlags ?: IntArray(0)
                        for (i in perms.indices) {
                            val granted = i < permFlags.size &&
                                (permFlags[i] and PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0
                            val level = if (i < permFlags.size) {
                                (permFlags[i] and PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0
                            } else {
                                false
                            }
                            permissionStates.add(mapOf(
                                "name" to perms[i],
                                "granted" to granted,
                                "neverForLocation" to level
                            ))
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
                        // API 28 起 GET_SIGNATURES 已废弃：改用 GET_SIGNING_CERTIFICATES +
                        // PackageInfo.signingInfo，才能拿到「多签名者」与「签名轮换历史」。
                        val signFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            PackageManager.GET_SIGNING_CERTIFICATES
                        } else {
                            @Suppress("DEPRECATION")
                            PackageManager.GET_SIGNATURES
                        }
                        val packageInfo = pm.getPackageInfo(
                            packageName,
                            signFlags or PackageManager.GET_META_DATA
                        )

                        // 签名列表：每张证书解析 X509，提取 Subject DN 与 SHA-256/SHA-1 指纹。
                        // 证书来源按官方语义二选一（两者互斥）：
                        //   - hasMultipleSigners() → apkContentsSigners：并列的**全部**签名者
                        //     （此时 getSigningCertificateHistory() 会返回 null）
                        //   - 否则 → signingCertificateHistory：原始→当前，含**轮换历史**
                        //     （末位为当前证书，其余为历史证书）
                        // kind: signer=并列签名者 / current=当前证书 / history=历史证书
                        val certEntries = mutableListOf<Pair<Signature, String>>()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            val signingInfo = packageInfo.signingInfo
                            if (signingInfo != null) {
                                if (signingInfo.hasMultipleSigners()) {
                                    signingInfo.apkContentsSigners?.forEach {
                                        certEntries.add(it to "signer")
                                    }
                                } else {
                                    val history = signingInfo.signingCertificateHistory
                                    if (history != null) {
                                        for (index in history.indices) {
                                            val isCurrent = index == history.lastIndex
                                            certEntries.add(
                                                history[index] to
                                                    if (isCurrent) "current" else "history"
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            packageInfo.signatures?.forEach { certEntries.add(it to "current") }
                        }

                        val signatures = mutableListOf<Map<String, String>>()
                        // 按 SHA-256 去重：多签名者与轮换历史理论上互斥，防御性兜底
                        val seenDigests = mutableSetOf<String>()
                        for ((sig, kind) in certEntries) {
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
                            if (sha256.isNotEmpty() && !seenDigests.add(sha256)) continue
                            signatures.add(mapOf(
                                "algorithm" to algorithm,
                                "subject" to subject,
                                "sha256" to sha256,
                                "sha1" to sha1,
                                "kind" to kind,
                            ))
                        }

                        // 签名形态摘要（供 UI 提示：并列多签名 / 含轮换历史）
                        var signingShape = "single"
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            val signingInfo = packageInfo.signingInfo
                            if (signingInfo != null) {
                                signingShape = when {
                                    signingInfo.hasMultipleSigners() -> "multiple"
                                    signingInfo.hasPastSigningCertificates() -> "rotation"
                                    else -> "single"
                                }
                            }
                        } else if (signatures.size > 1) {
                            signingShape = "multiple"
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

                // 已存在且与 APK 条目同尺寸 → 复用（避免覆写在用文件）
                if (target.exists() && target.length() == entry.size) return target
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
