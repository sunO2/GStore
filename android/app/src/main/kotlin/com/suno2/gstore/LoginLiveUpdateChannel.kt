package com.suno2.gstore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * GitHub 登录验证码 Live Update 通知（Android 16+）。
 *
 * Android 16 的 Live Updates（promoted ongoing notifications）是唯一无需厂商 SDK、
 * 无需审核的「上岛」通道：OPPO ColorOS 16 / 荣耀 MagicOS / 小米 HyperOS / vivo
 * OriginOS 由系统自行把 promoted 通知渲染成各家的灵动岛形态。
 *
 * 本通道只负责 Android 16+ 的通知；低版本仍由 Dart 侧 flutter_local_notifications
 * 兜底（普通进度通知）。
 */
object LoginLiveUpdateChannel {
    private const val TAG = "LoginLiveUpdate"

    private const val CHANNEL_METHOD = "gstore/login_live_update"
    private const val NOTIFICATION_CHANNEL_ID = "login_poll"
    private const val NOTIFICATION_CHANNEL_NAME = "GitHub 登录"
    private const val NOTIFICATION_ID = 999

    /** Android 16 起才存在 Notification.ProgressStyle / promoted 通知。 */
    private const val MIN_SDK = 36

    fun register(messenger: BinaryMessenger, context: Context) {
        ensureChannel(context)
        MethodChannel(messenger, CHANNEL_METHOD).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= MIN_SDK)
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "canPostPromoted" -> {
                    result.success(Build.VERSION.SDK_INT >= MIN_SDK &&
                        context.getSystemService(NotificationManager::class.java)
                            .canPostPromotedNotifications())
                }
                "show" -> {
                    val title = call.argument<String>("title") ?: "验证码"
                    val body = call.argument<String>("body") ?: ""
                    val progress = call.argument<Int>("progress") ?: 0
                    val shortText = call.argument<String>("shortText") ?: ""
                    if (Build.VERSION.SDK_INT >= MIN_SDK) {
                        result.success(post(context, title, body, progress, shortText))
                    } else {
                        result.success(
                            mapOf(
                                "posted" to false,
                                "promoted" to false,
                                "allowed" to false,
                            )
                        )
                    }
                }
                "cancel" -> {
                    context.getSystemService(NotificationManager::class.java)
                        .cancel(NOTIFICATION_ID)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        // 与 flutter_local_notifications 的渠道同 id/同名：已存在时不改变用户设置。
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "GitHub 设备验证码与有效期倒计时"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * 发布/更新验证码通知。
     *
     * [progress] 为剩余有效期百分比（0~100），进度条随 Dart 侧每秒 tick 更新。
     */
    @Suppress("NewApi")
    private fun post(
        context: Context,
        title: String,
        body: String,
        progress: Int,
        shortText: CharSequence,
    ): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_login)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(
                Notification.ProgressStyle()
                    .setProgress(progress.coerceIn(0, 100))
                    .setStyledByProgress(false),
            )

        requestPromotion(builder)
        setShortCriticalText(builder, shortText)

        val notification = builder.build()
        manager.notify(NOTIFICATION_ID, notification)

        // 仅用于诊断（adb logcat -s LoginLiveUpdate）：确认系统是否真的提升了通知。
        val activeFlags = manager.activeNotifications
            .firstOrNull { it.id == NOTIFICATION_ID }
            ?.notification
            ?.flags ?: 0
        val promoted = activeFlags and Notification.FLAG_PROMOTED_ONGOING != 0
        val allowed = manager.canPostPromotedNotifications()
        Log.i(TAG, "live update posted: promoted=$promoted allowed=$allowed progress=$progress")
        return mapOf("posted" to true, "promoted" to promoted, "allowed" to allowed)
    }

    /**
     * 请求系统提升为 Live Update。
     *
     * Android 16.0（旧模型）靠 `android.colorized=true`；Android 16 QPR1+/17
     * （新模型）靠 `setRequestPromotedOngoing`（或同名 extra），且必须 colorized=false。
     * 两种模型互斥，用反射判断当前系统是否有 setter。
     */
    private fun requestPromotion(builder: Notification.Builder) {
        val hasSetter = try {
            Notification.Builder::class.java
                .getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType)
                .invoke(builder, true)
            true
        } catch (_: Throwable) {
            false
        }
        if (hasSetter) return

        builder.addExtras(Bundle().apply {
            putBoolean("android.requestPromotedOngoing", true)
            putBoolean("android.colorized", true)
        })
    }

    /** 状态栏胶囊文案（Android 16 起支持），失败静默。 */
    private fun setShortCriticalText(builder: Notification.Builder, text: CharSequence) {
        if (text.isEmpty()) return
        try {
            Notification.Builder::class.java
                .getMethod("setShortCriticalText", CharSequence::class.java)
                .invoke(builder, text)
        } catch (_: Throwable) {
            // 旧系统/旧 SDK 没有该 API，忽略。
        }
    }
}
