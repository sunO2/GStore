/// Agent 内联原生卡片（实验特性 · 阶段一）
///
/// 纯 Dart 层：内联卡片的实验开关、白名单规格与 key 解析逻辑。
/// 不依赖 Flutter，也不依赖 `AgentService`（避免循环导入）。
///
/// 支持开关（switch）、滑块（slider）、分段选择（segmented）三类配置控件；
/// 仅暴露白名单内的配置项，其余 key 一律不解析为内联卡片，
/// 以保证 Agent 无法借内联控件操作敏感或非白名单配置。
library;

import 'package:gstore/core/config/config_registry.dart';

/// 内联原生控件的实验开关。
const bool kAgentInlineCardsEnabled = true;

/// 内联控件的类型。
enum AgentInlineControlKind { switchControl, slider, segmented }

/// 内联配置控件规格。
///
/// 类名保留 `AgentInlineSwitchSpec` 以兼容既有导入；`kind` 默认为开关。
class AgentInlineSwitchSpec {
  /// 配置 wire key（形如 `download.wifi_only`）。
  final String configKey;

  /// 卡片标题。
  final String title;

  /// 卡片副标题（说明配置含义）。
  final String subtitle;

  /// 控件类型。
  final AgentInlineControlKind kind;

  /// 用于把人类可读别名/标题解析到该配置。
  final List<String> aliases;

  /// 滑块最小值（仅 slider）。
  final num? min;

  /// 滑块最大值（仅 slider）。
  final num? max;

  /// 滑块步长（仅 slider）。
  final num? step;

  /// 单位（仅 slider，如「小时」）。
  final String? unit;

  /// 枚举取值（仅 segmented）。
  final List<String>? enumValues;

  /// 枚举展示文案（仅 segmented）。
  final Map<String, String>? enumLabels;

  /// 配置值类型：'bool' | 'int' | 'double' | 'string'。
  final String valueType;

  const AgentInlineSwitchSpec({
    required this.configKey,
    required this.title,
    required this.subtitle,
    this.kind = AgentInlineControlKind.switchControl,
    this.aliases = const <String>[],
    this.min,
    this.max,
    this.step,
    this.unit,
    this.enumValues,
    this.enumLabels,
    this.valueType = 'bool',
  });
}

/// 内联卡片白名单与 key 解析。
class AgentInlineCards {
  AgentInlineCards._();

