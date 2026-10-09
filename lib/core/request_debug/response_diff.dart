/// 「请求调试」响应 diff 纯逻辑（plan todo 18）。
///
/// 对两条历史响应快照的 Body 文本做**按行**比较，标出未变 / 新增 / 删除三类，
/// 供 [ResponseDiffView] 高亮展示。纯函数、无 UI、绝不抛异常。
library;

/// diff 行类型。
enum DiffLineKind {
  /// 两侧一致的行。
  unchanged,

  /// 仅出现在「新」侧（新增）。
  added,

  /// 仅出现在「旧」侧（删除）。
  removed,
}

/// 单条 diff 行（类型 + 文本）。
class DiffLine {
  const DiffLine(this.kind, this.text);

  /// 增删 / 未变类型。
  final DiffLineKind kind;

  /// 行文本（不含换行符）。
  final String text;

  @override
  String toString() => '${kind.name}: $text';
}

/// LCS 动态规划上限（行数乘积）。超过即退化为「整体删 + 整体增」，
/// 避免超长文本导致的 O(n×m) 内存爆炸。
const int maxDiffCells = 2000000;

/// 对两段文本做按行 diff（LCS）。
///
/// - `null` / 空串视为「无行」；两侧都为空返回空列表；
/// - 返回的 [DiffLine] 顺序即渲染顺序：删除行在其对应的新增行之前；
/// - 纯函数，绝不抛异常。
List<DiffLine> diffResponseLines(String? before, String? after) {
  final a = _splitLines(before);
  final b = _splitLines(after);
  if (a.isEmpty && b.isEmpty) return const <DiffLine>[];

  if (a.length * b.length > maxDiffCells) {
    return <DiffLine>[
      for (final line in a) DiffLine(DiffLineKind.removed, line),
      for (final line in b) DiffLine(DiffLineKind.added, line),
    ];
  }

  final n = a.length;
  final m = b.length;
  // dp[i][j] = a[i..] 与 b[j..] 的最长公共子序列长度。
  final dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffLineKind.unchanged, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine(DiffLineKind.removed, a[i]));
      i++;
    } else {
      out.add(DiffLine(DiffLineKind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffLineKind.removed, a[i]));
    i++;
  }
  while (j < m) {
    out.add(DiffLine(DiffLineKind.added, b[j]));
    j++;
  }
  return out;
}

List<String> _splitLines(String? text) {
  if (text == null || text.isEmpty) return const <String>[];
  return text.split('\n');
}
