import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/page/backup/state.dart';
import 'package:gstore/page/backup/widgets/backup_progress_sheet.dart';
import 'package:gstore/page/backup/widgets/backup_restore_sheet.dart';

/// 备份逻辑控制器（纯 Dart ChangeNotifier，非 GetX）。
///
/// 被 backup 页与 mine 页各自持有独立实例（导出选项/恢复模式互不共享），
/// 实例通过 [state] + [addListener] 驱动 UI 重建。
class BackupLogic extends ChangeNotifier {
  BackupLogic() {
    _initialize();
  }

  BackupState _state = const BackupState();

  /// 当前状态（不可变）。
  BackupState get state => _state;

  /// 更新状态并通知监听者。
  void _update(BackupState next) {
    _state = next;
    notifyListeners();
  }

  /// 备份服务（注册表注入：backup 模块下线时为 null → 本地备份/恢复功能软降级）。
  /// BackupModule 恒绑定 [BackupService.instance]（app_modules.dart），
  /// 故可安全收窄为具体类型以使用 initialize/getStatistics 等接口未覆盖的 API。
  final BackupService? _backupService =
      ModuleManager.instance.get<IBackupService>() as BackupService?;

  /// WebDAV 服务（注册表注入：webdav 模块下线时为 null → 相关功能软降级）
  final IWebDavService? _webdavService = ModuleManager.instance.get<IWebDavService>();

  /// 初始化
  Future<void> _initialize() async {
    try {
      appLog.info('BackupLogic: 开始初始化');
      final backup = _backupService;
      // backup 模块下线 → 跳过初始化（页面入口已隐藏/占位）
      if (backup == null) {
        appLog.info('BackupLogic: 备份模块未启用，跳过初始化');
        return;
      }
      await backup.initialize();
      appLog.info('BackupLogic: BackupService 初始化完成');
      await loadStatistics();
      await checkWebDavConfig();
      appLog.info('BackupLogic: 统计信息加载完成');
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 初始化失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      _update(_state.copyWith(errorMessage: '初始化失败: $e'));
    }
  }

  /// 检查 WebDAV 配置
  Future<void> checkWebDavConfig() async {
    // webdav 模块下线 → 降级为未配置（不读 secure storage）
    if (_webdavService == null) {
      _update(_state.copyWith(
        hasWebDavConfig: false,
        webDavStatus: WebDavConnectionStatus.notConfigured,
      ));
      return;
    }
    try {
      final hasConfig = await WebDavConfigManager.instance.hasConfig();
      debugPrint('BackupLogic: WebDAV 配置状态 - $hasConfig');

      // 如果有配置，测试连接
      if (hasConfig) {
        _update(_state.copyWith(hasWebDavConfig: true));
        await testWebDavConnection();
      } else {
        _update(_state.copyWith(
          hasWebDavConfig: false,
          webDavStatus: WebDavConnectionStatus.notConfigured,
        ));
      }
    } catch (e) {
      appLog.error('BackupLogic: 检查 WebDAV 配置失败 - $e');
      _update(_state.copyWith(
        hasWebDavConfig: false,
        webDavStatus: WebDavConnectionStatus.notConfigured,
      ));
    }
  }

