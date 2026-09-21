package com.suno2.gstore

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Log

/**
 * 无 UI 的 VPN 授权中转 Activity。
 *
 * 负责展示系统的 VPN 同意对话框并依据结果启动 [ProxyVpnService]。把这段
 * Activity-result 逻辑放在这里，是为了让 [MainActivity] 只保留"触发"（method
 * channel 转发），不承载任何 VPN 逻辑。
 *
 * 调用入口（MainActivity 的 `gstore/proxy_vpn` 通道 "prepare"）：
 * 启动本 Activity 并附配置 JSON；本 Activity 自行完成同意流程后返回结果。
 */
class VpnConsentActivity : Activity() {

    companion object {
        private const val TAG = "VpnConsentActivity"
        private const val REQUEST_VPN_CONSENT = 0x5651
        const val EXTRA_CONFIG = "config"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val consent = VpnService.prepare(this)
        if (consent == null) {
            // 已获授权：直接启动服务。
            startAndFinish(RESULT_OK)
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
            startAndFinish(RESULT_OK)
        } else {
            Log.w(TAG, "用户拒绝 VPN 授权")
            setResult(RESULT_CANCELED)
            finish()
        }
    }

    private fun startAndFinish(resultCode: Int) {
        val config = intent.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrEmpty()) {
            Log.w(TAG, "缺少配置，无法启动 VPN")
        } else {
            ProxyVpnService.start(this, config)
        }
        setResult(resultCode)
        finish()
    }
}
