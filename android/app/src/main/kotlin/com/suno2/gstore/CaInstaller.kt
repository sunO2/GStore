package com.suno2.gstore

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import android.util.Base64
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.security.auth.x500.X500Principal

/**
 * 抓包 MITM CA 的 Android 侧安装/检测能力（todo 17）。
 *
 * 本文件**只提供能力**，不接线 MethodChannel（通道与 Dart 封装属 todo 18，避免越界）。
 * 对外入口均为 `object CaInstaller` 的方法，返回值统一为可被 MethodChannel 序列化的
 * `Map<String, Any?>`。
 *
 * ## 诚实契约（务必遵守，防 misleading_success_output）
 * - **绝不静默提权**：非 root 时 `installSystemCa` 直接返回失败，不尝试任何提权。
 * - **绝不伪造成功**：`installUserCa` 成功只代表「系统安装器对话框已拉起 / 引导已下发」，
 *   返回 `userActionRequired=true`，**不声称已安装**；系统证书写入必须有 root 命令回显
 *   验证（`GSTORE_RESULT ok=1`）才算成功。
 * - **绝不因缺失 Intent/handler 崩溃**：所有 `startActivity`/`su` 均包在 `runCatching`，
 *   失败降级为引导路径。
 *
 * ## 已知限制
 * - Android 14+ 系统证书位于 APEX（`/apex/com.android.conscrypt/cacerts`），只能经
 *   `nsenter` 进入 Zygote/App 的 mount namespace 后 bind/rbind 覆盖（NVISO 方案）。
 * - **Shizuku（shell 权限）无法写系统存储**，明确不支持系统 CA 安装；只能走 root。
 * - 真机安装路径 **UNVERIFIED**（本仓库无 adb 设备），仅经静态分支审查。
 */
object CaInstaller {

    private const val TAG = "CaInstaller"

    /** 用户证书在系统安装器中的显示名（同时也是 Downloads 导出文件名前缀）。 */
    const val CA_ALIAS = "GStore Capture CA"
    private const val CA_FILE_NAME = "gstore-capture-ca.crt"

    /** API 边界：30 = Android 11（KeyChain 安装最后一个稳定可用大版本）。 */
    private const val API_R = 30

    /** API 边界：31 = Android 12（改为引导用户到安全设置）。 */
    private const val API_S = 31

    /** API 边界：33 = Android 13（系统 cacerts 仍在 `/system/etc`，可直接写文件）。 */
    private const val API_TIRAMISU = 33

    /** 系统 CA 目录。 */
    private const val LEGACY_CACERTS_DIR = "/system/etc/security/cacerts"
    internal const val APEX_CACERTS_DIR = "/apex/com.android.conscrypt/cacerts"

    /** root 命令等待上限：覆盖多 namespace bind，又不至于无限阻塞 UI 线程调用方。 */
    private const val ROOT_TIMEOUT_SEC = 30L

    /** 最近一次成功写入系统 CA 的文件名（`<hash>.0`），供 [systemCaInstalled] 无参查询。 */
    @Volatile
    private var lastSystemCaFileName: String? = null

