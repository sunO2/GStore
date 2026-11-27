import 'dart:convert';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';

import 'a2ui_render_validation.dart';

/// 阶段 B：对话内联 A2UI。
///
/// - 用 pruned basic catalog 生成模型提示词（Express 格式）
/// - 只在"界面比文字更清楚"的回合注入，避免每轮多 4-6k tokens
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

  /// 模型提示词（约 5k tokens）。
  String get promptSnippet =>
      _promptSnippet ??= _generator.createProcessor(_capabilities).promptSnippet;

  /// 每回合一个 processor；同回合多个模型步共享它。
  A2uiRequestProcessor createProcessor() =>
      _generator.createProcessor(_capabilities);

  /// 会产出"结构化结果"的工具：命中时通常值得用界面呈现。
  static const Set<String> _uiToolNames = {
    'searchApp',
    'getAppInfo',
    'installedApps',
    'updateApps',
    'fdroidRepo',
    'apkBrowser',
    'appSnapshot',
    'snapshotCompare',
  };

  /// 用户文本是否表达了适合用界面的意图。
  ///
  /// 关键词偏宽：宁可多给模型一次选择权，也不要在用户说"帮我找截图工具"
  /// 时因为没命中关键词而失去 UI 能力。
  bool shouldEnable(String text) {
    if (text.trim().isEmpty) return false;
    return _intentPattern.hasMatch(text);
  }

  /// 本轮工具选择结果是否指向"结果适合可视化"的工具。
  bool shouldEnableForTools(Iterable<String> toolNames) =>
      toolNames.any(_uiToolNames.contains);

  static final RegExp _intentPattern = RegExp(
    // 界面/组件
    r'(a2ui|生成式|界面|可视化|渲染|卡片|表单|列表|清单|表格|布局|看板|仪表盘|'
    r'选项卡|标签页|面板|预览|详情|统计|图[表标]|'
    // 交互
    r'筛选|过滤|排序|对比|比较|选择|勾选|多选|单选|输入|填写|'
    // 结果型动作
    r'推荐|挑选|排行|帮我找|搜索|查找|列出|哪些|有啥|有什么|都装了什么|'
    r'更新了[什哪]|差异|变化|'
    // 英文
    r'\brender\b|\bcard\b|\bform\b|\blist\b|\btable\b|\bui\b|\bview\b|'
    r'\btabs?\b|\bdashboard\b|\bpreview\b|\bcompare\b|\bfilter\b|\bselect\b|'
    r'\brecommend\b|\bsuggest\b|\bshow me\b)',
    caseSensitive: false,
  );

  /// 注入系统提示词的说明 + 官方 Express 契约。
  String promptSection() => '''
=== 生成式界面（A2UI）===
本轮适合用界面表达。你可以主动输出界面，不必等用户明确说"卡片/表单/列表"。

什么时候用界面：
- 结果是一组条目（搜索结果、已安装应用、可更新列表、对比项）→ List + Card
- 需要用户输入或选择（筛选、排序、范围、偏好、多个方案）→ 表单 + 按钮
- 单个对象的信息/状态（应用详情、版本差异、下载进度）→ Card + Icon + Divider
- 信息有层级（分类浏览、多个维度）→ Tabs / Column / Row

什么时候不要用：
- 一句话能答完、纯解释/闲聊、报错说明、需要精确排版的代码块。

规则：
- 需要真实数据时先调用工具，拿到结果后再渲染；不要编造数据。
- 普通说明文字放在 <a2ui> 标签外；一次回复最多一个 A2UI 块。
- 界面只做展示与信息收集；安装/卸载/删除等危险操作仍必须 confirmAction。
- 本轮已启用内联渲染，不要再调用 renderA2ui 工具。

统一风格（尽量保持一致，避免每次长得不一样）：
- 一张卡片只放一个主要动作按钮（variant="primary"），其余操作用默认按钮。
- 列表行固定结构：Row([Icon, Column([标题, 说明(caption)]), 操作按钮])，
  行与行之间用 Divider，不要用空 Text 撑间距。
- 标题简短（≤12 字），辅助信息用 variant="caption"，数字带单位（如 112 MB）。
- 用 Card 分组；Card 最多嵌套一层，更多层级改用 Column/Row + Divider。
- 需要切换视图用 Tabs；需要确认/详情弹层用 Modal；媒体用 Video/AudioPlayer
  （仅 http(s) 地址）。
- Text 支持简单 Markdown（**加粗** / *斜体*），variant 只有 body/caption；
  Image 用 variant="icon"|"avatar" 控制尺寸；组件总数 ≤60。

组件全部使用 A2UI v1.0 basic catalog：Column/Row/Card/Text/Button/Divider/
TextField/CheckBox/ChoicePicker/List/Tabs/Icon/Image/Slider/DateTimeInput/
Modal/Video/AudioPlayer。

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
