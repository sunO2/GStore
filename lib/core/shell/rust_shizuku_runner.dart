/// Rust 统一特权 shell 门面的 **Dart 入口**。
///
/// 数据通路（架构固定，与 `shizuku-rust-facade` 计划一致）：
/// `Dart → FRB(RustLib) → Rust(gstore_host) → JNI → Kotlin ShizukuExecBridge.exec
/// → Shizuku.newProcess(["sh","-c",cmd])`。
/// 即：特权 shell 命令的**唯一**执行源收敛到 Rust 宿主；Dart/业务层不再直接经
/// MethodChannel 插件执行命令（插件仅保留 `pingBinder`/`checkPermission`/
/// `requestPermission` 等需要 Activity 的权限 UI 关注点）。
///
/// 契约与既有 `CommandRunner`（`privileged_shell.dart` /
/// `third_party_perf_service.dart` / `system_fps_service.dart`）**逐字一致**：
/// * 返回 **stdout+stderr 合并**文本；
/// * **没有退出码**（成败由调用方经哨兵 `GSTORE_RESULT` 或输出形状判定）；
/// * 未执行 / 失败 / Rust 未就绪一律返回 `null`（绝不抛出）。
///
/// FRB 调用前必须确保 [RustLib] 已初始化；此处复用既有并发安全守卫
/// [RustBridge.ensureInitialized]（幂等 + 共享同一初始化 Future），**不重复** init。
library;

// 经 `RustLib.instance.api` 调用 FRB 生成的顶层方法（与生成物一致；`.api` 标注
// `@internal`，故按生成文件约定忽略该 lint）。
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/frb_generated.dart' show RustLib;

/// 执行一条特权 shell 命令，返回 stdout+stderr 合并文本；未执行 / 失败返回 `null`。
///
/// 生产实现 = Rust 统一门面（见文件头）；可直接作为 `CommandRunner` 默认值。
Future<String?> rustShizukuRunner(String command) async {
  try {
    await RustBridge.ensureInitialized();
    return await RustLib.instance.api.crateBridgeShizukuExec(command: command);
  } catch (e) {
    debugPrint('[RustShizuku] 执行失败: $e');
    return null;
  }
}

/// Shizuku 是否可用（Rust 侧 `pingBinder() && checkSelfPermission()==GRANTED`）。
///
/// 失败 / Rust 未就绪一律返回 `false`（绝不抛出）。
Future<bool> rustShizukuAvailable() async {
  try {
    await RustBridge.ensureInitialized();
    return await RustLib.instance.api.crateBridgeShizukuAvailable();
  } catch (_) {
    return false;
  }
}