    /** root 二进制常见路径（含 Magisk / KernelSU / APatch 痕迹）。 */
    private val SU_PATHS = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/sbin/su",
        "/vendor/bin/su", "/su/bin/su", "/system/bin/.ext/su",
    )

    /** root 方案特征目录（读不到即忽略，保守判定）。 */
    private val MAGISK_PATHS = listOf(
        "/sbin/.magisk", "/data/adb/magisk", "/data/adb/modules",
        "/data/adb/ksu", "/data/adb/ksud", "/data/adb/ap",
    )

    // ---------------------------------------------------------------------------------------------
    // 纯决策函数（无 Android 运行时依赖，可被 JVM 单测/静态审查复核；todo 18 在 Dart 侧镜像）
    // ---------------------------------------------------------------------------------------------

    /** 顶层安装动作决策。 */
    enum class CaInstallAction {
        /** 系统证书存储已确认存在该 CA → 无需安装。 */
        ALREADY_INSTALLED,

        /** 已 root → 走系统证书存储。 */
        INSTALL_SYSTEM,

        /** 非 root 且 API ≤ 30 → 拉起 KeyChain 用户证书安装器。 */
        INSTALL_USER_KEYCHAIN,

        /** 非 root 且 API ≥ 31 → 写 Downloads + 引导用户到「安全设置」手动安装。 */
        INSTALL_USER_GUIDE,
    }

    /** 系统证书写入方式。 */
    enum class SystemCaMethod {
        /** Android ≤ 13（API ≤ 33）：直接写 `/system/etc/security/cacerts/<hash>.0`。 */
        LEGACY_FS,

        /** Android 14+（API ≥ 34）：`nsenter` 进 namespace 后覆盖 APEX cacerts。 */
        APEX_NSENTER,
    }

    /**
     * 选择 CA 安装动作（纯函数）。
     *
     * 优先级：已安装 > root 系统写入 > 用户证书（按 API 分 KeyChain / 引导）。
     * 不读取任何全局状态，所有输入显式传入，便于全组合穷举。
     */
    fun chooseCaInstallAction(sdkInt: Int, isRooted: Boolean, systemInstalled: Boolean): CaInstallAction =
        when {
            systemInstalled -> CaInstallAction.ALREADY_INSTALLED
            isRooted -> CaInstallAction.INSTALL_SYSTEM
            sdkInt <= API_R -> CaInstallAction.INSTALL_USER_KEYCHAIN
            else -> CaInstallAction.INSTALL_USER_GUIDE
        }

    /** 选择系统 CA 写入方式（纯函数）：Android 14（API 34）起 cacerts 迁入 APEX。 */
    fun chooseSystemCaMethod(sdkInt: Int): SystemCaMethod =
        if (sdkInt <= API_TIRAMISU) SystemCaMethod.LEGACY_FS else SystemCaMethod.APEX_NSENTER

    /**
     * 构造系统 CA 安装 shell 脚本（纯函数）。
     *
     * 证书内容以 DER 的 base64 内联，避免依赖 su 读取应用私有目录（SELinux 差异）。
     * 脚本末尾打印 `GSTORE_RESULT ok=<0|1> [mounts=<n>]`，调用方据此**验证后才算成功**。
     */
    fun buildSystemCaInstallScript(sdkInt: Int, hashName: String, derBase64: String): String =
        when (chooseSystemCaMethod(sdkInt)) {
            SystemCaMethod.LEGACY_FS -> legacyScript(hashName, derBase64)
            SystemCaMethod.APEX_NSENTER -> apexScript(hashName, derBase64)
        }

    private fun legacyScript(hashName: String, derBase64: String): String = """
        |set -e
        |DIR=$LEGACY_CACERTS_DIR
        |SRC=/data/local/tmp/gstore_ca_src.0
        |echo '$derBase64' | base64 -d > "${'$'}SRC" 2>/dev/null || exit 3
        |mount -o rw,remount /system 2>/dev/null || mount -o rw,remount / 2>/dev/null || true
        |mkdir -p "${'$'}DIR" 2>/dev/null || true
        |cp "${'$'}SRC" "${'$'}DIR/$hashName" || exit 2
        |chmod 644 "${'$'}DIR/$hashName" 2>/dev/null || true
        |rm -f "${'$'}SRC" 2>/dev/null || true
        |[ -f "${'$'}DIR/$hashName" ] && echo GSTORE_RESULT ok=1 || echo GSTORE_RESULT ok=0
    """.trimMargin()

    private fun apexScript(hashName: String, derBase64: String): String = """
        |set -e
        |STAGE=/data/local/tmp/gstore_cacerts
        |APEX=$APEX_CACERTS_DIR
        |FALLBACK=$LEGACY_CACERTS_DIR
        |rm -rf "${'$'}STAGE" 2>/dev/null || true
        |mkdir -p "${'$'}STAGE" || exit 3
        |if [ -d "${'$'}APEX" ]; then cp -a "${'$'}APEX/." "${'$'}STAGE/" 2>/dev/null || true
        |elif [ -d "${'$'}FALLBACK" ]; then cp -a "${'$'}FALLBACK/." "${'$'}STAGE/" 2>/dev/null || true; fi
        |echo '$derBase64' | base64 -d > "${'$'}STAGE/$hashName" || exit 3
        |chmod 644 "${'$'}STAGE/$hashName" 2>/dev/null || true
        |TARGET="${'$'}APEX"; [ -d "${'$'}APEX" ] || TARGET="${'$'}FALLBACK"
        |MOUNTS=0
        |SEEN=""
        |for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        |  ns=$(readlink /proc/${'$'}pid/ns/mnt 2>/dev/null) || continue
        |  case " ${'$'}SEEN " in *" ${'$'}ns "*) continue;; esac
        |  SEEN="${'$'}SEEN ${'$'}ns"
        |  if nsenter --mount=/proc/${'$'}pid/ns/mnt -- mount --rbind "${'$'}STAGE" "${'$'}TARGET" 2>/dev/null; then MOUNTS=$((MOUNTS+1))
        |  elif nsenter --mount=/proc/${'$'}pid/ns/mnt -- mount --bind "${'$'}STAGE" "${'$'}TARGET" 2>/dev/null; then MOUNTS=$((MOUNTS+1)); fi
        |done
        |if [ "${'$'}MOUNTS" -gt 0 ]; then echo "GSTORE_RESULT ok=1 mounts=${'$'}MOUNTS"; else echo "GSTORE_RESULT ok=0 mounts=0"; fi
    """.trimMargin()

    // ---------------------------------------------------------------------------------------------
    // root 检测
    // ---------------------------------------------------------------------------------------------

    /**
     * root 检测（保守、无副作用）：Build tags、su 二进制、root 方案特征目录、`PATH` 中的 su。
     * 不主动执行 `su`（避免弹授权框），也绝不因权限拒绝而崩溃。
     */
    fun isRooted(): Boolean {
        return try {
            val tags = Build.TAGS
            if (tags != null && tags.contains("test-keys")) return true
            if (SU_PATHS.any { runCatching { File(it).exists() }.getOrDefault(false) }) return true
            if (MAGISK_PATHS.any { runCatching { File(it).exists() }.getOrDefault(false) }) return true
            pathHasSu()
        } catch (e: Exception) {
            Log.w(TAG, "isRooted 检测异常（按未 root 处理）: ${e.message}")
            false
        }
    }

    private fun pathHasSu(): Boolean {
        val path = System.getenv("PATH") ?: return false
        return path.split(File.pathSeparator).any { dir ->
            dir.isNotEmpty() && runCatching { File(dir, "su").exists() }.getOrDefault(false)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // 用户证书安装
    // ---------------------------------------------------------------------------------------------

    /**
     * 安装到**用户**证书存储。
     *
     * - API ≤ 30：`KeyChain.createInstallIntent()` 拉起系统安装器（用户确认后完成）。
     * - API ≥ 31：写 `.crt` 到 Downloads 并打开「安全设置」引导手动安装。
     *
     * 返回 `userActionRequired=true` 表示动作已下发、等待用户在系统 UI 确认，
     * **不代表已安装**。任何 Intent 不可用都降级到引导路径，不崩溃。
     */
    fun installUserCa(context: Context, bytes: ByteArray): Map<String, Any?> {
        val der = try {
            parseCert(bytes).encoded
        } catch (e: Exception) {
            Log.w(TAG, "证书解析失败: ${e.message}")
            return fail("BAD_CERT", "证书解析失败：${e.message ?: "无法识别 PEM/DER"}")
        }
        return if (Build.VERSION.SDK_INT <= API_R) {
            installUserViaKeyChain(context, der)
        } else {
            installUserViaGuide(context, der, "api_ge_31")
        }
    }

    private fun installUserViaKeyChain(context: Context, der: ByteArray): Map<String, Any?> {
        val intent = runCatching { KeyChain.createInstallIntent() }.getOrNull()
            ?: return installUserViaGuide(context, der, "keychain_intent_unavailable")
        intent.putExtra(KeyChain.EXTRA_CERTIFICATE, der)
        intent.putExtra(KeyChain.EXTRA_NAME, CA_ALIAS)
        val launched = try {
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "KeyChain 安装器不可用，降级为引导: ${e.message}")
            false
        }
        return if (launched) {
            mapOf(
                "ok" to true,
                "code" to "USER_KEYCHAIN_LAUNCHED",
                "action" to "keychain",
                "userActionRequired" to true,
                "installed" to false,
                "message" to "已拉起系统证书安装器，请在系统界面确认安装「$CA_ALIAS」。",
            )
        } else {
            installUserViaGuide(context, der, "keychain_launch_failed")
        }
    }

    /** 引导路径：导出 `.crt` 到 Downloads + 打开安全设置。失败也返回结构化结果，不抛。 */
    private fun installUserViaGuide(context: Context, der: ByteArray, reason: String): Map<String, Any?> {
        val pem = derToPem(der)
        val saved = runCatching { saveCertToDownloads(context, pem) }.getOrNull()
        val settingsOpened = runCatching {
            context.startActivity(
                Intent(Settings.ACTION_SECURITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.getOrElse {
            Log.w(TAG, "无法打开安全设置: ${it.message}")
            false
        }
        val code = when {
            saved != null -> "USER_GUIDE_DOWNLOADED"
            else -> "USER_GUIDE_NO_DOWNLOAD"
        }
        return mapOf(
            "ok" to true,
            "code" to code,
            "action" to "guide",
            "reason" to reason,
            "userActionRequired" to true,
            "installed" to false,
            "savedPath" to (saved ?: ""),
            "settingsOpened" to settingsOpened,
            "message" to buildString {
                append("请手动安装到用户证书存储：")
                if (saved != null) append("证书已保存到 Downloads/$CA_FILE_NAME，") else append("未能自动导出证书，")
                append("打开「设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书」选择该文件。")
            },
        )
    }

    /**
     * 写证书到公共 Downloads。API 29+ 走 MediaStore（免权限）；API 24–28 走
     * 公共目录（依赖 Manifest 中既有 `WRITE_EXTERNAL_STORAGE`）。失败返回 null。
     */
    private fun saveCertToDownloads(context: Context, pem: ByteArray): String? {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, CA_FILE_NAME)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/x-x509-ca-cert")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            val written = runCatching {
                resolver.openOutputStream(uri)?.use { it.write(pem) } != null
            }.getOrDefault(false)
            if (!written) {
                runCatching { resolver.delete(uri, null, null) }
                return null
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            runCatching { resolver.update(uri, values, null, null) }
            return "${Environment.DIRECTORY_DOWNLOADS}/$CA_FILE_NAME"
        }
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        return runCatching {
            if (!dir.exists() && !dir.mkdirs()) {
                null
            } else {
                val out = File(dir, CA_FILE_NAME)
                out.outputStream().use { it.write(pem) }
                out.absolutePath
            }
        }.getOrNull()
    }

    // ---------------------------------------------------------------------------------------------
    // 系统证书安装（仅 root）
    // ---------------------------------------------------------------------------------------------

    /**
     * 安装到**系统**证书存储。**仅当已 root**；非 root 直接失败，绝不提权/伪造成功。
     *
     * 机制（已定，按 API 分支）：
     * - API ≤ 33 → 写 `/system/etc/security/cacerts/<hash>.0`。
     * - API ≥ 34 → `nsenter` 进各 mount namespace 后 `--rbind` 覆盖 APEX cacerts
     *   （`/system/etc/security/cacerts` 仅作回退）。
     *
     * 只有脚本回显 `GSTORE_RESULT ok=1` 才返回成功。Magisk 模块路径为投机性尝试，
     * 本实现不依赖其稳定 API。
     */
    fun installSystemCa(pem: String): Map<String, Any?> {
        val cert = try {
            parseCert(pem.encodeToByteArray())
        } catch (e: Exception) {
            Log.w(TAG, "系统 CA 解析失败: ${e.message}")
            return fail("BAD_CERT", "CA 证书解析失败：${e.message ?: "无法识别 PEM/DER"}")
        }
        if (!isRooted()) {
            return fail("NOT_ROOT", "未检测到 root；Shizuku(shell) 无法写系统存储，系统 CA 安装仅支持 root。")
        }
        val der = cert.encoded
        val hashName = try {
            // 文件名必须是 subject Name 的 OpenSSL old hash（见 opensslSubjectHashOld 注释），
            // 传整张证书 DER 会得到错误文件名 → 系统不信任却误报成功。
            "${opensslSubjectHashOld(cert)}.0"
        } catch (e: Exception) {
            return fail("HASH_FAILED", "计算证书 subject hash 失败：${e.message}")
        }
        if (systemCaInstalled(der)) {
            lastSystemCaFileName = hashName
            return mapOf(
                "ok" to true, "code" to "ALREADY_INSTALLED", "action" to "noop",
                "fileName" to hashName, "userActionRequired" to false, "installed" to true,
                "message" to "系统证书存储已存在该 CA。",
            )
        }
        val sdk = Build.VERSION.SDK_INT
        val method = chooseSystemCaMethod(sdk)
        val derBase64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val script = buildSystemCaInstallScript(sdk, hashName, derBase64)
        val res = runRoot(script)
        val verified = res.ok && res.output.contains("GSTORE_RESULT ok=1")
        if (!verified) {
            val code = when {
                !res.completed -> "ROOT_TIMEOUT"
                res.exitCode != 0 -> "ROOT_DENIED_OR_FAILED"
                else -> "INSTALL_UNVERIFIED"
            }
            return mapOf(
                "ok" to false,
                "code" to code,
                "action" to method.name.lowercase(),
                "fileName" to hashName,
                "userActionRequired" to false,
                "installed" to false,
                "message" to "系统证书写入未通过验证（exit=${res.exitCode}）：${truncate(res.output)}",
            )
        }
        lastSystemCaFileName = hashName
        return mapOf(
            "ok" to true,
            "code" to "SYSTEM_CA_INSTALLED",
            "action" to method.name.lowercase(),
            "fileName" to hashName,
            "userActionRequired" to false,
            "installed" to true,
            "message" to "已写入系统证书存储（$hashName）。",
        )
    }

    // ---------------------------------------------------------------------------------------------
    // 系统证书状态检测
    // ---------------------------------------------------------------------------------------------

    /**
     * 检测系统证书是否已安装（**含 APEX 路径**）。
     *
     * @param pem 可选：提供后按该证书计算文件名精确匹配；缺省则用最近一次成功的文件名。
     * 无标记（从未装过且未传 pem）→ false。APEX 目录对 App 可能不可读，此时需 root 辅助探测。
     */
    fun systemCaInstalled(pem: ByteArray? = null): Boolean {
        val hashName = try {
            if (pem != null && pem.isNotEmpty()) "${opensslSubjectHashOld(parseCert(pem))}.0"
            else lastSystemCaFileName
        } catch (e: Exception) {
            lastSystemCaFileName
        } ?: return false

        // 直读（部分设备/ROM 下 APEX cacerts 对 App 可读）
        if (fileExists(APEX_CACERTS_DIR, hashName) || fileExists(LEGACY_CACERTS_DIR, hashName)) {
            return true
        }
        if (!isRooted()) return false
        val res = runRoot(
            "[ -f $APEX_CACERTS_DIR/$hashName ] || [ -f $LEGACY_CACERTS_DIR/$hashName ] || mount | grep -q gstore_cacerts && echo GSTORE_YES"
        )
        return res.ok && res.output.contains("GSTORE_YES")
    }

    private fun fileExists(dir: String, name: String): Boolean =
        runCatching { File(dir, name).exists() }.getOrDefault(false)

    // ---------------------------------------------------------------------------------------------
    // 内部工具
    // ---------------------------------------------------------------------------------------------

    /** 解析 PEM 或 DER 证书；非法输入抛异常（调用方转结构化失败，不崩溃）。 */
    private fun parseCert(bytes: ByteArray): X509Certificate {
        val factory = CertificateFactory.getInstance("X.509")
        return factory.generateCertificate(ByteArrayInputStream(bytes)) as X509Certificate
    }

    /** DER → PEM（下载给用户手动安装用）。 */
    private fun derToPem(der: ByteArray): ByteArray {
        val b64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val body = b64.chunked(64).joinToString("\n")
        return "-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----\n".encodeToByteArray()
    }

    /**
     * OpenSSL `X509_NAME_hash_old`：对 **subject Name 的 DER**（不是整张证书 DER）计算 MD5，
     * 取前 4 字节按 **小端** 组合为十六进制。Android cacerts 文件名即 `<hash>.0`。
     *
     * 注意：对 `rcgen` 生成的简单主体（PrintableString/UTF8String 的 CN）与 OpenSSL
     * 规范化结果一致；极端主体可能有差异，属尽力而为（真机 UNVERIFIED）。
     */
    private fun opensslSubjectHashOld(cert: X509Certificate): String {
        val md5 = MessageDigest.getInstance("MD5").digest(subjectNameDer(cert))
        val v = (md5[0].toInt() and 0xFF) or
            ((md5[1].toInt() and 0xFF) shl 8) or
            ((md5[2].toInt() and 0xFF) shl 16) or
            ((md5[3].toInt() and 0xFF) shl 24)
        return (v.toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')
    }

    /** subject Name 的 ASN.1 DER（即 OpenSSL `i2d_X509_NAME` 的输入）。 */
    private fun subjectNameDer(cert: X509Certificate): ByteArray {
        runCatching { return cert.subjectX500Principal.encoded }
            .onFailure { Log.w(TAG, "getSubjectX500Principal 失败，回退 subjectDN: ${it.message}") }
        // 回退：Android/RI 的 getSubjectDN() 返回 X500Principal，其 encoded 与原始 Name DER 一致。
        // 绝不在此用 `X500Principal(getSubjectDN().name)` 字符串重建——那会重排/重编码，得到错误 hash。
        val subject = cert.subjectDN
        if (subject is X500Principal) return subject.encoded
        throw IllegalStateException("无法获取 subject Name 的 DER 编码")
    }

    private class RootResult(val exitCode: Int, val output: String, val completed: Boolean) {
        val ok: Boolean get() = completed && exitCode == 0
    }

    /** 执行 root 命令；su 缺失/拒绝/超时均转为失败结果，绝不抛出。 */
    private fun runRoot(script: String): RootResult {
        return try {
            val proc = ProcessBuilder("su", "-c", script)
                .redirectErrorStream(true)
                .start()
            // 先 waitFor（带超时）再读输出：避免 su 等待用户授权时 readText 永久阻塞。
            val completed = proc.waitFor(ROOT_TIMEOUT_SEC, TimeUnit.SECONDS)
            if (!completed) {
                runCatching { proc.destroyForcibly() }
                return RootResult(-1, "[timeout]", false)
            }
            val output = runCatching {
                proc.inputStream.bufferedReader().use { it.readText() }
            }.getOrDefault("")
            RootResult(proc.exitValue(), output, true)
        } catch (e: Exception) {
            Log.w(TAG, "su 执行失败（按失败处理）: ${e.message}")
            RootResult(-1, "su 执行失败: ${e.message}", false)
        }
    }

    private fun truncate(s: String, max: Int = 512): String =
        if (s.length <= max) s else s.substring(0, max) + "…"

    private fun fail(code: String, message: String): Map<String, Any?> =
        mapOf(
            "ok" to false, "code" to code, "message" to message,
            "userActionRequired" to false, "installed" to false,
        )
}
