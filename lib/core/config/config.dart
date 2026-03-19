/// 统一配置管理系统
///
/// 提供统一的配置管理接口，支持多种配置类型的注册、加载、保存、备份和恢复
library;

export 'config_item.dart';
export 'config_provider.dart';
export 'config_storage.dart';
export 'config_backup.dart';
export 'config_manager.dart';

// 导出具体的配置提供者
export 'providers/theme_config_provider.dart';
export 'providers/webdav_config_provider.dart';
export 'providers/update_config_provider.dart';

// 配置初始化
export 'config_initializer.dart';
