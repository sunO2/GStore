/// 「请求调试」环境变量替换引擎（Postman `{{var}}` 语义，纯函数）。
///
/// 见 `.omo/plans/proxy-http-capture.md` todo 28 与
/// `.omo/plans/net-req-debug-enhancement.md` todo 20：`{{var}}` 替换作用于
/// URL / 头 / 体 / 查询（由调用方在发送 / 预览副本上调用本函数），来自当前
/// [DebugEnvironment] 或其作用域合并结果。**未定义变量保留原样**并在此处标记
/// （由 UI 高亮）。
///
/// 关键不变量：
/// - **不递归**：替换进文本的值即使含 `{{x}}` 也不再展开，且不计入缺失。
/// - **不修改**：本文件为纯函数，输入 [vars] 与 [text] 均只读，替换结果在
///   新字符串上返回——绝不回写存储的原始值。
/// - 变量名按 `{{ name }}` 语义**去首尾空白**后查表；未命中时保留**原始**
///   占位符文本（含空白）以便 UI 精确定位。
/// - 值为 `$` / 花括号 / 反斜杠 / Unicode 等特殊字符时按字面插入。
///
/// 默认值语法（todo 20）：`{{var:-default}}`——变量缺失时用 `default`；命中
/// （含空串）时忽略默认值。默认值本身可含其它 `{{var}}`（作为占位符语法的一
/// 部分被解析，**不**违反「不递归替换值」不变量），但深度受限以防御环。
library;

import 'debug_models.dart';

/// `{{var}}` 占位符：变量名不含花括号（允许内部空白，查表时 trim）。
final RegExp _placeholder = RegExp(r'\{\{([^{}]+)\}\}');

/// 默认值占位符的分隔符：`{{name:-default}}`。
const String _defaultSeparator = ':-';

/// 默认值内嵌占位符的最大递归深度（防 `{{a:-{{a:-...}}}}` 式环）。
const int _maxDefaultDepth = 8;

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

/// 将 [text] 中的 `{{var}}` / `{{var:-default}}` 用 [vars] 替换为对应值。
///
/// - 命中：替换为其值（值为空串亦视为命中，忽略默认值）。
/// - 未命中且有默认值：替换为默认值（默认值内的占位符会被解析，深度受限）。
/// - 未命中且无默认值：保留原始 `{{var}}` 文本并把变量名加入
///   [ResolveResult.missing]。
/// - 不递归：替换后的**变量值**不会被再次扫描。
///
/// 纯函数：不修改 [vars]，也不触碰任何存储状态。
ResolveResult resolveEnv(String text, Map<String, String> vars) =>
    _resolve(text, vars, 0);

ResolveResult _resolve(String text, Map<String, String> vars, int depth) {
  if (text.isEmpty) {
    return const ResolveResult('', <String>{});
  }
  final missing = <String>{};
  final resolved = text.replaceAllMapped(_placeholder, (match) {
    final raw = match.group(1)!.trim();
    final separator = raw.indexOf(_defaultSeparator);
    final name =
        separator < 0 ? raw : raw.substring(0, separator).trim();
    final defaultValue =
        separator < 0 ? null : raw.substring(separator + _defaultSeparator.length);
    final value = vars[name];
    if (value != null) {
      // 回调返回的字符串按字面插入：`$`、花括号等无特殊含义。
      return value;
    }
    if (defaultValue != null) {
      // 默认值是**占位符语法的一部分**：允许其中再含 `{{var}}`（解析它们不
      // 违反「不递归替换值」不变量），但限制深度以防御环。
      if (depth < _maxDefaultDepth && defaultValue.contains('{{')) {
        final inner = _resolve(defaultValue, vars, depth + 1);
        missing.addAll(inner.missing);
        return inner.text;
      }
      return defaultValue;
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
