const int KB = 1024;
const int MB = KB * 1024;
const int GB = MB * 1024;

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

/// 将 Markdown 中的相对路径图片替换为完整 raw URL（GitHub 仓库资源）
/// ![img](images/x.png) → ![img]({rawBaseUrl}images/x.png)
/// 绝对 URL（http/https/data:）与其余内容不动；rawBaseUrl 需以 / 结尾
String resolveReadmeImageUrls(String readme, String rawBaseUrl) {
  final pattern = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
  return readme.replaceAllMapped(pattern, (m) {
    final alt = m.group(1)!;
    final path = m.group(2)!;
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('data:')) {
      return m.group(0)!;
    }
    return '![$alt]($rawBaseUrl$path)';
  });
}
