import 'package:gstore/core/model/AppDetailInfo.dart';

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
