/// 应用配置管理
/// 集中管理所有配置项，避免硬编码
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/exception/AppException.dart';

/// 应用配置类
/// 单例模式，集中管理所有配置项
class AppConfig {
  AppConfig._internal();

  static final AppConfig _instance = AppConfig._internal();

  factory AppConfig() => _instance;

  /// 是否已初始化
  bool _isInitialized = false;

  /// ========== 网络配置 ==========

  /// 网络请求超时时间（毫秒）
  int networkTimeoutMs = 30000;

  /// 最大重试次数
  int maxRetryCount = 3;

  /// 是否启用网络日志
  bool enableNetworkLog = true;

  /// ========== 缓存配置 ==========

  /// 内存缓存最大数量
  int memoryCacheMaxSize = 100;

  /// 内存缓存过期时间（秒）
  int memoryCacheExpireSeconds = 300; // 5分钟

  /// 磁盘缓存过期时间（秒）
  int diskCacheExpireSeconds = 86400; // 24小时

  /// 是否启用缓存
  bool enableCache = true;

  /// ========== GitHub 渠道配置 ==========

  /// GitHub API 基础 URL
  static const String githubApiBaseUrl = 'https://api.github.com';

  /// GitHub Web 基础 URL
  static const String githubWebBaseUrl = 'https://github.com';

  /// GitHub OAuth Client ID
  static const String githubClientId = 'Ov23liK4Xz0eBlefQJJm';

  /// GitHub OAuth 范围
  static const String githubScope = 'repo';

  /// GitHub 默认用户
  String githubDefaultUser = 'sunO2';

  /// GitHub 默认仓库
  String githubDefaultRepository = 'GStore-Repositorys';

  /// GitHub 代理 URL（可选）
  String? githubProxyUrl;

  /// ========== vivo 渠道配置 ==========

  /// vivo API 基础 URL
  static const String vivoApiBaseUrl = 'https://h5-api.appstore.vivo.com.cn';

  /// vivo 搜索 URL
  static const String vivoSearchUrl = '$vivoApiBaseUrl/h5appstore/search/result-list';

  /// vivo 详情 URL
  static const String vivoDetailUrl = '$vivoApiBaseUrl/detailInfo';

  /// vivo 默认请求参数
  static const Map<String, dynamic> vivoDefaultParams = {
    'imei': '1234567890',
    'av': '18',
    'app_version': '2100',
    'pictype': 'webp',
    'h5_websource': 'h5appstore',
    'target': 'local',
    'cfrom': '2',
  };

  /// ========== F-Droid 渠道配置 ==========

  /// F-Droid 官方仓库 URL
  static const String fdroidOfficialRepo = 'https://f-droid.org/repo';

  /// F-Droid 镜像仓库列表
  static const List<String> fdroidMirrorRepos = [
    'https://f-droid.org/repo',
    'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
  ];

  /// F-Droid 默认仓库索引 URL
  static const String fdroidIndexUrl = '/index/v1/index-v2.jar';

  /// F-Droid 图标路径前缀
  static const String fdroidIconPath = '/icons/';

  /// ========== HTTP 渠道配置 ==========

  /// HTTP 渠道默认超时（毫秒）
  int httpChannelTimeoutMs = 15000;

  /// HTTP 渠道允许的最大文件大小（字节）
  int httpMaxFileSize = 100 * 1024 * 1024; // 100MB

  /// HTTP 允许的内容类型
  static const List<String> httpAllowedContentTypes = [
    'application/vnd.android.package-archive',
    'application/octet-stream',
  ];

  /// ========== 安全配置 ==========

  /// URL 白名单（**裸 host**，不含 scheme/path）
  ///
  /// 匹配规则见 [isWhitelistedHost]：仅当 `host == w` 或 `host.endsWith('.$w')`
  /// （点边界）时命中，避免 `github.com.evil.com`、`evilgithub.com` 等欺骗域名通过。
  static const Set<String> urlWhitelist = {
    'api.github.com',
    'github.com',
    // GitHub Release 资产实际下载域（objects.githubusercontent.com /
    // release-assets.githubusercontent.com；勿在此加入代理主机）。
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'h5-api.appstore.vivo.com.cn',
    'f-droid.org',
    'mirrors.tuna.tsinghua.edu.cn',
  };

  /// URL 允许的协议
  static const List<String> allowedProtocols = ['https', 'http'];

