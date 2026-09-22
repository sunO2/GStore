package com.suno2.gstore

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors

/**
 * 无 UI 的 VPN 授权中转 Activity。
 *
 * 负责展示系统的 VPN 同意对话框并依据结果启动 [ProxyVpnService]。把这段
 * Activity-result 逻辑放在这里，是为了让 [MainActivity] 只保留"触发"（method
 * channel 转发），不承载任何 VPN 逻辑。
 *
 * 调用入口（MainActivity 的 `gstore/proxy_vpn` 通道 "prepare"）：
 * 启动本 Activity 并附配置 JSON；本 Activity 自行完成同意流程、启动服务、
 * **等待 TUN fd 真正装进 Rust 宿主**后才返回结果。
 */
class VpnConsentActivity : Activity() {

    companion object {
        private const val TAG = "VpnConsentActivity"
        private const val REQUEST_VPN_CONSENT = 0x5651
        const val EXTRA_CONFIG = "config"

        // fd 安装等待上限：必须覆盖 establish()+nativeSetTunFd() 的耗时，又要远小于
        // Dart 侧可感知的卡顿阈值。超时按失败处理，绝不无限等待。
        private const val TUN_FD_WAIT_MS = 3000L
        private const val TUN_FD_POLL_MS = 50L
    }

    /// 启动请求幂等守卫：本 Activity 每个实例只允许发起一次服务启动与 fd 等待，
    /// 保证结果恰好回填一次（onCreate 与 onActivityResult 都可能走到同一条路径）。
    private var startRequested = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val consent = VpnService.prepare(this)
        if (consent == null) {
            // 已获授权：直接启动服务。
            startServiceAndAwaitFd()
        } else {
            @Suppress("DEPRECATION")
            startActivityForResult(consent, REQUEST_VPN_CONSENT)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VPN_CONSENT) return
        if (resultCode == RESULT_OK) {
            startServiceAndAwaitFd()
        } else {
            Log.w(TAG, "用户拒绝 VPN 授权")
            finishWith(RESULT_CANCELED)
        }
    }

    /**
     * 启动服务并等待 fd 就绪后才回结果。Dart 侧 `prepare()` 返回后立刻 `core.start`，
     * 而 `core.start(mode=vpn)` 要求宿主已有 pending TUN fd（否则 422
     * PROXY_TUN_FD_INVALID）。因此本 Activity 的结果码必须代表"fd 已安装"，
     * 不能只代表用户点了同意。
     *
     * 幂等：每个实例只进入一次；服务启动异常一律按取消返回，绝不抛出。
     */
    private fun startServiceAndAwaitFd() {
        if (startRequested) {
            Log.w(TAG, "已发起过启动请求，忽略重复调用")
            return
        }
        startRequested = true

        val config = intent.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrEmpty()) {
            Log.w(TAG, "缺少配置，无法启动 VPN")
            finishWith(RESULT_CANCELED)
            return
        }
        val started = runCatching { ProxyVpnService.start(this, config) }
            .onFailure { Log.w(TAG, "启动 VPN 服务失败: ${it.message}", it) }
            .isSuccess
        if (!started) {
            finishWith(RESULT_CANCELED)
            return
        }
        waitForTunFdThenFinish()
    }

    /// 统一出口：确保 setResult + finish 成对且只执行一次。
    private fun finishWith(resultCode: Int) {
        setResult(resultCode)
        finish()
    }

    /**
     * 有界轮询 [ProxyVpnService.tunFdInstalled]：轮询放在后台线程，结果回 UI 线程。
     * 超时或服务中途死亡（标志始终 false）→ 记警告并按取消返回，绝不永久阻塞。
     */
    private fun waitForTunFdThenFinish() {
        val executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "gstore-vpn-consent-wait")
        }
        executor.execute {
            val deadline = System.currentTimeMillis() + TUN_FD_WAIT_MS
            var installed = ProxyVpnService.tunFdInstalled
            while (!installed && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(TUN_FD_POLL_MS)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
                installed = ProxyVpnService.tunFdInstalled
            }
            if (!installed) {
                Log.w(TAG, "等待 TUN fd 安装超时（${TUN_FD_WAIT_MS}ms），按取消返回")
            }
            runOnUiThread {
                finishWith(if (installed) RESULT_OK else RESULT_CANCELED)
            }
            executor.shutdown()
        }
    }
}
