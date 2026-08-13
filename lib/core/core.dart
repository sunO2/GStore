import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_registry.dart';

// 设计系统
export 'package:gstore/core/design/design_tokens.dart';

// 新的统一数据模型
export 'package:gstore/core/model/IDetailInfo.dart';
export 'package:gstore/core/model/BackupData.dart';
export 'package:gstore/core/model/AppIdentity.dart';
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

// 更新管理模块
export 'package:gstore/core/update/app_update_info.dart';
export 'package:gstore/core/update/update_log.dart';
export 'package:gstore/core/update/update_manager.dart';

// 资源管理
export 'package:gstore/core/resource/Disposable.dart';

// 第三方库
export 'package:get/get.dart';
export 'package:gstore/http/github_request_mix.dart';
export 'package:gstore/db/apps/AppInfo.dart';
export 'dart:async';
export 'dart:convert';

/// 更新内存中的应用版本配置（version-only，代理配置走 ConfigService B 轨）。
///
/// Get.put 在已注册（如启动时 db_manager 注册）时静默保留旧实例（不替换），
/// 先 delete 再 put 保证新配置立即生效。
void updateConfig(String? version) {
  if (Get.isRegistered<AppInfoConfig>(tag: "config")) {
    Get.delete<AppInfoConfig>(tag: "config");
  }
  Get.put(AppInfoConfig(version ?? "0.0.0", null), tag: "config");
}

void updateDataBaseVersion(String? version) {
  updateConfig(version);
}

/// 代理缓存；null 表示尚未从 ConfigService 加载（getProxy 返回 defaultProxy）
String? _proxyCache;

/// ConfigService proxy_url 订阅（loadProxyFromConfig 建立，resetProxyForTest 取消）
StreamSubscription<ConfigChangeEvent>? _proxySubscription;

/// 代理值归一化：null（未设置/清除）→ 默认代理；'' 及具体值 → 原值
String _resolveProxyValue(Object? value) {
  if (value == null) return defaultProxy;
  return value.toString();
}

/// 从统一配置服务加载代理并订阅变化（幂等，重复调用直接返回）
///
/// - 读取 ConfigService.get(ConfigKeys.proxyUrl) 初始化缓存
///   （null → defaultProxy、'' → ''）
/// - 订阅 proxy_url 变化：B 轨写入（set/clear）后 getProxy() 即时反映
Future<void> loadProxyFromConfig() async {
  if (_proxySubscription != null) return; // 幂等
  _proxyCache = _resolveProxyValue(
    await ConfigService.instance.get(ConfigKeys.proxyUrl),
  );
  _proxySubscription = ConfigService.instance
      .watch(ConfigKeys.proxyUrl)
      .listen((event) {
    _proxyCache = _resolveProxyValue(event.newValue);
  });
}

/// 更新代理配置（B 轨：写入 ConfigService + 缓存即时更新）
///
/// - null：set null 清除（持久化删除该 key）
/// - 其他：写入统一存储并广播变化事件
/// - 缓存同步更新保证 getProxy() 立即生效（set 异步不阻塞即时读）
Future<void> updateProxy(String? proxyUrl) async {
  _proxyCache = _resolveProxyValue(proxyUrl);
  try {
    await ConfigService.instance.set(ConfigKeys.proxyUrl, proxyUrl);
  } catch (e) {
    debugPrint('代理配置持久化失败: $e');
  }
  // 写回复核：set 广播的变化事件异步送达（可能晚于后续写入），
  // 按最新写入值重设缓存，避免过期事件覆盖即时更新。
  _proxyCache = _resolveProxyValue(proxyUrl);
}

AppInfoConfig? getConfig() {
  try {
    // 必须带类型参数：GetX 的 key = Type + tag，无类型（dynamic）与
    // AppInfoConfig 注册的 key 不匹配 → 永远找不到 → getProxy 恒返回默认值
    AppInfoConfig? config = Get.find<AppInfoConfig>(tag: "config");
    return config;
  } catch (e) {
    return null;
  }
}

/// 默认 GitHub 代理前缀
const String defaultProxy = 'https://gh-proxy.org/';

/// 获取当前代理前缀
/// - 已加载（loadProxyFromConfig / updateProxy 后）：返回缓存值
///   （'' 表示不使用代理；清除/null 后为 defaultProxy）
/// - 未加载时返回 defaultProxy
String getProxy() {
  return _proxyCache ?? defaultProxy;
}

String get proxy => getProxy();

/// 取消代理订阅并重置缓存（仅测试使用）
@visibleForTesting
void resetProxyForTest() {
  _proxySubscription?.cancel();
  _proxySubscription = null;
  _proxyCache = null;
}
