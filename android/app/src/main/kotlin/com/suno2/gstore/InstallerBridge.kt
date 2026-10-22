package com.suno2.gstore

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.util.Collections
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Android install execution layer for the Rust [`InstallerPort`].
 *
 * Branch order is fixed: Shizuku (shell uid 2000) → `PackageInstaller` session →
 * system `ACTION_VIEW` intent. Every branch returns the same stable JSON object,
 * and asynchronous outcomes are delivered to Rust through
 * [nativeOnInstallResult] (one terminal report per session id).
 *
 * All blocking work stays on the caller's (Rust) thread; the PackageInstaller
 * and Intent paths only *start* work and return `pending`. User-action results
 * arrive through [InstallResultReceiver], never through `onActivityResult`.
 */
object InstallerBridge {

    private const val TAG = "InstallerBridge"

    private const val PREFS_NAME = "gstore_installer"
    private const val PREFS_KEY_PREFIX = "session_"
    private const val STAGE_DIR = "/data/local/tmp"

    /** Bounded wait for an asynchronous install before a `timeout` result. */
    private const val TIMEOUT_MS = 120_000L

    /**
     * Bounded wait for the blocking Shizuku shell call. The worker cannot be
     * force-killed, but the caller is bounded and still receives one terminal
     * result.
     */
    private const val SHIZUKU_TIMEOUT_SECONDS = 180L

    /** Explicit broadcast action used by the PackageInstaller `PendingIntent`. */
    const val ACTION_INSTALL_COMMIT = "com.suno2.gstore.action.INSTALL_COMMIT"

    /** Session key carried by the `PendingIntent` base intent. */
    const val EXTRA_SESSION_KEY = "gstore.install.sessionId"

    /** Package name captured before the install starts. */
    const val EXTRA_PACKAGE_NAME = "gstore.install.packageName"

    /** Install method captured before the install starts. */
    const val EXTRA_METHOD = "gstore.install.method"

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var initialized = false

