import 'dart:convert';

import 'package:gstore/core/theme/app_theme_config.dart';

/// 主题配置规范化工具（纯逻辑，无 UI 依赖）。
///
/// 负责把持久化/外部写入的原始主题配置（Map、JSON 字符串、双重编码 JSON）
/// 统一解析为 [AppThemeConfig]，并把各种颜色写法收敛为 8 位 ARGB 十六进制
/// 字符串，避免 `AppThemeConfig.fromJson` 因颜色格式不一致而解析失败。
class ThemeConfigNormalizer {
  ThemeConfigNormalizer._();

  /// 主题配置中支持自定义颜色的字段。
  static const List<String> colorKeys = <String>[
    'seedColor',
    'primaryColor',
    'secondaryColor',
    'tertiaryColor',
  ];

  /// 解析原始配置为 [AppThemeConfig]。
  ///
  /// - 支持 [Map]、JSON 字符串，以及最多两层编码的 JSON 字符串；
  /// - 空字符串、非法 JSON、非 Map、非法枚举索引等均返回 null（保持旧状态）。
  static AppThemeConfig? parse(Object? raw) {
    Object? decoded = raw;
    var depth = 0;
    // 最多解码两层，兼容持久化层可能出现的双重 JSON 编码。
    while (decoded is String && depth < 2) {
      final trimmed = decoded.trim();
      if (trimmed.isEmpty) return null;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return null;
      }
      depth++;
    }

    if (decoded is! Map) return null;

    try {
      final map = Map<String, dynamic>.from(decoded);
      final normalized = normalizeJson(map);
      return AppThemeConfig.fromJson(normalized);
    } catch (_) {
      // 字段损坏（如非法颜色/枚举索引）→ 返回 null，由调用方保留旧状态。
      return null;
    }
  }

  /// 规范化部分/完整主题 JSON。
  ///
  /// - 颜色支持 `#RRGGBB`、`0xAARRGGBB`、`RRGGBB`、`AARRGGBB` 及 int；
  /// - 输出颜色统一为 8 位 ARGB 十六进制字符串（无 `#` / `0x` 前缀）；
  /// - 出现自定义颜色且 `useCustomColors` 缺失/null 时自动置为 true；
  /// - 显式 `useCustomColors: false` 保持不变；
  /// - 不修改入参 map；非法枚举索引原样保留，使 [parse] 返回 null。
  static Map<String, dynamic> normalizeJson(Map<String, dynamic> json) {
    final result = <String, dynamic>{...json};
    var hasCustomColor = false;

    for (final key in colorKeys) {
      final value = result[key];
      if (value == null) continue;
      hasCustomColor = true;
      final hex = toArgbHex(value);
      if (hex != null) {
        result[key] = hex;
      }
      // 非法颜色保持原值，让 fromJson 抛错 -> parse 返回 null。
    }

    if (hasCustomColor && result['useCustomColors'] == null) {
      result['useCustomColors'] = true;
    }

    return result;
  }

  /// 把单个颜色解析为 ARGB int；非法输入返回 null。
  ///
  /// 字符串支持 `#RRGGBB`、`0xAARRGGBB`、`RRGGBB`、`AARRGGBB`（大小写不敏感）；
  /// int 大于 `0xFFFFFF` 视为 ARGB，否则视为 RRGGBB 并补全 FF alpha。
  static int? parseArgb(Object? value) {
    if (value is int) {
      if (value < 0 || value > 0xFFFFFFFF) return null;
      if (value <= 0xFFFFFF) return 0xFF000000 | value;
      return value;
    }

    if (value is! String) return null;

    var text = value.trim();
    if (text.startsWith('#')) {
      text = text.substring(1);
    }
    if (text.startsWith('0x') || text.startsWith('0X')) {
      text = text.substring(2);
    }
    if (text.isEmpty) return null;

    if (text.length == 6) {
      text = 'FF$text';
    }
    if (text.length != 8) return null;
    if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(text)) return null;

    return int.tryParse(text, radix: 16);
  }

  /// 把颜色转换为 8 位大写 ARGB 十六进制字符串（无前缀）；非法输入返回 null。
  static String? toArgbHex(Object? value) {
    final argb = parseArgb(value);
    if (argb == null) return null;
    return argb.toRadixString(16).padLeft(8, '0').toUpperCase();
  }
}
