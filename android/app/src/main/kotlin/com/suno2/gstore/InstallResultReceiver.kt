package com.suno2.gstore

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

/**
 * Terminal install results for [InstallerBridge].
 *
 * Two paths land here:
 * - the explicit `PendingIntent` broadcast from a `PackageInstaller` session
 *   ([InstallerBridge.ACTION_INSTALL_COMMIT]); and
 * - `PACKAGE_ADDED` / `PACKAGE_REPLACED` for the system-intent fallback, matched
 *   against the persisted pending session for that package.
 *
 * The receiver is `exported="false"`; the PackageInstaller path needs no intent
 * filter because its `PendingIntent` targets this class explicitly. Every
 * failure is logged and never crashes the process.
 */
class InstallResultReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return
        try {
            when (intent.action) {
                Intent.ACTION_PACKAGE_ADDED,
                Intent.ACTION_PACKAGE_REPLACED -> handlePackageAdded(intent)

                InstallerBridge.ACTION_INSTALL_COMMIT -> handleCommit(context, intent)

                else -> Unit
            }
        } catch (t: Throwable) {
            Log.w(TAG, "install result receiver failed: ${t.message}")
        }
    }

    private fun handlePackageAdded(intent: Intent) {
        val packageName = intent.data?.schemeSpecificPart ?: return
        val pending = InstallerBridge.pendingSessionForPackage(packageName) ?: return
        val version = InstallerBridge.installedVersionFor(packageName)
        InstallerBridge.reportTerminal(
            pending.sessionId,
            pending.method,
            "installed",
            packageName,
            version,
            null
        )
    }

    private fun handleCommit(context: Context, intent: Intent) {
        val sessionId = intent.getStringExtra(InstallerBridge.EXTRA_SESSION_KEY)
        if (sessionId.isNullOrEmpty()) {
            Log.w(TAG, "PackageInstaller callback without a session id")
            return
        }

        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val statusMessage = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val packageName = intent.getStringExtra(InstallerBridge.EXTRA_PACKAGE_NAME)
            ?: intent.getStringExtra(PackageInstaller.EXTRA_PACKAGE_NAME)

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val userAction = userActionIntent(intent)
                if (userAction != null) {
                    userAction.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { context.startActivity(userAction) }
                        .onFailure { Log.w(TAG, "could not start install confirmation: ${it.message}") }
                }
                // Stay pending; the terminal callback follows after the user acts.
            }

            PackageInstaller.STATUS_SUCCESS -> {
                val installed = packageName
                    ?: InstallerBridge.pendingPackageFor(sessionId)
                InstallerBridge.reportTerminal(
                    sessionId,
                    "package_installer",
                    "installed",
                    installed,
                    InstallerBridge.installedVersionFor(installed.orEmpty()),
                    null
                )
            }

            PackageInstaller.STATUS_FAILURE_BLOCKED,
            PackageInstaller.STATUS_FAILURE_ABORTED -> {
                InstallerBridge.reportTerminal(
                    sessionId,
                    "package_installer",
                    "denied",
                    packageName,
                    null,
                    "CORE_E_INSTALL_USER_REJECTED: ${statusMessage.orEmpty()}".trim()
                )
            }

            PackageInstaller.STATUS_FAILURE,
            PackageInstaller.STATUS_FAILURE_INVALID,
            PackageInstaller.STATUS_FAILURE_CONFLICT,
            PackageInstaller.STATUS_FAILURE_STORAGE,
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
            PackageInstaller.STATUS_FAILURE_TIMEOUT -> {
                val code = if (status == PackageInstaller.STATUS_FAILURE_TIMEOUT) {
                    "CORE_E_INSTALL_TIMEOUT"
                } else {
                    "CORE_E_INSTALL_FAILED"
                }
                InstallerBridge.reportTerminal(
                    sessionId,
                    "package_installer",
                    if (status == PackageInstaller.STATUS_FAILURE_TIMEOUT) "timeout" else "failed",
                    packageName,
                    null,
                    "$code: ${statusMessage.orEmpty()}".trim()
                )
            }

            else -> {
                // STATUS_INVALID / STATUS_ABANDONED are not public constants on
                // every API level; treat any other terminal code as failed.
                InstallerBridge.reportTerminal(
                    sessionId,
                    "package_installer",
                    "failed",
                    packageName,
                    null,
                    "CORE_E_INSTALL_FAILED: status=$status ${statusMessage.orEmpty()}".trim()
                )
            }
        }
    }

    private fun userActionIntent(intent: Intent): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
    }

    private companion object {
        const val TAG = "InstallResultReceiver"
    }
}
