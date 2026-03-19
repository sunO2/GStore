/// 应用基础信息抽象接口
/// 所有渠道的应用必须实现此接口
library;

/// 应用基础信息接口
/// 定义应用最核心的四个基础字段
abstract class IAppInfo {
  /// 应用包名（唯一标识）
  ///
  /// 用于：
  /// - 数据库主键
  /// - 应用安装状态检测
  /// - 应用去重和合并
  String get packageName;

  /// 应用名称
  String get appName;

  /// 应用图标URL
  String get icon;

  /// 应用简短描述
  String get description;
}
