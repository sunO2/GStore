/// SVG `<text>` + `scale()` 组变换的兼容修正
///
/// 背景：`vector_graphics` 在编译"纯缩放/平移"的组变换时，会把变换**折算进
/// 文本坐标 (x/y)** 并把 transform 置空，但**不会折算 font-size**；渲染阶段
/// 又不会自动应用父组变换 → 文本按原始字号（如 shields.io 的 110）绘制。
/// 表现：徽章背景正常，文字被放大十几倍并裁切。
///
/// 这里在交给 flutter_svg 之前做一次字符串级修正：跟踪祖先 `scale()` 的累计
/// 缩放，对每个 `<text>` 显式写入 `font-size = 继承字号 × 缩放`。坐标仍交给
/// 编译器折算（与它的行为一致），从而得到正确结果。
///
/// 只处理 **x/y 等比缩放且无旋转/斜切** 的情况；其他变换原样保留（编译器会
/// 保留 transform，由渲染器统一应用）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 对 SVG 字节做文本缩放修正（无 `<text>` 或无需修正时原样返回）。
Uint8List fixSvgTextScaleBytes(Uint8List bytes) {
  if (bytes.isEmpty) return bytes;
  // SVG 实际基本都是 UTF-8：不能用 latin1 解码后再 utf8 编码，
  // 否则中文会被双重编码成乱码。
  final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
  if (!text.contains('<text') || !text.contains('transform')) return bytes;
  final fixed = fixSvgTextScale(text);
  if (identical(fixed, text) || fixed == text) return bytes;
  return Uint8List.fromList(utf8.encode(fixed));
}

final RegExp _tagPattern = RegExp(
  r'<\s*(/?)\s*(g|text|tspan)\b([^>]*?)(/?)>',
  caseSensitive: false,
);

final RegExp _fontSizePattern =
    RegExp(r'''font-size\s*=\s*["']([^"']+)["']''', caseSensitive: false);
final RegExp _transformPattern =
    RegExp(r'''transform\s*=\s*["']([^"']*)["']''', caseSensitive: false);
final RegExp _scalePattern = RegExp(
  r'^\s*scale\s*\(\s*([+-]?[\d.]+)(?:\s*[, ]\s*([+-]?[\d.]+))?\s*\)\s*$',
  caseSensitive: false,
);

const double _defaultFontSize = 14.0;

/// 字符串版修正（可单测）。
String fixSvgTextScale(String svg) {
  final out = StringBuffer();
  var last = 0;
  final stack = <_Ctx>[const _Ctx(1, 1, _defaultFontSize)];
  var changed = false;

  for (final match in _tagPattern.allMatches(svg)) {
    out.write(svg.substring(last, match.start));
    last = match.end;
    final raw = match.group(0)!;
    final closing = match.group(1) == '/';
    final name = match.group(2)!.toLowerCase();
    final attrs = match.group(3) ?? '';
    final selfClosing = match.group(4) == '/';

    if (closing) {
      if (stack.length > 1) stack.removeLast();
      out.write(raw);
      continue;
    }

    final parent = stack.last;
    var sx = parent.sx;
    var sy = parent.sy;
    var fontSize = parent.fontSize;

    final fs = _parseNumber(_fontSizePattern.firstMatch(attrs)?.group(1));
    if (fs != null && fs > 0) fontSize = fs;

    final transform = _transformPattern.firstMatch(attrs)?.group(1);
    final scale = transform == null ? null : _parseScale(transform);
    if (scale != null) {
      sx *= scale.$1;
      sy *= scale.$2;
    }

    // 仅处理等比缩放（编译器会把位置折算、但字号不会）
    final needsFix = name == 'text' &&
        sx == sy &&
        sx > 0 &&
        sx != 1 &&
        !attrs.toLowerCase().contains('rotate');
    if (needsFix) {
      final scaled = fontSize * sx;
      out.write('<${match.group(2)}${_setFontSize(attrs, scaled)}'
          '${selfClosing ? '/' : ''}>');
      changed = true;
      if (!selfClosing) stack.add(_Ctx(sx, sy, scaled));
      continue;
    }

    out.write(raw);
    if (!selfClosing) stack.add(_Ctx(sx, sy, fontSize));
  }

  out.write(svg.substring(last));
  return changed ? out.toString() : svg;
}

class _Ctx {
  const _Ctx(this.sx, this.sy, this.fontSize);

  final double sx;
  final double sy;
  final double fontSize;
}

double? _parseNumber(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  return double.tryParse(trimmed.replaceAll(RegExp(r'(px|pt|em)$'), ''));
}

/// 解析 `scale(a[, b])`；其他变换返回 null。
(double, double)? _parseScale(String transform) {
  final match = _scalePattern.firstMatch(transform.trim());
  if (match == null) return null;
  final a = double.tryParse(match.group(1)!);
  if (a == null || a == 0) return null;
  final b = match.group(2) == null ? a : double.tryParse(match.group(2)!);
  if (b == null || b == 0) return null;
  return (a, b);
}

/// 写入/替换 `font-size`（保留标签其它属性与引号风格尽力而为）。
String _setFontSize(String attrs, double value) {
  final formatted = _formatNumber(value);
  final match = _fontSizePattern.firstMatch(attrs);
  if (match != null) {
    return attrs.replaceRange(
      match.start,
      match.end,
      'font-size="$formatted"',
    );
  }
  return ' font-size="$formatted"$attrs';
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  final text = value.toStringAsFixed(3);
  return text
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}
