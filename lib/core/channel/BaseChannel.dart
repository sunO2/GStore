/// 渠道基类
/// 提供渠道实现的通用功能，减少代码重复
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/error/ErrorHandler.dart';
import 'package:gstore/core/exception/AppException.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';

/// 渠道基类
/// 实现了 IChannel 接口的通用功能，子类只需实现特定逻辑
abstract class BaseChannel implements IChannel {
  /// 应用配置
  final AppConfig config;

  /// 错误处理器
  final ErrorHandler errorHandler;

  /// 缓存的应用列表
  List<AppInfo>? _cachedApps;

  /// 缓存的分类列表
  List<db.AppCategory>? _cachedCategories;

  /// 缓存的配置
  db.AppInfoConfig? _cachedConfig;

  /// 缓存过期时间（秒）
  final int cacheExpireSeconds;

  /// 缓存创建时间
  DateTime? _cacheCreatedAt;

  BaseChannel({
    required this.config,
    ErrorHandler? errorHandler,
    this.cacheExpireSeconds = 300, // 默认5分钟
  }) : errorHandler = errorHandler ?? ErrorHandler.instance;

  @override
  late ChannelInfo info;

  @override
  bool isInitialized = false;

  /// ========== 需要子类实现的方法 ==========

  /// 初始化渠道（子类实现）
  @override
  Future<void> initialize();

  /// 检查渠道是否可用（子类实现）
  @override
  Future<bool> checkAvailable();

  /// 获取所有应用（子类实现）
  @override
  Future<ChannelResult<List<AppInfo>>> getAllApps({
    bool forceRefresh = false,
  });

  /// 搜索应用（子类实现）
  @override
  Future<ChannelResult<List<AppInfo>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  });

  /// 获取应用详情（子类实现）
  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  });

  /// 获取分类（可选实现）
  @override
  Future<ChannelResult<List<db.AppCategory>>> getCategories({
    bool forceRefresh = false,
  }) async {
    // 默认返回空分类列表
    return ChannelResult.success(
      data: [],
      from: info.type,
      fromCache: false,
    );
  }

  /// 获取配置（可选实现）
  @override
  Future<ChannelResult<db.AppInfoConfig>> getConfig({
    bool forceRefresh = false,
  }) async {
    // 默认返回空配置
    return ChannelResult.success(
      data: db.AppInfoConfig('1.0.0', null),
      from: info.type,
      fromCache: false,
    );
  }

  /// ========== 通用功能方法 ==========

  /// 检查缓存是否有效
  bool get isCacheValid {
    if (_cacheCreatedAt == null) {
      return false;
    }
    final now = DateTime.now();
    final diff = now.difference(_cacheCreatedAt!);
    return diff.inSeconds < cacheExpireSeconds;
  }

  /// 清除缓存
  @override
  Future<void> clearCache() async {
    _cachedApps = null;
    _cachedCategories = null;
    _cachedConfig = null;
    _cacheCreatedAt = null;
    debugPrint('$runtimeType: 缓存已清除');
  }

  /// 安全执行渠道操作
  /// 统一错误处理和日志记录
  Future<ChannelResult<T>> safeExecute<T>(
    String operation,
    Future<ChannelResult<T>> Function() fn, {
    Map<String, dynamic>? extra,
  }) async {
    try {
      // 检查是否已初始化
      if (!isInitialized) {
        throw ChannelException.notInitialized(
          channelType: info.type.name,
        );
      }

      // 执行操作
      final result = await fn();

      // 更新缓存
      if (result.success && result.data is List<AppInfo>) {
        _cachedApps = result.data as List<AppInfo>;
        _cacheCreatedAt = DateTime.now();
      }

      return result;
    } on ChannelException catch (e) {
      // 渠道异常，直接记录并返回
      e.log();
      return ChannelResult.failure(
        from: info.type,
        error: e.message,
      );
    } on NetworkException catch (e) {
      // 网络异常
      e.log();
      return ChannelResult.failure(
        from: info.type,
        error: e.message,
      );
    } catch (e, stackTrace) {
      // 其他异常
      final exception = ExceptionHandler.catchException(e, stackTrace);

      // 使用错误处理器记录
      errorHandler.handle(
        exception,
        stackTrace,
        ErrorPriority.medium,
        {
          'channel': info.type.name,
          'operation': operation,
          ...?extra,
        },
      );

      return ChannelResult.failure(
        from: info.type,
        error: exception.message,
      );
    }
  }

  /// 安全执行并返回缓存数据
  Future<ChannelResult<T>> withCache<T>({
    required bool forceRefresh,
    required T? cachedData,
    required Future<ChannelResult<T>> Function() fetchFn,
    required ChannelType channelType,
  }) async {
    // 如果不强制刷新且有缓存，返回缓存
    if (!forceRefresh && cachedData != null && isCacheValid) {
      debugPrint('$runtimeType: 使用缓存数据');
      return ChannelResult.success(
        data: cachedData,
        from: channelType,
        fromCache: true,
      );
    }

    // 获取新数据
    return await fetchFn();
  }

  /// 记录调试信息
  void logDebug(String message) {
    if (config.enableDebugLog && config.logLevel.isDebug) {
      final filtered = config.filterSensitiveInfoInLog
          ? config.filterSensitiveInfo(message)
          : message;
      debugPrint('🟢 [DEBUG] $runtimeType: $filtered');
    }
  }

  /// 记录信息
  void logInfo(String message) {
    if (config.enableDebugLog && config.logLevel.isInfo) {
      final filtered = config.filterSensitiveInfoInLog
          ? config.filterSensitiveInfo(message)
          : message;
      debugPrint('🔵 [INFO] $runtimeType: $filtered');
    }
  }

  /// 记录警告
  void logWarning(String message) {
    if (config.enableDebugLog && config.logLevel.isWarning) {
      final filtered = config.filterSensitiveInfoInLog
          ? config.filterSensitiveInfo(message)
          : message;
      debugPrint('🟠 [WARN] $runtimeType: $filtered');
    }
  }

  /// 记录错误
  void logError(String message, {dynamic error, StackTrace? stackTrace}) {
    if (config.enableDebugLog && config.logLevel.isError) {
      final filtered = config.filterSensitiveInfoInLog
          ? config.filterSensitiveInfo(message)
          : message;
      debugPrint('🔴 [ERROR] $runtimeType: $filtered');
      if (error != null) {
        debugPrint('  错误: $error');
      }
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    }
  }
}

