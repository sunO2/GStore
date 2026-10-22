/// 统一特权 shell 门面的 **Dart 入口**。
///
/// 数据通路（架构固定，Todo 4/5 之后）：
/// `Dart → gstore/platform.exec → Kotlin PlatformChannel → ShizukuExecBridge.exec
/// → Shizuku.newProcess(["sh","-c",cmd])`。
/// 即：特权 shell 命令的**唯一**执行源是 `gstore/platform.exec`；Dart/业务层不再
/// 经 JNI，也不再经 `shizuku_api` 插件执行命令（插件仅保留 `pingBinder` /
/// `checkPermission` / `requestPermission` 等需要 Activity 的权限 UI 关注点）。
///
/// 契约与既有 `CommandRunner`（`privileged_shell.dart` /
/// `third_party_perf_service.dart` / `system_fps_service.dart`）**逐字一致**：
/// * 返回 **stdout+stderr 合并**文本；
/// * **没有退出码**（成败由调用方经哨兵 `GSTORE_RESULT` 或输出形状判定）；
/// * 未执行 / 失败 / Shizuku 不可用一律返回 `null`（绝不抛出）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/platform/platform_channel.dart';

final PlatformChannelClient _client = PlatformChannelClient();

/// 执行一条特权 shell 命令，返回 stdout+stderr 合并文本；未执行 / 失败返回 `null`。
///
/// 生产实现 = `gstore/platform.exec`（见文件头）；可直接作为 `CommandRunner`
/// 默认值。
Future<String?> rustShizukuRunner(String command) async {
  try {
    return await _client.exec(command);
  } catch (e) {
    debugPrint('[RustShizuku] 执行失败: $e');
    return null;
  }
}

/// Shizuku 是否可用（Kotlin 侧 `pingBinder() && checkSelfPermission()==GRANTED`）。
///
/// 失败 / 不可用一律返回 `false`（绝不抛出）。
Future<bool> rustShizukuAvailable() async {
  try {
    return await _client.available();
  } catch (e) {
    debugPrint('[RustShizuku] available 探测失败: $e');
    return false;
  }
}
