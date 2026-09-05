import 'dart:io';

const int KB = 1024;
const int MB = KB * 1024;
const int GB = MB * 1024;

/// 递归统计目录内所有文件的总字节数（容错：单文件读取失败跳过，不中断）。
Future<int> directorySize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity
      in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } catch (_) {
        // 单个文件读取失败跳过，不影响整体统计。
      }
    }
  }
  return total;
}

String byteSize(int bytes) {
  if (bytes >= GB) {
    return '${(bytes / GB).toStringAsFixed(2)} GB';
  } else if (bytes >= MB) {
    return '${(bytes / MB).toStringAsFixed(2)} MB';
  } else if (bytes >= KB) {
    return '${(bytes / KB).toStringAsFixed(2)} KB';
  } else {
    return '$bytes B';
  }
}

int compareVersion(String oldVersion, newVersion) {
  final oldParts = _parseVersion(oldVersion);
  final newParts = _parseVersion(newVersion);

  // 比较主版本、次版本和补丁版本（不足位数视为 0）
  final len = oldParts.length > newParts.length
      ? oldParts.length
      : newParts.length;
  for (int i = 0; i < len; i++) {
    final oldPart = i < oldParts.length ? oldParts[i] : 0;
    final newPart = i < newParts.length ? newParts[i] : 0;
    if (oldPart < newPart) return 1; // 新版本更大
    if (oldPart > newPart) return -1; // 旧版本更大
  }
  return 0; // 版本号相同
}

/// 从版本字符串提取所有数字段
/// 兼容 "v2"、"0-beta04"、"1.5.0-alpha" 等含非数字字符的版本号
/// 提取所有数字序列，如 "0-beta04" -> [0, 4]
List<int> _parseVersion(String version) {
  final matches = RegExp(r'\d+').allMatches(version);
  if (matches.isEmpty) return const [0];
  return matches.map((m) => int.parse(m.group(0)!)).toList();
}

/// 判断 URL 是否为 GitHub 相关域名（需要走代理）
bool isGithubUrl(String url) {
  return url.startsWith('https://github.com/') ||
      url.startsWith('http://github.com/') ||
      url.startsWith('https://raw.githubusercontent.com/') ||
      url.startsWith('https://api.github.com/') ||
      url.startsWith('https://objects.githubusercontent.com/') ||
      url.startsWith('https://user-images.githubusercontent.com/') ||
      url.startsWith('https://avatars.githubusercontent.com/') ||
      url.startsWith('https://camo.githubusercontent.com/');
}

/// 应用代理前缀（GitHub 相关域名且配置了代理时）
/// 返回处理后的 URL
String applyProxyIfNeeded(String url, String proxy) {
  if (proxy.isEmpty) return url;
  if (!isGithubUrl(url)) return url;
  if (url.startsWith(proxy)) return url; // 已带代理
  return '$proxy$url';
}

/// 将 Markdown 与 HTML 中的相对路径图片替换为完整 raw URL（GitHub 仓库资源）
/// ![img](images/x.png) → ![img]({rawBaseUrl}images/x.png)
/// <img src="screenshots/x.png"> → <img src="{rawBaseUrl}screenshots/x.png">
/// 绝对 URL（http/https/data:）与其余内容不动；rawBaseUrl 需以 / 结尾
String resolveReadmeImageUrls(String readme, String rawBaseUrl) {
  final pattern = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
  readme = readme.replaceAllMapped(pattern, (m) {
    final alt = m.group(1)!;
    final path = m.group(2)!;
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('data:')) {
      return m.group(0)!;
    }
    return '![$alt]($rawBaseUrl$path)';
  });
  final htmlImgPattern = RegExp(r'<img\b[^>]*\bsrc="([^"]+)"[^>]*>');
  return readme.replaceAllMapped(htmlImgPattern, (m) {
    final src = m.group(1)!;
    if (src.startsWith('http://') ||
        src.startsWith('https://') ||
        src.startsWith('data:')) {
      return m.group(0)!;
    }
    return m.group(0)!.replaceFirst('src="$src"', 'src="$rawBaseUrl$src"');
  });
}

