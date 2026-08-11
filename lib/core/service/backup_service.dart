import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/config_backup.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// 备份服务
/// 负责导出和导入应用数据
class BackupService implements IBackupService, IWebDavService {
  static BackupService? _instance;
  static BackupService get instance {
    _instance ??= BackupService._internal();
    return _instance!;
  }

  BackupService._internal();

  late AppAddedDatabase _aggregatorDb;
  late ChannelDatabase _channelDb;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    // 初始化聚合数据库
    final aggregatorDb = await AppAddedDatabase.create();
    _aggregatorDb = aggregatorDb;

    // 初始化渠道数据库
    final channelDb = await ChannelDatabaseManager.instance;
    _channelDb = channelDb;

    _isInitialized = true;
    appLog.info('BackupService: 初始化成功');
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
    final targetChannels = channels ?? ChannelType.values;

    appLog.info('BackupService: 开始导出数据（包含渠道数据库）');
    if (includeAppConfig) {
      debugPrint('BackupService: 将包含应用配置（主题等）');
    }

    // 收集聚合数据库应用
    final allApps = <BackupAppItem>[];

    // 从聚合数据库获取应用
    final addedApps = await _aggregatorDb.addedAppDao.getAllAddedApps();

    for (final addedApp in addedApps) {
      // 过滤条件
      if (exportOptions.enabledOnly && !addedApp.isEnabled) {
        continue;
      }

      if (targetChannels.any((c) => c.code == addedApp.channelId)) {
        final backupItem = BackupAppItem.fromAddedAppInfo(
          addedApp,
          exportOptions,
        );
        allApps.add(backupItem);
      }
    }

    // 收集渠道数据库应用
    final channelAppsMap = <String, List<ChannelAppBackupItem>>{};