  /// 是否启用 URL 验证
  bool enableUrlValidation = true;

  /// 是否在日志中过滤敏感信息
  bool filterSensitiveInfoInLog = true;

  /// 敏感信息关键词（用于日志过滤）
  static const List<String> sensitiveKeywords = [
    'token',
    'password',
    'secret',
    'key',
    'authorization',
    'cookie',
  ];

  /// ========== 日志配置 ==========

  /// 是否启用调试日志
  bool enableDebugLog = kDebugMode;

  /// 日志级别
  LogLevel logLevel = LogLevel.info;

  /// ========== 数据库配置 ==========

  /// 数据库名称
  static const String databaseName = 'gstore.db';

  /// 数据库版本
  static const int databaseVersion = 1;

  /// ========== 下载配置 ==========

  /// 下载并发数
  int downloadConcurrentCount = 3;

  /// 下载超时时间（毫秒）
  int downloadTimeoutMs = 60000; // 1分钟

  /// 下载临时目录
  static const String downloadTempDir = '/downloads/temp';

  /// 下载完成目录
  static const String downloadCompletedDir = '/downloads/completed';

  /// ========== UI 配置 ==========

  /// 每页显示的项目数量
  int pageSize = 20;

  /// 列表动画时长（毫秒）
  int listAnimationDurationMs = 300;

  /// ========== 初始化配置 ==========

  /// 初始化配置
  /// 可以从环境变量、配置文件等加载配置
  Future<void> initialize({
    Map<String, dynamic>? customConfig,
  }) async {
    if (_isInitialized) {
      debugPrint('AppConfig: 已经初始化，跳过');
      return;
    }

    appLog.info('AppConfig: 开始初始化...');

    // 加载自定义配置
    if (customConfig != null) {
      _loadCustomConfig(customConfig);
    }

    // 验证配置
    _validateConfig();

    _isInitialized = true;
    appLog.info('AppConfig: 初始化完成');
  }

  /// 加载自定义配置
  void _loadCustomConfig(Map<String, dynamic> config) {
    // 网络配置
    if (config['networkTimeoutMs'] is int) {
      networkTimeoutMs = config['networkTimeoutMs'] as int;
    }
    if (config['maxRetryCount'] is int) {
      maxRetryCount = config['maxRetryCount'] as int;
    }

    // GitHub 配置
    if (config['githubDefaultUser'] is String) {
      githubDefaultUser = config['githubDefaultUser'] as String;
    }
    if (config['githubDefaultRepository'] is String) {
      githubDefaultRepository = config['githubDefaultRepository'] as String;
    }
    if (config['githubProxyUrl'] is String) {
      githubProxyUrl = config['githubProxyUrl'] as String;
    }

    // 缓存配置
    if (config['enableCache'] is bool) {
      enableCache = config['enableCache'] as bool;
    }
    if (config['memoryCacheMaxSize'] is int) {
      memoryCacheMaxSize = config['memoryCacheMaxSize'] as int;
    }

    // 安全配置
    if (config['enableUrlValidation'] is bool) {
      enableUrlValidation = config['enableUrlValidation'] as bool;
    }

    appLog.info('AppConfig: 已加载自定义配置');
  }

  /// 验证配置
  void _validateConfig() {
    if (networkTimeoutMs <= 0) {
      throw ConfigurationException.invalid(
        key: 'networkTimeoutMs',
        reason: '必须大于 0',
      );
    }

    if (maxRetryCount < 0) {
      throw ConfigurationException.invalid(
        key: 'maxRetryCount',
        reason: '不能为负数',
      );
    }

    if (memoryCacheMaxSize <= 0) {
      throw ConfigurationException.invalid(
        key: 'memoryCacheMaxSize',
        reason: '必须大于 0',
      );
    }

    appLog.info('AppConfig: 配置验证通过');
  }

  /// 重置为默认配置
  void resetToDefault() {
    networkTimeoutMs = 30000;
    maxRetryCount = 3;
    enableNetworkLog = true;
    memoryCacheMaxSize = 100;
    memoryCacheExpireSeconds = 300;
    diskCacheExpireSeconds = 86400;
    enableCache = true;
    githubDefaultUser = 'sunO2';
    githubDefaultRepository = 'GStore-Repositorys';
    githubProxyUrl = null;
    httpChannelTimeoutMs = 15000;
    httpMaxFileSize = 100 * 1024 * 1024;
    enableUrlValidation = true;
    filterSensitiveInfoInLog = true;
    downloadConcurrentCount = 3;
    downloadTimeoutMs = 60000;
    pageSize = 20;
    listAnimationDurationMs = 300;

    appLog.info('AppConfig: 已重置为默认配置');
  }

