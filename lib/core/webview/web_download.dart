/// 内置浏览器下载：把 `onDownloadStartRequest` 的信息整理成 GStore 下载任务参数。
///
/// 文件名优先级：`suggestedFilename` → `Content-Disposition: filename=...`
/// → URL 最后一段 → `download_<时间戳>`；没有扩展名时按 MIME 补齐。
library;

/// 常见下载类型的扩展名（仅在文件名没有后缀时补）。
const Map<String, String> _mimeExtensions = {
  'application/vnd.android.package-archive': 'apk',
  'application/octet-stream': 'bin',
  'application/zip': 'zip',
  'application/x-zip-compressed': 'zip',
  'application/pdf': 'pdf',
  'application/json': 'json',
  'text/plain': 'txt',
  'text/csv': 'csv',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
};

/// 解析下载文件名（纯函数，方便单测）。
String resolveWebDownloadFileName({
  String? suggestedFilename,
  String? contentDisposition,
  String? mimeType,
  required Uri url,
}) {
  var name = suggestedFilename?.trim() ?? '';
  if (name.isEmpty) {
    name = _fromContentDisposition(contentDisposition) ?? '';
  }
  if (name.isEmpty) {
    final segments =
        url.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.isNotEmpty) name = segments.last;
  }
  if (name.isEmpty) {
    name = 'download_${DateTime.now().millisecondsSinceEpoch}';
  }

  // 去掉查询串/片段残留，替换文件系统非法字符。
  name = name.split('?').first.split('#').first;
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (name.isEmpty) {
    name = 'download_${DateTime.now().millisecondsSinceEpoch}';
  }

  if (!name.contains('.')) {
    final ext = _mimeExtensions[(mimeType ?? '').toLowerCase()];
    if (ext != null) name = '$name.$ext';
  }

  if (name.length > 120) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 8 ? name.substring(dot) : '';
    name = name.substring(0, 120 - ext.length) + ext;
  }
  return name;
}

String? _fromContentDisposition(String? header) {
  if (header == null || header.isEmpty) return null;
  final match = RegExp(
    r"""filename\*=UTF-8''([^;]+)|filename\s*=\s*(?:"([^"]+)"|([^;]+))""",
    caseSensitive: false,
  ).firstMatch(header);
  final raw = match?.group(1) ?? match?.group(2) ?? match?.group(3);
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  try {
    return Uri.decodeComponent(text);
  } catch (_) {
    return text;
  }
}
