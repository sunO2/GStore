package com.suno2.gstore

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * Shared `PackageManager` extraction used by the Dart `gstore/apk_info` and
 * `gstore/platform` channels. Keeps the signature/component rules in one place
 * so the two surfaces cannot drift.
 *
 * `installedAppJson` is the wire shape of the core `InstalledApp` DTO: the key
 * set is pinned by the plan's trap table and must stay exactly
 * `package_name, app_name, version_name, version_code, icon, is_system,
 * signature_sha256, source_dir, installer, target_sdk, min_sdk, abis`.
 */
object InventoryInspector {

    data class InstalledAppEntry(
        val packageName: String,
        val appName: String,
        val versionName: String,
        val versionCode: Long,
        val icon: String?,
        val isSystem: Boolean,
        val signatureSha256: String?,
        val sourceDir: String?,
        val installer: String?,
        val targetSdk: Int,
        val minSdk: Int,
        val abis: List<String>,
    )

    data class SignatureEntry(
        val algorithm: String,
        val subject: String,
        val sha256: String,
        val sha1: String,
        val kind: String,
    )

    data class SignatureReport(
        val entries: List<SignatureEntry>,
        val shape: String,
    )

    data class ComponentEntry(
        val kind: String,
        val name: String,
        val exported: Boolean,
        val enabled: Boolean,
        val processName: String?,
    )

    data class PermissionState(
        val name: String,
        val granted: Boolean,
        val neverForLocation: Boolean,
    )

    data class ComponentsReport(
        val components: List<ComponentEntry>,
        val permissionStates: List<PermissionState>,
    )

    fun installedApps(pm: PackageManager): List<InstalledAppEntry> {
        // One `getInstalledPackages` call. Signature flags ride along so
        // `signature_sha256` costs no extra per-app binder round trip.
        @Suppress("DEPRECATION")
        val packages = pm.getInstalledPackages(signatureFlags())
        return packages.mapNotNull { info -> entry(pm, info, installer = null) }
    }

    @Throws(PackageManager.NameNotFoundException::class)
    fun installedApp(pm: PackageManager, packageName: String): InstalledAppEntry {
        return entry(
            pm,
            pm.getPackageInfo(packageName, signatureFlags()),
            installer = installerPackage(pm, packageName),
        ) ?: throw PackageManager.NameNotFoundException(packageName)
    }

    @Throws(PackageManager.NameNotFoundException::class)
    fun sourceDir(pm: PackageManager, packageName: String): String? {
        return pm.getApplicationInfo(packageName, 0).sourceDir
    }

    @Throws(PackageManager.NameNotFoundException::class)
    fun permissions(pm: PackageManager, packageName: String): List<String> {
        return pm.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.toList() ?: emptyList()
    }