    /** Sessions that already produced one terminal result (Kotlin-side dedupe). */
    private val reportedTerminals: MutableSet<String> =
        Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())

    /** Recent terminal payloads so `queryInstallResult` can answer after reporting. */
    private val terminalPayloads = ConcurrentHashMap<String, String>()

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * Rust implementation of the durable result callback.
     *
     * JNI name: `Java_com_suno2_gstore_InstallerBridge_nativeOnInstallResult`.
     */
    @JvmStatic
    external fun nativeOnInstallResult(
        sessionId: String,
        status: String,
        packageName: String?,
        versionName: String?,
        error: String?
    )

    /**
     * Captures the application context. Called from `MainActivity.onCreate`
     * after the native library is loaded; best-effort, never throws.
     */
    @JvmStatic
    fun init(context: Context) {
        appContext = context.applicationContext ?: context
        initialized = true
    }

    private fun context(): Context? = appContext
    private fun packageManager(): PackageManager? = appContext?.packageManager

    private fun isInitialized(): Boolean = initialized && appContext != null

    /**
     * Whether this app may start installs at all. Below API 26 the unknown
     * sources check does not exist.
     */
    @JvmStatic
    fun canInstall(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            true
        } else {
            packageManager()?.canRequestPackageInstalls() == true
        }
    }.getOrDefault(false)

    /**
     * Installs `apkPath` under `sessionId`.
     *
     * Returns a stable JSON payload:
     * `{"method":"...","status":"installed|denied|failed|pending","packageName":...,"versionName":...,"error":...}`.
     * Never blocks for a user response.
     */
    @JvmStatic
    fun install(apkPath: String, sessionId: String): String {
        if (!isInitialized()) {
            return resultJson(
                "package_installer",
                "failed",
                error = "CORE_E_INSTALL_BRIDGE: InstallerBridge not initialized"
            )
        }
        val file = File(apkPath)
        if (!file.isFile) {
            return resultJson(
                "package_installer",
                "failed",
                error = "CORE_E_INSTALL_APK_MISSING: $apkPath"
            )
        }

        val archive = archiveInfo(file)
        val packageName = archive?.packageName
        val archiveVersion = archive?.versionName

        // (a) Shizuku silent install.
        if (ShizukuExecBridge.isAvailable()) {
            val shizuku = installViaShizuku(file, sessionId, packageName, archiveVersion)
            if (shizuku != null) {
                return shizuku
            }
        }

        // (b) PackageInstaller session, (c) system intent fallback.
        return installViaPackageInstaller(file, sessionId, packageName)
    }

    /**
     * Shizuku silent install with a caller-side bound.
     *
     * `ShizukuExecBridge.exec` is synchronous and not interruptible, so the
     * shell call runs on a daemon worker. The caller waits at most
     * [SHIZUKU_TIMEOUT_SECONDS] and then returns one terminal `timeout` result.
     * The abandoned worker cannot be force-killed, but it always removes the
     * staged APK in its own `finally` path once the shell call returns.
     */
    private fun installViaShizuku(
        file: File,
        sessionId: String,
        packageName: String?,
        archiveVersion: String?
    ): String? {
        val staged = File(STAGE_DIR, "gstore_install_${safeName(sessionId)}.apk")
        val command =
            "cp ${quote(file.absolutePath)} ${quote(staged.absolutePath)} && " +
                "pm install -r ${quote(staged.absolutePath)}; " +
                "rm -f ${quote(staged.absolutePath)}"

        val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "gstore-shizuku-install").apply { isDaemon = true }
        }
        val future = try {
            worker.submit(Callable<String> {
                try {
                    ShizukuExecBridge.exec(command)
                } catch (t: Throwable) {
                    "Error: ${t.message ?: t.javaClass.simpleName}"
                } finally {
                    // Always remove the staged APK, including after a slow shell
                    // call that outlived the caller's bounded wait.
                    runCatching {
                        ShizukuExecBridge.exec("rm -f ${quote(staged.absolutePath)}")
                    }
                }
            })
        } catch (t: Throwable) {
            worker.shutdownNow()
            Log.w(TAG, "Shizuku worker could not start: ${t.message}")
            return null
        }

        val output = try {
            future.get(SHIZUKU_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (t: TimeoutException) {
            future.cancel(true)
            worker.shutdownNow()
            Log.w(TAG, "Shizuku install exceeded ${SHIZUKU_TIMEOUT_SECONDS}s")
            return rememberTerminal(
                sessionId,
                "shizuku",
                "timeout",
                packageName,
                null,
                "CORE_E_INSTALL_TIMEOUT: ${SHIZUKU_TIMEOUT_SECONDS}s"
            )
        } catch (t: Throwable) {
            worker.shutdownNow()
            Log.w(TAG, "Shizuku install worker failed: ${t.message}")
            ""
        } finally {
            worker.shutdown()
        }

        if (output.trim().startsWith("Success")) {
            val version = installedVersion(packageName) ?: archiveVersion
            return rememberTerminal(sessionId, "shizuku", "installed", packageName, version, null)
        }
        if (isUserRejected(output)) {
            // Terminal: never silently fall back after an explicit rejection.
            return rememberTerminal(
                sessionId,
                "shizuku",
                "denied",
                packageName,
                null,
                "CORE_E_INSTALL_USER_REJECTED"
            )
        }
        Log.w(TAG, "Shizuku install failed, falling back: ${output.take(300)}")
        return null
    }

    private fun installViaPackageInstaller(
        file: File,
        sessionId: String,
        packageName: String?
    ): String {
        if (!canInstall()) {
            return rememberTerminal(
                sessionId,
                "package_installer",
                "denied",
                packageName,
                null,
                "CORE_E_INSTALL_UNKNOWN_SOURCES"
            )
        }

        val ctx = context()
            ?: return rememberTerminal(
                sessionId,
                "package_installer",
                "failed",
                packageName,
                null,
                "CORE_E_INSTALL_BRIDGE: context missing"
            )

        var session: PackageInstaller.Session? = null
        try {
            val installer = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            packageName?.let { params.setAppPackageName(it) }
            val sessionIdInt = installer.createSession(params)
            val created = installer.openSession(sessionIdInt)
            session = created

            FileInputStream(file).use { input ->
                created.openWrite("gstore.apk", 0L, -1L).use { output ->
                    input.copyTo(output)
                    created.fsync(output)
                }
            }

            val callback = Intent(ctx, InstallResultReceiver::class.java).apply {
                action = ACTION_INSTALL_COMMIT
                putExtra(EXTRA_SESSION_KEY, sessionId)
                putExtra(EXTRA_PACKAGE_NAME, packageName)
                putExtra(EXTRA_METHOD, "package_installer")
            }
            val flags = PendingIntentFlags.forSession()
            val pendingIntent = android.app.PendingIntent.getBroadcast(
                ctx,
                sessionIdInt,
                callback,
                flags
            )

            // Persist before commit so a broadcast that races the caller still
            // finds the session entry. The numeric PackageInstaller session id
            // is the only key that survives process death for recovery.
            persistPending(
                sessionId,
                packageName,
                "package_installer",
                file.absolutePath,
                sessionIdInt
            )
            created.commit(pendingIntent.intentSender)
            armTimeout(sessionId, "package_installer")
            return pendingJson("package_installer", packageName)
        } catch (t: Throwable) {
            Log.w(TAG, "PackageInstaller failed, falling back to intent: ${t.message}")
            runCatching { session?.abandon() }
            runCatching { session?.close() }
            return installViaIntent(ctx, file, sessionId, packageName)
        }
    }

    private fun installViaIntent(
        ctx: Context,
        file: File,
        sessionId: String,
        packageName: String?
    ): String {
        return try {
            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileProvider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            persistPending(sessionId, packageName, "intent", file.absolutePath)
            ctx.startActivity(intent)
            armTimeout(sessionId, "intent")
            pendingJson("intent", packageName)
        } catch (t: Throwable) {
            Log.w(TAG, "Intent install could not start: ${t.message}")
            rememberTerminal(
                sessionId,
                "intent",
                "failed",
                packageName,
                null,
                "CORE_E_INSTALL_INTENT: ${t.message ?: t.javaClass.simpleName}"
            )
        }
    }

    /**
     * Uninstalls through Shizuku when available, otherwise opens the system
     * uninstall confirmation. Returns Shizuku success or "intent launched".
     */
    @JvmStatic
    fun uninstall(packageName: String): Boolean {
        if (packageName.isBlank()) {
            return false
        }
        if (ShizukuExecBridge.isAvailable()) {
            val output = runCatching {
                ShizukuExecBridge.exec("pm uninstall --user 0 ${quote(packageName)}")
            }.getOrDefault("")
            return output.trim().startsWith("Success")
        }
        val ctx = context() ?: return false
        return runCatching {
            ctx.startActivity(
                Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.getOrDefault(false)
    }

    /** Launches a package's default activity; false when it has none. */
    @JvmStatic
    fun launch(packageName: String): Boolean {
        val ctx = context() ?: return false
        val intent = ctx.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching {
            ctx.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    /**
     * Process-death recovery: returns the same stable JSON with a terminal or
     * `pending` status, or null when the session is unknown. Never blocks on a
     * user response.
     */
    @JvmStatic
    fun queryInstallResult(sessionId: String): String? {
        terminalPayloads[sessionId]?.let { return it }

        val pending = readPending(sessionId) ?: return null

        // A package update after the pending entry was created is the
        // strongest terminal signal available after process death.
        if (packageUpdatedSince(pending.packageName, pending.createdAt)) {
            return installedJson(
                pending.method,
                pending.packageName,
                installedVersion(pending.packageName)
            )
        }
        if (pending.method == "intent") {
            return pendingJson("intent", pending.packageName)
        }
        if (pending.method != "package_installer") {
            return pendingJson(pending.method, pending.packageName)
        }

        // Recovery must use the numeric PackageInstaller session id persisted
        // at commit time; the app session id is a string and never parseable.
        val numeric = pending.installerSessionId ?: sessionId.toIntOrNull()
        if (numeric != null) {
            val info = runCatching {
                packageManager()?.packageInstaller?.getSessionInfo(numeric)
            }.getOrNull()
            if (info != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    info.isStaged &&
                    info.isStagedSessionFailed
                ) {
                    return resultJson(
                        "package_installer",
                        "failed",
                        pending.packageName,
                        null,
                        "CORE_E_INSTALL_FAILED: staged session ${info.stagedSessionErrorCode}"
                    )
                }
                // Active, sealed, or committed: the system still owns the
                // session and will deliver a terminal broadcast when it exits.
                return pendingJson("package_installer", pending.packageName)
            }
        }

        // Session is gone but the package was not updated (checked above).
        // Keep reporting pending instead of fabricating a failure: a persisted
        // app session may still be resolved by a late broadcast.
        return pendingJson("package_installer", pending.packageName)
    }

    // ------------------------------------------------------------------
    // Result reporting (used by InstallResultReceiver and sync branches)
    // ------------------------------------------------------------------

    /**
     * Reports one terminal result to Rust exactly once per session id.
     * Failures are logged; this method never throws.
     */
    @JvmStatic
    fun reportTerminal(
        sessionId: String,
        method: String,
        status: String,
        packageName: String?,
        versionName: String?,
        error: String?
    ) {
        if (!reportedTerminals.add(sessionId)) {
            return
        }
        terminalPayloads[sessionId] = resultJson(method, status, packageName, versionName, error)
        runCatching {
            nativeOnInstallResult(sessionId, status, packageName, versionName, error)
        }.onFailure {
            Log.w(TAG, "nativeOnInstallResult failed: ${it.message}")
        }
        clearPending(sessionId)
    }

    private fun rememberTerminal(
        sessionId: String,
        method: String,
        status: String,
        packageName: String?,
        versionName: String?,
        error: String?
    ): String {
        reportedTerminals.add(sessionId)
        val json = resultJson(method, status, packageName, versionName, error)
        terminalPayloads[sessionId] = json
        clearPending(sessionId)
        return json
    }

    /** Pending session id + metadata matching an installed package, if any. */
    fun pendingSessionForPackage(packageName: String): PendingSession? {
        val values = prefs()?.all ?: return null
        for ((key, value) in values) {
            if (!key.startsWith(PREFS_KEY_PREFIX)) continue
            val pending = parsePending(value as? String) ?: continue
            if (pending.packageName == packageName) {
                return PendingSession(key.removePrefix(PREFS_KEY_PREFIX), pending)
            }
        }
        return null
    }

    /** Package name persisted for a session id, when still pending. */
    fun pendingPackageFor(sessionId: String): String? = readPending(sessionId)?.packageName

    /** Installed version name, or null when the package is absent. */
    fun installedVersionFor(packageName: String): String? = installedVersion(packageName)

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private fun installedVersion(packageName: String?): String? {
        if (packageName.isNullOrEmpty()) return null
        return runCatching {
            @Suppress("DEPRECATION")
            packageManager()?.getPackageInfo(packageName, 0)?.versionName
        }.getOrNull()
    }

    private fun archiveInfo(file: File): android.content.pm.PackageInfo? = runCatching {
        @Suppress("DEPRECATION")
        packageManager()?.getPackageArchiveInfo(file.absolutePath, 0)
    }.getOrNull()

    private fun packageUpdatedSince(packageName: String?, createdAt: Long): Boolean {
        if (packageName.isNullOrEmpty()) return false
        val info = runCatching {
            @Suppress("DEPRECATION")
            packageManager()?.getPackageInfo(packageName, 0)
        }.getOrNull() ?: return false
        return info.lastUpdateTime >= createdAt
    }

    private fun armTimeout(sessionId: String, method: String) {
        mainHandler.postDelayed({
            val pending = readPending(sessionId) ?: return@postDelayed
            if (reportedTerminals.contains(sessionId)) return@postDelayed
            reportTerminal(
                sessionId,
                pending.method.ifEmpty { method },
                "timeout",
                pending.packageName,
                null,
                "CORE_E_INSTALL_TIMEOUT: ${TIMEOUT_MS / 1000}s"
            )
        }, TIMEOUT_MS)
    }

    private fun isUserRejected(output: String): Boolean {
        val lower = output.lowercase()
        return lower.contains("rejected permissions") ||
            lower.contains("install_failed_aborted")
    }

    private fun safeName(value: String): String =
        value.replace(Regex("[^A-Za-z0-9_.-]"), "_")

    private fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    private fun prefs() = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun persistPending(
        sessionId: String,
        packageName: String?,
        method: String,
        apkPath: String,
        installerSessionId: Int? = null
    ) {
        val payload = JSONObject().apply {
            put("packageName", packageName ?: JSONObject.NULL)
            put("method", method)
            put("createdAt", System.currentTimeMillis())
            put("apkPath", apkPath)
            put("installerSessionId", installerSessionId ?: JSONObject.NULL)
        }
        prefs()?.edit()?.putString(PREFS_KEY_PREFIX + sessionId, payload.toString())?.apply()
    }

    private fun readPending(sessionId: String): PendingInstall? =
        parsePending(prefs()?.getString(PREFS_KEY_PREFIX + sessionId, null))

    private fun parsePending(raw: String?): PendingInstall? {
        if (raw.isNullOrEmpty()) return null
        return runCatching {
            val json = JSONObject(raw)
            PendingInstall(
                packageName = if (json.isNull("packageName")) {
                    null
                } else {
                    json.optString("packageName").ifEmpty { null }
                },
                method = json.optString("method", "intent"),
                createdAt = json.optLong("createdAt", 0L),
                apkPath = if (json.isNull("apkPath")) null else json.optString("apkPath"),
                installerSessionId = if (!json.has("installerSessionId") ||
                    json.isNull("installerSessionId")
                ) {
                    null
                } else {
                    json.optInt("installerSessionId", -1).takeIf { it >= 0 }
                }
            )
        }.getOrNull()
    }

    private fun clearPending(sessionId: String) {
        prefs()?.edit()?.remove(PREFS_KEY_PREFIX + sessionId)?.apply()
    }

    private fun pendingJson(method: String, packageName: String?): String =
        resultJson(method, "pending", packageName, null, null)

    private fun installedJson(
        method: String,
        packageName: String?,
        versionName: String?
    ): String = resultJson(method, "installed", packageName, versionName, null)

    private fun resultJson(
        method: String,
        status: String,
        packageName: String? = null,
        versionName: String? = null,
        error: String? = null
    ): String = JSONObject().apply {
        put("method", method)
        put("status", status)
        put("packageName", packageName ?: JSONObject.NULL)
        put("versionName", versionName ?: JSONObject.NULL)
        put("error", error ?: JSONObject.NULL)
    }.toString()

    /** Persisted pending entry. */
    data class PendingInstall(
        val packageName: String?,
        val method: String,
        val createdAt: Long,
        val apkPath: String?,
        /** Numeric `PackageInstaller` session id, for process-death recovery. */
        val installerSessionId: Int?
    )

    /** Matched pending session. */
    data class PendingSession(
        val sessionId: String,
        val install: PendingInstall
    ) {
        val method: String get() = install.method
        val packageName: String? get() = install.packageName
    }

    private object PendingIntentFlags {
        fun forSession(): Int {
            val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                android.app.PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            return android.app.PendingIntent.FLAG_UPDATE_CURRENT or mutable
        }
    }
}
