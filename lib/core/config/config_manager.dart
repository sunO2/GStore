/// 统一配置管理器
///
/// 提供配置的注册、加载、保存、导出、导入等统一管理功能
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

import 'config_provider.dart';
import 'config_storage.dart';
import 'config_backup.dart';

/// 配置管理器（单例）
///
/// 负责管理所有配置的加载、保存、备份和恢复
class ConfigManager {
  ConfigManager._internal();

  static ConfigManager? _instance;
  static ConfigManager get instance => _instance ??= ConfigManager._internal();

  /// 配置版本
  static const int _currentVersion = 1;

  /// 配置版本键
  static const String _versionKey = 'config_version';

  /// 是否已初始化
  bool _initialized = false;

  /// 缓存的应用版本
  String? _cachedAppVersion;

  /// 配置注册表
  ///
  /// Key: configKey
  /// Value: ConfigProvider 实例
  final Map<String, ConfigProvider> _providers = {};

  /// 存储实例
  late final CompositeConfigStorage _storage;

  /// 配置变化控制器
  final _changeController = StreamController<Map<String, dynamic>>.broadcast();

  /// 配置变化流
  Stream<Map<String, dynamic>> get onChange => _changeController.stream;

  /// 当前配置版本
  int get currentVersion => _currentVersion;

  /// 设置应用版本（用于备份数据）
  void setAppVersion(String version) {
    _cachedAppVersion = version;
  }

  /// 初始化配置管理器
  Future<void> initialize() async {
    if (_initialized) return;

    appLog.info('ConfigManager: 开始初始化');

    // 创建存储实例
    _storage = CompositeConfigStorage([
      SharedPrefsConfigStorage(),
      SecureConfigStorage(),
    ]);

    // 初始化存储
    await _storage.initialize();

    // 检查配置版本
    await _checkAndMigrateVersion();

    _initialized = true;
    appLog.info('ConfigManager: 初始化完成 (版本: $_currentVersion)');
  }

  /// 检查并迁移配置版本
  Future<void> _checkAndMigrateVersion() async {
    final savedVersion = await _storage.getInt(_versionKey) ?? 0;

    if (savedVersion < _currentVersion) {
      appLog.info('ConfigManager: 检测到配置版本变更: $savedVersion -> $_currentVersion');
      // TODO: 实现版本迁移逻辑
      await _storage.setInt(_versionKey, _currentVersion);
    }
  }

  /// 注册配置提供者
  ///
  /// 如果已存在相同 key 的提供者，将覆盖旧的提供者
  void registerProvider<T>(ConfigProvider<T> provider) {
    debugPrint('ConfigManager: 注册配置提供者 - ${provider.configKey}');
    _providers[provider.configKey] = provider;
  }

  /// 注销配置提供者
  void unregisterProvider(String configKey) {
    debugPrint('ConfigManager: 注销配置提供者 - $configKey');
    _providers.remove(configKey);
  }

  /// 获取配置提供者
  ConfigProvider<T>? getProvider<T>(String configKey) {
    return _providers[configKey] as ConfigProvider<T>?;
  }

  /// 检查提供者是否已注册
  bool hasProvider(String configKey) {
    return _providers.containsKey(configKey);
  }

  /// 获取所有已注册的配置键
  List<String> get configKeys => _providers.keys.toList();

  /// 获取内部提供者映射（仅供内部使用）
  Map<String, ConfigProvider> get providers => _providers;

  /// 加载指定配置
  Future<T?> loadConfig<T>(String configKey) async {
    final provider = getProvider<T>(configKey);
    if (provider == null) {
      debugPrint('ConfigManager: 未找到配置提供者 - $configKey');
      return null;
    }

    try {
      final config = await provider.load();
      debugPrint('ConfigManager: 加载配置 - $configKey: ${config != null ? "成功" : "不存在"}');
      return config;
    } catch (e, stackTrace) {
      appLog.error('ConfigManager: 加载配置失败 - $configKey: $e');
      debugPrint('ConfigManager: 堆栈跟踪: $stackTrace');
      return null;
    }
  }

  /// 保存指定配置
  Future<bool> saveConfig<T>(String configKey, T config) async {
    final provider = getProvider<T>(configKey);
    if (provider == null) {
      debugPrint('ConfigManager: 未找到配置提供者 - $configKey');
      return false;
    }

    try {
      final success = await provider.save(config);
      if (success) {
        appLog.info('ConfigManager: 保存配置成功 - $configKey');
        // 发送配置变化事件（仅发送键，不发送数据以避免类型问题）
        _changeController.add({configKey: true});
      } else {
        appLog.error('ConfigManager: 保存配置失败 - $configKey');
      }
      return success;
    } catch (e, stackTrace) {
      appLog.error('ConfigManager: 保存配置异常 - $configKey: $e');
      debugPrint('ConfigManager: 堆栈跟踪: $stackTrace');
      return false;
    }
  }

