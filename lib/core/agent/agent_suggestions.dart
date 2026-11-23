/// 回复末尾的「可点击建议」解析（P3-8）
///
/// 模型经常在结尾给出"需要我帮你…吗？"之类的追问。这里把这类内容解析成
/// 可点击建议：点击后直接把**祈使句**作为用户消息发送。
///
/// 解析优先级：
/// 1. 结构化标记行：`建议：A|B|C`（提示词会引导模型这样输出；最可靠）
/// 2. 结尾的祈使型列表项（`- 帮我下载 Termux`）
/// 3. 结尾的提议型问句（`需要我帮你下载 Termux 吗？` → `下载 Termux`）
///
/// 纯函数、无 UI 依赖，便于单测。
library;

class AgentSuggestion {
  const AgentSuggestion({required this.label, required this.sendText});

  /// 按钮上展示的文案
  final String label;

  /// 点击后作为用户消息发送的文本（通常是祈使句）
  final String sendText;
}

class AgentSuggestions {
  AgentSuggestions._();

  static const int maxCount = 3;
  static const int _maxLabelChars = 28;

  /// 从助手回复正文中提取建议（没有则返回空列表）。
  static List<AgentSuggestion> extract(String text, {int max = maxCount}) {
    if (text.trim().isEmpty) return const [];

    final structured = _fromStructuredLine(text);
    if (structured.isNotEmpty) return _dedupe(structured, max);

    final imperative = _fromImperativeList(text);
    if (imperative.length >= 2) return _dedupe(imperative, max);

    final offer = _fromOfferQuestion(text);
    return _dedupe([...imperative, ...offer], max);
  }

  /// 渲染用：去掉末尾的结构化建议行（按钮已经展示了同样的选项）。
  ///
  /// 只删最后一个非空行匹配到的 `建议：` 行；正文中的其它内容保持原样。
  static String stripStructuredLine(String text) {
    final lines = text.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (_structuredLine.hasMatch(lines[i])) {
        lines.removeAt(i);
        // 去掉行后残留的尾部空行
        while (lines.isNotEmpty && lines.last.trim().isEmpty) {
          lines.removeLast();
        }
        return lines.join('\n').trimRight();
      }
      break;
    }
    return text;
  }

  // -------------------------------------------------------------------------
  // 1. `建议：A|B|C`
  // -------------------------------------------------------------------------

  static final RegExp _structuredLine = RegExp(
    r'^[\s>*_`•-]*\**\s*(建议|下一步|可选操作)\s*\**\s*[:：]\s*(.+)$',
    multiLine: true,
  );

  static List<AgentSuggestion> _fromStructuredLine(String text) {
    final matches = _structuredLine.allMatches(text).toList();
    if (matches.isEmpty) return const [];
    final raw = matches.last.group(2) ?? '';
    final parts = raw
        .split(RegExp(r'[|｜]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final out = <AgentSuggestion>[];
    for (final part in parts) {
      final command = _toCommand(part);
      if (command.isEmpty) continue;
      out.add(AgentSuggestion(label: _clipLabel(command), sendText: command));
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 2. 祈使型列表项
  // -------------------------------------------------------------------------

  static const List<String> _imperativePrefixes = [
    '帮我',
    '帮我看看',
    '查看',
    '打开',
    '下载',
    '安装',
    '检查',
    '对比',
    '搜索',
    '抓取',
    '总结',
    '继续',
    '再查',
    '换成',
    '不用',
    '取消',
    '先不',
  ];

  static final RegExp _listItem =
      RegExp(r'^\s*(?:[-*•]|\d+[.、)])\s+(.+?)\s*$', multiLine: true);

  static List<AgentSuggestion> _fromImperativeList(String text) {
    final lines = text.split('\n');
    // 只看回复末尾 1/3，避免把正文中的列表当成建议
    final start = (lines.length * 2 / 3).floor();
    final tail = lines.sublist(start).join('\n');
    final out = <AgentSuggestion>[];
    for (final match in _listItem.allMatches(tail)) {
      final raw = match.group(1)?.trim() ?? '';
      if (raw.isEmpty || raw.length > 40) continue;
      final looksQuestion = RegExp(r'[？?]\s*$').hasMatch(raw);
      final imperative = _imperativePrefixes.any(raw.startsWith) ||
          _imperativePrefixes.any((p) => raw.contains(p));
      if (!looksQuestion && !imperative) continue;
      final command = _toCommand(raw);
      if (command.isEmpty) continue;
      out.add(AgentSuggestion(label: _clipLabel(command), sendText: command));
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 3. 提议型问句
  // -------------------------------------------------------------------------

  static const List<String> _offerPrefixes = [
    '是否需要我',
    '需不需要我',
    '要不要我',
    '需要我',
    '要不要',
    '是否要我',
    '要我',
    '我可以',
  ];

  static List<AgentSuggestion> _fromOfferQuestion(String text) {
    // 末尾最多两句话
    final sentences = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .split(RegExp(r'(?<=[。！？!?])'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final tail = sentences.length > 2
        ? sentences.sublist(sentences.length - 2)
        : sentences;
    final out = <AgentSuggestion>[];
    for (final sentence in tail.reversed) {
      if (!RegExp(r'[？?]\s*$').hasMatch(sentence)) continue;
      if (sentence.length > 60) continue;
      if (!_offerPrefixes.any(sentence.startsWith)) continue;
      final command = _toCommand(sentence);
      if (command.isEmpty) continue;
      out.add(AgentSuggestion(label: _clipLabel(command), sendText: command));
    }
    return out.reversed.toList();
  }

  // -------------------------------------------------------------------------
  // 归一化
  // -------------------------------------------------------------------------

  /// 把建议文案转成可直接发送的祈使句。
  static String _toCommand(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'^[\s>*_`•\-\d.、)）]+'), '');
    s = s.replaceAll(RegExp(r'[\s*`]+$'), '');
    s = s.replaceAll(RegExp(r'[？?。！!]+\s*$'), '').trim();
    for (final prefix in const [
      '是否需要我',
      '需不需要我',
      '要不要我',
      '需要我',
      '要不要',
      '是否要我',
      '要我',
      '我可以',
    ]) {
      if (s.startsWith(prefix)) {
        s = s.substring(prefix.length).trim();
        break;
      }
    }
    s = s.replaceFirst(RegExp(r'^(帮你|帮您|你|您)'), '').trim();
    s = s.replaceFirst('帮你', '').replaceFirst('帮您', '').trim();
    s = s.replaceAll(RegExp(r'(吗|呢|吧)$'), '').trim();
    return s;
  }

  static String _clipLabel(String text) {
    if (text.length <= _maxLabelChars) return text;
    return '${text.substring(0, _maxLabelChars)}…';
  }

  static List<AgentSuggestion> _dedupe(List<AgentSuggestion> items, int max) {
    final seen = <String>{};
    final out = <AgentSuggestion>[];
    for (final item in items) {
      final key = item.sendText.trim();
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(item);
      if (out.length >= max) break;
    }
    return out;
  }
}
