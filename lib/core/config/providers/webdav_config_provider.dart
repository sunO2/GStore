/// WebDAV 配置提供者
///
/// 管理 WebDAV 相关的配置（敏感数据，使用加密存储）
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/logger/LogManager.dart';

import '../config_provider.dart';
import '../config_storage.dart';
import '../../webdav/webdav_config.dart';

/// WebDAV 配置提供者
///
/// 负责管理 WebDAV 服务器的连接配置，包括 URL、用户名、密码等敏感信息
/// 所有数据都使用加密存储
class WebDavConfigProvider extends ConfigProvider<WebDavConfig> {
  WebDavConfigProvider(this._storage);

  final ConfigStorage _storage;

  /// 配置键
  @override
  String get configKey => 'webdav_config';

  /// URL 键
  static const String _urlKey = 'webdav_url';

  /// 用户名键
  static const String _usernameKey = 'webdav_username';

  /// 密码键
  static const String _passwordKey = 'webdav_password';

  /// 备份路径键
  static const String _backupPathKey = 'webdav_backup_path';

  /// 是否启用 HTTPS 键
  static const String _enableHttpsKey = 'webdav_enable_https';

  /// 配置变化控制器
  final _configController = StreamController<WebDavConfig?>.broadcast();

  /// 当前配置
  WebDavConfig? _currentConfig;

  /// 当前配置
  WebDavConfig? get currentConfig => _currentConfig;

  @override
  Future<WebDavConfig?> load() async {
    try {
      final url = await _storage.getString(_urlKey);
      final username = await _storage.getString(_usernameKey);
      final password = await _storage.getString(_passwordKey);
      final backupPath = await _storage.getString(_backupPathKey);
      final enableHttpsStr = await _storage.getString(_enableHttpsKey);

      if (url == null || username == null || password == null) {
        _currentConfig = null;
        return null;
      }

      final config = WebDavConfig(
        url: url,
        username: username,
        password: password,
        backupPath: backupPath ?? '/GStore',
        enableHttps: enableHttpsStr == 'true',
      );

      _currentConfig = config;
      appLog.info('WebDavConfigProvider: 配置已加载 - $url');
      return config;
    } catch (e, stackTrace) {
      appLog.error('WebDavConfigProvider: 加载配置失败 - $e');
      appLog.error('WebDavConfigProvider: 堆栈跟踪: $stackTrace');
      _currentConfig = null;
      return null;
    }
  }

  @override
  Future<bool> save(WebDavConfig config) async {
    try {
      final success = await Future.wait([
        _storage.setString(_urlKey, config.url),
        _storage.setString(_usernameKey, config.username),
        _storage.setString(_passwordKey, config.password),
        _storage.setString(_backupPathKey, config.backupPath),
        _storage.setString(_enableHttpsKey, config.enableHttps.toString()),
      ]);

      if (success.every((s) => s)) {
        _currentConfig = config;
        _configController.add(config);
        appLog.info('WebDavConfigProvider: 配置已保存 - ${config.url}');
        return true;
      } else {
        appLog.error('WebDavConfigProvider: 保存配置失败 - 部分字段保存失败');
        return false;
      }
    } catch (e, stackTrace) {
      appLog.error('WebDavConfigProvider: 保存配置异常 - $e');
      appLog.error('WebDavConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    try {
      final success = await Future.wait([
        _storage.remove(_urlKey),
        _storage.remove(_usernameKey),
        _storage.remove(_passwordKey),
        _storage.remove(_backupPathKey),
        _storage.remove(_enableHttpsKey),
      ]);

      if (success.every((s) => s)) {
        _currentConfig = null;
        _configController.add(null);
        appLog.info('WebDavConfigProvider: 配置已清除');
        return true;
      } else {
        appLog.error('WebDavConfigProvider: 清除配置失败 - 部分字段清除失败');
        return false;
      }
    } catch (e, stackTrace) {
      appLog.error('WebDavConfigProvider: 清除配置异常 - $e');
      appLog.error('WebDavConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }

  @override
  Stream<WebDavConfig?> watch() {
    return _configController.stream;
  }

  /// 检查是否有配置
  Future<bool> hasConfig() async {
    final config = await load();
    return config != null && config.isValid;
  }

  /// 测试配置是否有效
  bool validateConfig(WebDavConfig config) {
    return config.isValid;
  }

  /// 获取基础 URL
  String getBaseUrl(WebDavConfig config) {
    return config.baseUrl;
  }

  /// 释放资源
  void dispose() {
    _configController.close();
  }

  @override
  Future<bool> importFromJson(Map<String, dynamic> json) async {
    try {
      appLog.info('WebDavConfigProvider: 开始从 JSON 导入配置');
      debugPrint('WebDavConfigProvider: JSON keys: ${json.keys.toList()}');

      final config = WebDavConfig.fromJson(json);
      debugPrint('WebDavConfigProvider: 配置对象创建成功');

      final success = await save(config);
      debugPrint('WebDavConfigProvider: 保存结果 - $success');
      return success;
    } catch (e, stackTrace) {
      appLog.error('WebDavConfigProvider: 导入配置失败 - $e');
      appLog.error('WebDavConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }
}
