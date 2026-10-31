import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/config/migration/config_migration_tool.dart';
import 'package:gstore/core/config/migration/config_restore_adapter.dart';
import 'package:gstore/core/config/rust/config_api.dart' show ConfigExportValue;
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/core_snapshot_backup.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

/// 备份/恢复进度日志回调（旁路输出，不影响返回/异常语义）
typedef BackupLogCallback = void Function(String message, {bool isError});

/// 备份服务
/// 负责导出和导入应用数据
class BackupService implements IBackupService {
  static BackupService? _instance;
  static BackupService get instance {
    _instance ??= BackupService._internal();
    return _instance!;
  }

  BackupService._internal();

  ChannelDatabase? _channelDb;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    // 聚合应用读写在迁移后一律走 flag 路由的 AddedAppsFacade（核心或旧
    // backend），不再直接持有聚合库句柄；仅保留渠道库。
    final channelDb = await ChannelDatabaseManager.instance;
    _channelDb = channelDb;

    _isInitialized = true;
    appLog.info('BackupService: 初始化成功');
  }

  /// 读取某渠道的已添加应用（导出用），按 flag 路由：
  ///
  /// - `channels` 开（Rust core 拥有渠道域）→ 读 `RustChannelFacade`（core 的
  ///   `ChannelApi.listApps`）；
  /// - 关 → 读旧 Dart 渠道库（legacy backend）。
  ///
  /// 注：core 的 `ChannelAppInfo` 不含 `addTime`/`sourceId`/`apprepo`（FRB 面未
  /// 暴露），core 车道的导出项 `addTime` 记为 0；旧车道保持原样。源标识虽无
  /// 独立字段，却随 `extraJson['sourceId']` 返回，这里必须提到同级 `sourceId`
  /// ——它是恢复后详情/图标路由回哪个源的唯一依据。此差异已在 284 证据中记录。
  Future<List<ChannelAppBackupItem>> _readChannelBackupItems(
    String code,
  ) async {
    if (CoreFlags.channels) {
      final entries = await RustChannelFacade.instance
          .getAllApps(key: code, forceRefresh: false);
      return entries
          .map((rust.ChannelAppInfo entry) => ChannelAppBackupItem(
                appId: entry.appId,
                name: entry.name,
                user: entry.user,
                repositories: entry.repositories,
                icon: entry.icon,
                description: entry.des,
                category:
                    entry.category.isEmpty ? null : entry.category.join(','),
                addTime: 0,
                channelCode: code,
                extra: entry.extraJson,
                sourceId: _sourceIdFromExtraJson(entry.extraJson),
              ))
          .toList();
    }
    final channelDb = _channelDb;
    if (channelDb == null) return const <ChannelAppBackupItem>[];
    final apps = await channelDb.dao.getAppsByChannel(code);
    return apps.map(ChannelAppBackupItem.fromChannelAddedApp).toList();
  }

  /// Builds the shared `app_config.json` / `apps.json.appConfig` payload (C16).
  ///
  /// Every export path funnels through this method, and this method only uses
  /// `ConfigService.exportRaw()` → `ConfigApi.export()`; raw values are wanted
  /// for a backup artifact (C3). If the Rust export fails because a leftover
  /// `config_entry` row no longer maps to a registry key, fall back to
  /// per-key raw reads and skip the unreadable rows instead of failing the
  /// whole backup.
  Future<Map<String, dynamic>?> _buildAppConfigMap() async {
    final grouped = <String, dynamic>{};
    try {
      final entries = await ConfigService.instance.exportRaw();
      for (final ConfigExportValue entry in entries) {
        grouped[entry.wireKey] = entry.value;
      }
    } catch (e) {
      appLog.warning(
          'BackupService: ConfigApi.export 失败，回退逐键导出（跳过未注册/不可读行）: $e');
      for (final entry in ConfigService.instance.list()) {
        try {
          grouped[entry.key] =
              await ConfigService.instance.getRaw(entry.key);
        } catch (err) {
          appLog.warning('BackupService: 跳过无法导出的配置 ${entry.key}: $err');
        }
      }
    }

    final configs = <String, dynamic>{...grouped};
    _addLegacyConfigAliases(configs, grouped);

    final proxy = _nonEmptyString(grouped[ConfigKeys.proxyUrl]);
    final webdav = await _exportWebDavConfig(grouped);
    if (proxy != null) {
      configs[LegacyConfigKeys.proxyUrl] = proxy;
    }
    if (webdav != null) {
      configs[LegacyConfigKeys.webdavConfig] = webdav;
    }

    final payload = <String, dynamic>{
      // C16: config_format is additive; ConfigBackupData.version stays 1.
      'version': 1,
      'timestamp': DateTime.now().toIso8601String(),
      'appVersion': null,
      'config_format': 2,
      'configs': configs,
    };
    // Top-level mirrors for the old importer.
    if (proxy != null) {
      payload[LegacyConfigKeys.proxyUrl] = proxy;
    }
    if (webdav != null) {
      payload[LegacyConfigKeys.webdavConfig] = webdav;
    }
    return payload;
  }

  /// Grouped wire key → legacy alias for keys whose names differ.
  static const Map<String, String> _legacyAliasesByWireKey = <String, String>{
    ConfigKeys.themeConfig: LegacyConfigKeys.themeConfig,
    ConfigKeys.themeMode: LegacyConfigKeys.themeMode,
    ConfigKeys.proxyUrl: LegacyConfigKeys.proxyUrl,
    ConfigKeys.catalogUrl: LegacyConfigKeys.catalogUrl,
    ConfigKeys.agentModels: LegacyConfigKeys.agentModels,
    ConfigKeys.agentSelectedModelId: LegacyConfigKeys.agentSelectedModelId,
    ConfigKeys.agentModelCatalog: LegacyConfigKeys.agentModelCatalog,
    ConfigKeys.fdroidSources: LegacyConfigKeys.fdroidSources,
    ConfigKeys.lastSourceId: LegacyConfigKeys.lastSourceId,
    ConfigKeys.selectedChannels: LegacyConfigKeys.selectedChannels,
    ConfigKeys.webdavUrl: LegacyConfigKeys.webdavUrl,
    ConfigKeys.webdavUsername: LegacyConfigKeys.webdavUsername,
    ConfigKeys.webdavPassword: LegacyConfigKeys.webdavPassword,
    ConfigKeys.webdavBackupPath: LegacyConfigKeys.webdavBackupPath,
    ConfigKeys.webdavEnableHttps: LegacyConfigKeys.webdavEnableHttps,
  };

  /// Adds the legacy mirror keys (C16) next to the grouped keys.
  void _addLegacyConfigAliases(
    Map<String, dynamic> configs,
    Map<String, dynamic> grouped,
  ) {
    for (final entry in _legacyAliasesByWireKey.entries) {
      if (grouped.containsKey(entry.key)) {
        configs[entry.value] = grouped[entry.key];
      }
    }

    final hasDownload =
        grouped.keys.any((key) => key.startsWith('download.'));
    if (hasDownload) {
      configs[LegacyConfigKeys.downloadConfig] = <String, dynamic>{
        'multiSegmentEnabled':
            _asBool(grouped[ConfigKeys.downloadMultiSegmentEnabled]) ?? true,
        'maxSegments': _asInt(grouped[ConfigKeys.downloadDefaultConnections]) ?? 8,
        'segmentSizeBytes': 8 * 1024 * 1024,
        'maxConcurrentDownloads':
            _asInt(grouped[ConfigKeys.downloadMaxConcurrent]) ?? 3,
        'wifiOnly': _asBool(grouped[ConfigKeys.downloadWifiOnly]) ?? false,
        'maxRetryCount': _asInt(grouped[ConfigKeys.downloadMaxRetries]) ?? 3,
      };
    }

    final hasUpdate = grouped.keys.any((key) => key.startsWith('update.'));
    if (hasUpdate) {
      final lastCheck =
          _nonEmptyString(grouped[ConfigKeys.updateLastCheckTime]);
      final lastVersion =
          _nonEmptyString(grouped[ConfigKeys.updateLastUpdatedVersion]);
      configs[LegacyConfigKeys.updateConfig] = <String, dynamic>{
        'channel': _nonEmptyString(grouped[ConfigKeys.updateChannel]) ?? 'stable',
        'autoUpdatePolicy': _legacyAutoUpdatePolicy(
            grouped[ConfigKeys.updateAutoUpdatePolicy]),
        'ignorePrerelease':
            _asBool(grouped[ConfigKeys.updateIgnorePrerelease]) ?? true,
        'silentUpdate': _asBool(grouped[ConfigKeys.updateSilentUpdate]) ?? false,
        'checkIntervalHours':
            _asInt(grouped[ConfigKeys.updateCheckIntervalHours]) ?? 24,
        'lastCheckTime': lastCheck,
        'lastUpdatedVersion': lastVersion,
      };
    }
  }

  /// Exports WebDAV as the legacy aggregate object (and the top-level mirror).
  ///
  /// Prefers the manager copy (the old app's real storage, including the
  /// password) and falls back to the grouped raw values.
  ///
  /// Known divergence until Todo 31: the legacy `WebDavConfigManager` copy and
  /// the Rust `webdav.*` store are still two writes, so the manager can win
  /// here even when it differs from Rust. Todo 31 unifies WebDAV onto the Rust
  /// store and makes both sources agree.
  Future<Map<String, dynamic>?> _exportWebDavConfig(
    Map<String, dynamic> grouped,
  ) async {
    try {
      final manager = await WebDavConfigManager.instance.loadConfig();
      if (manager != null) return manager.toJson();
    } catch (e) {
      appLog.error('BackupService: 读取 WebDAV 配置失败 - $e');
    }
    final hasWebDav = grouped.keys.any((key) => key.startsWith('webdav.'));
    if (!hasWebDav) return null;
    return <String, dynamic>{
      'url': _nonEmptyString(grouped[ConfigKeys.webdavUrl]) ?? '',
      'username': _nonEmptyString(grouped[ConfigKeys.webdavUsername]) ?? '',
      'password': _nonEmptyString(grouped[ConfigKeys.webdavPassword]) ?? '',
      'backupPath':
          _nonEmptyString(grouped[ConfigKeys.webdavBackupPath]) ?? '/GStore',
      'enableHttps': _asBool(grouped[ConfigKeys.webdavEnableHttps]) ?? true,
    };
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  static bool? _asBool(Object? value) => value is bool ? value : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static String _legacyAutoUpdatePolicy(Object? value) {
    return switch (_nonEmptyString(value)) {
      'wifi_only' => 'wifiOnly',
      'never' => 'never',
      'always' => 'always',
      _ => 'wifiOnly',
    };
  }

  // ==================== 导出功能 ====================

  /// 导出所有数据到 JSON
  ///
  /// [options] 导出选项
  /// [channels] 指定导出的渠道，为空则导出所有
  Future<BackupData> exportData({
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = true,  // 新增：是否包含应用配置
  }) async {
    if (!_isInitialized) await initialize();

    final exportOptions = options ?? const BackupOptions();

    // 目标渠道 code 集合：显式 channels（枚举）或全部枚举渠道 + 动态脚本渠道 channelKey
    // + 聚合库数据反推（已添加应用的所有 channelId）。
    // 脚本渠道应用存于 channel_added_app.channelCode = channelKey（如 'js_pingan'），
    // 不在 ChannelType.values 内——必须显式并入，否则通过 JS 渠道添加的应用不会被备份。
    // 从聚合库反推保证：即使脚本渠道已卸载（未注册），历史添加的应用仍能被备份。
    final allAddedApps = await AddedAppsFacade.instance.list();
    final targetCodes = <String>{
      for (final c in (channels ?? ChannelType.values)) c.code,
      for (final ch in ChannelManager.instance.dynamicChannels) channelCode(ch),
      for (final app in allAddedApps) app.channelId,
    };

    appLog.info('BackupService: 开始导出数据（包含渠道数据库），目标渠道: $targetCodes');
    if (includeAppConfig) {
      debugPrint('BackupService: 将包含应用配置（主题等）');
    }

    // 收集聚合数据库应用
    final allApps = <BackupAppItem>[];

    for (final addedApp in allAddedApps) {
      // 过滤条件
      if (exportOptions.enabledOnly && !addedApp.isEnabled) {
        continue;
      }

      if (targetCodes.contains(addedApp.channelId)) {
        final backupItem = BackupAppItem.fromAddedAppInfo(
          addedApp,
          exportOptions,
        );
        allApps.add(backupItem);
      }
    }

    // 收集渠道数据库应用（flag 路由：channels on 读 Rust core，off 读旧渠道库）
    final channelAppsMap = <String, List<ChannelAppBackupItem>>{};

    for (final code in targetCodes) {
      try {
        appLog.info('BackupService: 导出渠道 $code 的数据');
        final backupItems = await _readChannelBackupItems(code);

        if (backupItems.isNotEmpty) {
          channelAppsMap[code] = backupItems;
          appLog.info('BackupService: 渠道 $code 导出 ${backupItems.length} 个应用');

          // 更新聚合数据中的 extra 字段
          for (final backupItem in backupItems) {
            final existingApp = allApps.indexWhere((app) =>
              app.appId == backupItem.appId && app.channelId == code);

            if (existingApp != -1) {
              // 更新 extra 字段
              final oldApp = allApps[existingApp];
              allApps[existingApp] = BackupAppItem(
                channelId: oldApp.channelId,
                appId: oldApp.appId,
                appName: oldApp.appName,
                iconUrl: oldApp.iconUrl,
                description: oldApp.description,
                category: oldApp.category,
                addTime: oldApp.addTime,
                sortOrder: oldApp.sortOrder,
                isEnabled: oldApp.isEnabled,
                extra: backupItem.extra, // 从渠道数据库获取的 extra
              );
            }
          }
        }
      } catch (e) {
        appLog.error('BackupService: 导出渠道 $code 失败 - $e');
      }
    }

    // 导出应用配置（如果需要）。
    //
    // C16：所有导出路径共享同一个 `ConfigApi.export` 辅助方法（raw 值），
    // app_config.json / apps.json.appConfig 都由这里构造；`includeAppConfig`
    // 为 false 时整个 appConfig 缺省（绝不用 *** 掩码）。
    Map<String, dynamic>? appConfig;
    if (includeAppConfig) {
      try {
        appLog.info('BackupService: 开始导出应用配置');
        appConfig = await _buildAppConfigMap();
        if (appConfig != null) {
          final configCount =
              (appConfig['configs'] as Map?)?.length ?? 0;
          appLog.info('BackupService: 应用配置导出完成 (共 $configCount 项配置)');
        }
      } catch (e) {
        appLog.error('BackupService: 导出应用配置失败 - $e');
      }
    }

    // 导出扩展数据（F-Droid 源、Agent 配置等）
    //
    // C16：extras 里全部是配置承载数据（F-Droid 源、Agent 模型/API Key、脚本
    // 渠道 env）。`includeAppConfig` 为 false 时必须**整体省略**，绝不能用
    // `***` 掩码——旧恢复路径会把掩码原样写回。
    final extras = <String, dynamic>{};
    if (includeAppConfig) {
      try {
        // F-Droid 仓库源列表
        final fdroidSources = FdroidRepoManager.instance.sources;
        if (fdroidSources.isNotEmpty) {
          extras['fdroid_sources'] =
              fdroidSources.map((s) => s.toJson()).toList();
          appLog.info('BackupService: 导出 F-Droid 源 ${fdroidSources.length} 个');
        }
      } catch (e) {
        appLog.error('BackupService: 导出 F-Droid 源失败 - $e');
      }

      try {
        // Agent LLM 模型配置
        final modelStore = await AgentModelStore.load();
        if (modelStore.models.isNotEmpty) {
          extras['agent_models'] = modelStore.models
              .map((m) => {
                    'id': m.id,
                    'name': m.name,
                    'provider': m.provider.name,
                    'apiKey': m.apiKey,
                    'model': m.model,
                    'baseUrl': m.baseUrl,
                  })
              .toList();
          extras['agent_selected_id'] = modelStore.selectedId;
          appLog.info('BackupService: 导出 Agent 模型 ${modelStore.models.length} 个');
        }
      } catch (e) {
        appLog.error('BackupService: 导出 Agent 配置失败 - $e');
      }

      // 导出脚本渠道环境变量（channelKey → env map）
      // zip 本体经 tar.gz 的 channels/ 条目原样打包；env 随 apps.json 的 extras 走（JSON 明文）。
      //
      // Rust 脚本通道（CoreFlags.jsChannel=true，生产默认）：渠道包 env 存 Rust
      // `channel_env` 表 + FileSecretStore，经 `ScriptApi.getEnv` 逐包读取导出
      // （与脚本 `host.env.get` 同一份存储，敏感项从密钥存储解析）。
      try {
        final jsEnvs = <String, Map<String, String>>{};
        final omitted = <String>[];
        if (CoreFlags.jsChannel) {
          await RustScriptChannelLane.instance.refresh();
          for (final pack in RustScriptChannelLane.instance.packs) {
            try {
              final env = await ScriptApi.instance.getEnv(key: pack.key);
              if (env.isNotEmpty) jsEnvs[pack.key] = env;
            } catch (e) {
              // 单个包读取失败不阻塞其他包；显式记录遗漏，绝不静默丢弃。
              omitted.add(pack.key);
              appLog.warning(
                  'BackupService: Rust 脚本渠道包 ${pack.key} 的 env 读取失败: $e');
            }
          }
        }
        if (jsEnvs.isNotEmpty) {
          extras['js_envs'] = jsEnvs;
          appLog.info('BackupService: 导出脚本渠道环境变量 ${jsEnvs.length} 个渠道');
        }
        if (omitted.isNotEmpty) {
          // 读取失败的渠道包键记录于 extras.js_envs_rust_lane_omitted（可见性，不静默丢弃）。
          extras['js_envs_rust_lane_omitted'] = omitted;
          appLog.warning(
              'BackupService: ${omitted.length} 个 Rust 脚本渠道包的 env 未导出'
              '（键记录于 extras.js_envs_rust_lane_omitted）');
        }
      } catch (e) {
        appLog.error('BackupService: 导出脚本渠道环境变量失败 - $e');
      }
    }

    // 导出用户分类标签（v2.1 新增）
    List<BackupTagItem>? backupTags;
    try {
      // 标签索引键为 'channelId:appId'（facade/核心的稳定投影）。appId 内的
      // ':' 不是分隔符——只按第一个 ':' 切分，与写入侧的键构造严格对称。
      final tagsIndex = await AddedAppsFacade.instance.tagsIndex();
      final flatTags = <BackupTagItem>[];
      tagsIndex.forEach((key, tags) {
        final sep = key.indexOf(':');
        if (sep < 0) return;
        final channelId = key.substring(0, sep);
        final appId = key.substring(sep + 1);
        for (final tag in tags) {
          flatTags.add(
              BackupTagItem(channelId: channelId, appId: appId, tag: tag));
        }
      });
      if (flatTags.isNotEmpty) {
        backupTags = flatTags;
        appLog.info('BackupService: 导出用户标签 ${flatTags.length} 个');
      }
    } catch (e) {
      appLog.error('BackupService: 导出用户标签失败 - $e');
    }

    // 构建元数据
    final channelCounts = <String, int>{};
    for (final app in allApps) {
      channelCounts[app.channelId] = (channelCounts[app.channelId] ?? 0) + 1;
    }

    final metadata = BackupMetadata(
      version: BackupVersion.v2_1, // 使用 v2.1 版本（含分类标签 + 代理配置）
      exportDate: DateTime.now(),
      appVersion: await AppVersionService.versionName() ?? 'unknown',
      totalApps: allApps.length,
      channelCounts: channelCounts,
      options: exportOptions,
    );

    final backupData = BackupData(
      metadata: metadata,
      apps: allApps,
      channelApps: channelAppsMap,
      appConfig: appConfig,
      extras: extras.isNotEmpty ? extras : null,
      tags: backupTags,
    );

    appLog.info('BackupService: 导出完成 - ${allApps.length} 个聚合应用, ${channelAppsMap.length} 个渠道有额外数据${includeAppConfig ? ", 包含应用配置" : ""}, 扩展数据 ${extras.length} 类');
    return backupData;
  }

  /// 导出备份压缩包（tar.gz bytes）
  ///
  /// 供 WebDAV 等传输层上传；[includeAppConfig] 控制是否附带独立的
  /// app_config.json 归档文件。
  /// [options] 导出选项
  /// [channels] 指定导出的渠道
  Future<Uint8List> exportCompressedBackup({
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async {
    appLog.info('BackupService: 开始导出备份压缩包');
    try {
      // 生成备份数据
      onLog?.call('开始导出数据...');
      final backupData = await exportData(
        options: options,
        channels: channels,
        // C16: without forwarding the flag the WebDAV path would leak config
        // (and secrets) while `includeAppConfig` is false.
        includeAppConfig: includeAppConfig,
      );
      onLog?.call('已添加应用 ${backupData.apps.length} 个');
      if (backupData.channelApps.isNotEmpty) {
        onLog?.call('导出渠道库数据（${backupData.channelApps.length} 个渠道）');
      }
      if (backupData.tags != null && backupData.tags!.isNotEmpty) {
        onLog?.call('导出分类标签（${backupData.tags!.length} 个）');
      }
      if (backupData.appConfig != null && backupData.appConfig!.isNotEmpty) {
        onLog?.call('导出应用配置（${backupData.appConfig!.length} 项）');
      }

      // 创建 Archive 对象
      final archive = Archive();

      // 添加 apps.json 到归档
      final appsJsonString = jsonEncode(backupData.toJson());
      final appsBytes = utf8.encode(appsJsonString);
      archive.addFile(ArchiveFile('apps.json', appsBytes.length, appsBytes));
      debugPrint('BackupService: apps.json 已添加 (${appsBytes.length} bytes)');

      // app_config.json 与 apps.json.appConfig 使用同一份共享载荷（C16）。
      if (includeAppConfig) {
        debugPrint('BackupService: 包含应用配置');
        final appConfig = backupData.appConfig;
        final configs = appConfig?['configs'];
        final configCount = configs is Map ? configs.length : 0;
        if (appConfig != null &&
            configs is Map &&
            configCount > 0) {
          appLog.info('BackupService: 应用配置导出成功，包含 $configCount 项配置');
          // 添加 app_config.json 到归档
          final configJsonString = jsonEncode(appConfig);
          final configBytes = utf8.encode(configJsonString);
          archive.addFile(ArchiveFile(
              'app_config.json', configBytes.length, configBytes));
          debugPrint(
              'BackupService: app_config.json 已添加 (${configBytes.length} bytes)');

          // 打印配置键列表
          for (final key in configs.keys) {
            debugPrint('BackupService:   - $key');
          }
        } else {
          debugPrint('BackupService: ⚠️ 配置为空，跳过 app_config.json');
        }
      }

      // 渠道包（脚本渠道 zip）——tar.gz 原生二进制条目，无需 base64
      final channelFiles = await buildChannelPackageArchiveFiles();
      for (final entry in channelFiles) {
        archive.addFile(entry);
        debugPrint('BackupService: channels 条目已添加 ${entry.name}');
      }
      if (channelFiles.isNotEmpty) {
        onLog?.call('导出渠道包（${channelFiles.length} 个）');
      }

      // 打包压缩
      onLog?.call('打包压缩备份数据...');
      // 将 Archive 编码为 tar 字节
      final tarBytes = TarEncoder().encode(archive);

      // 使用 gzip 压缩
      final uploadBytes = Uint8List.fromList(gzip.encode(tarBytes));

      appLog.info('BackupService: 备份压缩包生成完成 (${uploadBytes.length} bytes)');
      return uploadBytes;
    } catch (e) {
      appLog.error('BackupService: 导出备份压缩包失败 - $e');
      onLog?.call('导出失败: $e', isError: true);
      rethrow;
    }
  }

  // ==================== Core 数据库快照 ====================

  /// 导出 Rust core 数据库快照（`VACUUM INTO`）。
  ///
  /// [path] 为空时落在应用支持目录下的 `gstore_core/files/backups`。快照不含
  /// 宿主密钥库：`secrets_excluded` 恒为 true。
  Future<CoreSnapshotExport> exportCoreSnapshot({String? path}) async {
    final result = await CoreSnapshotBackup.export(path: path);
    appLog.info(
      'BackupService: 导出核心快照 ${result.path} (${result.bytes} bytes, '
      'secrets_excluded=${result.secretsExcluded})',
    );
    return result;
  }

  /// 用核心快照替换当前 core 数据库。
  ///
  /// 校验、完整性检查与预恢复备份全部在替换前完成；失败会回滚到原库并抛出
  /// 带 `CORE_E_SNAPSHOT_*` 前缀的异常。
  Future<CoreSnapshotRestore> restoreCoreSnapshot(String path) async {
    final result = await CoreSnapshotBackup.restore(path);
    appLog.info(
      'BackupService: 恢复核心快照 $path -> schema v${result.schemaVersion} '
      '(secrets_excluded=${result.secretsExcluded})',
    );
    return result;
  }

  // ==================== 导入功能 ====================

  /// 从文件导入
  ///
  /// [filePath] 文件路径
  /// [mode] 导入模式
  /// [restoreAppConfig] 是否恢复应用配置
  Future<BackupImportResult> importFromFile(
    String filePath, {
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    appLog.info('BackupService: ========== 开始导入 ==========');
    debugPrint('BackupService: 文件路径: $filePath');
    debugPrint('BackupService: 导入模式: $mode');
    debugPrint('BackupService: 恢复应用配置: $restoreAppConfig');

    // 读取文件
    final file = File(filePath);
    if (!await file.exists()) {
      appLog.error('BackupService: ❌ 文件不存在');
      throw BackupException('文件不存在: $filePath');
    }

    // 检查文件类型
    if (!filePath.endsWith('.tar.gz')) {
      appLog.error('BackupService: ❌ 不支持的文件格式');
      throw BackupException('不支持的文件格式，请使用 .tar.gz 格式的备份文件');
    }

    String jsonString = '';
    Map<String, dynamic>? configData;

    debugPrint('BackupService: 检测到 tar.gz 压缩文件，开始解压');

    // 读取文件
    final bytes = await file.readAsBytes();

    // 先用 gzip 解压
    final decompressedBytes = gzip.decode(bytes);
    debugPrint('BackupService: Gzip 解压完成，大小: ${decompressedBytes.length} bytes');

    // 再用 TarDecoder 解包
    final tarDecoder = TarDecoder();
    final archive = tarDecoder.decodeBytes(decompressedBytes);
    debugPrint('BackupService: Tar 解包完成，包含 ${archive.files.length} 个文件');

    // 提取文件
    final channelZipEntries = <String, List<int>>{};
    for (final archiveFile in archive.files) {
      debugPrint('BackupService: 找到文件: ${archiveFile.name} (${archiveFile.size} bytes)');

      if (archiveFile.name == 'apps.json') {
        final fileBytes = archiveFile.content as List<int>;
        jsonString = utf8.decode(fileBytes);
        debugPrint('BackupService: apps.json 已加载');
      } else if (archiveFile.name == 'app_config.json') {
        final fileBytes = archiveFile.content as List<int>;
        final configJsonString = utf8.decode(fileBytes);
        configData = jsonDecode(configJsonString) as Map<String, dynamic>;
        debugPrint('BackupService: app_config.json 已加载，包含 ${configData.length} 项配置');
      } else if (archiveFile.name.startsWith('channels/')) {
        // JS 脚本渠道 zip 包：暂存，数据导入完成后写回渠道包目录
        final fileBytes = archiveFile.content as List<int>;
        channelZipEntries[archiveFile.name] = fileBytes;
        debugPrint('BackupService: 捕获渠道包条目 ${archiveFile.name} (${fileBytes.length} bytes)');
      }
    }

    if (jsonString.isEmpty) {
      appLog.error('BackupService: ❌ 未找到 apps.json 文件');
      throw BackupException('备份文件中未找到 apps.json');
    }

    debugPrint('BackupService: 开始解析 JSON...');

    // 解析 JSON
    final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
    debugPrint('BackupService: JSON 解析成功');
    debugPrint('BackupService: JSON keys: ${jsonData.keys.toList()}');

    final backupData = BackupData.fromJson(jsonData);

    debugPrint('BackupService: BackupData 解析成功');
    debugPrint('BackupService: 版本: ${backupData.metadata.version}');
    debugPrint('BackupService: 应用总数: ${backupData.apps.length}');
    debugPrint('BackupService: 渠道数据: ${backupData.channelApps.length} 个渠道');

    // 打印渠道数据详情
    if (backupData.channelApps.isNotEmpty) {
      debugPrint('BackupService: 渠道数据详情:');
      for (final entry in backupData.channelApps.entries) {
        debugPrint('BackupService:   - ${entry.key}: ${entry.value.length} 个应用');
        for (final app in entry.value.take(3)) {
          debugPrint('BackupService:     - ${app.appId} (${app.name}), extra: ${app.extra}');
        }
        if (entry.value.length > 3) {
          debugPrint('BackupService:     ... 还有 ${entry.value.length - 3} 个');
        }
      }
    }

    // 验证版本
    if (!_isSupportedVersion(backupData.metadata.version)) {
      appLog.error('BackupService: ❌ 不支持的版本: ${backupData.metadata.version}');
      throw BackupException(
        '不支持的备份版本: ${backupData.metadata.version}',
      );
    }

    appLog.info('BackupService: ✅ 版本验证通过');
    appLog.info('BackupService: 开始导入数据...');

    // Todo 29: config restore is handled by the single
    // `ConfigRestoreAdapter` path inside `importData`; pass the standalone
    // `app_config.json` payload through so both archive locations are covered
    // without a second restore implementation.
    final result = await importData(
      backupData,
      mode: mode,
      restoreAppConfig: restoreAppConfig,
      appConfigJson: configData,
    );
    if (!result.success) {
      // Mirror importBackupBytes: a blocked/failed data import must abort the
      // restore before any channel zip is written.
      final detail = result.writeWarnings.isNotEmpty
          ? result.writeWarnings.join('; ')
          : (result.error ?? '恢复未完成');
      appLog.error('BackupService: 恢复中止: $detail');
      onLog?.call('恢复中止: $detail', isError: true);
      return result;
    }

    // 写回脚本渠道 zip 包 + 重新注册（旧备份无 channels/ 条目时为空，自动跳过）
    if (channelZipEntries.isNotEmpty) {
      final restored = await _restoreChannelPackages(channelZipEntries);
      debugPrint('BackupService: 渠道包恢复完成 ${restored} 个');
      onLog?.call('渠道包恢复完成（$restored 个）');
    }

    appLog.info('BackupService: ========== 导入完成 ==========');
    appLog.info('BackupService: 成功: ${result.success}');
    debugPrint('BackupService: 总数: ${result.totalCount}');
    debugPrint('BackupService: 新增: ${result.addedCount}');
    debugPrint('BackupService: 跳过: ${result.skippedCount}');
    onLog?.call('恢复完成');

    return result;
  }

  /// 从备份压缩包 bytes 恢复
  ///
  /// 下载层（WebDAV 等）拉取 tar.gz bytes 后交给备份模块恢复。
  /// [mode] 导入模式
  /// [restoreAppConfig] 是否恢复应用配置
  Future<BackupImportResult> importBackupBytes(
    Uint8List bytes, {
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    appLog.info('BackupService: 从备份字节导入');
    try {
      // 解压并解析
      onLog?.call('解压并解析备份数据...');
      String jsonString = '';
      Map<String, dynamic>? configData;

      debugPrint('BackupService: 检测到 tar.gz 格式');
      // 先用 gzip 解压
      final decompressedBytes = gzip.decode(bytes);
      // 再用 TarDecoder 解包
      final tarDecoder = TarDecoder();
      final archive = tarDecoder.decodeBytes(decompressedBytes);

      // 提取文件
      final channelZipEntries = <String, List<int>>{};
      for (final archiveFile in archive.files) {
        if (archiveFile.name == 'apps.json') {
          final fileBytes = archiveFile.content as List<int>;
          jsonString = utf8.decode(fileBytes);
        } else if (archiveFile.name == 'app_config.json') {
          final fileBytes = archiveFile.content as List<int>;
          final configJsonString = utf8.decode(fileBytes);
          configData = jsonDecode(configJsonString) as Map<String, dynamic>;
        } else if (archiveFile.name.startsWith('channels/')) {
          // JS 脚本渠道 zip 包：暂存，数据导入完成后写回渠道包目录
          final fileBytes = archiveFile.content as List<int>;
          channelZipEntries[archiveFile.name] = fileBytes;
        }
      }

      if (jsonString.isEmpty) {
        appLog.error('BackupService: ❌ 未找到 apps.json 文件');
        throw BackupException('备份文件中未找到 apps.json');
      }

      // 解析 JSON
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      final backupData = BackupData.fromJson(jsonData);
      onLog?.call('解析完成，共 ${backupData.apps.length} 个应用');

      // 验证版本
      if (!_isSupportedVersion(backupData.metadata.version)) {
        throw BackupException(
          '不支持的备份版本: ${backupData.metadata.version}',
        );
      }

      appLog.info('BackupService: 备份版本: ${backupData.metadata.version}, 开始导入');

      // 导入数据（内部各阶段同步输出 onLog；配置恢复同样由 importData 内的
      // 唯一 `ConfigRestoreAdapter` 路径完成，配置失败不会中止应用数据导入）
      final result = await importData(
        backupData,
        mode: mode,
        onLog: onLog,
        restoreAppConfig: restoreAppConfig,
        appConfigJson: configData,
      );
      if (!result.success) {
        // 典型场景：恢复写被核心写标记拦截（typed警告已由 importData 输出）。
        onLog?.call('恢复中止: ${result.error}', isError: true);
        return result;
      }

      // 写回脚本渠道 zip 包 + 重新注册（旧备份无 channels/ 条目时为空，自动跳过）
      if (channelZipEntries.isNotEmpty) {
        final restored = await _restoreChannelPackages(channelZipEntries);
        onLog?.call('渠道包恢复完成（$restored 个）');
      }

      onLog?.call('恢复完成');
      return result;
    } catch (e) {
      appLog.error('BackupService: 从备份字节导入失败 - $e');
      onLog?.call('恢复失败: $e', isError: true);
      rethrow;
    }
  }

  /// 导入数据
  ///
  /// [backupData] 备份数据
  /// [mode] 导入模式
  /// [restoreAppConfig] 是否恢复应用配置（默认 true，保持既有调用语义）
  /// [appConfigJson] 归档内独立的 `app_config.json` 载荷；与
  ///   `backupData.appConfig` 一起交给同一个 [ConfigRestoreAdapter]。
  Future<BackupImportResult> importData(
    BackupData backupData, {
    BackupImportMode mode = BackupImportMode.merge,
    BackupLogCallback? onLog,
    bool restoreAppConfig = true,
    Map<String, dynamic>? appConfigJson,
  }) async {
    final result = BackupImportResult();

    if (!_isInitialized) await initialize();

    appLog.info('BackupService: ========== 开始导入数据 ==========');
    debugPrint('BackupService: 应用数量: ${backupData.apps.length}');
    debugPrint('BackupService: 版本: ${backupData.metadata.version}');
    debugPrint('BackupService: 渠道数据: ${backupData.channelApps.length} 个渠道');
    debugPrint('BackupService: 导入模式: $mode');

    try {
      // 验证版本
      if (!_isSupportedVersion(backupData.metadata.version)) {
        appLog.error('BackupService: ❌ 不支持的版本: ${backupData.metadata.version}');
        throw BackupException(
          '不支持的备份版本: ${backupData.metadata.version}',
        );
      }

      appLog.info('BackupService: ✅ 版本验证通过');
      onLog?.call('开始导入应用数据（${backupData.apps.length} 个）...');

      // 根据导入模式处理聚合数据库
      switch (mode) {
        case BackupImportMode.replace:
          appLog.info('BackupService: 模式: REPLACE - 清空并重新添加');
          // 替换模式：先清空，再添加
          await AddedAppsFacade.instance.clearAll();
          appLog.info('BackupService: 已清空聚合数据库');
          await _addAllAppsToAggregator(backupData.apps);
          break;

        case BackupImportMode.merge:
          appLog.info('BackupService: 模式: MERGE - 合并已存在的应用');
          // 合并模式：添加不存在的应用
          final existingApps = await AddedAppsFacade.instance.list();
          final existingKeys = existingApps
              .map((app) => '${app.channelId}_${app.appId}')
              .toSet();

          debugPrint('BackupService: Merge 模式 - 已存在 ${existingApps.length} 个应用');
          if (existingApps.isNotEmpty) {
            debugPrint('BackupService: 已存在应用列表:');
            for (final app in existingApps.take(5)) {
              debugPrint('BackupService:   - ${app.channelId}/${app.appId}');
            }
            if (existingApps.length > 5) {
              debugPrint('BackupService:   ... 还有 ${existingApps.length - 5} 个');
            }
          }

          final newApps = backupData.apps
              .where((app) {
                final key = '${app.channelId}_${app.appId}';
                final exists = existingKeys.contains(key);
                if (exists) {
                  debugPrint('BackupService: 跳过已存在应用 - $key (${app.appName})');
                }
                return !exists;
              })
              .toList();

          debugPrint('BackupService: Merge 模式 - 需要添加 ${newApps.length} 个新应用');
          if (newApps.isNotEmpty) {
            debugPrint('BackupService: 新应用列表:');
            for (final app in newApps.take(5)) {
              debugPrint('BackupService:   + ${app.channelId}/${app.appId} (${app.appName})');
            }
            if (newApps.length > 5) {
              debugPrint('BackupService:   ... 还有 ${newApps.length - 5} 个');
            }
          }
          await _addAllAppsToAggregator(newApps);

          result.skippedCount = backupData.apps.length - newApps.length;
          break;

        case BackupImportMode.update:
          appLog.info('BackupService: 模式: UPDATE - 更新或添加');
          // 更新模式：更新存在的应用，添加不存在的
          await _addAllAppsToAggregator(backupData.apps);
          break;
      }

      onLog?.call('应用数据导入完成');

      // 导入渠道数据库数据（v2.0 及更新版本包含渠道数据）
      if ((backupData.metadata.version == BackupVersion.v2_0 ||
              backupData.metadata.version == BackupVersion.v2_1) &&
          backupData.channelApps.isNotEmpty) {
        appLog.info('BackupService: 开始导入渠道数据库数据（${backupData.channelApps.length} 个渠道）');
        onLog?.call('导入渠道库数据（${backupData.channelApps.length} 个渠道）...');
        if (CoreFlags.channels) {
          // 核心拥有渠道域：把备份里真正带 name/icon 的 `channelApps` 段灌进
          // core 的 `channel_apps`（只写元数据，不动 added_apps 成员关系）。
          //
          // 关键：`_addAllAppsToAggregator` 只能拿到聚合库的引用（v3 起 `apps`
          // 段的 appName 就是 appId 占位），真正的元数据只在这段 `channelApps`
          // 里。旧实现仍走 legacy Dart 渠道库并被 `LegacyWriteGuard` 拦下，于是
          // 出现「首页恢复了、发现页不恢复」。这里改为按渠道路由到 core
          // （js lane 走脚本域存储）。
          final report = await _importChannelAppsToCore(backupData.channelApps);
          onLog?.call(
              '渠道库导入完成（元数据 ${report.restored} 条，失败 ${report.failed} 条）');
        } else {
          try {
            await _importChannelApps(backupData.channelApps, mode);
            onLog?.call('渠道库导入完成');
          } on LegacyWriteBlocked catch (blocked) {
            // 渠道域的写标记已武装（核心拥有渠道库）：RESTORE 语义从"整体失败"
            // 降级为"typed 部分警告"——catalog 已走核心，渠道元数据留待核心导入。
            // 绝不写渠道库（_importChannelApps 的 guard 保持 fail-closed）。
            final warning = CoreWriteBlockedWarning(
              domain: blocked.domain,
              operation: 'importData',
              detail: 'channel restore skipped; the Rust core owns this domain',
            );
            result.writeWarnings.add(warning);
            appLog.warning('BackupService: $warning');
            onLog?.call(warning.toString(), isError: true);
          }
        }
      } else {
        debugPrint('BackupService: 无渠道数据需要导入（版本: ${backupData.metadata.version}, 渠道数: ${backupData.channelApps.length}）');
      }

      // 导入应用配置（如果存在）
      //
      // Todo 29 / C16: 所有恢复入口只走这一条 `ConfigRestoreAdapter` 路径。
      // 它同时读取 `apps.json.appConfig`（BackupData 内嵌）与独立
      // `app_config.json`，按 grouped-wins 合并，并经 Rust import 接缝逐键
      // 恢复；单个坏键只汇报失败，绝不中止应用数据导入。
      if (restoreAppConfig) {
        await _restoreBackupConfig(
          embeddedAppConfig: backupData.appConfig,
          appConfigJson: appConfigJson,
          onLog: onLog,
        );
      } else if ((backupData.appConfig != null &&
              backupData.appConfig!.isNotEmpty) ||
          (appConfigJson != null && appConfigJson.isNotEmpty)) {
        debugPrint('BackupService: 跳过应用配置导入（用户未选择恢复配置）');
        onLog?.call('已跳过应用配置恢复');
      } else {
        debugPrint('BackupService: 备份中不包含应用配置');
      }

      // 导入用户分类标签（v2.1 新增；insertTags 复合主键冲突 replace，幂等追加）
      if (backupData.tags != null && backupData.tags!.isNotEmpty) {
        onLog?.call('恢复用户分类标签（${backupData.tags!.length} 个）...');
        try {
          // setTags 整体替换（等价旧 insertTags 的复合主键 replace 语义）：
          // 先按 (channelId, appId) 分组，每个应用只调用一次。
          final tagGroups = <(String, String), List<String>>{};
          for (final t in backupData.tags!) {
            tagGroups
                .putIfAbsent((t.channelId, t.appId), () => <String>[])
                .add(t.tag);
          }
          for (final group in tagGroups.entries) {
            // 旧备份的标签也可能挂在 `local_db` 上：同样映射到 `gstore`，
            // 避免恢复流程写出任何 `local_db` 行。
            await AddedAppsFacade.instance.setTags(
              _mapChannelId(group.key.$1),
              group.key.$2,
              group.value,
            );
          }
          appLog.info('BackupService: ✅ 用户标签恢复完成（${backupData.tags!.length} 个）');
          onLog?.call('用户标签恢复完成');
        } catch (e) {
          appLog.error('BackupService: 恢复用户标签失败 - $e');
          onLog?.call('用户标签恢复失败: $e', isError: true);
        }
      } else {
        debugPrint('BackupService: 备份中不包含用户标签');
      }

      // 导入扩展数据（F-Droid 源、Agent 配置等）
      if (backupData.extras != null && backupData.extras!.isNotEmpty) {
        appLog.info('BackupService: 开始导入扩展数据（${backupData.extras!.keys.toList()}）');

        // F-Droid 仓库源
        final fdroidSources = backupData.extras!['fdroid_sources'];
        if (fdroidSources is List && fdroidSources.isNotEmpty) {
          try {
            final manager = FdroidRepoManager.instance;
            // 清理现有源（保留默认）
            final defaultIds = {'official', 'tuna_mirror'};
            for (final source in List.of(manager.sources)) {
              if (!defaultIds.contains(source.id)) {
                await manager.removeSource(source.id);
              }
            }
            // 添加备份的源（跳过默认源）
            for (final item in fdroidSources) {
              if (item is Map<String, dynamic>) {
                final source = FdroidSource.fromJson(item);
                if (!defaultIds.contains(source.id)) {
                  await manager.addSource(source);
                }
              }
            }
            appLog.info('BackupService: ✅ F-Droid 源恢复完成');
          } catch (e) {
            appLog.error('BackupService: 恢复 F-Droid 源失败 - $e');
          }
        }

        // Agent LLM 模型配置
        final agentModels = backupData.extras!['agent_models'];
        if (agentModels is List && agentModels.isNotEmpty) {
          try {
            final store = await AgentModelStore.load();
            for (final item in agentModels) {
              if (item is Map<String, dynamic>) {
                final model = AgentModel(
                  id: item['id'] as String? ?? '',
                  name: item['name'] as String? ?? '',
                  provider: AgentLlmProvider.values.firstWhere(
                    (e) => e.name == item['provider'],
                    orElse: () => AgentLlmProvider.google,
                  ),
                  apiKey: item['apiKey'] as String? ?? '',
                  model: item['model'] as String? ?? '',
                  baseUrl: item['baseUrl'] as String? ?? '',
                );
                if (model.id.isNotEmpty) {
                  // add 已按 id 去重（同 id 更新、新 id 追加），
                  // 同一备份恢复多次不会产生重复模型
                  await store.add(model, select: false);
                }
              }
            }
            final selectedId = backupData.extras!['agent_selected_id'] as String?;
            if (selectedId != null && store.models.any((m) => m.id == selectedId)) {
              await store.select(selectedId);
            } else if (store.models.isNotEmpty) {
              await store.select(store.models.first.id);
            }
            appLog.info('BackupService: ✅ Agent 模型配置恢复完成');
          } catch (e) {
            appLog.error('BackupService: 恢复 Agent 配置失败 - $e');
          }
        }

        // JS 脚本渠道环境变量（channelKey → env map；备份含敏感配置明文，Rust 侧经
        // FileSecretStore 加密存储）。恢复走 `ScriptApi.setEnv`（与脚本 host.env.get
        // 同一份存储）。
        final jsEnvs = backupData.extras!['js_envs'];
        if (jsEnvs is Map && jsEnvs.isNotEmpty) {
          onLog?.call('恢复脚本渠道环境变量（${jsEnvs.length} 个渠道）...');
          try {
            var restoredCount = 0;
            for (final entry in jsEnvs.entries) {
              final key = entry.key.toString();
              final envRaw = entry.value;
              if (envRaw is! Map) continue;
              final env = envRaw.map((k, v) => MapEntry(k.toString(), v.toString()));
              if (env.isEmpty) continue;
              await ScriptApi.instance.setEnv(key: key, env: env);
              restoredCount++;
            }
            appLog.info('BackupService: ✅ 脚本渠道环境变量恢复完成（$restoredCount 个）');
            onLog?.call('脚本渠道环境变量恢复完成');
          } catch (e) {
            appLog.error('BackupService: 恢复脚本渠道环境变量失败 - $e');
            onLog?.call('脚本渠道环境变量恢复失败: $e', isError: true);
          }
        }
      } else {
        debugPrint('BackupService: 备份中不包含扩展数据');
      }

      result.success = true;
      result.totalCount = backupData.apps.length;
      result.addedCount = backupData.apps.length - result.skippedCount;

      appLog.info('BackupService: ✅ 导入成功');
      debugPrint('BackupService: 总数: ${result.totalCount}, 新增: ${result.addedCount}, 跳过: ${result.skippedCount}');

      // 发送数据库变化事件，通知UI刷新
      appLog.info('BackupService: 📢 发送批量导入事件，通知UI刷新');
      DatabaseEventBus.instance.send(DatabaseChangeEvent(
        type: DatabaseChangeType.batchImport,
        data: {'totalCount': result.totalCount, 'addedCount': result.addedCount},
      ));

      // 验证导入结果
      final finalCount = await AddedAppsFacade.instance.totalCount();
      debugPrint('BackupService: 验证 - 聚合数据库当前总数: $finalCount');

      // 打印导入的应用列表
      final importedApps = await AddedAppsFacade.instance.list();
      debugPrint('BackupService: 导入的应用列表:');
      for (final app in importedApps.take(10)) {
        debugPrint('BackupService:   - ${app.channelId}/${app.appId}');
      }
      if (importedApps.length > 10) {
        debugPrint('BackupService:   ... 还有 ${importedApps.length - 10} 个');
      }
    } on LegacyWriteBlocked catch (blocked) {
      // 恢复写被核心写标记拦截（catalog/channel）：返回 typed warning，
      // 不把原始异常抛给调用方，也不静默吞掉。
      return _reportBlockedRestore(result, blocked, onLog);
    } catch (e, stackTrace) {
      result.success = false;
      result.error = e.toString();
      appLog.error('BackupService: ❌ 导入失败 - $e');
      appLog.error('BackupService: 堆栈跟踪: $stackTrace');
      rethrow;
    }

    appLog.info('BackupService: ========== 导入数据完成 ==========');
    return result;
  }

  /// Surfaces a blocked restore as a typed warning on the result and log.
  BackupImportResult _reportBlockedRestore(
    BackupImportResult result,
    LegacyWriteBlocked blocked,
    BackupLogCallback? onLog,
  ) {
    final warning = CoreWriteBlockedWarning(
      domain: blocked.domain,
      operation: 'importData',
      detail: 'restore write refused; the Rust core owns this domain',
    );
    result.success = false;
    result.error = warning.toString();
    result.writeWarnings.add(warning);
    appLog.warning('BackupService: $warning');
    onLog?.call(warning.toString(), isError: true);
    return result;
  }

  /// 批量添加应用到聚合数据库（经 flag 路由的 [AddedAppsFacade]）
  Future<void> _addAllAppsToAggregator(List<BackupAppItem> apps) async {
    debugPrint('BackupService: 开始添加 ${apps.length} 个应用到聚合数据库');

    try {
      // 逆序添加：核心 `add` 落 `add_time=now`，后加的排前；逆序是恢复备份
      // 顺序的 best-effort。精确 add_time 顺序由后续 Rust `add_all` 提供。
      for (final a in apps.reversed) {
        // 旧备份的渠道 id 可能仍是 `local_db`（core 接管前的本地库渠道）。
        // `local_db` 的驱动不再接受写入，也不在首页投影里，恢复时必须落到
        // 接管的 `gstore` 渠道，否则成员关系「恢复了但看不见」。
        final channel = _mapChannelId(a.channelId);
        if (_isReferenceOnlyBackupItem(a)) {
          // v3 `apps` item: name/icon are placeholders (appName == appId).
          // Metadata normally comes from `channelApps` via
          // `_importChannelAppsToCore`; writing the placeholder here would
          // downgrade a good `channel_apps` row to name=appId, icon=''.
          //
          // Older backups have NO `channelApps['local_db']` entry at all (the
          // legacy `LocalDbChannel.addApp` was `unsupported`, so the export
          // never produced one). For the mapped `gstore` channel the catalog is
          // then the only source of real metadata: resolving it and writing via
          // `add` restores BOTH `channel_apps('gstore')` and the membership.
          // Other channels keep the membership-only path (no placeholder write).
          if (channel == 'gstore') {
            final catalog = await _catalogApp(a.appId);
            if (catalog != null) {
              await AddedAppsFacade.instance.add(
                channel,
                a.appId,
                sortOrder: a.sortOrder,
                appInfo: catalog,
              );
              if (!a.isEnabled) {
                // Same end state as the legacy toggle (membership row removed)
                // but without re-entering a metadata-writing add branch.
                await AddedAppsFacade.instance.remove(channel, a.appId);
              }
              continue;
            }
          }
          await AddedAppsFacade.instance.addMembership(
            channel,
            a.appId,
            sortOrder: a.sortOrder,
          );
          if (!a.isEnabled) {
            // Same end state as the legacy toggle (membership row removed) but
            // membership-only: `toggle` canonicalizes and could fall into its
            // metadata-writing add branch for a placeholder item.
            await AddedAppsFacade.instance.remove(channel, a.appId);
          }
          continue;
        }
        // 备份自带 appName/iconUrl：作为 appInfo 传给 facade，由 Rust
        // `LibraryService` 同一次调用恢复 channel_apps 元数据 + added_apps 引用，
        // 否则「恢复了首页却没恢复发现页」。js lane 由 Rust 脚本 driver 承接。
        //
        // 备份里的 name 为空/等于 appId 时查目录库补真实 name/icon；查不到就
        // 按原 summary 写入 —— 绝不因为缺元数据丢应用。
        final summary = _withBackupSource(
          await _withCatalogMetadata(AppSummary(
            appId: a.appId,
            name: a.appName.isNotEmpty ? a.appName : a.appId,
            user: '',
            repositories: '',
            icon: a.iconUrl ?? '',
            des: a.description ?? '',
            category: _splitBackupCategory(a.category),
          )),
          itemSourceId: a.sourceId,
          extra: _decodeBackupExtra(a.extra),
        );
        await AddedAppsFacade.instance.add(
          channel,
          a.appId,
          sortOrder: a.sortOrder,
          appInfo: summary,
        );
        if (!a.isEnabled) {
          // 核心 `add` 恒落 is_enabled=1；禁用项必须补一次 toggle 才能还原。
          await AddedAppsFacade.instance
              .toggle(channel, a.appId, appInfo: summary);
        }
      }
      appLog.info('BackupService: 成功插入 ${apps.length} 个应用到聚合数据库');

      // 打印插入的应用列表
      for (final app in apps) {
        debugPrint(
            'BackupService: 已插入 - ${_mapChannelId(app.channelId)}/${app.appId}');
      }
    } catch (e) {
      appLog.error('BackupService: 插入聚合数据库失败 - $e');
      rethrow;
    }
  }

  /// A backup `apps` item with no real metadata: `fromAddedAppInfo` writes
  /// `appName = appId` and nulls icon/description/category. Restoring such an
  /// item must only write membership, never `channel_apps`.
  bool _isReferenceOnlyBackupItem(BackupAppItem a) =>
      a.appName == a.appId &&
      (a.iconUrl == null || a.iconUrl!.isEmpty) &&
      a.description == null &&
      a.category == null;

  /// 备份的 `category` 是逗号分隔字符串；空/缺失 → null（不合成分类）。
  List<String>? _splitBackupCategory(String? raw) {
    if (raw == null) return null;
    final items = raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    return items.isEmpty ? null : items;
  }

  /// 旧备份里的本地库渠道 id 仍可能是 `local_db`。
  ///
  /// core 接管后本地库渠道由 `gstore` 承载：`local_db` 的 `add_app` 会返回
  /// `unsupported`（元数据被丢），成员关系也落在首页投影看不到的旧渠道。
  /// 恢复时统一把 `local_db` 映射到 `gstore`，其余 id 原样透传。
  static String _mapChannelId(String id) => id == 'local_db' ? 'gstore' : id;

  /// 元数据兜底：备份里的 name 为空或只是 appId 占位时，用目录库补真实
  /// name/icon/描述；目录库查不到（或查询失败）时返回原 summary。
  ///
  /// 调用方必须写入返回的 summary —— 缺失元数据绝不丢应用。
  Future<AppSummary> _withCatalogMetadata(AppSummary summary) async {
    if (summary.name.isNotEmpty && summary.name != summary.appId) {
      return summary;
    }
    final catalog = await _catalogApp(summary.appId);
    if (catalog == null) return summary;
    return summary.copyWith(
      packageName: catalog.packageName ?? summary.packageName,
      name: catalog.name.isNotEmpty ? catalog.name : summary.name,
      user: catalog.user.isNotEmpty ? catalog.user : summary.user,
      repositories:
          catalog.repositories.isNotEmpty ? catalog.repositories : summary.repositories,
      icon: catalog.icon.isNotEmpty ? catalog.icon : summary.icon,
      des: catalog.des.isNotEmpty ? catalog.des : summary.des,
      category: catalog.category ?? summary.category,
    );
  }

  /// 目录库查询（best-effort）：任何失败都降级为 null。
  Future<AppSummary?> _catalogApp(String appId) async {
    try {
      return await CatalogFacade.instance.getApp(appId);
    } catch (error) {
      appLog.warning('BackupService: 目录库补元数据失败 - $appId: $error');
      return null;
    }
  }

  /// 把备份 `channelApps` 段的元数据写入核心 `channel_apps`（**只写元数据**）。
  ///
  /// 非脚本渠道走 `ChannelManager.addAppByCode`（core 拥有渠道域时即
  /// `ChannelApi.addApp`）；脚本渠道走 `RustScriptChannelLane.addApp`。
  /// 不写 `added_apps` —— 成员关系已由 [_addAllAppsToAggregator] 恢复，这里只
  /// 负责让首页/发现页/详情能读到真实 name/icon。
  Future<({int restored, int failed})> _importChannelAppsToCore(
    Map<String, List<ChannelAppBackupItem>> channelAppsMap,
  ) async {
    var restored = 0;
    var failed = 0;
    final lane = RustScriptChannelLane.instance;
    for (final entry in channelAppsMap.entries) {
      // 旧备份把本地库渠道记成 `local_db`：写它只会命中不支持的旧驱动
      // （`add_app` → unsupported），元数据被丢。统一落到 `gstore`。
      final code = _mapChannelId(entry.key);
      final isLane = lane.enabled && lane.packFor(code) != null;
      for (final item in entry.value) {
        final summary = _withBackupSource(
          await _withCatalogMetadata(AppSummary(
            appId: item.appId,
            name: item.name.isNotEmpty ? item.name : item.appId,
            user: item.user,
            repositories: item.repositories,
            icon: item.icon,
            des: item.description,
            category: _splitBackupCategory(item.category),
            extra: _decodeBackupExtra(item.extra),
          )),
          itemSourceId: item.sourceId,
          extra: _decodeBackupExtra(item.extra),
        );
        try {
          if (isLane) {
            await lane.addApp(code, summary);
            restored++;
            continue;
          }
          final result =
              await ChannelManager.instance.addAppByCode(code, summary);
          if (result.success) {
            restored++;
          } else {
            failed++;
            appLog.warning(
                'BackupService: 恢复渠道元数据失败 - $code/${item.appId}: ${result.error}');
          }
        } catch (error) {
          failed++;
          appLog.error(
              'BackupService: 恢复渠道元数据失败 - $code/${item.appId}: $error');
        }
      }
    }
    appLog.info('BackupService: 渠道元数据导入完成 - 成功 $restored，失败 $failed');
    return (restored: restored, failed: failed);
  }

  /// 备份的 `extra` 是 JSON 字符串；非法/缺失 → null（不抛）。
  Map<String, dynamic>? _decodeBackupExtra(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// core 的 `ChannelAppInfo` 把记录所属源放在 `extraJson['sourceId']`。
  String? _sourceIdFromExtraJson(String? raw) {
    final value = _decodeBackupExtra(raw)?['sourceId']?.toString().trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 恢复时补齐记录所属的源，并让图标不再依赖 `source_id`。
  ///
  /// - `extra['sourceId']` 只在缺失时由备份项的 `sourceId` 补齐（不覆盖已有值）；
  /// - 旧备份存的是源**标识**（`fp:<HEX>`、`url:<url>`、源 id），而 Rust 驱动
  ///   只认同配置里的源 URL，能映射就先映射成 URL；
  /// - 图标是仓库内相对键（`icons/<pkg>.png`）时按该源解析成绝对地址，与
  ///   Rust `FdroidDriver::absolute_icon_url` 同语义。映射不到源时原样保留：
  ///   绝不猜源，也绝不因此丢应用。
  AppSummary _withBackupSource(
    AppSummary summary, {
    String? itemSourceId,
    Map<String, dynamic>? extra,
  }) {
    final merged = <String, dynamic>{...?extra};
    final fromExtra = merged['sourceId']?.toString().trim();
    final identity = (fromExtra != null && fromExtra.isNotEmpty)
        ? fromExtra
        : itemSourceId?.trim();
    if (identity == null || identity.isEmpty) {
      return merged.isEmpty ? summary : summary.copyWith(extra: merged);
    }
    final sourceUrl = _sourceUrlForIdentity(identity);
    merged['sourceId'] = sourceUrl ?? identity;
    return summary.copyWith(
      extra: merged,
      icon: sourceUrl == null
          ? summary.icon
          : _absoluteIcon(summary.icon, summary.appId, sourceUrl),
    );
  }

  /// 源标识 → 可路由的源 URL（旧标识交给 [FdroidRepoManager.resolveSourceUrl]
  /// 按读侧 `identityMatches` 的规则核对自己配置的源）。
  static String? _sourceUrlForIdentity(String identity) {
    final raw = identity.trim();
    if (raw.isEmpty) return null;
    if (_isHttpUrl(raw)) return _trimUrl(raw);
    if (raw.length > 4 && raw.substring(0, 4).toLowerCase() == 'url:') {
      final inner = raw.substring(4);
      if (_isHttpUrl(inner)) return _trimUrl(inner);
    }
    try {
      final url = FdroidRepoManager.instance.resolveSourceUrl(raw);
      return (url == null || url.isEmpty) ? null : _trimUrl(url);
    } catch (_) {
      return null;
    }
  }

  static bool _isHttpUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  /// 驱动的 `normalize_source` 语义：去首尾空白 + 去掉尾部 `/`。
  static String _trimUrl(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Rust `FdroidDriver::absolute_icon_url` 的等价物。
  static String _absoluteIcon(String icon, String appId, String sourceUrl) {
    if (icon.isEmpty) {
      return appId.isEmpty
          ? _trimUrl(sourceUrl)
          : _joinRepoUrl(sourceUrl, 'icons/$appId.png');
    }
    return _joinRepoUrl(sourceUrl, _repoAssetPath(icon));
  }

  /// Rust `normalize_repo_asset_path`：绝对地址原样保留，否则取最后一个
  /// `/repo/` 之后的部分并去掉前导 `/`。
  static String _repoAssetPath(String raw) {
    if (_isHttpUrl(raw)) return raw;
    var value = raw;
    final query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    final marker = value.lastIndexOf('/repo/');
    if (marker >= 0) value = value.substring(marker + '/repo/'.length);
    var start = 0;
    while (start < value.length && value.codeUnitAt(start) == 0x2F) {
      start++;
    }
    return value.substring(start);
  }

  /// Rust `join_repo_url`：绝对路径原样返回，空路径返回基址。
  static String _joinRepoUrl(String base, String path) {
    if (_isHttpUrl(path)) return path;
    final trimmedBase = _trimUrl(base);
    var start = 0;
    while (start < path.length && path.codeUnitAt(start) == 0x2F) {
      start++;
    }
    final trimmedPath = path.substring(start);
    return trimmedPath.isEmpty ? trimmedBase : '$trimmedBase/$trimmedPath';
  }

  /// 导入渠道数据库应用
  Future<void> _importChannelApps(
    Map<String, List<ChannelAppBackupItem>> channelAppsMap,
    BackupImportMode mode,
  ) async {
    await LegacyWriteGuard.assertAllowed('channel');
    appLog.info('BackupService: ========== 开始导入渠道数据库 ==========');
    debugPrint('BackupService: 渠道数量: ${channelAppsMap.length}');
    debugPrint('BackupService: 渠道列表: ${channelAppsMap.keys.toList()}');
    debugPrint('BackupService: 导入模式: $mode');

    if (channelAppsMap.isEmpty) {
      debugPrint('BackupService: ⚠️ channelAppsMap 为空，跳过导入');
      return;
    }

    for (final entry in channelAppsMap.entries) {
      final channelCode = entry.key;
      final backupItems = entry.value;

      try {
        debugPrint('BackupService: 处理渠道 $channelCode');
        debugPrint('BackupService: - 应用数量: ${backupItems.length}');

        if (backupItems.isEmpty) {
          debugPrint('BackupService: ⚠️ 渠道 $channelCode 没有应用数据');
          continue;
        }

        // 检查是否需要清空该渠道
        if (mode == BackupImportMode.replace) {
          final beforeCount = await _channelDb!.dao.getCountByChannel(channelCode);
          debugPrint('BackupService: - 清空前数量: $beforeCount');
          await _channelDb!.dao.clearChannel(channelCode);
          appLog.info('BackupService: - 已清空渠道 $channelCode');
        }

        // 转换并插入渠道应用
        final channelApps = backupItems
            .map((item) {
              debugPrint('BackupService: - 转换应用: ${item.appId}');
              debugPrint('BackupService:   - name: ${item.name}');
              debugPrint('BackupService:   - extra: ${item.extra}');
              return item.toChannelAddedApp();
            })
            .toList();

        debugPrint('BackupService: - 转换完成，准备插入 ${channelApps.length} 个应用');

        int insertedCount = 0;
        int skippedCount = 0;

        for (final app in channelApps) {
          if (mode == BackupImportMode.merge) {
            // 检查是否已存在
            final existing = await _channelDb!.dao.getApp(app.appId, channelCode);
            if (existing != null) {
              debugPrint('BackupService:   - 跳过已存在: ${app.appId}');
              skippedCount++;
              continue; // 跳过已存在的
            }
          }

          try {
            await _channelDb!.dao.insertApp(app);
            insertedCount++;
            appLog.info('BackupService:   - ✅ 插入成功: ${app.appId} (${app.name})');
          } catch (e) {
            appLog.error('BackupService:   - ❌ 插入失败: ${app.appId} - $e');
          }
        }

        // 验证导入结果
        final afterCount = await _channelDb!.dao.getCountByChannel(channelCode);
        appLog.info('BackupService: 渠道 $channelCode 导入完成');
        debugPrint('BackupService: - 插入: $insertedCount 个');
        debugPrint('BackupService: - 跳过: $skippedCount 个');
        debugPrint('BackupService: - 导入后总数: $afterCount');
      } catch (e, stackTrace) {
        appLog.error('BackupService: ❌ 导入渠道 $channelCode 失败 - $e');
        appLog.error('BackupService: 堆栈跟踪: $stackTrace');
      }
    }

    appLog.info('BackupService: ========== 渠道数据库导入完成 ==========');

    // 最终验证
    final totalCount = await _channelDb!.dao.getTotalCount();
    debugPrint('BackupService: 验证 - 渠道数据库当前总数: $totalCount');

    final allApps = await _channelDb!.dao.getAllApps();
    debugPrint('BackupService: 渠道数据库所有应用:');
    for (final app in allApps.take(10)) {
      debugPrint('BackupService:   - ${app.channelCode}/${app.appId} (${app.name})');
      debugPrint('BackupService:     extra: ${app.extra}');
    }
    if (allApps.length > 10) {
      debugPrint('BackupService:   ... 还有 ${allApps.length - 10} 个');
    }
  }

  // ==================== 辅助方法 ====================

  /// 支持的备份版本（v1.0 / v2.0 / v2.1）
  bool _isSupportedVersion(BackupVersion version) {
    return version == BackupVersion.v1_0 ||
        version == BackupVersion.v2_0 ||
        version == BackupVersion.v2_1;
  }

  /// 测试用：标记服务已初始化（跳过 initialize 的 path_provider 依赖）
  ///
  /// 运行时聚合读写走核心 [AddedAppsFacade]；旧 Floor 聚合库
  /// (`AppAddedDatabase`) 已删除，测试直接设 [AddedAppsFacade.backendOverride]
  /// 注入内存 backend，避免触碰 FRB/sqflite。
  @visibleForTesting
  void setTestInitialized() {
    _isInitialized = true;
  }

  /// 测试用：注入渠道数据库（跳过 initialize 的 path_provider 依赖）
  @visibleForTesting
  void setTestChannelDatabase(ChannelDatabase channelDb) {
    _channelDb = channelDb;
  }

  /// 测试注入：渠道包目录（跳过 path_provider 的 getApplicationDocumentsDirectory）
  @visibleForTesting
  Directory? debugChannelsDirectory;

  /// 测试注入：配置恢复使用的 Rust import 接缝（Todo 29）。
  ///
  /// 生产保持 null，由 [ConfigRestoreAdapter] 懒创建 `GeneratedConfigMigrationApi`。
  @visibleForTesting
  static ConfigMigrationApi? debugConfigRestoreApi;

  /// 最近一次配置恢复的逐键报告（仅测试/证据使用；不含值）。
  @visibleForTesting
  static ConfigRestoreReport? debugLastConfigRestoreReport;

  /// 复位配置恢复测试状态。
  @visibleForTesting
  static void debugResetConfigRestore() {
    debugConfigRestoreApi = null;
    debugLastConfigRestoreReport = null;
  }

  /// 唯一配置恢复路径（Todo 29 / C16）。
  ///
  /// 两个归档位置都交给 [ConfigRestoreAdapter]：`apps.json.appConfig`
  /// （内嵌于 [BackupData]）与独立 `app_config.json`。适配器负责
  /// legacy/grouped 映射与 grouped-wins，并逐键调用 Rust import 接缝。
  ///
  /// 语义保证：
  /// * 单键（甚至整个接缝）失败只记录/汇报，**绝不上抛**，因此不会中止
  ///   应用数据导入；
  /// * 进度日志只含 storageKey/wireKey/status/code，**绝不含配置值**。
  Future<void> _restoreBackupConfig({
    required Map<String, dynamic>? embeddedAppConfig,
    required Map<String, dynamic>? appConfigJson,
    BackupLogCallback? onLog,
  }) async {
    final hasEmbedded =
        embeddedAppConfig != null && embeddedAppConfig.isNotEmpty;
    final hasFile = appConfigJson != null && appConfigJson.isNotEmpty;
    if (!hasEmbedded && !hasFile) {
      debugPrint('BackupService: 备份中不包含应用配置');
      return;
    }

    final itemCount = _configRestoreItemCount(embeddedAppConfig, appConfigJson);
    appLog.info('BackupService: 开始恢复应用配置（$itemCount 项，adapter）');
    onLog?.call('开始导入应用配置（$itemCount 项）...');

    try {
      final adapter = ConfigRestoreAdapter(
        api: debugConfigRestoreApi ?? _DefaultConfigRestoreApi(),
      );
      final report = await adapter.restore(
        embeddedAppConfig: embeddedAppConfig,
        appConfigJson: appConfigJson,
      );
      debugLastConfigRestoreReport = report;

      for (final entry in report.entries) {
        final storageKey = entry.originalKey ?? entry.wireKey;
        final code = entry.code == null ? '' : ' code=${entry.code}';
        appLog.info(
          'BackupService: 配置恢复 storageKey=$storageKey '
          'wireKey=${entry.wireKey} status=${entry.status}$code',
        );
      }

      if (report.success) {
        appLog.info('BackupService: ✅ 应用配置恢复完成（${report.restored} 项）');
        onLog?.call('应用配置恢复完成（${report.restored} 项）');
      } else {
        final summary = report.failures.entries
            .take(5)
            .map((entry) => '${entry.key}(${entry.value})')
            .join(', ');
        appLog.error('BackupService: ⚠️ 应用配置恢复部分失败: $summary');
        onLog?.call('应用配置恢复部分失败: $summary', isError: true);
      }
    } catch (e, stackTrace) {
      // 接缝初始化/未知异常：汇报但不中止应用数据导入。
      appLog.error('BackupService: 导入应用配置失败: $e');
      appLog.error('BackupService: 堆栈跟踪: $stackTrace');
      onLog?.call('应用配置恢复失败: $e', isError: true);
    }
  }

  /// Counts config entries in both archive locations for the progress message.
  static int _configRestoreItemCount(
    Map<String, dynamic>? embedded,
    Map<String, dynamic>? file,
  ) {
    int countOf(Map<String, dynamic>? payload) {
      if (payload == null) return 0;
      final configs = payload['configs'];
      if (configs is Map) return configs.length;
      return payload.length;
    }

    return countOf(embedded) + countOf(file);
  }

  /// 解析渠道包目录（channels/*.zip 所在目录，与 ChannelLoader 约定一致）
  Future<Directory?> _resolveChannelsDirectory() async {
    try {
      final override = debugChannelsDirectory;
      if (override != null) return override;
      final docs = await getApplicationDocumentsDirectory();
      return Directory(path.join(docs.path, 'channels'));
    } catch (e) {
      appLog.error('BackupService: 解析渠道包目录失败 - $e');
      return null;
    }
  }

  /// 收集渠道包归档条目（channels/<fileName>.zip），供 tar.gz 导出。
  ///
  /// 读取渠道包目录下所有 *.zip（脚本渠道包 = entry.js + detail.js + meta.json + 图标），
  /// 以原始 zip 字节打入备份包（tar 原生二进制，无需 base64/解压重组）。
  Future<List<ArchiveFile>> buildChannelPackageArchiveFiles() async {
    final files = <ArchiveFile>[];
    try {
      final dir = await _resolveChannelsDirectory();
      if (dir == null || !await dir.exists()) return files;
      final zipFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in zipFiles) {
        final bytes = await file.readAsBytes();
        final name = file.uri.pathSegments.last;
        files.add(ArchiveFile('channels/$name', bytes.length, bytes));
        appLog.info('BackupService: 打包渠道包 $name (${bytes.length} bytes)');
      }
    } catch (e) {
      appLog.error('BackupService: 收集渠道包失败 - $e');
    }
    return files;
  }

  /// 恢复脚本渠道 zip 包：写入渠道包目录（`channels/` 条目名 → 取文件名），
  /// 随后重跑 [ChannelLoader.loadAndRegister] 重新注册（幂等：内容未变跳过、变化更新）。
  ///
  /// 返回恢复（写入）的渠道包数量。单包失败不阻塞其他；整个恢复失败仅记日志不抛
  /// （数据导入已完成，渠道包恢复失败不影响应用数据恢复的成败语义）。
  Future<int> _restoreChannelPackages(Map<String, List<int>> channelZipEntries) async {
    if (channelZipEntries.isEmpty) return 0;
    // 渠道包写回 + 重新注册属于渠道域：核心已拥有时 fail-closed，绝不落盘/注册。
    try {
      await LegacyWriteGuard.assertAllowed('channel');
    } on LegacyWriteBlocked catch (blocked) {
      final warning = CoreWriteBlockedWarning(
        domain: blocked.domain,
        operation: '_restoreChannelPackages',
        detail: 'channel pack restore refused; the Rust core owns this domain',
      );
      appLog.warning('BackupService: $warning');
      return 0;
    }
    try {
      final dir = await _resolveChannelsDirectory();
      if (dir == null) {
        appLog.error('BackupService: 无法解析渠道包目录，跳过渠道包恢复');
        return 0;
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 写入 zip（条目名 'channels/<name>.zip' → 只取文件名，防路径穿越）
      var restored = 0;
      for (final entry in channelZipEntries.entries) {
        final parts = entry.key.split('/');
        final fileName = parts.length == 2 ? parts[1] : entry.key;
        if (!fileName.endsWith('.zip') ||
            fileName.contains('..') ||
            fileName.contains('/')) {
          appLog.error('BackupService: 跳过非法渠道包文件名 - ${entry.key}');
          continue;
        }
        try {
          final file = File('${dir.path}/$fileName');
          await file.writeAsBytes(entry.value);
          restored++;
          appLog.info('BackupService: 渠道包已写回 - $fileName');
        } catch (e) {
          appLog.error('BackupService: 写入渠道包 $fileName 失败 - $e');
        }
      }

      // 重新注册（幂等；失败不阻塞——zip 已落盘，下次启动扫描同样会加载）
      if (restored > 0) {
        try {
          await ChannelLoader(directory: dir).loadAndRegister();
          appLog.info('BackupService: ✅ 渠道包重新注册完成（$restored 个）');
        } catch (e) {
          appLog.error('BackupService: 渠道包重新注册失败（zip 已落盘，重启会重新加载）- $e');
        }
      }
      return restored;
    } catch (e) {
      appLog.error('BackupService: 恢复渠道包失败 - $e');
      return 0;
    }
  }

  /// 获取默认导出目录
  Future<String> getDefaultExportDirectory() async {
    try {
      // 尝试获取外部存储目录（如 /storage/emulated/0/Download）
      if (Platform.isAndroid) {
        // Android: 使用 Download 目录
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (await downloadsDir.exists()) {
          final gstoreDir = Directory(path.join(downloadsDir.path, 'GStore'));
          if (!await gstoreDir.exists()) {
            await gstoreDir.create();
          }
          return gstoreDir.path;
        }

        // 备选方案：使用外部存储目录
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          return externalDir.path;
        }
      }

      // iOS 或其他平台：使用应用文档目录
      final docDir = await getApplicationDocumentsDirectory();
      return docDir.path;
    } catch (e) {
      appLog.error('BackupService: 获取默认导出目录失败 - $e');
      // 最后的备选方案：使用应用文档目录
      final docDir = await getApplicationDocumentsDirectory();
      return docDir.path;
    }
  }

  /// 获取所有备份文件
  Future<List<BackupFile>> getBackupFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final backupDir = Directory(path.join(directory.path, 'backups'));

    if (!await backupDir.exists()) {
      return [];
    }

    final files = await backupDir.list().toList();
    final backupFiles = <BackupFile>[];

    for (final file in files) {
      if (file is File) {
        final stat = await file.stat();
        final isCompressed = file.path.endsWith('.gz');

        backupFiles.add(BackupFile(
          path: file.path,
          name: path.basename(file.path),
          size: stat.size,
          modified: stat.modified,
          isCompressed: isCompressed,
        ));
      }
    }

    // 按修改时间倒序排列
    backupFiles.sort((a, b) => b.modified.compareTo(a.modified));
    return backupFiles;
  }

  /// 删除备份文件
  Future<void> deleteBackupFile(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
      appLog.info('BackupService: 已删除备份文件 - $filePath');
    }
  }

  /// 获取备份统计信息
  Future<BackupStatistics> getStatistics() async {
    if (!_isInitialized) await initialize();

    final allApps = await AddedAppsFacade.instance.list();

    final channelCounts = <String, int>{};
    var enabledCount = 0;
    var disabledCount = 0;

    for (final app in allApps) {
      channelCounts[app.channelId] = (channelCounts[app.channelId] ?? 0) + 1;
      if (app.isEnabled) {
        enabledCount++;
      } else {
        disabledCount++;
      }
    }

    return BackupStatistics(
      totalApps: allApps.length,
      enabledApps: enabledCount,
      disabledApps: disabledCount,
      channelCounts: channelCounts,
    );
  }
}

// ==================== 相关类定义 ====================

/// 导入模式
enum BackupImportMode {
  /// 替换模式：清空后导入
  replace,

  /// 合并模式：只添加不存在的
  merge,

  /// 更新模式：更新存在的，添加不存在的
  update,
}

/// 导入结果
class BackupImportResult {
  bool success = false;
  int totalCount = 0;
  int addedCount = 0;
  int skippedCount = 0;
  String? error;

  /// Typed warnings for writes refused by a Rust core marker
  /// (`CORE_E_WRITE_BLOCKED`); empty on a clean restore.
  final List<CoreWriteBlockedWarning> writeWarnings =
      <CoreWriteBlockedWarning>[];

  Map<String, dynamic> toJson() => {
    'success': success,
    'totalCount': totalCount,
    'addedCount': addedCount,
    'skippedCount': skippedCount,
    'error': error,
  };
}

/// 备份文件信息
class BackupFile {
  final String path;
  final String name;
  final int size;
  final DateTime modified;
  final bool isCompressed;

  BackupFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.isCompressed,
  });

  /// 格式化文件大小
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 备份统计信息
class BackupStatistics {
  final int totalApps;
  final int enabledApps;
  final int disabledApps;
  final Map<String, int> channelCounts;

  BackupStatistics({
    required this.totalApps,
    required this.enabledApps,
    required this.disabledApps,
    required this.channelCounts,
  });

  Map<String, dynamic> toJson() => {
    'totalApps': totalApps,
    'enabledApps': enabledApps,
    'disabledApps': disabledApps,
    'channelCounts': channelCounts,
  };
}

/// 备份异常
class BackupException implements Exception {
  final String message;
  BackupException(this.message);

  @override
  String toString() => message;
}

/// Default `ConfigMigrationApi` for [BackupService]'s restore path.
///
/// Production delegates straight to the generated Rust `ConfigApi.import_`
/// seam. The Flutter test host has no native library, so only there (when the
/// generated seam cannot even be created) it falls back to an in-memory
/// `ConfigService` bridge. That bridge is *not* a second restore flow: the
/// adapter still owns mapping/precedence and still reports per-key status; it
/// only substitutes the unavailable FFI transport so existing tests can assert
/// the restore outcome. Production never reaches the fallback because
/// `ConfigApi.init()` succeeds once the core is up, and any real import error
/// is reported by the adapter as a per-key failure.
class _DefaultConfigRestoreApi implements ConfigMigrationApi {
  ConfigMigrationApi? _delegate;

  Future<ConfigMigrationApi> _resolve() async {
    final existing = _delegate;
    if (existing != null) return existing;
    try {
      return _delegate = await GeneratedConfigMigrationApi.create();
    } catch (error) {
      if (Platform.environment['FLUTTER_TEST'] != 'true') rethrow;
      debugPrint(
        'BackupService: 原生 ConfigApi 不可用，使用测试内存配置接缝: $error',
      );
      return _delegate = _InMemoryConfigServiceRestoreApi();
    }
  }

  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    return (await _resolve()).importEntries(entries, source: source);
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(List<MigrationEntry> entries) async {
    return (await _resolve()).verifyEntries(entries);
  }

  @override
  Future<String?> getMeta(String key) async => (await _resolve()).getMeta(key);

  @override
  Future<void> setMeta(String key, String valueJson) async {
    await (await _resolve()).setMeta(key, valueJson);
  }
}

/// Test-only transport: applies imported entries through the `ConfigService`
/// test backend (which is itself an injected in-memory `ConfigApiClient`).
class _InMemoryConfigServiceRestoreApi implements ConfigMigrationApi {
  @override
  Future<MigrationImportResult> importEntries(
    List<MigrationEntry> entries, {
    required String source,
  }) async {
    final failed = <String, String>{};
    var applied = 0;
    for (final entry in entries) {
      final result = await ConfigService.instance.set(entry.wireKey, entry.value);
      if (result.success) {
        applied++;
      } else {
        failed[entry.wireKey] = 'config_import_failed';
      }
    }
    return MigrationImportResult(
      total: entries.length,
      applied: applied,
      unchanged: 0,
      eventsPublished: applied,
      failed: failed,
    );
  }

  @override
  Future<MigrationVerifyResult> verifyEntries(List<MigrationEntry> entries) =>
      throw UnimplementedError('verifyEntries is unused by backup restore');

  @override
  Future<String?> getMeta(String key) =>
      throw UnimplementedError('getMeta is unused by backup restore');

  @override
  Future<void> setMeta(String key, String valueJson) =>
      throw UnimplementedError('setMeta is unused by backup restore');
}