  /// 清除指定配置
  Future<bool> clearConfig(String configKey) async {
    final provider = _providers[configKey];
    if (provider == null) {
      debugPrint('ConfigManager: 未找到配置提供者 - $configKey');
      return false;
    }

    try {
      final success = await provider.clear();
      if (success) {
        appLog.info('ConfigManager: 清除配置成功 - $configKey');
        // 发送配置变化事件（仅发送键，不发送数据以避免类型问题）
        _changeController.add({configKey: false});
      } else {
        appLog.error('ConfigManager: 清除配置失败 - $configKey');
      }
      return success;
    } catch (e, stackTrace) {
      appLog.error('ConfigManager: 清除配置异常 - $configKey: $e');
      debugPrint('ConfigManager: 堆栈跟踪: $stackTrace');
      return false;
    }
  }

  /// 检查配置是否存在
  Future<bool> hasConfig(String configKey) async {
    final provider = _providers[configKey];
    if (provider == null) return false;
    return await provider.exists();
  }

  /// 监听指定配置变化
  Stream<Map<String, dynamic>> watchConfig(String configKey) {
    return onChange.where((event) => event.containsKey(configKey));
  }

  /// 导出所有配置
  Future<ConfigBackupData> exportAll() async {
    appLog.info('ConfigManager: 开始导出所有配置');

    final Map<String, dynamic> configs = {};

    for (final entry in _providers.entries) {
      try {
        final config = await entry.value.load();
        if (config != null && config is dynamic) {
          // 尝试调用 toJson
          try {
            configs[entry.key] = config.toJson();
            debugPrint('ConfigManager: 导出配置 - ${entry.key}');
          } catch (e) {
            appLog.error('ConfigManager: 配置没有 toJson 方法 - ${entry.key}: $e');
          }
        }
      } catch (e) {
        appLog.error('ConfigManager: 导出配置失败 - ${entry.key}: $e');
      }
    }

    // 获取应用版本（可选）
    String? appVersion;
    try {
      // 获取应用版本的方式由调用方决定
      // 这里可以接受一个可选的版本号参数
      appVersion = _cachedAppVersion;
    } catch (e) {
      appLog.error('ConfigManager: 获取应用版本失败: $e');
    }

    final backupData = ConfigBackupData(
      version: _currentVersion,
      timestamp: DateTime.now(),
      appVersion: appVersion,
      configs: configs,
    );

    appLog.info('ConfigManager: 配置导出完成 (共 ${configs.length} 项配置)');
    return backupData;
  }

  /// 导出配置为 JSON 字符串
  Future<String> exportToJson() async {
    final backupData = await exportAll();
    return jsonEncode(backupData.toJson());
  }

  /// 导入所有配置
  Future<bool> importAll(ConfigBackupData data) async {
    appLog.info('ConfigManager: 开始导入配置 (版本: ${data.version})');

    // 检查版本是否兼容
    if (data.version > _currentVersion) {
      appLog.error('ConfigManager: 配置版本过新，无法导入');
      return false;
    }

    int successCount = 0;
    int failCount = 0;

    for (final entry in data.configs.entries) {
      final provider = _providers[entry.key];
      if (provider == null) {
        debugPrint('ConfigManager: 跳过未知配置 - ${entry.key}');
        continue;
      }

      try {
        // 使用 importFromJson 方法导入配置
        // entry.value 是 Map<String, dynamic>
        final success = await provider.importFromJson(entry.value);
        if (success) {
          successCount++;
          appLog.info('ConfigManager: 导入配置成功 - ${entry.key}');
        } else {
          failCount++;
          appLog.error('ConfigManager: 导入配置失败 - ${entry.key}');
        }
      } catch (e, stackTrace) {
        failCount++;
        appLog.error('ConfigManager: 导入配置异常 - ${entry.key}: $e');
        debugPrint('ConfigManager: 堆栈跟踪: $stackTrace');
      }
    }

    // 更新配置版本
    await _storage.setInt(_versionKey, _currentVersion);

    appLog.info('ConfigManager: 配置导入完成 (成功: $successCount, 失败: $failCount)');
    return failCount == 0;
  }

  /// 从 JSON 字符串导入配置
  Future<bool> importFromJson(String jsonString) async {
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final backupData = ConfigBackupData.fromJson(json);
      return await importAll(backupData);
    } catch (e) {
      appLog.error('ConfigManager: JSON 解析失败: $e');
      return false;
    }
  }

  /// 清除所有配置
  Future<bool> clearAll() async {
    appLog.info('ConfigManager: 开始清除所有配置');

    bool allSuccess = true;
    for (final configKey in _providers.keys) {
      final success = await clearConfig(configKey);
      allSuccess = allSuccess && success;
    }

    appLog.info('ConfigManager: 清除所有配置完成');
    return allSuccess;
  }

  /// 获取配置统计信息
  Future<Map<String, dynamic>> getStatistics() async {
    int totalConfigs = _providers.length;
    int existingConfigs = 0;
    int sensitiveConfigs = 0;

    for (final entry in _providers.entries) {
      final exists = await entry.value.exists();
      if (exists) existingConfigs++;
    }

    return {
      'totalConfigs': totalConfigs,
      'existingConfigs': existingConfigs,
      'sensitiveConfigs': sensitiveConfigs,
      'version': _currentVersion,
    };
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