  /// ========== URL 工具方法 ==========

  /// 判断主机名是否命中 [urlWhitelist]（点边界匹配）。
  ///
  /// 仅接受精确相等或**子域**（`host.endsWith('.$w')`），绝不使用
  /// 无边界 `contains`，因此 `github.com.evil.com`、`evilgithub.com`
  /// 不会命中 `github.com`。传入的 host 会小写归一化。
  static bool isWhitelistedHost(String host) {
    if (host.isEmpty) {
      return false;
    }
    final normalized = host.toLowerCase();
    for (final w in urlWhitelist) {
      if (normalized == w || normalized.endsWith('.$w')) {
        return true;
      }
    }
    return false;
  }

  /// 验证 URL 是否安全
  ///
  /// 规则：协议必须在 [allowedProtocols] 中；由于白名单语义为 **https-only**
  /// （历史白名单条目是完整 `https://` 前缀，`http` 从不匹配），此处对白名单
  /// host 强制要求 `https`，不接受明文 `http`。host 必须以点边界命中
  /// [urlWhitelist]。任何解析失败/空 host 一律返回 false。
  bool isValidUrl(String url) {
    if (!enableUrlValidation) {
      return true;
    }

    try {
      final uri = Uri.parse(url);

      // 检查协议
      if (!allowedProtocols.contains(uri.scheme)) {
        return false;
      }

      // 白名单语义为 https-only：明文 http 不通过（与历史行为一致，不放宽到 http）
      if (uri.scheme != 'https') {
        return false;
      }

      // 检查主机名（点边界白名单匹配，禁止对整串/无边界 contains）
      if (uri.host.isEmpty) {
        return false;
      }
      return isWhitelistedHost(uri.host);
    } catch (e) {
      return false;
    }
  }

  /// 验证 URL，失败则抛出异常
  void validateUrl(String url) {
    if (!isValidUrl(url)) {
      throw SecurityException.invalidUrl(
        url: url,
        reason: 'URL 不在白名单中或使用了不安全的协议',
      );
    }
  }

  /// ========== 日志工具方法 ==========

  /// 过滤敏感信息
  String filterSensitiveInfo(String message) {
    if (!filterSensitiveInfoInLog) {
      return message;
    }

    String filtered = message;
    for (final keyword in sensitiveKeywords) {
      // 使用正则表达式替换敏感信息
      final pattern = RegExp('(["\']?$keyword["\']?\\s*[:=]\\s*["\']?)([^"\'\\s,}]+)', caseSensitive: false);
      filtered = filtered.replaceAll(pattern, '\$1***');
    }

    return filtered;
  }

  /// 记录配置信息
  void logConfig() {
    if (!enableDebugLog) {
      return;
    }

    debugPrint('========== 应用配置 ==========');
    debugPrint('网络超时: ${networkTimeoutMs}ms');
    debugPrint('最大重试: $maxRetryCount 次');
    debugPrint('缓存: ${enableCache ? "启用" : "禁用"}');
    debugPrint('内存缓存: $memoryCacheMaxSize 项, ${memoryCacheExpireSeconds}秒');
    debugPrint('GitHub: $githubDefaultUser/$githubDefaultRepository');
    debugPrint('URL 验证: ${enableUrlValidation ? "启用" : "禁用"}');
    debugPrint('============================');
  }
}

/// 日志级别
enum LogLevel {
  /// 调试级别
  debug,

  /// 信息级别
  info,

  /// 警告级别
  warning,

  /// 错误级别
  error,

  /// 无日志
  none,
}

/// 日志级别扩展
extension LogLevelExtension on LogLevel {
  /// 是否应该输出调试日志
  bool get isDebug => this == LogLevel.debug;

  /// 是否应该输出信息日志
  bool get isInfo => index <= LogLevel.info.index;

  /// 是否应该输出警告日志
  bool get isWarning => index <= LogLevel.warning.index;

  /// 是否应该输出错误日志
  bool get isError => index <= LogLevel.error.index;
}
