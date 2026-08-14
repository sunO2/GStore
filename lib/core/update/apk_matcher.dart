import 'package:gstore/core/model/AppDetailInfo.dart';

/// 是否 Android 可安装文件（.apk / .aab，大小写不敏感）
bool isInstallableDownload(DownloadInfo dl) {
  final lower = dl.name.toLowerCase();
  return lower.endsWith('.apk') || lower.endsWith('.aab');
}

/// 过滤出可安装下载（保留原顺序）
List<DownloadInfo> filterInstallableDownloads(List<DownloadInfo> downloads) =>
    downloads.where(isInstallableDownload).toList();

/// 从下载候选中按文件名 Levenshtein 相似度选择最接近 [preferred] 的项。
///
/// 规则：
/// - candidates 为空 / preferred 为空 → null（调用方回退现有 selectBestDownload 规则）
/// - 小写归一化后计算 Levenshtein 编辑距离（标准 DP）
/// - 距离最小者胜；多个同距离 → 取候选列表靠前者（保持顺序确定性）
/// - 距离 0（完全一致）→ 直接返回该项
DownloadInfo? pickClosestApk(List<DownloadInfo> candidates, String preferred) {
  if (candidates.isEmpty || preferred.trim().isEmpty) return null;
  final target = preferred.toLowerCase();
  DownloadInfo? best;
  var bestDistance = 0x7fffffff;
  for (final candidate in candidates) {
    final distance = _levenshtein(candidate.name.toLowerCase(), target);
    // 同距离保留靠前者（best 仅在更小时更新），距离 0 直接返回
    if (distance < bestDistance) {
      bestDistance = distance;
      best = candidate;
      if (distance == 0) break;
    }
  }
  return best;
}

/// 结合用户 APK 选择偏好与默认规则（selectBestDownload）选出下载项。
///
/// 规则：
/// - [preferred] 非空且能在 [candidates] 中按文件名相似度匹配到项 → 返回匹配项
/// - 其余情况（无偏好 / 偏好为空串 / candidates 为空 / 无匹配）→ 返回 [fallback]
///   （即渠道按设备架构选出的 check.latestDownload，现规则不变）
/// - [candidates] 为 null（如缓存恢复路径无 detail）→ 回退 [fallback]
DownloadInfo selectDownloadWithPreference({
  required DownloadInfo fallback,
  required List<DownloadInfo>? candidates,
  required String? preferred,
}) {
  if (preferred == null || preferred.trim().isEmpty) return fallback;
  final list = candidates ?? const <DownloadInfo>[];
  return pickClosestApk(list, preferred) ?? fallback;
}

/// 标准 Levenshtein 编辑距离（动态规划，O(n*m)）。
/// 文件名通常 <100 字符，两行滚动数组即可满足空间需求。
int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final curr = List<int>.filled(b.length + 1, 0);
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = _min3(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    prev = curr;
  }
  return prev[b.length];
}

int _min3(int x, int y, int z) => x < y ? (x < z ? x : z) : (y < z ? y : z);
