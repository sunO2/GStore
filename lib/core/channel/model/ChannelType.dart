/// 渠道类型枚举
enum ChannelType {
  /// 本地数据库渠道
  localDb('local_db', '本地数据库', 1),

  /// GitHub API 渠道
  github('github', 'GitHub API', 2),

  /// HTTP API 渠道
  http('http', 'HTTP API', 3),

  /// vivo 应用市场渠道
  vivo('vivo', 'vivo 应用市场', 4),

  /// F-Droid 应用市场渠道
  fdroid('fdroid', 'F-Droid', 5),

  /// 自定义渠道
  custom('custom', '自定义', 99);

  final String code;
  final String description;
  final int priority;

  const ChannelType(this.code, this.description, this.priority);

  /// 通过 code 获取 ChannelType
  static ChannelType? fromCode(String code) {
    try {
      return ChannelType.values.firstWhere((e) => e.code == code);
    } catch (_) {
      return null;
    }
  }
}
