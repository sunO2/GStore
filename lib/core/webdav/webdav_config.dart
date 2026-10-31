import 'package:flutter/foundation.dart';
import 'package:gstore/core/logger/LogManager.dart';

import '../config/config_registry.dart' show ConfigKeys;
import '../config/config_service.dart' show ConfigChangeSource, ConfigService;

/// WebDAV 配置
class WebDavConfig {
  /// 服务器地址
  final String url;

  /// 用户名
  final String username;

  /// 密码
  final String password;

  /// 备份路径
  final String backupPath;

  /// 是否启用 HTTPS
  final bool enableHttps;

  WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
    this.backupPath = '/GStore',
    this.enableHttps = true,
  });

  /// 从 JSON 创建
  factory WebDavConfig.fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: json['url'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      backupPath: json['backupPath'] as String? ?? '/GStore',
      enableHttps: json['enableHttps'] as bool? ?? true,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'username': username,
      'password': password,
      'backupPath': backupPath,
      'enableHttps': enableHttps,
    };
  }

  /// 复制并修改
  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? backupPath,
    bool? enableHttps,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      backupPath: backupPath ?? this.backupPath,
      enableHttps: enableHttps ?? this.enableHttps,
    );
  }

  /// 获取完整的基础 URL
  String get baseUrl {
    final cleanUrl = url.trim();
    // 如果已经包含协议，直接使用
    if (cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://')) {
      // 移除末尾的斜杠，因为路径拼接时会添加
      return cleanUrl.replaceAll(RegExp(r'/+$'), '');
    }
    // 否则添加协议
    final protocol = enableHttps ? 'https://' : 'http://';
    return '$protocol$cleanUrl';
  }

  /// 验证配置是否有效
  bool get isValid {
    return url.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
  }

  @override
  String toString() {
    return 'WebDavConfig(url: $url, username: $username, backupPath: $backupPath)';
  }
}

/// WebDAV 配置管理器
///
/// Thin facade over [ConfigService] for the five grouped keys
/// `webdav.url/username/password/backup_path/enable_https` (C3: the password
/// is a Secret, the other fields are sensitive Owner keys). All persistence is
/// owned by the Rust-backed `ConfigService`; this class no longer touches
/// platform secure storage directly.
///
/// [saveConfig] is rollback-safe: it snapshots the five previous raw values,
/// writes them one by one through [ConfigService.set], and restores the
/// snapshot if any write fails. [loadConfig] always reads trusted raw values
/// (including the password); UI/Agent surfaces must use [ConfigService.get]
/// instead, which masks sensitive fields.
class WebDavConfigManager {
  /// The five grouped wire keys in a stable write order.
  static const List<String> _keys = <String>[
    ConfigKeys.webdavUrl,
    ConfigKeys.webdavUsername,
    ConfigKeys.webdavPassword,
    ConfigKeys.webdavBackupPath,
    ConfigKeys.webdavEnableHttps,
  ];

  static final WebDavConfigManager _instance = WebDavConfigManager._internal();
  static WebDavConfigManager get instance => _instance;

  WebDavConfigManager._internal();

  /// 保存配置（逐字段 `ConfigService.set`；任一字段失败则回滚到旧值）。
  Future<void> saveConfig(WebDavConfig config) async {
    final service = ConfigService.instance;
    final previous = <String, Object?>{};
    for (final key in _keys) {
      previous[key] = await service.getRaw(key);
    }

    final values = <String, Object?>{
      ConfigKeys.webdavUrl: config.url,
      ConfigKeys.webdavUsername: config.username,
      ConfigKeys.webdavPassword: config.password,
      ConfigKeys.webdavBackupPath: config.backupPath,
      ConfigKeys.webdavEnableHttps: config.enableHttps,
    };

    try {
      for (final key in _keys) {
        final result = await service.set(
          key,
          values[key],
          source: ConfigChangeSource.user,
        );
        if (!result.success) {
          throw StateError('保存 WebDAV 配置失败: ${result.message}');
        }
      }
      appLog.info('WebDavConfigManager: 配置已保存');
    } catch (e) {
      appLog.error('WebDavConfigManager: 保存配置失败，尝试回滚 - $e');
      await _rollback(service, previous);
      rethrow;
    }
  }

  /// Restores every field to its pre-save value (best effort, never masks the
  /// original failure).
  Future<void> _rollback(
    ConfigService service,
    Map<String, Object?> previous,
  ) async {
    for (final key in _keys) {
      try {
        final result = previous[key] == null
            ? await service.clear(key, source: ConfigChangeSource.user)
            : await service.set(
                key,
                previous[key],
                source: ConfigChangeSource.user,
              );
        if (!result.success) {
          appLog.warning(
            'WebDavConfigManager: 回滚 $key 失败 - ${result.message}',
          );
        }
      } catch (e) {
        appLog.warning('WebDavConfigManager: 回滚 $key 异常 - $e');
      }
    }
  }

  /// 加载配置（可信原始值；密码不做脱敏）。
  ///
  /// Returns `null` when the required url/username/password are absent/empty,
  /// preserving the pre-unification "not configured" contract for callers.
  Future<WebDavConfig?> loadConfig() async {
    try {
      final service = ConfigService.instance;
      final raw = <String, Object?>{};
      for (final key in _keys) {
        raw[key] = await service.getRaw(key);
      }

      final url = raw[ConfigKeys.webdavUrl];
      final username = raw[ConfigKeys.webdavUsername];
      final password = raw[ConfigKeys.webdavPassword];
      if (url is! String ||
          username is! String ||
          password is! String ||
          url.isEmpty ||
          username.isEmpty ||
          password.isEmpty) {
        debugPrint('WebDavConfigManager: 未找到配置');
        return null;
      }

      final backupPath = raw[ConfigKeys.webdavBackupPath];
      final enableHttps = raw[ConfigKeys.webdavEnableHttps];
      final config = WebDavConfig(
        url: url,
        username: username,
        password: password,
        backupPath: backupPath is String && backupPath.isNotEmpty
            ? backupPath
            : '/GStore',
        enableHttps: enableHttps is bool ? enableHttps : true,
      );

      appLog.info('WebDavConfigManager: 配置已加载');
      return config;
    } catch (e) {
      appLog.error('WebDavConfigManager: 加载配置失败 - $e');
      return null;
    }
  }

  /// 清除配置
  Future<void> clearConfig() async {
    try {
      final service = ConfigService.instance;
      for (final key in _keys) {
        final result = await service.clear(
          key,
          source: ConfigChangeSource.user,
        );
        if (!result.success) {
          appLog.warning('WebDavConfigManager: 清除 $key 失败 - ${result.message}');
        }
      }
      appLog.info('WebDavConfigManager: 配置已清除');
    } catch (e) {
      appLog.error('WebDavConfigManager: 清除配置失败 - $e');
    }
  }

  /// 检查是否有配置
  Future<bool> hasConfig() async {
    final config = await loadConfig();
    return config != null && config.isValid;
  }
}
