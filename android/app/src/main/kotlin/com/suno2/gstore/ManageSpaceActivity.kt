package com.suno2.gstore

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// 系统"管理空间"入口中转 Activity。
///
/// 由 Android 系统设置（设置 → 应用 → GStore → 存储 → 管理空间）经
/// `android:manageSpaceActivity` 配置启动。本 Activity **不渲染任何界面、
/// 不创建 Flutter 引擎**——只负责携带"管理空间"标记拉起 MainActivity
/// （应用唯一引擎所在），随即自我关闭，由 MainActivity 路由到缓存管理页。
///
/// 使用 CLEAR_TOP | SINGLE_TOP 复用已存在的 MainActivity 实例：
/// - 应用已在后台运行 → 带回前台并复用主引擎，不产生第二个引擎
/// - 应用未运行 → 正常冷启动 MainActivity
class ManageSpaceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val intent = Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_MANAGE_SPACE)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
                    or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    or Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        startActivity(intent)
        finish()
    }
}
