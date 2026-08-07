/// 配置初始化
///
/// 负责初始化配置管理系统并注册所有配置提供者
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

import 'config_manager.dart';
import 'config_storage.dart';
import 'providers/theme_config_provider.dart';
import 'providers/webdav_config_provider.dart';
import 'providers/update_config_provider.dart';
import '../workflow/workflow.dart';

/// 配置初始化器
///
/// 负责初始化配置管理系统并注册所有配置提供者
class ConfigInitializer {
  ConfigInitializer._();

  /// 是否已初始化
  static bool _initialized = false;

  /// 初始化配置管理系统
  ///
  /// 这应该在应用启动时调用，在所有其他配置操作之前
  static Future<void> initialize() async {
    // 幂等性检查
    if (_initialized) {
      debugPrint('ConfigInitializer: 已初始化，跳过重复初始化');
      return;
    }

    appLog.info('ConfigInitializer: 开始初始化配置管理系统');

    // 初始化配置管理器
    final manager = ConfigManager.instance;
    await manager.initialize();

    // 创建存储实例
    final sharedPrefsStorage = SharedPrefsConfigStorage();
    final secureStorage = SecureConfigStorage();

    // 初始化存储
    await sharedPrefsStorage.initialize();
    await secureStorage.initialize();

    final storage = CompositeConfigStorage([
      sharedPrefsStorage,
      secureStorage,
    ]);

    // 注册所有配置提供者
    _registerProviders(manager, storage);

    // 初始化工作流管理器
    await WorkflowManager.instance.initialize(storage);
    appLog.info('ConfigInitializer: 工作流管理器初始化完成');

    _initialized = true;
    appLog.info('ConfigInitializer: 配置管理系统初始化完成');
  }

  /// 注册所有配置提供者
  static void _registerProviders(
    ConfigManager manager,
    CompositeConfigStorage storage,
  ) {
    // 注册主题配置提供者
    manager.registerProvider(
      ThemeConfigProvider(storage),
    );
    appLog.info('ConfigInitializer: 已注册主题配置提供者');

    // 注册 WebDAV 配置提供者
    manager.registerProvider(
      WebDavConfigProvider(SecureConfigStorage()),
    );
    appLog.info('ConfigInitializer: 已注册 WebDAV 配置提供者');

    // 注册更新配置提供者
    manager.registerProvider(
      UpdateConfigProvider(storage),
    );
    appLog.info('ConfigInitializer: 已注册更新配置提供者');
  }

  /// 获取主题配置提供者
  static ThemeConfigProvider getThemeConfigProvider() {
    final provider = ConfigManager.instance.providers['theme_config'];
    if (provider == null || provider is! ThemeConfigProvider) {
      throw StateError('ThemeConfigProvider not registered. Call initialize() first.');
    }
    return provider;
  }

  /// 获取 WebDAV 配置提供者
  static WebDavConfigProvider getWebDavConfigProvider() {
    final provider = ConfigManager.instance.providers['webdav_config'];
    if (provider == null || provider is! WebDavConfigProvider) {
      throw StateError('WebDavConfigProvider not registered. Call initialize() first.');
    }
    return provider;
  }

  /// 获取更新配置提供者
  static UpdateConfigProvider getUpdateConfigProvider() {
    final provider = ConfigManager.instance.providers['update_config'];
    if (provider == null || provider is! UpdateConfigProvider) {
      throw StateError('UpdateConfigProvider not registered. Call initialize() first.');
    }
    return provider;
  }
}
