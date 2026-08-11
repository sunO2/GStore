import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_registry.dart';

// 设计系统
export 'package:gstore/core/design/design_tokens.dart';

// 新的统一数据模型
export 'package:gstore/core/model/IDetailInfo.dart';
export 'package:gstore/core/model/BackupData.dart';
export 'package:gstore/core/model/AppSummary.dart';
export 'package:gstore/core/data/metadata_repository.dart';

// 核心服务
export 'package:gstore/core/service/db_manager.dart';
export 'package:gstore/core/service/user_manager.dart';
export 'package:gstore/core/service/downloadService.dart';
export 'package:gstore/core/service/backup_service.dart';
export 'package:gstore/core/service/install_manager.dart';
export 'package:gstore/core/service/badge_service.dart';
export 'package:gstore/core/utils/logger.dart';
export 'package:gstore/core/utils/unit.dart';
export 'package:gstore/core/routers.dart';

// 渠道相关
export 'package:gstore/core/channel/channel.dart';

// 聚合和下载
export 'package:gstore/core/aggregate/aggregate.dart';
export 'package:gstore/core/download/download.dart';

// F-Droid 相关
export 'package:gstore/core/fdroid/fdroid_repo.dart';

// WebDAV 相关
export 'package:gstore/core/webdav/webdav_client.dart';
export 'package:gstore/core/webdav/webdav_config.dart';

// 日志管理
export 'package:gstore/core/logger/LogManager.dart' hide LogLevel;

// 错误处理和配置
export 'package:gstore/core/exception/AppException.dart';
export 'package:gstore/core/config/AppConfig.dart';
export 'package:gstore/core/config/config_service.dart';
export 'package:gstore/core/config/config_registry.dart';
export 'package:gstore/core/error/ErrorHandler.dart';
export 'package:gstore/core/security/UrlValidator.dart';

// 主题控制
export 'package:gstore/core/theme/theme_controller.dart';

// 依赖注入
export 'package:gstore/core/di/ServiceContainer.dart';
export 'package:gstore/core/di/ServiceRegistrar.dart';

// 缓存管理
export 'package:gstore/core/cache/CacheManager.dart';

// 事件系统
export 'package:gstore/core/event/database_event.dart';

// Agent 智能助手
export 'package:gstore/core/agent/agent_model_store.dart';
export 'package:gstore/core/agent/agent_session_store.dart';
export 'package:gstore/core/agent/agent_service.dart';
export 'package:gstore/core/agent/platform_arch.dart';

// 模块化框架（ModuleManager + 动态代理）
export 'package:gstore/core/module/module.dart';

// 资源管理
export 'package:gstore/core/resource/Disposable.dart';

// 第三方库
export 'package:get/get.dart';
export 'package:gstore/http/github_request_mix.dart';
export 'package:gstore/db/apps/AppInfo.dart';
export 'dart:async';
export 'dart:convert';

void updateConfig(AppInfoConfig? config) {
  if (null != config) {
    Get.put(config, tag: "config");
  }
}

void updateDataBaseVersion(String? version) {
  AppInfoConfig? config = getConfig();
  updateConfig(AppInfoConfig(version ?? "0.0.0", config?.proxy));
}

void updateProxy(String? proxyUrl) {
  AppInfoConfig? config = getConfig();
  // 存空串表示不使用代理
  updateConfig(AppInfoConfig(config?.version ?? "0.0.0", proxyUrl ?? ''));
  // 持久化代理配置到数据库
  try {
    final manager = Get.find<DbManager>();
    manager.persistConfig(AppInfoConfig(config?.version ?? "0.0.0", proxyUrl ?? ''));
  } catch (e) {
    debugPrint('更新代理配置持久化失败: $e');
  }
}AppInfoConfig? getConfig() {
  try {
    AppInfoConfig? config = Get.find(tag: "config");
    return config;
  } catch (e) {
    return null;
  }
}

/// 默认 GitHub 代理前缀
const String defaultProxy = 'https://gh-proxy.org/';

/// 获取当前代理前缀
/// - 配置为空串/null 时表示不使用代理，返回空字符串
/// - 从未配置过（内存无 config）时返回默认代理
String getProxy() {
  AppInfoConfig? config = getConfig();
  if (null == config) {
    return defaultProxy;
  }
  final proxy = config.proxy?.trim() ?? '';
  return proxy;
}

String get proxy => getProxy();

/// 启动代理配置桥接：监听 ConfigService 的 proxy_url 变化，
/// 变化后更新内存 config 与数据库，使 getProxy() 立即生效。
/// 在应用启动（ConfigInitializer 初始化完成后）调用一次。
void startProxyConfigBridge() {
  try {
    final service = ConfigService.instance;
    if (_proxyBridgeStarted) return;
    _proxyBridgeStarted = true;

    // 同步一次：内存/DB 中已有代理值时写入统一存储
    Future(() async {
      try {
        final current = getProxy();
        if (current.isNotEmpty) {
          await service.set(
            ConfigKeys.proxyUrl,
            current,
            source: ConfigChangeSource.internal,
          );
        }
      } catch (e) {
        debugPrint('代理配置同步失败: $e');
      }
    });

    service.watch(ConfigKeys.proxyUrl).listen((event) {
      final value = event.newValue?.toString() ?? '';
      if (value != getProxy()) {
        updateProxy(value);
      }
    });
  } catch (e) {
    debugPrint('代理配置桥接启动失败: $e');
  }
}

bool _proxyBridgeStarted = false;
