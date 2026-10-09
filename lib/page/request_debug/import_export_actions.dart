/// 「请求调试」导入 / 导出的**页面层动作**（plan todo 16）。
///
/// 纯编解码在 `lib/core/request_debug/import_export/`；本文件只负责：
/// - 文件选择 / 保存接缝（默认走既有 [FilePicker.platform]，测试可注入假实现）；
/// - 把解码结果并入 [RequestDebugStore]、把 store 内容编码后另存。
///
/// 设计约束：弹层提示走 [AppDialogs]（统一入口），不手写 `showDialog`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/request_debug/import_export/import_export.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

/// 选中的文件（名称 + UTF-8 文本内容）。
typedef DebugPickedFile = ({String name, String content});

/// 文件选择接缝：返回 `null` 表示用户取消。
typedef DebugPickFile = Future<DebugPickedFile?> Function(
  List<String> allowedExtensions,
);

/// 文件保存接缝：返回 `true` 表示已保存。
typedef DebugSaveFile = Future<bool> Function(
  String suggestedName,
  List<int> bytes,
);

/// 集合导入可接受的扩展名。
const List<String> kDebugImportExtensions = <String>[
  'har',
  'json',
  'http',
  'rest',
  'txt',
];

/// 默认文件选择：既有 [FilePicker.platform.pickFiles] 方式（SAF，无需权限）。
Future<DebugPickedFile?> defaultDebugPickFile(
  List<String> allowedExtensions,
) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.first;
  final bytes = file.bytes;
  if (bytes == null) return null;
  return (name: file.name, content: utf8.decode(bytes, allowMalformed: true));
}

/// 默认文件保存：既有 [FilePicker.platform.saveFile] 方式。
Future<bool> defaultDebugSaveFile(
  String suggestedName,
  List<int> bytes,
) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出',
    fileName: suggestedName,
    bytes: Uint8List.fromList(bytes),
  );
  return path != null;
}

/// 选择文件并导入集合（自动识别 HAR / Postman / OpenAPI(JSON) / 原始 HTTP）。
///
/// 失败路径全部走 [AppDialogs.showError]，绝不崩。成功追加到 store 并落盘。
Future<void> importDebugCollections(
  BuildContext context,
  RequestDebugFacade facade, {
  DebugPickFile? pickFile,
}) async {
  final picked = await (pickFile ?? defaultDebugPickFile)(kDebugImportExtensions);
  if (picked == null) return;

  final format = DebugImportExport.detectFormat(
    picked.content,
    fileName: picked.name,
  );
  if (format == null) {
    AppDialogs.showError(
      '无法识别文件格式：请选择 HAR / Postman / OpenAPI(JSON) / 原始 HTTP 文件',
    );
    return;
  }
  final result = DebugImportExport.decodeCollections(format, picked.content);
  if (!result.isSuccess) {
    AppDialogs.showError('导入失败：${result.error!.message}');
    return;
  }
  final imported = result.requireValue();
  if (imported.isEmpty) {
    AppDialogs.showError('文件中没有可导入的集合');
    return;
  }
  final remapped = remapImportedCollections(imported);
  facade.store.collections.addAll(remapped);
  final saved = await facade.save();
  if (!context.mounted) return;
  if (!saved) {
    AppDialogs.showError('已导入但保存失败，改动未写入磁盘');
    return;
  }
  final requestCount =
      imported.fold<int>(0, (sum, c) => sum + c.requests.length);
  AppDialogs.showSuccess(
    '已导入 ${remapped.length} 个集合 / $requestCount 个请求（${format.label}）',
  );
}

/// 把集合树编码为 [format] 并另存为文件。
Future<void> exportDebugCollections(
  BuildContext context,
  List<DebugCollection> collections,
  DebugTransferFormat format, {
  DebugSaveFile? saveFile,
}) async {
  if (collections.isEmpty) {
    AppDialogs.showError('没有可导出的集合');
    return;
  }
  final text = DebugImportExport.encodeCollections(format, collections);
  final ok = await (saveFile ?? defaultDebugSaveFile)(
    'request-debug-collections.${format.defaultExtension}',
    utf8.encode(text),
  );
  if (!context.mounted) return;
  if (ok) {
    AppDialogs.showSuccess('已导出集合（${format.label}）');
  } else {
    AppDialogs.showError('导出失败');
  }
}

/// 把环境导出为 JSON 文件。
Future<void> exportDebugEnvironments(
  BuildContext context,
  List<DebugEnvironment> environments, {
  DebugSaveFile? saveFile,
}) async {
  if (environments.isEmpty) {
    AppDialogs.showError('没有可导出的环境');
    return;
  }
  final text = DebugImportExport.encodeEnvironmentsJson(environments);
  final ok = await (saveFile ?? defaultDebugSaveFile)(
    'request-debug-environments.json',
    utf8.encode(text),
  );
  if (!context.mounted) return;
  if (ok) {
    AppDialogs.showSuccess('已导出环境');
  } else {
    AppDialogs.showError('导出失败');
  }
}

/// 把改写规则导出为 JSON 文件。
Future<void> exportDebugRules(
  BuildContext context,
  List<DebugRewriteRule> rules, {
  DebugSaveFile? saveFile,
}) async {
  if (rules.isEmpty) {
    AppDialogs.showError('没有可导出的规则');
    return;
  }
  final text = DebugImportExport.encodeRulesJson(rules);
  final ok = await (saveFile ?? defaultDebugSaveFile)(
    'request-debug-rules.json',
    utf8.encode(text),
  );
  if (!context.mounted) return;
  if (ok) {
    AppDialogs.showSuccess('已导出规则');
  } else {
    AppDialogs.showError('导出失败');
  }
}