/// 渠道数据构建器
/// 帮助构建渠道特定的数据对象
class ChannelDataBuilder {
  /// 构建 AppInfo 对象
  static AppInfo buildAppInfo({
    required String appId,
    required String name,
    required String user,
    required String repositories,
    String? icon,
    String? des,
    List<String>? category,
  }) {
    return AppInfo(
      appId,
      name ?? '',
      user,
      repositories,
      icon ?? '',
      des ?? '',
      category,
    );
  }

  /// 构建 AppCategory 对象
  static db.AppCategory buildCategory({
    required String id,
    required String description,
    String? icon,
  }) {
    return db.AppCategory(
      id,
      description,
      icon ?? '',
    );
  }

  /// 构建错误结果
  static ChannelResult<T> errorResult<T>({
    required ChannelType channel,
    required String message,
    dynamic error,
  }) {
    // 记录错误
    if (error != null) {
      debugPrint('ChannelDataBuilder: $message - $error');
    }

    return ChannelResult.failure(
      from: channel,
      error: message,
    );
  }

  /// 验证应用数据
  static bool isValidAppInfo(AppInfo app) {
    return app.appId.isNotEmpty &&
        app.name.isNotEmpty &&
        app.icon.isNotEmpty;
  }

  /// 过滤无效的应用
  static List<AppInfo> filterValidApps(List<AppInfo> apps) {
    return apps.where((app) => isValidAppInfo(app)).toList();
  }

  /// 分页处理
  static List<T> paginate<T>(List<T> items, int page, int pageSize) {
    if (page < 0 || pageSize <= 0) {
      return [];
    }

    final start = page * pageSize;
    if (start >= items.length) {
      return [];
    }

    final end = (start + pageSize).clamp(0, items.length);
    return items.sublist(start, end);
  }

  /// 去重（基于 appId）
  static List<AppInfo> deduplicateApps(List<AppInfo> apps) {
    final seen = <String>{};
    final result = <AppInfo>[];

    for (final app in apps) {
      if (seen.add(app.appId)) {
        result.add(app);
      }
    }

    return result;
  }

  /// 排序（按名称）
  static List<AppInfo> sortByName(List<AppInfo> apps, {bool ascending = true}) {
    final sorted = List<AppInfo>.from(apps);
    sorted.sort((a, b) => ascending
        ? a.name.compareTo(b.name)
        : b.name.compareTo(a.name));
    return sorted;
  }
}

/// 网络请求辅助类
class ChannelNetworkHelper {
  final AppConfig config;
  final ErrorHandler errorHandler;

  ChannelNetworkHelper({
    required this.config,
    ErrorHandler? errorHandler,
  }) : errorHandler = errorHandler ?? ErrorHandler.instance;

  /// 安全执行网络请求
  Future<T> safeRequest<T>(
    String url, {
    required Future<T> Function() requestFn,
    Map<String, dynamic>? headers,
    Duration? timeout,
  }) async {
    // 验证 URL
    config.validateUrl(url);

    try {
      // 执行请求
      final result = await requestFn()
          .timeout(timeout ?? Duration(milliseconds: config.networkTimeoutMs));

      return result;
    } catch (e, stackTrace) {
      // 转换为网络异常
      if (e is AppException) {
        rethrow;
      }

      throw NetworkException(
        message: '网络请求失败: ${e.toString()}',
        url: url,
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 重试请求
  Future<T> retryRequest<T>(
    Future<T> Function() requestFn, {
    int maxRetries = 3,
    Duration? delayBetweenRetries,
  }) async {
    int attempts = 0;
    var lastError;

    while (attempts < maxRetries) {
      try {
        return await requestFn();
      } catch (e) {
        lastError = e;
        attempts++;

        if (attempts < maxRetries) {
          // 等待后重试
          await Future.delayed(
            delayBetweenRetries ?? const Duration(seconds: 1),
          );
        }
      }
    }

    throw NetworkException(
      message: '请求失败，已重试 $maxRetries 次',
      originalError: lastError,
      code: 'MAX_RETRIES_EXCEEDED',
    );
  }

  /// 构建标准请求头
  Map<String, String> buildHeaders({
    Map<String, String>? customHeaders,
    String? userAgent,
    String? acceptLanguage,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (userAgent != null) 'User-Agent': userAgent,
      if (acceptLanguage != null) 'Accept-Language': acceptLanguage,
      ...?customHeaders,
    };

    return headers;
  }
}