/// 将 HTML <img> 标签转换为 markdown 图片语法（flutter_markdown_plus 不支持内联 HTML）
/// <img src="URL" alt="x" width="200" height="100"> → ![x](URL "200x100")
/// <a href="HREF"><img ...></a> → [![x](URL "200x100")](HREF)
/// 无 width/height → ![alt](URL)；无 alt → ![](URL)
/// title 编码格式 "WxH"；仅单边时 "Wx" / "xH"（width x height，仅含数字时）
///
/// 处理链（依次）：
/// 1. <a> 包裹的 img → markdown 链接图片（提取 a 的 href + img 的 src/alt/width/height）
/// 2. 单独 <img> → markdown 图片
/// 3. 剥离孤立内联 HTML 标签：<br> → 换行；其余常见标签（a/div/span/p/h1-6 等）→ ''（内容保留），
///    避免 <a>/<div> 等行首标签被 CommonMark 判为 HTML 块而吞掉后续 markdown 语法
///
/// 限制与说明：
/// - 无 src 的 img 原样保留；无 href 的 <a> 包裹按单独 img 处理（a 标签由步骤 3 剥离）
/// - alt 仅按原样嵌入，未转义其中的 ] ( ) —— README 场景 alt 均为简单文本，
///   若遇复杂 alt 需自行转义
/// - 仅支持双引号属性（HTML 标准写法）；width/height 可为纯数字或带 px 后缀，
///   含 % / 小数等其他单位时不编码 title
/// - <img> 不在剥离名单（理论上已全转换；若残留保持原样不剥）
String convertHtmlImgsToMarkdown(String html) {
  // 1. <a> 包裹 img → markdown 链接图片
  final aImgPattern =
      RegExp(r'<a\b[^>]*>\s*(<img\b[^>]*>)\s*</a>', caseSensitive: false);
  html = html.replaceAllMapped(aImgPattern, (m) {
    final full = m.group(0)!;
    final aTag = full.substring(0, full.indexOf('>') + 1);
    final href = _extractImgAttrs(aTag)['href'] ?? '';
    final imgTag = m.group(1)!;
    final imgMd = _imgTagToMarkdown(imgTag);
    if (href.isEmpty || imgMd == imgTag) return imgTag; // 无 href/src → a 由步骤 3 剥离
    return '[$imgMd]($href)';
  });

  // 2. 单独 img
  final imgPattern = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  html =
      html.replaceAllMapped(imgPattern, (m) => _imgTagToMarkdown(m.group(0)!));

  // 3. 剥离孤立内联 HTML 标签（img 已全部转换，剩余标签不影响 markdown 解析）
  final brPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
  html = html.replaceAll(brPattern, '\n');
  final orphanPattern = RegExp(
      r'</?(?:a|div|span|center|p|h[1-6]|strong|em|b|i|u|font|table|thead|tbody|tr|td|th|ul|ol|li)(?:\s[^>]*)?/?>',
      caseSensitive: false);
  return html.replaceAll(orphanPattern, '');
}

/// 提取单个 HTML 标签内的双引号属性（键转小写）
Map<String, String> _extractImgAttrs(String tag) {
  final attrs = <String, String>{};
  for (final a in RegExp(r'([a-zA-Z:]+)="([^"]*)"').allMatches(tag)) {
    attrs[a.group(1)!.toLowerCase()] = a.group(2)!;
  }
  return attrs;
}

/// 将单个 <img> 标签转 markdown 图片语法；无 src 时原样返回原标签
String _imgTagToMarkdown(String tag) {
  final attrs = _extractImgAttrs(tag);
  final src = attrs['src'];
  if (src == null || src.isEmpty) return tag; // 无 src → 原样保留
  final alt = attrs['alt'] ?? '';
  final w = attrs['width'] == null ? null : _stripImgSize(attrs['width']!);
  final h = attrs['height'] == null ? null : _stripImgSize(attrs['height']!);
  var md = '![$alt]($src';
  if (w != null && h != null) {
    md += ' "${w}x$h"';
  } else if (w != null) {
    md += ' "${w}x"'; // 仅宽度：高度交由 _ReadmeImage loose 自适应
  } else if (h != null) {
    md += ' "x$h"'; // 仅高度：宽度等比补全
  }
  return '$md)';
}

/// 剥离 width/height 的 px 后缀，仅纯数字（可带 px）时返回数字串，否则返回 null
/// "200" / "200px" → "200"；"50%" / "200.5" → null
String? _stripImgSize(String raw) {
  final m = RegExp(r'^([0-9]+)(?:px)?$', caseSensitive: false)
      .firstMatch(raw.trim());
  return m?.group(1);
}
