/// 「请求调试」导入 / 导出统一门面（plan todo 16）。
///
/// 把集合级（HAR / Postman / OpenAPI / 原始 HTTP）与环境 / 规则 JSON 的纯编解码
/// 收敛到单一入口，供 UI 分区调用。**不含 IO / UI**：文件选择由页面层的
/// FilePicker 接缝负责，本层只处理文本。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

import 'codec_utils.dart';
import 'har_codec.dart';
import 'import_export_types.dart';
import 'openapi_codec.dart';
import 'postman_codec.dart';
import 'raw_http_codec.dart';

/// 集合 / 环境 / 规则的编解码统一入口。
class DebugImportExport {
  const DebugImportExport._();

  /// 把 [collections] 编码为指定 [format] 的文本。
  static String encodeCollections(
    DebugTransferFormat format,
    List<DebugCollection> collections,
  ) {
    switch (format) {
      case DebugTransferFormat.har:
        return encodeHar(collections);
      case DebugTransferFormat.postman:
        return encodePostman(collections);
      case DebugTransferFormat.openapi:
        return encodeOpenApi(collections);
      case DebugTransferFormat.rawHttp:
        return encodeRawHttp(<DebugRequest>[
          for (final c in collections) ...c.requests,
        ]);
    }
  }

  /// 把 [text] 按指定 [format] 解码为集合列表（失败 → 结构化错误）。
  static DebugTransferResult<List<DebugCollection>> decodeCollections(
    DebugTransferFormat format,
    String text,
  ) {
    switch (format) {
      case DebugTransferFormat.har:
        return decodeHar(text);
      case DebugTransferFormat.postman:
        return decodePostman(text);
      case DebugTransferFormat.openapi:
        return decodeOpenApi(text);
      case DebugTransferFormat.rawHttp:
        final result = decodeRawHttp(text);
        if (!result.isSuccess) {
          return DebugTransferResult.failure(result.error!);
        }
        return DebugTransferResult.success(<DebugCollection>[
          DebugCollection(
            id: generateDebugId('col'),
            name: '导入',
            requests: result.value!,
          ),
        ]);
    }
  }

  /// 按内容（并可选按文件名后缀）识别格式；无法识别返回 `null`。
  static DebugTransferFormat? detectFormat(String text, {String? fileName}) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map) {
        final map = decoded.cast<String, dynamic>();
        final log = map['log'];
        if (log is Map && log['entries'] is List) {
          return DebugTransferFormat.har;
        }
        if (map['openapi'] is String) return DebugTransferFormat.openapi;
        final info = map['info'];
        if (info is Map &&
            debugStr(info['schema']).contains('postman')) {
          return DebugTransferFormat.postman;
        }
        if (map['item'] is List) return DebugTransferFormat.postman;
      }
      if (_looksLikeRawHttp(trimmed)) {
        return DebugTransferFormat.rawHttp;
      }
    }
    return _formatFromFileName(fileName);
  }

  // ==================== 环境 / 规则（JSON）====================

  /// 环境列表 → JSON 文本（含格式标识，便于导入时校验）。
  static String encodeEnvironmentsJson(List<DebugEnvironment> environments) {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'format': 'gstore.debug.environments',
      'version': 1,
      'environments': <Map<String, dynamic>>[
        for (final e in environments) e.toJson(),
      ],
    });
  }

  /// JSON 文本 → 环境列表（失败 → 结构化错误；单条损坏被隔离）。
  static DebugTransferResult<List<DebugEnvironment>> decodeEnvironmentsJson(
    String text,
  ) {
    final decoded = _decodeJsonRoot(text, '环境');
    if (decoded is DebugTransferResult<Object?>) {
      return DebugTransferResult.failure(decoded.error!);
    }
    final list = _extractList(decoded, 'environments');
    if (list == null) {
      return const DebugTransferResult.failure(
        DebugTransferError(
          DebugTransferErrorKind.invalidStructure,
          '环境 JSON 缺少 environments 数组',
        ),
      );
    }
    final out = <DebugEnvironment>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(DebugEnvironment.fromJson(item.cast<String, dynamic>()));
      } catch (_) {
        // 单条损坏被隔离。
      }
    }
    return DebugTransferResult.success(out);
  }

  /// 改写规则列表 → JSON 文本。
  static String encodeRulesJson(List<DebugRewriteRule> rules) {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'format': 'gstore.debug.rules',
      'version': 1,
      'rules': <Map<String, dynamic>>[
        for (final r in rules) r.toJson(),
      ],
    });
  }

  /// JSON 文本 → 改写规则列表（失败 → 结构化错误；单条损坏被隔离）。
  static DebugTransferResult<List<DebugRewriteRule>> decodeRulesJson(
    String text,
  ) {
    final decoded = _decodeJsonRoot(text, '规则');
    if (decoded is DebugTransferResult<Object?>) {
      return DebugTransferResult.failure(decoded.error!);
    }
    final list = _extractList(decoded, 'rules');
    if (list == null) {
      return const DebugTransferResult.failure(
        DebugTransferError(
          DebugTransferErrorKind.invalidStructure,
          '规则 JSON 缺少 rules 数组',
        ),
      );
    }
    final out = <DebugRewriteRule>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(DebugRewriteRule.fromJson(item.cast<String, dynamic>()));
      } catch (_) {
        // 单条损坏被隔离。
      }
    }
    return DebugTransferResult.success(out);
  }
}

/// 解析 JSON 根；失败时返回一个 `DebugTransferResult.failure`（以 `Object?` 伪装），
/// 成功时返回解析后的根对象。调用方通过 `is DebugTransferResult` 判别。
Object? _decodeJsonRoot(String text, String label) {
  if (text.trim().isEmpty) {
    return DebugTransferResult<Object?>.failure(
      DebugTransferError(DebugTransferErrorKind.empty, '$label 内容为空'),
    );
  }
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    return DebugTransferResult<Object?>.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidJson,
        '$label JSON 解析失败：${e.message}',
      ),
    );
  }
}

List<dynamic>? _extractList(Object? decoded, String key) {
  if (decoded is List) return decoded;
  if (decoded is Map) {
    final value = decoded[key];
    if (value is List) return value;
  }
  return null;
}

bool _looksLikeRawHttp(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('###')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) return false;
    return RegExp(r'^[A-Z]+$').hasMatch(parts[0]);
  }
  return false;
}

DebugTransferFormat? _formatFromFileName(String? fileName) {
  if (fileName == null) return null;
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.har')) return DebugTransferFormat.har;
  if (lower.endsWith('.http') || lower.endsWith('.rest')) {
    return DebugTransferFormat.rawHttp;
  }
  return null;
}

/// 为导入的集合树**重新铸造** id（并重映射 `parentId` / 请求的 `collectionId`），
/// 避免与现有集合 id 冲突。纯函数：不修改输入，返回新列表。
///
/// [mintId] 可注入以在测试中确定化；默认用 [generateDebugId]。
List<DebugCollection> remapImportedCollections(
  List<DebugCollection> incoming, {
  String Function(String oldId)? mintId,
}) {
  final mint = mintId ?? (old) => generateDebugId('col');
  final idMap = <String, String>{
    for (final c in incoming) c.id: mint(c.id),
  };
  final out = <DebugCollection>[];
  for (final c in incoming) {
    final newId = idMap[c.id]!;
    final newParent = c.parentId == null ? null : idMap[c.parentId];
    out.add(
      DebugCollection(
        id: newId,
        name: c.name,
        parentId: newParent,
        requests: <DebugRequest>[
          for (final r in c.requests) r.copyWith(collectionId: newId),
        ],
      ),
    );
  }
  return out;
}
