import 'dart:convert';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';

import 'a2ui_render_validation.dart';

/// 阶段 B：对话内联 A2UI。
///
/// - 用 pruned basic catalog 生成模型提示词（Express 格式）
/// - 只在用户表达出界面意图时注入，避免每轮多 4-5k tokens
/// - 解析 `<a2ui>...</a2ui>` 块，供聊天流式渲染
class A2uiInlineService {
  A2uiInlineService._();

  static final A2uiInlineService instance = A2uiInlineService._();

  static const List<String> _allowedFunctions = [
    'required',
    'regex',
    'length',
    'numeric',
    'email',
    'formatString',
    'formatNumber',
    'formatDate',
    'pluralize',
    'and',
    'or',
    'not',
  ];

  late final CatalogConfig _catalog = CatalogConfig(
    BasicCatalog.v1_0(),
    transformers: [
      ComponentPruningTransformer(A2uiRenderValidation.allowedComponents),
      FunctionPruningTransformer(_allowedFunctions),
    ],
  );

  late final A2uiGenerator _generator = A2uiGenerator(catalogs: [_catalog]);

  late final A2uiRendererCapabilities _capabilities =
      A2uiRendererCapabilities.forCatalogIds(
    [BasicCatalog.v1_0Id],
    version: A2uiProtocolVersion.v1_0,
  );

  String? _promptSnippet;

  /// 模型提示词（约 4.7k tokens）。
  String get promptSnippet =>
      _promptSnippet ??= _generator.createProcessor(_capabilities).promptSnippet;

  /// 每回合一个 processor；同回合多个模型步共享它。
  A2uiRequestProcessor createProcessor() =>
      _generator.createProcessor(_capabilities);

  /// 是否值得为本轮注入 A2UI 提示词。
  ///
  /// 只在明确涉及界面/卡片/表单/列表时开启；普通聊天不付出 token 成本。
  bool shouldEnable(String text) {
    if (text.trim().isEmpty) return false;
    return _intentPattern.hasMatch(text);
  }

  static final RegExp _intentPattern = RegExp(
    r'(a2ui|生成式|卡片|表单|列表|界面|可视化|渲染|筛选|'
    r'\brender\b|\bcard\b|\bform\b|\blist\b|\bui\b)',
    caseSensitive: false,
  );

  /// 注入系统提示词的说明 + 官方 Express 契约。
  String promptSection() => '''
=== 生成式界面（A2UI） ===
本轮用户可能需要界面。请直接用 A2UI Express 输出 UI，并用
<a2ui> 和 </a2ui> 包裹；不要调用 renderA2ui 工具。
普通说明文字放在标签外；一次回复可以包含一个 A2UI 块。
UI 只用于展示/收集信息；卸载、删除、安装等危险操作仍必须调用
confirmAction 让用户确认。

$promptSnippet''';
}

/// 把内联 A2UI 原始消息编码到既有持久化字段（assistant 消息的 toolResult）。
///
/// 复用 `tool_result` 列可以避免 Rust schema 迁移；以后有独立列再替换。
class A2uiInlineCodec {
  A2uiInlineCodec._();

  static const String prefix = '@a2ui:v1:';

  static String encode(List<Map<String, Object?>> messages) =>
      '$prefix${jsonEncode(messages)}';

  static List<Map<String, Object?>>? decode(String? raw) {
    if (raw == null || !raw.startsWith(prefix)) return null;
    try {
      final decoded = jsonDecode(raw.substring(prefix.length));
      if (decoded is! List) return null;
      return [
        for (final item in decoded)
          if (item is Map)
            item.map((key, value) => MapEntry(key.toString(), value)),
      ];
    } catch (_) {
      return null;
    }
  }
}