  /// 白名单（有序，中文文案）。
  static const List<AgentInlineSwitchSpec> _controlSpecs =
      <AgentInlineSwitchSpec>[
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.downloadMultiSegmentEnabled,
      title: '多段下载',
      subtitle: '自适应分段并行下载（最大 8 段），大文件下载更快；弱网时可关闭',
      aliases: <String>[
        '分段下载',
        '多线程下载',
        '多段并发下载',
        'multi-segment',
        'multi segment',
        'segment download',
      ],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.downloadWifiOnly,
      title: '仅 Wi-Fi 下载',
      subtitle: '仅在 Wi-Fi 网络下下载应用',
      aliases: <String>[
        '仅wifi',
        '仅 wifi',
        '只wifi',
        'wifi下载',
        'wifi-only',
        'wifi only',
      ],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.updateSilentUpdate,
      title: '静默更新',
      subtitle: '更新应用时不弹出确认提示',
      aliases: <String>[
        '静默升级',
        'silent update',
      ],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.updateIgnorePrerelease,
      title: '忽略预发布版本',
      subtitle: '检查更新时跳过 beta / dev 版本',
      aliases: <String>[
        '预发布',
        'beta版本',
        'dev版本',
        'prerelease',
        'ignore prerelease',
      ],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.downloadMaxConcurrent,
      title: '最大并发下载数',
      subtitle: '同时进行的最大下载任务数（1-10）',
      kind: AgentInlineControlKind.slider,
      min: 1,
      max: 10,
      step: 1,
      valueType: 'int',
      aliases: <String>['并发下载', '最大并发', '并发数'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.downloadMaxRetries,
      title: '下载重试次数',
      subtitle: '下载失败后的最大重试次数（0-5）',
      kind: AgentInlineControlKind.slider,
      min: 0,
      max: 5,
      step: 1,
      valueType: 'int',
      aliases: <String>['重试次数', '下载重试'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.downloadDefaultConnections,
      title: '默认连接数',
      subtitle: '多段下载时单任务默认使用的连接数（分段数）',
      kind: AgentInlineControlKind.slider,
      min: 1,
      max: 16,
      step: 1,
      valueType: 'int',
      aliases: <String>['连接数', '分段数'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.updateCheckIntervalHours,
      title: '检查更新间隔',
      subtitle: '自动检查更新的间隔（小时）',
      kind: AgentInlineControlKind.slider,
      min: 1,
      max: 168,
      step: 1,
      valueType: 'int',
      unit: '小时',
      aliases: <String>['检查间隔', '更新间隔'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.updateAutoUpdatePolicy,
      title: '自动更新策略',
      subtitle: 'never / wifi_only / always',
      kind: AgentInlineControlKind.segmented,
      enumValues: <String>['never', 'wifi_only', 'always'],
      enumLabels: <String, String>{
        'never': '从不',
        'wifi_only': '仅 Wi-Fi',
        'always': '总是',
      },
      valueType: 'string',
      aliases: <String>['自动更新', '更新策略'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.updateChannel,
      title: '更新渠道',
      subtitle: 'stable / beta / dev',
      kind: AgentInlineControlKind.segmented,
      enumValues: <String>['stable', 'beta', 'dev'],
      enumLabels: <String, String>{
        'stable': '稳定版',
        'beta': '测试版',
        'dev': '开发版',
      },
      valueType: 'string',
      aliases: <String>['更新渠道'],
    ),
    AgentInlineSwitchSpec(
      configKey: ConfigKeys.themeMode,
      title: '主题模式',
      subtitle: '跟随系统 / 浅色 / 深色',
      kind: AgentInlineControlKind.segmented,
      enumValues: <String>['0', '1', '2'],
      enumLabels: <String, String>{
        '0': '跟随系统',
        '1': '浅色',
        '2': '深色',
      },
      valueType: 'int',
      aliases: <String>[
        '主题模式',
        '深色模式',
        '浅色模式',
        '深浅色主题',
        '主题设置',
        '主题切换',
        '明暗主题',
        '夜间模式',
        '暗色模式',
        '深色主题',
        '浅色主题',
        'theme mode',
        'dark mode',
        'light mode',
      ],
    ),
  ];

  /// 全部控件白名单（开关 + 滑块 + 分段选择）。
  static List<AgentInlineSwitchSpec> get controlSpecs => _controlSpecs;

  /// 仅开关类控件（向后兼容）。
  static List<AgentInlineSwitchSpec> get switchSpecs => _controlSpecs
      .where((s) => s.kind == AgentInlineControlKind.switchControl)
      .toList();

  /// 把一个配置 key 或人类别名/标题解析为白名单规格。
  ///
  /// 归一化（小写 + 去空白）后匹配：[AgentInlineSwitchSpec.configKey] 必须
  /// 精确相等，而 [AgentInlineSwitchSpec.title] 与
  /// [AgentInlineSwitchSpec.aliases] 允许被归一化后的输入包含。
  /// key 为 null、空串或不在白名单时返回 null。
  ///
  /// [kind] 可选，取值为 `switch` / `slider` / `segmented`（未知值返回 null）；
  /// 传入时只返回类型匹配的规格。
  static AgentInlineSwitchSpec? controlForKey(String? key, {String? kind}) {
    if (key == null) return null;

    AgentInlineControlKind? kindFilter;
    if (kind != null && kind.isNotEmpty) {
      kindFilter = _kindFromName(kind);
      if (kindFilter == null) return null;
    }

    AgentInlineSwitchSpec? match;
    for (final spec in controlSpecs) {
      if (spec.configKey == key) {
        match = spec;
        break;
      }
    }

    if (match == null) {
      final normalized = _normalize(key);
      if (normalized.isEmpty) return null;
      for (final spec in controlSpecs) {
        final needles = <String>[spec.title, ...spec.aliases];
        for (final needle in needles) {
          final n = _normalize(needle);
          if (n.isNotEmpty && normalized.contains(n)) {
            match = spec;
            break;
          }
        }
        if (match != null) break;
      }
    }

    if (match == null) return null;
    if (kindFilter != null && match.kind != kindFilter) return null;
    return match;
  }

  /// 仅开关类查找（向后兼容）。
  static AgentInlineSwitchSpec? switchForKey(String? key) {
    return controlForKey(key, kind: 'switch');
  }

  /// 从对话文本识别提到的配置控件（标题/key/别名），按白名单顺序去重。
  /// 既用于给模型注入"可展示控件"提示，也用于模型未显式出卡时的兜底渲染。
  static List<AgentInlineSwitchSpec> controlsInText(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return const <AgentInlineSwitchSpec>[];
    final result = <AgentInlineSwitchSpec>[];
    final seen = <String>{};
    for (final spec in _controlSpecs) {
      final needles = <String>[spec.title, spec.configKey, ...spec.aliases];
      final matched = needles.any((n) => normalized.contains(_normalize(n)));
      if (matched && seen.add(spec.configKey)) result.add(spec);
    }
    return result;
  }

  static AgentInlineControlKind? _kindFromName(String name) {
    switch (name) {
      case 'switch':
        return AgentInlineControlKind.switchControl;
      case 'slider':
        return AgentInlineControlKind.slider;
      case 'segmented':
        return AgentInlineControlKind.segmented;
      default:
        return null;
    }
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  }
}
