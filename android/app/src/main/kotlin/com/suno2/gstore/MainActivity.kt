package com.suno2.gstore

import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {
    companion object {
        private const val CHANNEL = "gstore/system_intent"
        private const val APK_INFO_CHANNEL = "gstore/apk_info"
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
