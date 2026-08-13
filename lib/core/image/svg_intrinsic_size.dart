import 'dart:convert';
import 'dart:typed_data';

/// 扫描 SVG 根标签的最大前缀字节数（覆盖 BOM/XML 声明/注释 + 根标签足够）。
const int _svgPrefixLimit = 2048;

/// 从 SVG 字节中解析固有尺寸（根标签的 width/height/viewBox）。
///
/// 规则：
/// - 数字 + 可选 'px' 视为有效长度；含 %/其他单位/非法值 → 视为无；
/// - width 与 height 都有 → 用之；仅其一 + viewBox → 按 viewBox 宽高比补另一维；
/// - 仅 viewBox → 用 viewBox 宽高；都无 → null。
///
/// 纯 Dart 实现，不依赖 flutter_svg 解析器。
({double width, double height})? parseSvgIntrinsicSize(Uint8List bytes) {
  if (bytes.isEmpty) return null;

  final end = bytes.length < _svgPrefixLimit ? bytes.length : _svgPrefixLimit;
  final prefix = latin1.decode(bytes.sublist(0, end));

  // 定位根标签：容忍 BOM/XML 声明/<!-- 注释 --> 前缀。
  final svgStart = prefix.indexOf('<svg');
  if (svgStart == -1) return null;
  final tagEnd = prefix.indexOf('>', svgStart);
  if (tagEnd == -1) return null;
  final tag = prefix.substring(svgStart, tagEnd);

  final attrs = <String, String>{};
  for (final m in RegExp(r'([a-zA-Z:]+)\s*=\s*"([^"]*)"').allMatches(tag)) {
    attrs[m.group(1)!] = m.group(2)!;
  }

  final width = _parseLength(attrs['width']);
  final height = _parseLength(attrs['height']);
  final viewBox = _parseViewBox(attrs['viewBox']);

  if (width != null && height != null) {
    return (width: width, height: height);
  }
  if (viewBox != null) {
    // 仅 width / 仅 height：用 viewBox 宽高比补另一维。
    if (width != null && viewBox.width > 0) {
      return (width: width, height: width * viewBox.height / viewBox.width);
    }
    if (height != null && viewBox.height > 0) {
      return (width: height * viewBox.width / viewBox.height, height: height);
    }
    return (width: viewBox.width, height: viewBox.height);
  }
  return null;
}

/// 解析长度属性：数字 + 可选 'px'；其余（%/单位/非法）→ null。
double? _parseLength(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(?:px)?$').firstMatch(trimmed);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// 解析 viewBox："b0 b1 b2 b3"（容忍逗号分隔）→ 宽=b2 高=b3；非法 → null。
({double width, double height})? _parseViewBox(String? value) {
  if (value == null) return null;
  final parts = value.trim().split(RegExp(r'[\s,]+'));
  if (parts.length < 4) return null;
  final b0 = double.tryParse(parts[0]);
  final b1 = double.tryParse(parts[1]);
  final b2 = double.tryParse(parts[2]);
  final b3 = double.tryParse(parts[3]);
  if (b0 == null || b1 == null || b2 == null || b3 == null) return null;
  if (b2 <= 0 || b3 <= 0) return null;
  return (width: b2, height: b3);
}
