/// A2UI payload 归一化：把常见的「旧式/误写」数据绑定改写成 v1.0 的 `@path`。
///
/// 模型（以及一些按旧版 A2UI 训练的 Agent）经常把绑定写成字符串：
///
/// ```json
/// {"component": "Text", "text": "$name"}
/// {"component": "Text", "text": "累计 $acc"}
/// {"component": "Text", "text": "$/products/0/nav"}
/// ```
///
/// v1.0 只认 `{"@path": "name"}` / `{"@path": "/products/0/nav"}`，
/// 字符串会被原样显示成占位符。这里在渲染前做一次保守归一化：
///
/// - 整串绑定 `"$name"` → `{"@path": "name"}`，`"$/a/b"` → `{"@path": "/a/b"}`
/// - 旧版绑定对象 `{"path": "name"}` → `{"@path": "name"}`（不含 componentId）
/// - 混合文本 `"累计 $acc"` → `Row([Text("累计 "), Text({"@path": "acc"})])`
/// - 只处理 `text` / `value` / `label` / `placeholder` / `description` / `url`
///   以及 `action.context` 里的值，不碰结构字段（id/child/children/组件名）
///
/// 解析不确定的表达式（`${formatString(...)}` 等）保持原样，避免误改。
library;

/// 把一个或多个 A2UI 消息里的旧式绑定改写成 v1.0 `@path`。
///
/// 输入不会被修改；返回新的消息列表（必要时会追加拆分出来的子组件）。
List<Map<String, Object?>> normalizeA2uiBindings(
  List<Map<String, Object?>> messages,
) {
  final usedIds = <String>{};
  for (final message in messages) {
    for (final body in message.values) {
      if (body is Map && body['components'] is List) {
        for (final component in body['components'] as List) {
          if (component is Map && component['id'] is String) {
            usedIds.add(component['id'] as String);
          }
        }
      }
    }
  }

  final out = <Map<String, Object?>>[];
  for (final message in messages) {
    final copy = _copy(message);
    for (final entry in copy.entries.toList()) {
      final body = entry.value;
      if (body is! Map) continue;
      final components = body['components'];
      if (components is! List) continue;
      final rewritten = <Object?>[];
      final extra = <Map<String, Object?>>[];
      for (final component in components) {
        if (component is! Map) {
          rewritten.add(component);
          continue;
        }
        final normalized = _normalizeComponent(component, extra, usedIds);
        rewritten.add(normalized);
      }
      rewritten.addAll(extra);
      body['components'] = rewritten;
    }
    out.add(copy);
  }
  return out;
}

/// 单个组件的归一化（导出供测试）。
Map<String, Object?> normalizeA2uiComponent(
  Map<Object?, Object?> component, {
  List<Map<String, Object?>>? extra,
  Set<String>? usedIds,
}) =>
    _normalizeComponent(component, extra ?? [], usedIds ?? <String>{});

const List<String> _valueSlots = [
  'value',
  'label',
  'placeholder',
  'description',
  'url',
];

Map<String, Object?> _normalizeComponent(
  Map<Object?, Object?> component,
  List<Map<String, Object?>> extra,
  Set<String> usedIds,
) {
  final out = _copy(component);

  final action = out['action'];
  if (action is Map) {
    final event = action['event'];
    _normalizeContext(action);
    if (event is Map) _normalizeContext(event);
  }

  if (out['component'] == 'Text') {
    final text = out['text'];
    final legacy = _coerceBinding(text);
    if (legacy != null) out['text'] = legacy;
    if (text is String) {
      final segments = _segments(text);
      if (segments != null && segments.any((s) => s.isPath)) {
        if (segments.length == 1) {
          out['text'] = {'@path': segments.single.value};
        } else {
          final id = out['id'] is String ? out['id'] as String : 'text';
          // Row 子项之间自带 8px 间距，字面量两端的空格去掉更自然。
          final parts = [
            for (final segment in segments)
              if (segment.isPath)
                segment
              else
                _Segment.literal(segment.value.trim()),
          ].where((s) => s.isPath || s.value.isNotEmpty).toList();
          final children = <String>[];
          for (var i = 0; i < parts.length; i++) {
            final segment = parts[i];
            final childId = _uniqueId('${id}__s$i', usedIds);
            children.add(childId);
            extra.add(<String, Object?>{
              'id': childId,
              'component': 'Text',
              'text': segment.isPath
                  ? <String, Object?>{'@path': segment.value}
                  : segment.value,
              if (out['variant'] != null) 'variant': out['variant'],
            });
          }
          out
            ..['component'] = 'Row'
            ..remove('text')
            ..['children'] = children;
        }
      }
    }
  }

  for (final slot in _valueSlots) {
    final coerced = _coerceBinding(out[slot]);
    if (coerced != null) out[slot] = coerced;
  }
  return out;
}

