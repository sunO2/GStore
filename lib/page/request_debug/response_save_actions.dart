/// 「请求调试」响应体存盘的页面层动作（plan todo 18）。
///
/// 纯字节决策在 `lib/core/request_debug/response_body_save.dart`；本文件负责
/// 文件保存接缝（默认复用既有 [defaultDebugSaveFile] / FilePicker，测试可注入）
/// 与统一提示。
///
/// 设计约束：提示走 [AppDialogs]（统一入口），不手写 `showDialog`。
library;

import 'package:flutter/widgets.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'import_export_actions.dart';

export 'import_export_actions.dart' show DebugSaveFile;

/// 把响应体**逐字节**存盘。
///
/// [saveFile] 为空时走 [defaultDebugSaveFile]（FilePicker）；返回是否已保存。
/// 保存失败 / 取消均经 [AppDialogs] 显式反馈，绝不静默。
Future<bool> saveDebugResponseBody(
  BuildContext context,
  DebugResponse response, {
  DebugSaveFile? saveFile,
}) async {
  final bytes = responseBodyBytesForSave(response);
  final name = suggestResponseBodyFileName(response);
  final ok = await (saveFile ?? defaultDebugSaveFile)(name, bytes);
  if (!context.mounted) return ok;
  if (ok) {
    AppDialogs.showSuccess('已保存响应体');
  } else {
    AppDialogs.showError('保存失败');
  }
  return ok;
}
