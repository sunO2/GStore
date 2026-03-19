/// 配置项基类
///
/// 所有配置类都必须继承此基类，确保统一的序列化接口
library;

/// 配置项基类
///
/// 提供配置项的基本接口：
/// - 唯一标识 key
/// - 版本管理 version
/// - 敏感性标记 sensitive（是否需要加密存储）
/// - 序列化/反序列化
abstract class ConfigItem {
  /// 配置唯一标识（用于存储键）
  String get key;

  /// 配置版本（用于数据迁移）
  ///
  /// 当配置结构发生变化时，增加版本号并实现对应的迁移逻辑
  int get version;

  /// 是否为敏感数据
  ///
  /// 敏感数据将使用加密存储（FlutterSecureStorage）
  /// 非敏感数据使用普通存储（SharedPreferences）
  bool get sensitive;

  /// 转换为 JSON（用于序列化）
  Map<String, dynamic> toJson();

  /// 从 JSON 创建实例（用于反序列化）
  /// 子类必须实现此工厂构造函数
  ConfigItem.fromJson(Map<String, dynamic> json);

  /// 获取默认配置实例
  ///
  /// 子类应实现此 getter 以返回默认配置
  /// 如果子类没有实现，将抛出 UnimplementedError
  static ConfigItem get defaultConfig {
    throw UnimplementedError(
      'Subclasses must implement defaultConfig getter',
    );
  }

  /// 复制并修改部分属性
  ///
  /// 这是一个可选的实现，如果配置类需要不可变更新模式
  /// 子类如果不实现，调用将抛出 UnimplementedError
  ConfigItem copyWith() {
    throw UnimplementedError(
      'Subclasses must implement copyWith method',
    );
  }
}
