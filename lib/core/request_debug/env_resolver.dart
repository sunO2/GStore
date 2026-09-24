/// 「请求调试」环境变量替换引擎（Postman `{{var}}` 语义，纯函数）。
///
/// 见 `.omo/plans/proxy-http-capture.md` todo 28：`{{var}}` 替换作用于
/// URL / 头 / 体 / 查询（由调用方在发送 / 预览副本上调用本函数），来自当前
/// [DebugEnvironment]。**未定义变量保留原样**并在此处标记（由 UI 高亮）。
///
/// 关键不变量：
/// - **不递归**：替换进文本的值即使含 `{{x}}` 也不再展开，且不计入缺失。
/// - **不修改**：本文件为纯函数，输入 [vars] 与 [text] 均只读，替换结果在
///   新字符串上返回——绝不回写存储的原始值。
/// - 变量名按 `{{ name }}` 语义**去首尾空白**后查表；未命中时保留**原始**
///   占位符文本（含空白）以便 UI 精确定位。
/// - 值为 `$` / 花括号 / 反斜杠 / Unicode 等特殊字符时按字面插入。
library;

import 'debug_models.dart';

/// `{{var}}` 占位符：变量名不含花括号（允许内部空白，查表时 trim）。
final RegExp _placeholder = RegExp(r'\{\{([^{}]+)\}\}');

/// 一次替换的结果。
class ResolveResult {
  const ResolveResult(this.text, this.missing);

  /// 替换后的文本（[vars] 中已定义变量被替换；未定义占位符原样保留）。
  final String text;

  /// 未能解析（未定义）的变量名集合；按首次出现顺序去重。
  final Set<String> missing;

  /// 是否存在未定义变量。
  bool get hasMissing => missing.isNotEmpty;

  @override
  String toString() => 'ResolveResult(text: $text, missing: $missing)';
}

/// 将 [text] 中的 `{{var}}` 用 [vars] 替换为对应值。
///
/// - 命中：替换为其值（值为空串亦视为命中）。
/// - 未命中：保留原始 `{{var}}` 文本并把变量名加入 [ResolveResult.missing]。
/// - 不递归：替换后的值不会被再次扫描。
///
/// 纯函数：不修改 [vars]，也不触碰任何存储状态。
ResolveResult resolveEnv(String text, Map<String, String> vars) {
  if (text.isEmpty) {
    return const ResolveResult('', <String>{});
  }
  final missing = <String>{};
  final resolved = text.replaceAllMapped(_placeholder, (match) {
    final name = match.group(1)!.trim();
    final value = vars[name];
    if (value != null) {
      // 回调返回的字符串按字面插入：`$`、花括号等无特殊含义。
      return value;
    }
    missing.add(name);
    // 保留原始占位符（含空白），供 UI 标记定位。
    return match.group(0)!;
  });
  return ResolveResult(resolved, missing);
}

/// [resolveEnv] 的便捷重载：直接取用 [env] 的变量表。
///
/// 仅读取 [DebugEnvironment.vars]，不修改该对象。
ResolveResult resolveEnvIn(String text, DebugEnvironment env) =>
    resolveEnv(text, env.vars);
