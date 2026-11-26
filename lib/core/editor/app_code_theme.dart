import 'package:flutter/material.dart';

/// 把 GStore 的 Material 3 ColorScheme 映射成 re_highlight 的 token 主题。
///
/// re_highlight 的 token class 名与 highlight.js 一致；`_findStyle` 会按
/// `keyword-control` → `keyword` 逐级回退，因此这里只需覆盖常用基础 token。
/// 颜色全部来自 [ColorScheme]，避免硬编码。
Map<String, TextStyle> appCodeTheme(ColorScheme scheme) => {
      'root': TextStyle(
        color: scheme.onSurface,
        backgroundColor: scheme.surface,
      ),
      'comment': TextStyle(
        color: scheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
      'quote': TextStyle(
        color: scheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
      'doctag': TextStyle(color: scheme.primary),
      'keyword': TextStyle(color: scheme.primary),
      'formula': TextStyle(color: scheme.primary),
      'section': TextStyle(color: scheme.primary),
      'name': TextStyle(color: scheme.primary),
      'selector-tag': TextStyle(color: scheme.primary),
      'title': TextStyle(color: scheme.primary),
      'literal': TextStyle(color: scheme.tertiary),
      'string': TextStyle(color: scheme.tertiary),
      'regexp': TextStyle(color: scheme.tertiary),
      'addition': TextStyle(color: scheme.tertiary),
      'attribute': TextStyle(color: scheme.tertiary),
      'meta-string': TextStyle(color: scheme.tertiary),
      'number': TextStyle(color: scheme.secondary),
      'attr': TextStyle(color: scheme.secondary),
      'variable': TextStyle(color: scheme.secondary),
      'template-variable': TextStyle(color: scheme.secondary),
      'type': TextStyle(color: scheme.secondary),
      'selector-class': TextStyle(color: scheme.secondary),
      'selector-attr': TextStyle(color: scheme.secondary),
      'selector-pseudo': TextStyle(color: scheme.secondary),
      'built_in': TextStyle(color: scheme.secondary),
      'symbol': TextStyle(color: scheme.primary),
      'bullet': TextStyle(color: scheme.primary),
      'link': TextStyle(color: scheme.primary),
      'meta': TextStyle(color: scheme.onSurfaceVariant),
      'selector-id': TextStyle(color: scheme.primary),
      'deletion': TextStyle(color: scheme.error),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: FontWeight.bold),
    };
