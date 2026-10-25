/// 发现页「搜索渠道选择器」的轻量值类型。
///
/// 搜索选择器需要把 Dart 渠道（枚举/脚本渠道，[IChannel]）和 Rust 脚本通道包
/// 并列展示，但 Rust 通道包**不是** `IChannel`：`CoreFlags.jsChannel` 打开后
/// Dart `JsChannel` 已注销、Rust 通道包也没有绑定 channel driver。用一个只承载
/// 「选择 + 展示」所需字段的描述类型承载它们，避免伪造一个谎报能力的 `IChannel`。
library;

/// 一个可搜索渠道的轻量描述。
///
/// [code] 是唯一路由键：枚举/脚本渠道 = `channelCode(channel)`，
/// Rust 通道包 = `pack.key`（`js_*`）。[name] 仅用于展示。
class SearchChannelOption {
  const SearchChannelOption({required this.code, required this.name});

  /// 渠道 code（选择 + 搜索/保存路由键）。
  final String code;

  /// 展示名：Rust 通道包名（缺失时回退 [code]）。
  final String name;

  @override
  String toString() => 'SearchChannelOption($code, $name)';
}

/// 保存搜索结果到渠道的类型化结果（成功 / 失败 + 稳定机器码）。
///
/// 取代旧的 `bool`：调用方必须能区分「写入成功」和「该渠道根本没有保存 API」，
/// 而不是把两者都当成一个静默的 `false`。
sealed class SearchSaveOutcome {
  const SearchSaveOutcome();
}

/// 保存成功。
final class SearchSaved extends SearchSaveOutcome {
  const SearchSaved();
}

/// 保存失败；[code] 是稳定机器码，[message] 面向用户。
final class SearchSaveFailed extends SearchSaveOutcome {
  const SearchSaveFailed(this.code, this.message);

  /// Rust 脚本通道当前没有向 Dart 暴露保存 API。
  static const String laneUnsupported = 'CORE_E_SEARCH_SAVE_LANE_UNSUPPORTED';

  /// 渠道不可用 / 未注册（旧 Dart 路径）。
  static const String channelUnavailable =
      'CORE_E_SEARCH_SAVE_CHANNEL_UNAVAILABLE';

  /// 渠道写入失败。
  static const String writeFailed = 'CORE_E_SEARCH_SAVE_WRITE_FAILED';

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