    for (final channel in targetChannels) {
      try {
        appLog.info('BackupService: 导出渠道 ${channel.name} 的数据');
        final channelApps = await _channelDb.dao.getAppsByChannel(channel.code);

        if (channelApps.isNotEmpty) {
          final backupItems = channelApps
              .map((app) => ChannelAppBackupItem.fromChannelAddedApp(app))
              .toList();
          channelAppsMap[channel.code] = backupItems;
          appLog.info('BackupService: ${channel.name} 渠道导出 ${backupItems.length} 个应用');

          // 更新聚合数据中的 extra 字段
          for (final backupItem in backupItems) {
            final existingApp = allApps.indexWhere((app) =>
              app.appId == backupItem.appId && app.channelId == channel.code);

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
        appLog.error('BackupService: 导出渠道 ${channel.name} 失败 - $e');
      }
    }

    // 导出应用配置（如果需要）
    Map<String, dynamic>? appConfig;
    if (includeAppConfig) {
      try {
        appLog.info('BackupService: 开始导出应用配置');
        final configManager = ConfigManager.instance;
        final configBackupData = await configManager.exportAll();

        // 将 ConfigBackupData 转换为 Map
        appConfig = configBackupData.toJson();
        appLog.info('BackupService: 应用配置导出完成 (共 ${appConfig.length} 项配置)');
      } catch (e) {
        appLog.error('BackupService: 导出应用配置失败 - $e');
      }
    }

    // 导出扩展数据（F-Droid 源、Agent 配置等）
    final extras = <String, dynamic>{};
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

    // 构建元数据
    final channelCounts = <String, int>{};
    for (final app in allApps) {
      channelCounts[app.channelId] = (channelCounts[app.channelId] ?? 0) + 1;
    }

    final metadata = BackupMetadata(
      version: BackupVersion.v2_0, // 使用 v2.0 版本
      exportDate: DateTime.now(),
      appVersion: '1.0.24',
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
    );

    appLog.info('BackupService: 导出完成 - ${allApps.length} 个聚合应用, ${channelAppsMap.length} 个渠道有额外数据${includeAppConfig ? ", 包含应用配置" : ""}, 扩展数据 ${extras.length} 类');
    return backupData;
  }

  /// 导出到文件
  ///
  /// [filePath] 文件路径
  /// [options] 导出选项
  /// [channels] 指定导出的渠道
  Future<String> exportToFile({
    String? filePath,
    BackupOptions? options,
    List<ChannelType>? channels,
  }) async {
    final backupData = await exportData(options: options, channels: channels);

    // 如果没有指定路径，使用默认路径
    final targetPath = filePath ?? await _getDefaultBackupPath();

    // 确保目录存在
    final directory = Directory(path.dirname(targetPath));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    // 转换为 JSON
    final jsonString = jsonEncode(backupData.toJson());

    // 写入文件
    final file = File(targetPath);
    await file.writeAsString(jsonString);

    appLog.info('BackupService: 已导出到 $targetPath');
    return targetPath;
  }

  /// 导出到压缩文件（gzip）
  ///
  /// [filePath] 文件路径
  /// [options] 导出选项
  /// [channels] 指定导出的渠道
  Future<String> exportToCompressedFile({
    String? filePath,
    BackupOptions? options,
    List<ChannelType>? channels,
  }) async {
    final backupData = await exportData(
      options: options?.copyWith(compressed: true),
      channels: channels,
    );

    // 如果没有指定路径，使用默认路径
    final targetPath = filePath ?? await _getDefaultBackupPath(compressed: true);

    // 确保目录存在
    final directory = Directory(path.dirname(targetPath));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    // 转换为 JSON
    final jsonString = jsonEncode(backupData.toJson());

    // 压缩并写入文件
    final bytes = utf8.encode(jsonString);
    final compressedBytes = gzip.encode(bytes);

    final file = File(targetPath);
    await file.writeAsBytes(compressedBytes);

    appLog.info('BackupService: 已导出到 $targetPath');
    return targetPath;
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
    if (backupData.metadata.version != BackupVersion.v1_0 &&
        backupData.metadata.version != BackupVersion.v2_0) {
      appLog.error('BackupService: ❌ 不支持的版本: ${backupData.metadata.version}');
      throw BackupException(
        '不支持的备份版本: ${backupData.metadata.version}',
      );
    }

    appLog.info('BackupService: ✅ 版本验证通过');
    appLog.info('BackupService: 开始导入数据...');

    // 如果有配置数据且需要恢复配置，则导入配置
    if (configData != null && restoreAppConfig) {
      appLog.info('BackupService: 开始导入应用配置，包含 ${configData.length} 项配置');
      try {
        // 确保配置管理器已初始化
        await ConfigInitializer.initialize();
        debugPrint('BackupService: ConfigManager 初始化完成，已注册 ${ConfigManager.instance.configKeys.length} 个配置');

        final configManager = ConfigManager.instance;
        final importSuccess = await configManager.importAll(
          ConfigBackupData.fromJson(configData),
        );
        if (importSuccess) {
          appLog.info('BackupService: ✅ 应用配置导入成功');
        } else {
          appLog.error('BackupService: ⚠️ 应用配置导入部分失败');
        }
      } catch (e, stackTrace) {
        appLog.error('BackupService: ⚠️ 导入应用配置失败: $e');
        appLog.error('BackupService: 堆栈跟踪: $stackTrace');
        // 配置导入失败不影响应用数据导入
      }
    } else if (configData != null && !restoreAppConfig) {
      debugPrint('BackupService: 跳过应用配置导入（用户未选择恢复配置）');
    }

    final result = await importData(backupData, mode: mode);

    appLog.info('BackupService: ========== 导入完成 ==========');
    appLog.info('BackupService: 成功: ${result.success}');
    debugPrint('BackupService: 总数: ${result.totalCount}');
    debugPrint('BackupService: 新增: ${result.addedCount}');
    debugPrint('BackupService: 跳过: ${result.skippedCount}');

    return result;
  }

  /// 导入数据
  ///
  /// [backupData] 备份数据
  /// [mode] 导入模式
  Future<BackupImportResult> importData(
    BackupData backupData, {
    BackupImportMode mode = BackupImportMode.merge,
  }) async {
    if (!_isInitialized) await initialize();

    final result = BackupImportResult();

    appLog.info('BackupService: ========== 开始导入数据 ==========');
    debugPrint('BackupService: 应用数量: ${backupData.apps.length}');
    debugPrint('BackupService: 版本: ${backupData.metadata.version}');
    debugPrint('BackupService: 渠道数据: ${backupData.channelApps.length} 个渠道');
    debugPrint('BackupService: 导入模式: $mode');

    try {
      // 验证版本
      if (backupData.metadata.version != BackupVersion.v1_0 &&
          backupData.metadata.version != BackupVersion.v2_0) {
        appLog.error('BackupService: ❌ 不支持的版本: ${backupData.metadata.version}');
        throw BackupException(
          '不支持的备份版本: ${backupData.metadata.version}',
        );
      }

      appLog.info('BackupService: ✅ 版本验证通过');

      // 根据导入模式处理聚合数据库
      switch (mode) {
        case BackupImportMode.replace:
          appLog.info('BackupService: 模式: REPLACE - 清空并重新添加');
          // 替换模式：先清空，再添加
          await _aggregatorDb.addedAppDao.clearAll();
          appLog.info('BackupService: 已清空聚合数据库');
          await _addAllAppsToAggregator(backupData.apps);
          break;

        case BackupImportMode.merge:
          appLog.info('BackupService: 模式: MERGE - 合并已存在的应用');
          // 合并模式：添加不存在的应用
          final existingApps = await _aggregatorDb.addedAppDao.getAllAddedApps();
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

      // 导入渠道数据库数据
      if (backupData.metadata.version == BackupVersion.v2_0 && backupData.channelApps.isNotEmpty) {
        appLog.info('BackupService: 开始导入渠道数据库数据（${backupData.channelApps.length} 个渠道）');
        await _importChannelApps(backupData.channelApps, mode);
      } else {
        debugPrint('BackupService: 无渠道数据需要导入（版本: ${backupData.metadata.version}, 渠道数: ${backupData.channelApps.length}）');
      }

      // 导入应用配置（如果存在）
      if (backupData.appConfig != null && backupData.appConfig!.isNotEmpty) {
        try {
          appLog.info('BackupService: 开始导入应用配置');
          debugPrint('BackupService: 配置项: ${backupData.appConfig!.keys.toList()}');

          final configManager = ConfigManager.instance;
          // 将 Map 转换为 ConfigBackupData
          final configBackupData = ConfigBackupData(
            version: 1, // 当前配置版本
            timestamp: DateTime.now(),
            appVersion: backupData.metadata.appVersion,
            configs: backupData.appConfig!,
          );

          final importSuccess = await configManager.importAll(configBackupData);
          if (importSuccess) {
            appLog.info('BackupService: ✅ 应用配置导入成功');
          } else {
            appLog.error('BackupService: ⚠️ 应用配置导入部分失败');
          }
        } catch (e) {
          appLog.error('BackupService: 导入应用配置失败 - $e');
          // 配置导入失败不影响应用导入
        }
      } else {
        debugPrint('BackupService: 备份中不包含应用配置');
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
      } else {
        debugPrint('BackupService: 备份中不包含扩展数据');
      }

      result.success = true;
      result.totalCount = backupData.apps.length;
      result.addedCount = backupData.apps.length - (result.skippedCount ?? 0);

      appLog.info('BackupService: ✅ 导入成功');
      debugPrint('BackupService: 总数: ${result.totalCount}, 新增: ${result.addedCount}, 跳过: ${result.skippedCount}');

      // 发送数据库变化事件，通知UI刷新
      appLog.info('BackupService: 📢 发送批量导入事件，通知UI刷新');
      DatabaseEventBus.instance.send(DatabaseChangeEvent(
        type: DatabaseChangeType.batchImport,
        data: {'totalCount': result.totalCount, 'addedCount': result.addedCount},
      ));

      // 验证导入结果
      final finalCount = await _aggregatorDb.addedAppDao.getTotalCount();
      debugPrint('BackupService: 验证 - 聚合数据库当前总数: $finalCount');

      // 打印导入的应用列表
      final importedApps = await _aggregatorDb.addedAppDao.getAllAddedApps();
      debugPrint('BackupService: 导入的应用列表:');
      for (final app in importedApps.take(10)) {
        debugPrint('BackupService:   - ${app.channelId}/${app.appId}');
      }
      if (importedApps.length > 10) {
        debugPrint('BackupService:   ... 还有 ${importedApps.length - 10} 个');
      }
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

  /// 批量添加应用到聚合数据库
  Future<void> _addAllAppsToAggregator(List<BackupAppItem> apps) async {
    debugPrint('BackupService: 开始添加 ${apps.length} 个应用到聚合数据库');

    final addedApps = apps.map((backupApp) {
      // 聚合库只存引用（v3），应用信息字段忽略，恢复后由渠道实时获取
      return AddedAppInfo(
        channelId: backupApp.channelId,
        appId: backupApp.appId,
        addTime: backupApp.addTime,
        sortOrder: backupApp.sortOrder,
        isEnabled: backupApp.isEnabled,
      );
    }).toList();

    try {
      await _aggregatorDb.addedAppDao.insertApps(addedApps);
      appLog.info('BackupService: 成功插入 ${addedApps.length} 个应用到聚合数据库');

      // 打印插入的应用列表
      for (final app in addedApps) {
        debugPrint('BackupService: 已插入 - ${app.channelId}/${app.appId}');
      }
    } catch (e) {
      appLog.error('BackupService: 插入聚合数据库失败 - $e');
      rethrow;
    }
  }

  /// 导入渠道数据库应用
  Future<void> _importChannelApps(
    Map<String, List<ChannelAppBackupItem>> channelAppsMap,
    BackupImportMode mode,
  ) async {
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
          final beforeCount = await _channelDb.dao.getCountByChannel(channelCode);
          debugPrint('BackupService: - 清空前数量: $beforeCount');
          await _channelDb.dao.clearChannel(channelCode);
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
            final existing = await _channelDb.dao.getApp(app.appId, channelCode);
            if (existing != null) {
              debugPrint('BackupService:   - 跳过已存在: ${app.appId}');
              skippedCount++;
              continue; // 跳过已存在的
            }
          }

          try {
            await _channelDb.dao.insertApp(app);
            insertedCount++;
            appLog.info('BackupService:   - ✅ 插入成功: ${app.appId} (${app.name})');
          } catch (e) {
            appLog.error('BackupService:   - ❌ 插入失败: ${app.appId} - $e');
          }
        }

        // 验证导入结果
        final afterCount = await _channelDb.dao.getCountByChannel(channelCode);
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
    final totalCount = await _channelDb.dao.getTotalCount();
    debugPrint('BackupService: 验证 - 渠道数据库当前总数: $totalCount');

    final allApps = await _channelDb.dao.getAllApps();
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

  /// 获取默认备份路径
  Future<String> _getDefaultBackupPath({bool compressed = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final backupDir = Directory(path.join(directory.path, 'backups'));

    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final extension = compressed ? '.json.gz' : '.json';
    final fileName = 'gstore_backup_$timestamp$extension';

    return path.join(backupDir.path, fileName);
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

  // ==================== WebDAV 功能 ====================

  /// 上传备份到 WebDAV
  ///
  /// [config] WebDAV 配置
  /// [compressed] 是否压缩
  /// [options] 导出选项
  /// [channels] 指定导出的渠道
  /// [includeAppConfig] 是否包含应用配置
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = false,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
  }) async {
    appLog.info('BackupService: 开始上传到 WebDAV');

    // 生成备份数据
    final backupData = await exportData(options: options, channels: channels);

    // 创建 Archive 对象
    final archive = Archive();

    // 添加 apps.json 到归档
    final appsJsonString = jsonEncode(backupData.toJson());
    final appsBytes = utf8.encode(appsJsonString);
    archive.addFile(ArchiveFile('apps.json', appsBytes.length, appsBytes));
    debugPrint('BackupService: apps.json 已添加 (${appsBytes.length} bytes)');

    // 检查是否需要包含应用配置
    if (includeAppConfig) {
      debugPrint('BackupService: 包含应用配置');
      try {
        // 确保配置管理器已初始化
        await ConfigInitializer.initialize();
        debugPrint('BackupService: ConfigManager 初始化完成，已注册 ${ConfigManager.instance.configKeys.length} 个配置');

        final configManager = ConfigManager.instance;
        final configBackup = await configManager.exportAll();

        appLog.info('BackupService: 应用配置导出成功，包含 ${configBackup.configs.length} 项配置');

        if (configBackup.configs.isNotEmpty) {
          // 添加 app_config.json 到归档
          final configJsonString = jsonEncode(configBackup.toJson());
          final configBytes = utf8.encode(configJsonString);
          archive.addFile(ArchiveFile('app_config.json', configBytes.length, configBytes));
          debugPrint('BackupService: app_config.json 已添加 (${configBytes.length} bytes)');

          // 打印配置键列表
          for (final key in configBackup.configs.keys) {
            debugPrint('BackupService:   - $key');
          }
        } else {
          debugPrint('BackupService: ⚠️ 配置为空，跳过 app_config.json');
        }
      } catch (e, stackTrace) {
        appLog.error('BackupService: 导出应用配置失败: $e');
        appLog.error('BackupService: 堆栈跟踪: $stackTrace');
      }
    }

    // 将 Archive 编码为 tar 字节
    final tarBytes = TarEncoder().encode(archive);

    // 使用 gzip 压缩
    final uploadBytes = Uint8List.fromList(gzip.encode(tarBytes));

    // 创建 WebDAV 客户端
    final client = WebDavClient(config);

    // 确保备份目录存在
    await client.ensureDirectory(config.backupPath);

    // 生成文件名（统一格式）
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final fileName = 'gstore_backup_$timestamp.tar.gz';
    final remotePath = '${config.backupPath}/$fileName'.replaceAll('//', '/');

    // 上传文件
    await client.uploadFile(remotePath, uploadBytes);

    appLog.info('BackupService: 上传到 WebDAV 成功 - $remotePath');
    return remotePath;
  }

  /// 从 WebDAV 下载备份并导入
  ///
  /// [config] WebDAV 配置
  /// [remotePath] 远程文件路径
  /// [mode] 导入模式
  /// [restoreAppConfig] 是否恢复应用配置
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
  }) async {
    appLog.info('BackupService: 从 WebDAV 下载备份 - $remotePath');
    debugPrint('BackupService: 恢复应用配置: $restoreAppConfig');

    // 创建 WebDAV 客户端
    final client = WebDavClient(config);

    // 下载文件
    final bytes = await client.downloadFile(remotePath);

    // 解压并解析
    String jsonString = '';
    Map<String, dynamic>? configData;

    debugPrint('BackupService: 检测到 tar.gz 格式');
    // 先用 gzip 解压
    final decompressedBytes = gzip.decode(bytes);
    // 再用 TarDecoder 解包
    final tarDecoder = TarDecoder();
    final archive = tarDecoder.decodeBytes(decompressedBytes);

    // 提取文件
    for (final archiveFile in archive.files) {
      if (archiveFile.name == 'apps.json') {
        final fileBytes = archiveFile.content as List<int>;
        jsonString = utf8.decode(fileBytes);
      } else if (archiveFile.name == 'app_config.json') {
        final fileBytes = archiveFile.content as List<int>;
        final configJsonString = utf8.decode(fileBytes);
        configData = jsonDecode(configJsonString) as Map<String, dynamic>;
      }
    }

    // 解析 JSON
    final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
    final backupData = BackupData.fromJson(jsonData);

    // 验证版本
    if (backupData.metadata.version != BackupVersion.v1_0 &&
        backupData.metadata.version != BackupVersion.v2_0) {
      throw BackupException(
        '不支持的备份版本: ${backupData.metadata.version}',
      );
    }

    // 如果有配置数据且需要恢复配置，则导入配置
    if (configData != null && restoreAppConfig) {
      appLog.info('BackupService: 开始导入应用配置，包含 ${configData.length} 项配置');
      try {
        // 确保配置管理器已初始化
        await ConfigInitializer.initialize();
        debugPrint('BackupService: ConfigManager 初始化完成，已注册 ${ConfigManager.instance.configKeys.length} 个配置');

        final configManager = ConfigManager.instance;
        await configManager.importAll(
          ConfigBackupData.fromJson(configData),
        );
        appLog.info('BackupService: 应用配置导入成功');
      } catch (e) {
        appLog.error('BackupService: 导入应用配置失败: $e');
      }
    } else if (configData != null && !restoreAppConfig) {
      debugPrint('BackupService: 跳过应用配置导入（用户未选择恢复配置）');
    }

    appLog.info('BackupService: 备份版本: ${backupData.metadata.version}, 开始导入');

    // 导入数据
    return importData(backupData, mode: mode);
  }

  /// 测试 WebDAV 连接
  Future<bool> testWebDavConnection(WebDavConfig config) async {
    try {
      final client = WebDavClient(config);
      return await client.testConnection();
    } catch (e) {
      appLog.error('BackupService: WebDAV 连接测试失败 - $e');
      return false;
    }
  }

  /// 列出 WebDAV 目录文件
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async {
    final config = await WebDavConfigManager.instance.loadConfig();
    if (config == null) return const [];
    final client = WebDavClient(config);
    return client.listFiles(dirPath, pattern: pattern);
  }

  /// 获取备份统计信息
  Future<BackupStatistics> getStatistics() async {
    if (!_isInitialized) await initialize();

    final allApps = await _aggregatorDb.addedAppDao.getAllAddedApps();

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
