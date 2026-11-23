/// 上下文预算（P3-2）
///
/// 把「模型上下文窗口」换算成「本回合可用提示 token」，并提供一个保守的
/// 字符→token 估算。纯函数、无依赖，便于单测。
///
/// 设计取舍：
/// - 提示只占窗口的 [promptShare]（默认 60%），其余留给输出、工具结果与
///   下一轮的工具请求 schema，避免"刚好塞满"导致 400/截断。
/// - token 估算对中文取 1 字 = 1 token（悲观），英文按 4 字符 = 1 token。
///   宁可少放一点历史，也不要在中文长会话里超窗。
library;

class AgentContextBudget {
  AgentContextBudget._();

  /// 未配置窗口时的云端默认提示预算（≈24k token，与历史行为一致）
  static const int defaultCloudPromptTokens = 24000;

  /// 本地模型默认（无工具 / 有工具）
  static const int defaultLocalPromptTokens = 3000;
  static const int defaultLocalToolsPromptTokens = 6000;

  /// 提示占窗口比例
  static const double promptShare = 0.6;

  /// 本回合允许的提示 token 数。
  ///
  /// [contextWindow] <= 0 → 使用默认值（云端 24k / 本地 3k~6k）。
  static int promptTokensFor({
    required int contextWindow,
    required bool local,
    required bool toolsEnabled,
  }) {
    if (contextWindow > 0) {
      final share = (contextWindow * promptShare).round();
      return share < 512 ? 512 : share;
    }
    if (local) {
      return toolsEnabled
          ? defaultLocalToolsPromptTokens
          : defaultLocalPromptTokens;
    }
    return defaultCloudPromptTokens;
  }

  /// 保守 token 估算：CJK 1 字 ≈ 1 token；ASCII 4 字符 ≈ 1 token；
  /// 其余（标点/emoji）2 个 ≈ 1 token。
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var ascii = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else if (rune <= 0x7F) {
        ascii++;
      } else {
        other++;
      }
    }
    return cjk + (ascii + 3) ~/ 4 + (other + 1) ~/ 2;
  }

  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意
      (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
      (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意
      (rune >= 0x3040 && rune <= 0x30FF) || // 日文假名
      (rune >= 0xAC00 && rune <= 0xD7AF) || // 韩文
      (rune >= 0x3000 && rune <= 0x303F); // CJK 标点（按 1 token 计更保守）

  /// 把字符上限换算成 token 预算的下界（用于本地模型的字符上限）。
  static int charsForWindow(int contextWindow) {
    if (contextWindow <= 0) return 0;
    final share = (contextWindow * promptShare).round();
    return share < 512 ? 512 : share;
  }
}
