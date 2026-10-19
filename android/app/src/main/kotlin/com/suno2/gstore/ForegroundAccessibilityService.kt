package com.suno2.gstore

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import org.json.JSONObject

/**
 * 前台应用事件源（AccessibilityService）。
 *
 * 背景：`ForegroundWatcher` 原本每 5s 经 Shizuku 执行一次
 * `dumpsys activity activities`。开启本无障碍服务后，系统会在每次
 * `TYPE_WINDOW_STATE_CHANGED` 时推送当前包名 / Activity，Rust 宿主经 JNI
 * 直读缓存即可，**零 shell、零轮询**。
 *
 * ## 边界与安全
 * - 只订阅窗口状态变化，`canRetrieveWindowContent=false`：**不读取任何界面内容**；
 * - 事件回调里只保存 package / class 两个字符串与时间戳，不落盘、不上传；
 * - [isEnabled] 通过 `AccessibilityManager.getEnabledAccessibilityServiceList`
 *   与自身 `resolveInfo` 比对，任何异常一律返回 `false`；
 * - [readJson] 永不抛出：异常降级为 `enabled=false` 的最小 JSON。
 *
 * 服务未开启时，`ForegroundWatcher` 自动回退到既有 `dumpsys` 路径，行为不变。
 */
class ForegroundAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ForegroundA11y"

        /** 最近一次窗口事件的前台包名（`null` = 尚未收到事件）。 */
        @Volatile
        var currentPackage: String? = null
            private set

        /** 最近一次窗口事件的 Activity 类名（`null` = 未知）。 */
        @Volatile
        var currentActivity: String? = null
            private set

        /** 最近一次窗口事件时间（Unix ms；`0` = 尚未收到事件）。 */
        @Volatile
        var updatedAtMs: Long = 0L
            private set

        /**
         * 本服务是否已在系统设置中启用。
         *
         * 与 `getEnabledAccessibilityServiceList(FEEDBACK_ALL_MASK)` 的
         * `resolveInfo.serviceInfo.{packageName,name}` 逐项比对；任何异常 →
         * `false`（绝不崩溃）。
         */
        @JvmStatic
        fun isEnabled(context: Context): Boolean = try {
            val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE)
                as? AccessibilityManager
            if (manager == null) {
                false
            } else {
                val expectedPackage = context.packageName
                val expectedName = ForegroundAccessibilityService::class.java.name
                manager.getEnabledAccessibilityServiceList(
                    AccessibilityServiceInfo.FEEDBACK_ALL_MASK
                ).any { info ->
                    val serviceInfo = info.resolveInfo?.serviceInfo
                    serviceInfo != null &&
                        serviceInfo.packageName == expectedPackage &&
                        serviceInfo.name == expectedName
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "isEnabled 失败（按未启用处理）: ${e.message}")
            false
        }

        /**
         * JNI 直读入口：`{"enabled":bool,"package":string|null,
         * "activity":string|null,"updatedAtMs":long}`。
         *
         * 任何异常 → 最小 JSON（`enabled=false`），绝不抛出。
         */
        @JvmStatic
        fun readJson(context: Context): String = try {
            JSONObject().apply {
                put("enabled", isEnabled(context))
                put("package", currentPackage ?: JSONObject.NULL)
                put("activity", currentActivity ?: JSONObject.NULL)
                put("updatedAtMs", updatedAtMs)
            }.toString()
        } catch (e: Exception) {
            Log.w(TAG, "readJson 失败: ${e.message}")
            "{\"enabled\":false,\"package\":null,\"activity\":null,\"updatedAtMs\":0}"
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        try {
            if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
            val packageName = event.packageName?.toString()
            if (packageName.isNullOrEmpty()) return
            currentPackage = packageName
            currentActivity = event.className?.toString()
            updatedAtMs = System.currentTimeMillis()
        } catch (e: Exception) {
            // 事件回调绝不崩溃：单条异常丢弃即可。
            Log.w(TAG, "onAccessibilityEvent 失败（忽略）: ${e.message}")
        }
    }

    override fun onInterrupt() {
        // 无需中断处理：本服务只做只读事件缓存。
    }
}
