package com.suno2.gstore

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * Kotlin side of the Rust notification/FGS host.
 *
 * The Rust sink calls these statics with a stable JSON payload. Notifications
 * are never posted while the user has denied `POST_NOTIFICATIONS`; in that case
 * the caller receives `CORE_E_NOTIFY_PERMISSION_DENIED`.
 */
object NotificationBridge {

    private const val TAG = "NotificationBridge"

    /** Progress notification channel (shared with the legacy Dart path). */
    const val DOWNLOAD_CHANNEL_ID = "download_progress"
    private const val DOWNLOAD_CHANNEL_NAME = "下载任务"

    /** Foreground-service notification channel. */
    const val FOREGROUND_CHANNEL_ID = "foreground_service"
    private const val FOREGROUND_CHANNEL_NAME = "后台下载"

    /** Stable foreground-service notification id. */
    const val FOREGROUND_NOTIFICATION_ID = 997

    const val EXTRA_FOREGROUND_ID = "com.suno2.gstore.extra.FOREGROUND_ID"
    const val EXTRA_NOTIFICATION_JSON = "com.suno2.gstore.extra.NOTIFICATION_JSON"
    const val EXTRA_NOTIFICATION_PAYLOAD = "com.suno2.gstore.extra.NOTIFICATION_PAYLOAD"

    private const val DEFAULT_PAYLOAD = "download_center"
    private const val REQUEST_POST_NOTIFICATIONS = 9971

    private const val CODE_NOT_INITIALIZED = "CORE_E_PLATFORM_NOT_INITIALIZED"
    private const val CODE_PERMISSION_DENIED = "CORE_E_NOTIFY_PERMISSION_DENIED"
    private const val CODE_NOTIFY_FAILED = "CORE_E_NOTIFY_FAILED"
    private const val CODE_FGS_FAILED = "CORE_E_FGS_FAILED"

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var currentActivity: Activity? = null

    @Volatile
    private var initialized = false

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * Caches the application context and starts tracking the resumed activity
     * so the first notification can request `POST_NOTIFICATIONS` when possible.
     * Best-effort: any failure is logged, never thrown.
     */
    @JvmStatic
    fun init(context: Context) {
        val application = context.applicationContext ?: context
        appContext = application
        if (context is Activity) currentActivity = context
        if (application is Application) {
            runCatching {
                application.registerActivityLifecycleCallbacks(
                    object : Application.ActivityLifecycleCallbacks {
                        override fun onActivityResumed(activity: Activity) {
                            currentActivity = activity
                        }

                        override fun onActivityPaused(activity: Activity) {
                            if (currentActivity === activity) currentActivity = null
                        }

                        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
                        override fun onActivityStarted(activity: Activity) = Unit
                        override fun onActivityStopped(activity: Activity) = Unit
                        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
                        override fun onActivityDestroyed(activity: Activity) = Unit
                    },
                )
            }.onFailure { Log.w(TAG, "registerActivityLifecycleCallbacks 失败（忽略）: ${it.message}") }
        }
        if (initialized) return
        runCatching { ensureChannels(application) }
            .onSuccess { initialized = true }
            .onFailure { Log.w(TAG, "通知渠道初始化失败（忽略）: ${it.message}") }
    }