  /// 测试 WebDAV 连接
  Future<void> testWebDavConnection() async {
    final webdav = _webdavService;
    // webdav 模块下线 → 降级为未配置
    if (webdav == null) {
      _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.notConfigured));
      return;
    }
    try {
      _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.testing));

      final config = await WebDavConfigManager.instance.loadConfig();
      if (config == null) {
        _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.notConfigured));
        return;
      }

      final success = await webdav.testWebDavConnection(config);

      if (success) {
        _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.connected));
        appLog.info('BackupLogic: WebDAV 连接测试成功');
      } else {
        _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.failed));
        appLog.error('BackupLogic: WebDAV 连接测试失败');
      }
    } catch (e) {
      appLog.error('BackupLogic: WebDAV 连接测试异常 - $e');
      _update(_state.copyWith(webDavStatus: WebDavConnectionStatus.failed));
    }
  }

  /// 加载统计信息
  Future<void> loadStatistics() async {
    final backup = _backupService;
    // backup 模块下线 → 不加载（保持现状，页面入口已隐藏/占位）
    if (backup == null) return;
    try {
      debugPrint('BackupLogic: 开始加载统计信息');
      final statistics = await backup.getStatistics();
      _update(_state.copyWith(statistics: statistics));
      debugPrint('BackupLogic: 统计信息加载成功 - 总数: ${statistics.totalApps}');
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 加载统计信息失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      _update(_state.copyWith(errorMessage: '加载统计信息失败: $e'));
    }
  }

  /// 导出压缩备份（可选择是否包含应用配置）
  Future<void> exportCompressed(BuildContext context) async {
    final backup = _backupService;
    // backup 模块下线 → 短路提示，不发起导出
    if (backup == null) {
      if (context.mounted) AppDialogs.showWarning('备份模块未启用');
      return;
    }
    try {
      appLog.info('BackupLogic: 开始导出压缩备份');
      _update(_state.copyWith(isExporting: true));

      // 创建 Archive 对象
      final archive = Archive();

      // 先生成应用备份数据（使用用户配置的导出选项）
      debugPrint('BackupLogic: 正在生成应用备份数据...');
      final backupData = await backup.exportData(
        options: _buildBackupOptions(),
      );

      // 移除 appConfig 字段（如果存在），因为我们将配置单独保存
      final appsData = backupData.appConfig != null
          ? backupData.copyWith(appConfig: null)
          : backupData;

      // 添加 apps.json 到归档
      final appsJsonString = jsonEncode(appsData.toJson());
      final appsBytes = utf8.encode(appsJsonString);
      archive.addFile(ArchiveFile('apps.json', appsBytes.length, appsBytes));
      debugPrint('BackupLogic: apps.json 已添加 (${appsBytes.length} bytes)');

      // 检查是否需要包含应用配置
      if (_state.includeAppConfig) {
        debugPrint('BackupLogic: 包含应用配置');
        try {
          // 确保配置管理器已初始化
          await ConfigInitializer.initialize();
          debugPrint('BackupLogic: ConfigManager 初始化完成，已注册 ${ConfigManager.instance.configKeys.length} 个配置');

          final configManager = ConfigManager.instance;
          final configBackup = await configManager.exportAll();

          appLog.info('BackupLogic: 应用配置导出成功，包含 ${configBackup.configs.length} 项配置');

          if (configBackup.configs.isEmpty) {
            debugPrint('BackupLogic: ⚠️ 配置为空，跳过 app_config.json');
          } else {
            // 添加 app_config.json 到归档
            final configJsonString = jsonEncode(configBackup.toJson());
            final configBytes = utf8.encode(configJsonString);
            archive.addFile(ArchiveFile('app_config.json', configBytes.length, configBytes));
            debugPrint('BackupLogic: app_config.json 已添加 (${configBytes.length} bytes)');

            // 打印配置键列表
            for (final key in configBackup.configs.keys) {
              debugPrint('BackupLogic:   - $key');
            }
          }
        } catch (e, stackTrace) {
          appLog.error('BackupLogic: 导出应用配置失败: $e');
          appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
          AppDialogs.showWarning('导出应用配置失败，仅导出应用数据');
        }
      } else {
        debugPrint('BackupLogic: 不包含应用配置');
      }

      // 渠道包（脚本渠道 zip 原样打包进 tar.gz，无需 base64）
      try {
        final channelFiles = await _backupService?.buildChannelPackageArchiveFiles() ?? const [];
        for (final entry in channelFiles) {
          archive.addFile(entry);
          debugPrint('BackupLogic: channels 条目已添加 ${entry.name}');
        }
        if (channelFiles.isNotEmpty) {
          debugPrint('BackupLogic: 渠道包 ${channelFiles.length} 个已打包');
        }
      } catch (e) {
        appLog.error('BackupLogic: 收集渠道包失败（不影响应用数据导出）- $e');
      }

      // 将 Archive 编码为 tar 字节
      final tarBytes = TarEncoder().encode(archive);

      // 使用 gzip 压缩
      final compressedBytes = gzip.encode(tarBytes);

      debugPrint('BackupLogic: 压缩完成: ${tarBytes.length} -> ${compressedBytes.length} bytes (${((1 - compressedBytes.length / tarBytes.length) * 100).toStringAsFixed(1)}% 压缩率)');

      await _saveCompressedBackup(context, Uint8List.fromList(compressedBytes), tarBytes.length);
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 导出失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      _update(_state.copyWith(isExporting: false));
      AppDialogs.showError('导出数据失败: $e', title: '导出失败');
    }
  }

  /// 保存压缩备份文件
  Future<void> _saveCompressedBackup(
    BuildContext context,
    Uint8List compressedBytes,
    int originalSize,
  ) async {
    // 生成文件名（统一格式）
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final fileName = 'gstore_backup_$timestamp.tar.gz';

    debugPrint('BackupLogic: 数据生成完成，准备保存文件: $fileName (${compressedBytes.length} bytes, 压缩率: ${((1 - compressedBytes.length / originalSize) * 100).toStringAsFixed(1)}%)');

    // 使用 FilePicker 保存文件（需要传入数据）
    String? outputPath;

    try {
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存压缩备份文件',
        fileName: fileName,
        lockParentWindow: true,
        type: FileType.custom,
        allowedExtensions: ['tar.gz'],
        bytes: compressedBytes,
      );
      debugPrint('BackupLogic: 文件保存路径: $outputPath');
    } catch (e) {
      appLog.error('BackupLogic: FilePicker.saveFile 失败: $e');
    }

    // 如果用户取消选择，提示用户
    if (outputPath == null || outputPath.isEmpty) {
      debugPrint('BackupLogic: 用户取消选择或文件选择器返回空路径');
      _update(_state.copyWith(isExporting: false));
      AppDialogs.showSnackbar('您取消了导出操作', title: '已取消');
      return;
    }

    appLog.info('BackupLogic: 导出成功');
    _update(_state.copyWith(isExporting: false));
    AppDialogs.showSuccess('备份已保存到：$outputPath', title: '导出成功');
  }

  /// 切换是否包含应用配置
  void toggleIncludeAppConfig(bool value) {
    _update(_state.copyWith(includeAppConfig: value));
  }

  /// 切换导出选项：图标 URL
  void toggleIncludeIconUrls(bool value) {
    _update(_state.copyWith(includeIconUrls: value));
  }

  /// 切换导出选项：描述
  void toggleIncludeDescription(bool value) {
    _update(_state.copyWith(includeDescription: value));
  }

  /// 切换导出选项：分类
  void toggleIncludeCategory(bool value) {
    _update(_state.copyWith(includeCategory: value));
  }

  /// 切换导出选项：extra
  void toggleIncludeExtra(bool value) {
    _update(_state.copyWith(includeExtra: value));
  }

  /// 切换导出选项：仅已启用
  void toggleEnabledOnly(bool value) {
    _update(_state.copyWith(enabledOnly: value));
  }

  /// 构建导出选项
  BackupOptions _buildBackupOptions() {
    return BackupOptions(
      includeIconUrls: _state.includeIconUrls,
      includeDescription: _state.includeDescription,
      includeCategory: _state.includeCategory,
      includeExtra: _state.includeExtra,
      enabledOnly: _state.enabledOnly,
      includeAppConfig: _state.includeAppConfig,
    );
  }

  /// 切换是否恢复应用配置
  void toggleRestoreAppConfig(bool value) {
    _update(_state.copyWith(restoreAppConfig: value));
  }

  /// 设置恢复模式
  void setRestoreMode(RestoreMode mode) {
    _update(_state.copyWith(restoreMode: mode));
  }

  /// 将 RestoreMode 转换为 BackupImportMode
  BackupImportMode _convertRestoreMode(RestoreMode mode) {
    switch (mode) {
      case RestoreMode.replace:
        return BackupImportMode.replace;
      case RestoreMode.merge:
        return BackupImportMode.merge;
      case RestoreMode.update:
        return BackupImportMode.update;
    }
  }

  /// 选择并导入文件
  Future<void> selectAndImportFile(BuildContext context) async {
    // backup 模块下线 → 短路提示，不打开文件选择器
    if (_backupService == null) {
      if (context.mounted) AppDialogs.showWarning('备份模块未启用');
      return;
    }
    try {
      debugPrint('BackupLogic: 开始选择导入文件');

      // 使用 FilePicker 选择文件（使用 SAF，不需要权限）
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gz'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        debugPrint('BackupLogic: 用户取消选择文件');
        return;
      }

      final filePath = result.files.single.path;
      if (filePath == null) {
        appLog.error('BackupLogic: 无法获取文件路径');
        AppDialogs.showError('无法获取选择的文件路径', title: '文件路径错误');
        return;
      }

      debugPrint('BackupLogic: 选择的文件: $filePath');
      debugPrint('BackupLogic: 恢复模式: ${_state.restoreMode}');
      await importFromFile(context, filePath);
    } catch (e) {
      appLog.error('BackupLogic: 选择文件失败 - $e');
      AppDialogs.showError('选择备份文件失败: $e', title: '选择文件失败');
    }
  }

  /// 从文件导入
  Future<void> importFromFile(
    BuildContext context,
    String filePath,
  ) async {
    final backup = _backupService;
    // backup 模块下线 → 短路提示，不发起恢复
    if (backup == null) {
      if (context.mounted) AppDialogs.showWarning('备份模块未启用');
      return;
    }
    try {
      _update(_state.copyWith(isImporting: true));

      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: const Center(
            child: AppLoading(size: AppLoadingSize.medium),
          ),
        ),
      );

      // 使用 state 中的恢复模式
      final result = await backup.importFromFile(
        filePath,
        mode: _convertRestoreMode(_state.restoreMode),
        restoreAppConfig: _state.restoreAppConfig,
      );

      Navigator.pop(context); // 关闭进度对话框

      if (result.success) {
        _update(_state.copyWith(isImporting: false));

        // 发送数据库变化事件
        DatabaseEventBus.instance.send(const DatabaseChangeEvent(
          type: DatabaseChangeType.batchImport,
        ));

        // 显示成功消息
        String message = '导入成功！已添加 ${result.addedCount} 个应用';
        if (result.skippedCount != null && result.skippedCount! > 0) {
          message += '，跳过 ${result.skippedCount} 个已存在的应用';
        }

        AppDialogs.showSuccess(message, title: '导入成功');

        // 刷新数据
        await loadStatistics();
      } else {
        _update(_state.copyWith(isImporting: false));
        AppDialogs.showError(result.error ?? '未知错误', title: '导入失败');
      }
    } catch (e) {
      _update(_state.copyWith(isImporting: false));

      // 确保关闭对话框
      Navigator.of(context, rootNavigator: true).pop();

      AppDialogs.showError('导入失败: $e', title: '导入失败');
    }
  }

  // ==================== WebDAV 功能 ====================

  /// 上传到 WebDAV（进度面板：日志流式输出）
  Future<void> uploadToWebDav(BuildContext context, {bool compressed = false}) async {
    final webdav = _webdavService;
    // webdav 模块下线 → 降级提示，不发起上传
    if (webdav == null) {
      AppDialogs.showWarning('WebDAV 模块未启用');
      return;
    }
    appLog.info('BackupLogic: 开始上传到 WebDAV');

    // 同步检查：已有备份/恢复任务进行中则不重复触发
    // （经注册表取实现，webdav 模块下线时降级为不忙）
    if (ModuleManager.instance.get<IWebDavTaskManager>()?.isBusy ?? false) {
      AppDialogs.showWarning('备份/恢复任务进行中，请稍候');
      return;
    }

    // 打开进度面板（config 加载移入面板 task 内，点击立即弹面板；
    // isUploadingWebDav 保持 true 使源按钮禁用，防止重复触发）
    _update(_state.copyWith(isUploadingWebDav: true));
    try {
      await showModalBottomSheet<bool>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        isScrollControlled: true,
        builder: (_) => BackupProgressSheet(
          title: '备份到网盘',
          task: (onLog) async {
            onLog('加载 WebDAV 配置...');
            final config = await WebDavConfigManager.instance.loadConfig();
            if (config == null) {
              onLog('未配置 WebDAV 信息', isError: true);
              throw BackupException('未配置 WebDAV 信息');
            }
            onLog('配置加载成功');
            await webdav.uploadToWebDav(
              config: config,
              compressed: compressed,
              includeAppConfig: _state.includeAppConfig,
              onLog: onLog,
            );
          },
        ),
      );
    } finally {
      _update(_state.copyWith(isUploadingWebDav: false));
    }
  }

  /// 从 WebDAV 下载并导入（单面板三阶段：加载配置/列文件 → 选择 → 恢复）
  Future<void> downloadFromWebDav(BuildContext context) async {
    final webdav = _webdavService;
    // webdav 模块下线 → 降级提示，不发起下载
    if (webdav == null) {
      AppDialogs.showWarning('WebDAV 模块未启用');
      return;
    }
    appLog.info('BackupLogic: 从 WebDAV 下载备份');

    // 同步检查：已有备份/恢复任务进行中则不重复触发
    // （经注册表取实现，webdav 模块下线时降级为不忙）
    if (ModuleManager.instance.get<IWebDavTaskManager>()?.isBusy ?? false) {
      AppDialogs.showWarning('备份/恢复任务进行中，请稍候');
      return;
    }

    // 打开恢复面板（面板内：阶段1 加载配置+列文件 → 阶段2 选择 →
    // 阶段3 恢复；isImporting 保持 true 防重复触发）
    _update(_state.copyWith(isImporting: true));
    try {
      final success = await showModalBottomSheet<bool>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        isScrollControlled: true,
        builder: (_) => BackupRestoreSheet(
          title: '从网盘恢复备份',
          prepareTask: (onLog) async {
            onLog('加载 WebDAV 配置...');
            final config = await WebDavConfigManager.instance.loadConfig();
            if (config == null) {
              onLog('未配置 WebDAV 信息', isError: true);
              throw BackupException('未配置 WebDAV 信息');
            }
            onLog('连接 WebDAV...');
            final files = await webdav.listFiles(
              config.backupPath,
              pattern: 'gstore_backup_*.tar.gz',
            );
            // 按修改时间倒序排序（最新的在前）
            files.sort((a, b) => b.modified.compareTo(a.modified));
            onLog('找到 ${files.length} 个备份文件');
            return files;
          },
          restoreTask: (file, onLog) async {
            final config = await WebDavConfigManager.instance.loadConfig();
            if (config == null) throw BackupException('未配置 WebDAV 信息');
            await webdav.downloadFromWebDav(
              config: config,
              remotePath: file.path,
              mode: _convertRestoreMode(_state.restoreMode),
              restoreAppConfig: _state.restoreAppConfig,
              onLog: onLog,
            );
          },
        ),
      );

      // 面板关闭后：成功才刷新数据（失败/关闭不触发）
      if (success == true) {
        // 发送数据库变化事件
        DatabaseEventBus.instance.send(const DatabaseChangeEvent(
          type: DatabaseChangeType.batchImport,
        ));
        await loadStatistics();
      }
    } finally {
      _update(_state.copyWith(isImporting: false));
    }
  }
}
