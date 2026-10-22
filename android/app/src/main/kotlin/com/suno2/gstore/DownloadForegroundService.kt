package com.suno2.gstore

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * `dataSync` foreground service used by the Rust notification host while
 * downloads run. Repeated starts only update the same notification; a malformed
 * payload falls back to a generic "background download" notification.
 */
class DownloadForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getIntExtra(
            NotificationBridge.EXTRA_FOREGROUND_ID,
            NotificationBridge.FOREGROUND_NOTIFICATION_ID,
        ) ?: NotificationBridge.FOREGROUND_NOTIFICATION_ID
        val payload = intent?.getStringExtra(NotificationBridge.EXTRA_NOTIFICATION_JSON)
        val notification = runCatching {
            buildNotification(payload, id)
        }.getOrElse {
            Log.w(TAG, "前台通知构建失败，使用默认内容: ${it.message}")
            buildNotification(null, id)
        }
        startForeground(id, notification)
        return START_NOT_STICKY
    }

    private fun buildNotification(payload: String?, id: Int): Notification {
        val effective = payload?.takeIf { it.isNotBlank() }
            ?: """{"title":"后台下载中","body":"GStore 正在后台下载应用"}"""
        return NotificationBridge.buildNotification(this, effective, id, forceOngoing = true)
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private companion object {
        const val TAG = "DownloadForegroundService"
    }
}