    /** Whether the user currently allows notifications. */
    @JvmStatic
    fun notificationsEnabled(): Boolean {
        val context = appContext ?: return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /** Requests `POST_NOTIFICATIONS`; must run with an Activity context. */
    @JvmStatic
    fun requestPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        runCatching {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_POST_NOTIFICATIONS,
            )
        }.onFailure { Log.w(TAG, "请求通知权限失败（忽略）: ${it.message}") }
    }

    /** Creates the download and foreground-service channels when missing. */
    @JvmStatic
    fun ensureChannels(context: Context) {
        createChannel(context, DOWNLOAD_CHANNEL_ID, DOWNLOAD_CHANNEL_NAME, "下载任务进度通知")
        createChannel(context, FOREGROUND_CHANNEL_ID, FOREGROUND_CHANNEL_NAME, "保持后台下载运行")
    }

    private fun createChannel(context: Context, id: String, name: String, description: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        if (manager.getNotificationChannel(id) != null) return
        val channel = NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW).apply {
            this.description = description
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun ensureChannelFor(context: Context, id: String) {
        if (id == DOWNLOAD_CHANNEL_ID || id == FOREGROUND_CHANNEL_ID) {
            ensureChannels(context)
        } else {
            createChannel(context, id, "通知", "GStore 通知")
        }
    }

    /** Builds one notification from the stable Rust payload. */
    @JvmStatic
    fun buildNotification(
        context: Context,
        json: String,
        fallbackId: Int,
        forceOngoing: Boolean = false,
    ): Notification {
        val payload = runCatching { JSONObject(json) }.getOrElse { JSONObject() }
        val channelId = payload.optString("channelId", DOWNLOAD_CHANNEL_ID)
        ensureChannelFor(context, channelId)
        val progress = if (payload.has("progress") && !payload.isNull("progress")) {
            payload.optInt("progress", 0).coerceIn(0, 100)
        } else {
            null
        }
        val ongoing = payload.optBoolean("ongoing", forceOngoing)
        val tapPayload = if (payload.has("payload") && !payload.isNull("payload")) {
            payload.optString("payload", DEFAULT_PAYLOAD)
        } else {
            DEFAULT_PAYLOAD
        }
        val title = payload.optString("title", "")
        val body = payload.optString("body", "")
        val contentIntent = PendingIntent.getActivity(
            context,
            fallbackId,
            Intent(context, MainActivity::class.java).apply {
                putExtra(EXTRA_NOTIFICATION_PAYLOAD, tapPayload)
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher_foreground)
            .setContentTitle(title)
            .setContentText(body)
            .setOnlyAlertOnce(true)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setProgress(100, progress ?: 0, progress == null)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    /** Posts one notification. Never throws; failures are typed JSON. */
    @JvmStatic
    fun notify(json: String): String {
        val context = appContext ?: return errorJson(CODE_NOT_INITIALIZED, "NotificationBridge not initialized")
        return try {
            ensureChannels(context)
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                currentActivity?.let { activity ->
                    mainHandler.post { requestPermission(activity) }
                }
                errorJson(CODE_PERMISSION_DENIED, "notifications disabled")
            } else {
                val payload = JSONObject(json)
                val id = payload.optInt("id", 0)
                NotificationManagerCompat.from(context).notify(
                    id,
                    buildNotification(context, json, id),
                )
                okJson()
            }
        } catch (e: SecurityException) {
            errorJson(CODE_PERMISSION_DENIED, e.message ?: "notifications denied")
        } catch (e: Exception) {
            Log.w(TAG, "notify 失败: ${e.message}")
            errorJson(CODE_NOTIFY_FAILED, e.message ?: "notify failed")
        }
    }

    /** Starts [DownloadForegroundService] with one serialized payload. */
    @JvmStatic
    fun startForeground(notificationId: Int, json: String): String {
        val context = appContext ?: return errorJson(CODE_NOT_INITIALIZED, "NotificationBridge not initialized")
        return try {
            ensureChannels(context)
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                putExtra(EXTRA_FOREGROUND_ID, notificationId)
                putExtra(EXTRA_NOTIFICATION_JSON, json)
            }
            ContextCompat.startForegroundService(context, intent)
            okJson()
        } catch (e: Exception) {
            Log.w(TAG, "startForeground 失败: ${e.message}")
            errorJson(CODE_FGS_FAILED, e.message ?: "start foreground failed")
        }
    }

    /** Stops [DownloadForegroundService]; idempotent. */
    @JvmStatic
    fun stopForeground(): String {
        val context = appContext ?: return errorJson(CODE_NOT_INITIALIZED, "NotificationBridge not initialized")
        return try {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
            okJson()
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground 失败: ${e.message}")
            errorJson(CODE_FGS_FAILED, e.message ?: "stop foreground failed")
        }
    }

    private fun okJson(): String = JSONObject().put("ok", true).toString()

    private fun errorJson(code: String, message: String): String =
        JSONObject().put("ok", false).put("code", code).put("message", message).toString()
}
