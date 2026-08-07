import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gstore/core/logger/LogManager.dart';

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
class WebDavConfigManager {
  static const String _keyUrl = 'webdav_url';
  static const String _keyUsername = 'webdav_username';
  static const String _keyPassword = 'webdav_password';
  static const String _keyBackupPath = 'webdav_backup_path';
  static const String _keyEnableHttps = 'webdav_enable_https';

  static final WebDavConfigManager _instance = WebDavConfigManager._internal();
  static WebDavConfigManager get instance => _instance;

  WebDavConfigManager._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  /// 保存配置
  Future<void> saveConfig(WebDavConfig config) async {
    try {
      await _storage.write(key: _keyUrl, value: config.url);
      await _storage.write(key: _keyUsername, value: config.username);
      await _storage.write(key: _keyPassword, value: config.password);
      await _storage.write(key: _keyBackupPath, value: config.backupPath);
      await _storage.write(key: _keyEnableHttps, value: config.enableHttps.toString());

      appLog.info('WebDavConfigManager: 配置已保存');
    } catch (e) {
      appLog.error('WebDavConfigManager: 保存配置失败 - $e');
      rethrow;
    }
  }

  /// 加载配置
  Future<WebDavConfig?> loadConfig() async {
    try {
      final url = await _storage.read(key: _keyUrl);
      final username = await _storage.read(key: _keyUsername);
      final password = await _storage.read(key: _keyPassword);
      final backupPath = await _storage.read(key: _keyBackupPath);
      final enableHttpsStr = await _storage.read(key: _keyEnableHttps);

      if (url == null || username == null || password == null) {
        debugPrint('WebDavConfigManager: 未找到配置');
        return null;
      }

      final config = WebDavConfig(
        url: url,
        username: username,
        password: password,
        backupPath: backupPath ?? '/GStore',
        enableHttps: enableHttpsStr == 'true',
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
      await _storage.delete(key: _keyUrl);
      await _storage.delete(key: _keyUsername);
      await _storage.delete(key: _keyPassword);
      await _storage.delete(key: _keyBackupPath);
      await _storage.delete(key: _keyEnableHttps);

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
