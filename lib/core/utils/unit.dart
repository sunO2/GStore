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
  // 将版本号字符串分割为整数列表
  List<int> parseVersion(String version) {
    return version.split('.').map(int.parse).toList();
  }

  List<int> oldParts = parseVersion(oldVersion);
  List<int> newParts = parseVersion(newVersion);

  // 比较主版本、次版本和补丁版本
  for (int i = 0; i < 3; i++) {
    if (oldParts[i] < newParts[i]) return 1; // v1 比 v2 新
    if (oldParts[i] > newParts[i]) return -1; // v1 比 v2 旧
  }
  return 0; // 版本号相同
}
