package com.suno2.gstore

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * Android 快捷设置（QS）磁贴：代理开关。
 *
 * ## 职责边界（钉死）
 * 磁贴**只负责两件事**：
 *  - 已运行时 → 调用 [ProxyVpnService.stop] 断开（拆除由原生服务完成）；
 *  - 未运行时 → 拉起 [MainActivity] 并携带 [MainActivity.ACTION_PROXY_CONNECT]，
 *    由 Dart 侧编排完整的连接流程（prepare → core.start → 路由重放）。
 *
 * 磁贴**绝不**直接调用 [ProxyVpnService.start]：连接需要 Dart 编排，绕过它会导致
 * 宿主状态与 Dart 引擎不一致。磁贴仅"发信号"，消费方是 Dart（poll 契约）。
 *
 * 所有回调均包 try/catch：磁贴属于系统 UI，任何异常都不得让 SystemUI 崩溃。
 */
class ProxyTileService : TileService() {

    companion object {
        private const val TAG = "ProxyTileService"

        /** 使用 `startActivityAndCollapse(PendingIntent)` 重载的最低 API（34 / U）。 */
        private const val API_ANDROID_14 = 34
    }

    override fun onTileAdded() {
        super.onTileAdded()
        // 无需持久化状态，磁贴状态完全由 ProxyVpnService.isRunning 推导。
    }

    override fun onTileRemoved() {
        super.onTileRemoved()
        // 同上，无副作用。
    }

    override fun onStartListening() {
        super.onStartListening()
        try {
            val t = qsTile ?: return
            t.state = if (ProxyVpnService.isRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            t.updateTile()
        } catch (t: Throwable) {
            Log.w(TAG, "onStartListening 更新磁贴失败（忽略）: ${t.message}")
        }
    }

    override fun onClick() {
        super.onClick()
        try {
            val t = qsTile
            if (ProxyVpnService.isRunning) {
                // 断开：原生服务自行拆除，磁贴立即置为未激活。
                ProxyVpnService.stop(this)
                t?.state = Tile.STATE_INACTIVE
                t?.updateTile()
            } else {
                // 连接：拉起 App 并携带 action，由 Dart 侧消费后编排连接。
                val intent = Intent(this, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_PROXY_CONNECT)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (Build.VERSION.SDK_INT >= API_ANDROID_14) {
                    val pi = PendingIntent.getActivity(
                        this,
                        0,
                        intent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    startActivityAndCollapse(pi)
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(intent)
                }
                // 连接由 Dart 编排：不在磁贴内改状态，稍后 onStartListening
                // 会依据 ProxyVpnService.isRunning 反映真实结果。
            }
        } catch (t: Throwable) {
            // 磁贴错误绝不向上冒泡（SystemUI 稳定性）。
            Log.w(TAG, "onClick 处理失败（忽略）: ${t.message}")
        }
    }
}