    @Throws(PackageManager.NameNotFoundException::class)
    fun signatures(pm: PackageManager, packageName: String): SignatureReport {
        val signFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val packageInfo = pm.getPackageInfo(packageName, signFlags)

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
                                history[index] to if (isCurrent) "current" else "history"
                            )
                        }
                    }
                }
            }
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures?.forEach { certEntries.add(it to "current") }
        }

        val entries = mutableListOf<SignatureEntry>()
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
                algorithm = cert.sigAlgName?.ifEmpty { "SHA256withRSA" } ?: "SHA256withRSA"
                sha256 = sha256Of(sig)
                sha1 = sha1Of(sig)
            } catch (e: Exception) {
                // A single unparseable certificate degrades to empty fields.
            }
            if (sha256.isNotEmpty() && !seenDigests.add(sha256)) continue
            entries.add(SignatureEntry(algorithm, subject, sha256, sha1, kind))
        }

        var shape = "single"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo
            if (signingInfo != null) {
                shape = when {
                    signingInfo.hasMultipleSigners() -> "multiple"
                    signingInfo.hasPastSigningCertificates() -> "rotation"
                    else -> "single"
                }
            }
        } else if (entries.size > 1) {
            shape = "multiple"
        }
        return SignatureReport(entries, shape)
    }

    @Throws(PackageManager.NameNotFoundException::class)
    fun components(pm: PackageManager, packageName: String): ComponentsReport {
        val packageInfo = pm.getPackageInfo(
            packageName,
            PackageManager.GET_ACTIVITIES or
                PackageManager.GET_SERVICES or
                PackageManager.GET_RECEIVERS or
                PackageManager.GET_PROVIDERS or
                PackageManager.GET_PERMISSIONS
        )

        val components = mutableListOf<ComponentEntry>()
        packageInfo.activities?.forEach {
            component(it.name, "ACTIVITY", it.exported, it.enabled, it.processName)
                ?.let(components::add)
        }
        packageInfo.services?.forEach {
            component(it.name, "SERVICE", it.exported, it.enabled, it.processName)
                ?.let(components::add)
        }
        packageInfo.receivers?.forEach {
            component(it.name, "RECEIVER", it.exported, it.enabled, it.processName)
                ?.let(components::add)
        }
        packageInfo.providers?.forEach {
            component(it.name, "PROVIDER", it.exported, it.enabled, it.processName)
                ?.let(components::add)
        }

        val permissionStates = mutableListOf<PermissionState>()
        val perms = packageInfo.requestedPermissions ?: emptyArray()
        val permFlags = packageInfo.requestedPermissionsFlags ?: IntArray(0)
        for (index in perms.indices) {
            val granted = index < permFlags.size &&
                (permFlags[index] and PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0
            val neverForLocation = index < permFlags.size &&
                (permFlags[index] and PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0
            permissionStates.add(PermissionState(perms[index], granted, neverForLocation))
        }
        return ComponentsReport(components, permissionStates)
    }

    fun installedAppJson(entry: InstalledAppEntry): JSONObject {
        return JSONObject().apply {
            put("package_name", entry.packageName)
            put("app_name", entry.appName)
            put("version_name", entry.versionName)
            put("version_code", entry.versionCode)
            put("icon", entry.icon ?: JSONObject.NULL)
            put("is_system", entry.isSystem)
            put("signature_sha256", entry.signatureSha256 ?: JSONObject.NULL)
            put("source_dir", entry.sourceDir ?: JSONObject.NULL)
            put("installer", entry.installer ?: JSONObject.NULL)
            put("target_sdk", entry.targetSdk)
            put("min_sdk", entry.minSdk)
            put("abis", JSONArray(entry.abis))
        }
    }

    private fun signatureFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    private fun entry(
        pm: PackageManager,
        info: PackageInfo,
        installer: String?,
    ): InstalledAppEntry? {
        val appInfo = info.applicationInfo ?: return null
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return InstalledAppEntry(
            packageName = info.packageName ?: appInfo.packageName ?: return null,
            appName = appInfo.loadLabel(pm)?.toString() ?: "",
            versionName = info.versionName ?: "",
            versionCode = versionCode,
            icon = appInfo.icon.takeIf { it != 0 }?.let { "resource://$it" },
            isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
            signatureSha256 = firstSignerSha256(info),
            sourceDir = appInfo.sourceDir,
            installer = installer,
            targetSdk = appInfo.targetSdkVersion,
            minSdk = appInfo.minSdkVersion,
            abis = deviceAbis(),
        )
    }

    /** First (deduped) signer SHA-256; null when the package exposes no certificate. */
    private fun firstSignerSha256(info: PackageInfo): String? {
        val signers: List<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return null
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners?.toList().orEmpty()
            } else {
                // Current signer is the last entry of the rotation history.
                listOfNotNull(signingInfo.signingCertificateHistory?.lastOrNull())
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.toList().orEmpty()
        }
        val seen = linkedSetOf<String>()
        for (signer in signers) {
            val digest = sha256Of(signer)
            if (digest.isNotEmpty() && seen.add(digest)) return digest
        }
        return null
    }

    /**
     * The public SDK exposes no per-app ABI list — `ApplicationInfo.primaryCpuAbi`
     * and the per-split ABI data are hidden APIs — so the device ABI list is the
     * documented fallback, matching `PlatformFacts.abis`.
     */
    private fun deviceAbis(): List<String> = Build.SUPPORTED_ABIS.toList()

    /**
     * Install source is absent from `getInstalledPackages`, and a per-app lookup
     * would turn the bulk scan into an N+1 query, so list entries report unknown;
     * the single-app path resolves the real installer.
     */
    private fun installerPackage(pm: PackageManager, packageName: String): String? =
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                pm.getInstallSourceInfo(packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                pm.getInstallerPackageName(packageName)
            }
        }.getOrNull()?.takeIf { it.isNotEmpty() }

    private fun sha256Of(signature: Signature): String =
        MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString(":") { "%02x".format(it.toInt() and 0xFF) }

    private fun sha1Of(signature: Signature): String =
        MessageDigest.getInstance("SHA-1")
            .digest(signature.toByteArray())
            .joinToString(":") { "%02x".format(it.toInt() and 0xFF) }

    private fun component(
        name: String?,
        kind: String,
        exported: Boolean,
        enabled: Boolean,
        processName: String?,
    ): ComponentEntry? {
        if (name.isNullOrEmpty()) return null
        return ComponentEntry(
            kind = kind,
            name = name,
            exported = exported,
            enabled = enabled,
            processName = processName?.takeIf { it.isNotEmpty() },
        )
    }
}