void _normalizeContext(Map<Object?, Object?> holder) {
  final context = holder['context'];
  if (context is! Map) return;
  final rewritten = <String, Object?>{};
  for (final entry in context.entries) {
    final value = entry.value;
    final coerced = _coerceBinding(value);
    rewritten['${entry.key}'] = coerced ?? value;
  }
  holder['context'] = rewritten;
}

/// 识别几种旧的绑定写法，返回 v1.0 的 `{"@path": ...}`。
///
/// - 字符串 `$name` / `$/a/b` / `${name}`
/// - 旧版对象 `{"path": "name"}`（带 `componentId` 的是列表模板，必须保留）
Map<String, Object?>? _coerceBinding(Object? value) {
  if (value is String) {
    final path = _wholePath(value);
    return path == null ? null : {'@path': path};
  }
  if (value is Map && !value.containsKey('componentId')) {
    final path = value['path'];
    if (path is String && value.keys.every((k) => k == 'path')) {
      return {'@path': path};
    }
  }
  return null;
}

/// 整串就是一个绑定（`$name` / `$/a/b` / `${name}`）时返回路径。
String? _wholePath(String value) {
  final segments = _segments(value);
  if (segments == null || segments.length != 1) return null;
  final only = segments.single;
  return only.isPath ? only.value : null;
}

class _Segment {
  const _Segment.literal(this.value) : isPath = false;
  const _Segment.path(this.value) : isPath = true;

  final String value;
  final bool isPath;
}

/// `$` 开头、前面不是 `$`（`$$` 当转义，保持字面量）。
final RegExp _reference = RegExp(
  r'(?<!\$)\$(?:\{([^{}]*)\}|(/[A-Za-z0-9_./~-]+)|([A-Za-z_][A-Za-z0-9_.]*))',
);

/// 简单的 JSON Pointer / 相对路径（模板内 `name`、`item.name`）。
final RegExp _path = RegExp(r'^(?:/[A-Za-z0-9_~./-]*|[A-Za-z_][A-Za-z0-9_.]*)$');

List<_Segment>? _segments(String input) {
  if (!input.contains(r'$')) return [_Segment.literal(input)];
  final segments = <_Segment>[];
  var cursor = 0;
  for (final match in _reference.allMatches(input)) {
    final content = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    if (content.isEmpty) return null;
    // 含函数调用/运算的表达式不处理，避免拆坏。
    if (!_path.hasMatch(content)) return null;
    if (match.start > cursor) {
      segments.add(_Segment.literal(input.substring(cursor, match.start)));
    }
    segments.add(_Segment.path(content));
    cursor = match.end;
  }
  if (cursor < input.length) {
    segments.add(_Segment.literal(input.substring(cursor)));
  }
  return segments;
}

String _uniqueId(String base, Set<String> usedIds) {
  var id = base;
  var suffix = 1;
  while (!usedIds.add(id)) {
    id = '${base}_${suffix++}';
  }
  return id;
}

Map<String, Object?> _copy(Map<Object?, Object?> source) {
  final out = <String, Object?>{};
  for (final entry in source.entries) {
    out['${entry.key}'] = _copyValue(entry.value);
  }
  return out;
}

Object? _copyValue(Object? value) {
  if (value is Map) return _copy(value);
  if (value is List) return [for (final item in value) _copyValue(item)];
  return value;
}
