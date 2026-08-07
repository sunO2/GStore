import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:file_picker/file_picker.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/page/backup/state.dart';

class BackupLogic extends GetxController {
  final BackupState state = BackupState();
  final BackupService _backupService = BackupService.instance;

  @override
  void onInit() {
    super.onInit();
    _initialize();
  }

  /// 初始化
  Future<void> _initialize() async {
    try {
      appLog.info('BackupLogic: 开始初始化');
      await _backupService.initialize();
      appLog.info('BackupLogic: BackupService 初始化完成');
      await loadStatistics();
      await checkWebDavConfig();
      appLog.info('BackupLogic: 统计信息加载完成');
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 初始化失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '初始化失败: $e';
    }
  }

  /// 检查 WebDAV 配置
  Future<void> checkWebDavConfig() async {
    try {
      final hasConfig = await WebDavConfigManager.instance.hasConfig();
      state.hasWebDavConfig.value = hasConfig;
      debugPrint('BackupLogic: WebDAV 配置状态 - $hasConfig');

      // 如果有配置，测试连接
      if (hasConfig) {
        await testWebDavConnection();
      } else {
        state.webDavStatus.value = WebDavConnectionStatus.notConfigured;
      }
    } catch (e) {
      appLog.error('BackupLogic: 检查 WebDAV 配置失败 - $e');
      state.hasWebDavConfig.value = false;
      state.webDavStatus.value = WebDavConnectionStatus.notConfigured;
    }
  }

  /// 测试 WebDAV 连接
  Future<void> testWebDavConnection() async {
    try {
      state.webDavStatus.value = WebDavConnectionStatus.testing;

      final config = await WebDavConfigManager.instance.loadConfig();
      if (config == null) {
        state.webDavStatus.value = WebDavConnectionStatus.notConfigured;
        return;
      }

      final success = await _backupService.testWebDavConnection(config);

      if (success) {
        state.webDavStatus.value = WebDavConnectionStatus.connected;
        appLog.info('BackupLogic: WebDAV 连接测试成功');
      } else {
        state.webDavStatus.value = WebDavConnectionStatus.failed;
        appLog.error('BackupLogic: WebDAV 连接测试失败');
      }
    } catch (e) {
      appLog.error('BackupLogic: WebDAV 连接测试异常 - $e');
      state.webDavStatus.value = WebDavConnectionStatus.failed;
    }
  }

  /// 加载统计信息
  Future<void> loadStatistics() async {
    try {
      debugPrint('BackupLogic: 开始加载统计信息');
      final statistics = await _backupService.getStatistics();
      state.statistics.value = statistics;
      debugPrint('BackupLogic: 统计信息加载成功 - 总数: ${statistics.totalApps}');
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 加载统计信息失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      state.errorMessage.value = '加载统计信息失败: $e';
    }
  }

  /// 导出压缩备份（可选择是否包含应用配置）
  Future<void> exportCompressed(BuildContext context) async {
    try {
      appLog.info('BackupLogic: 开始导出压缩备份');
      state.isExporting.value = true;

      // 创建 Archive 对象
      final archive = Archive();

      // 先生成应用备份数据（使用用户配置的导出选项）
      debugPrint('BackupLogic: 正在生成应用备份数据...');
      final backupData = await _backupService.exportData(
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
      if (state.includeAppConfig.value) {
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

          if (context.mounted) {
            Get.snackbar(
              '提示',
              '导出应用配置失败，仅导出应用数据',
              duration: const Duration(seconds: 2),
              snackPosition: SnackPosition.BOTTOM,
            );
          }
        }
      } else {
        debugPrint('BackupLogic: 不包含应用配置');
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
      state.isExporting.value = false;

      if (context.mounted) {
        Get.snackbar(
          '导出失败',
          '导出数据失败: $e',
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
        );
      }
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
      state.isExporting.value = false;

      if (context.mounted) {
        Get.snackbar(
          '已取消',
          '您取消了导出操作',
          duration: const Duration(seconds: 2),
          snackPosition: SnackPosition.BOTTOM,
        );
      }
      return;
    }

    appLog.info('BackupLogic: 导出成功');
    state.isExporting.value = false;

    if (context.mounted) {
      Get.snackbar(
        '导出成功',
        '备份已保存到：$outputPath',
        duration: const Duration(seconds: 5),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// 切换是否包含应用配置
  void toggleIncludeAppConfig(bool value) {
    state.includeAppConfig.value = value;
  }

  /// 切换导出选项：图标 URL
  void toggleIncludeIconUrls(bool value) {
    state.includeIconUrls.value = value;
  }

  /// 切换导出选项：描述
  void toggleIncludeDescription(bool value) {
    state.includeDescription.value = value;
  }

  /// 切换导出选项：分类
  void toggleIncludeCategory(bool value) {
    state.includeCategory.value = value;
  }

  /// 切换导出选项：extra
  void toggleIncludeExtra(bool value) {
    state.includeExtra.value = value;
  }

  /// 切换导出选项：仅已启用
  void toggleEnabledOnly(bool value) {
    state.enabledOnly.value = value;
  }

  /// 构建导出选项
  BackupOptions _buildBackupOptions() {
    return BackupOptions(
      includeIconUrls: state.includeIconUrls.value,
      includeDescription: state.includeDescription.value,
      includeCategory: state.includeCategory.value,
      includeExtra: state.includeExtra.value,
      enabledOnly: state.enabledOnly.value,
      includeAppConfig: state.includeAppConfig.value,
    );
  }

  /// 切换是否恢复应用配置
  void toggleRestoreAppConfig(bool value) {
    state.restoreAppConfig.value = value;
  }

  /// 设置恢复模式
  void setRestoreMode(RestoreMode mode) {
    state.restoreMode.value = mode;
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
        if (context.mounted) {
          Get.snackbar(
            '文件路径错误',
            '无法获取选择的文件路径',
            duration: const Duration(seconds: 3),
          );
        }
        return;
      }

      debugPrint('BackupLogic: 选择的文件: $filePath');
      debugPrint('BackupLogic: 恢复模式: ${state.restoreMode.value}');
      await importFromFile(context, filePath);
    } catch (e) {
      appLog.error('BackupLogic: 选择文件失败 - $e');
      if (context.mounted) {
        Get.snackbar(
          '选择文件失败',
          '选择备份文件失败: $e',
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  /// 从文件导入
  Future<void> importFromFile(
    BuildContext context,
    String filePath,
  ) async {
    try {
      state.isImporting.value = true;

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
      final result = await _backupService.importFromFile(
        filePath,
        mode: _convertRestoreMode(state.restoreMode.value),
        restoreAppConfig: state.restoreAppConfig.value,
      );

      Navigator.pop(context); // 关闭进度对话框

      if (result.success) {
        state.isImporting.value = false;

        // 发送数据库变化事件
        DatabaseEventBus.instance.send(const DatabaseChangeEvent(
          type: DatabaseChangeType.batchImport,
        ));

        // 显示成功消息
        String message = '导入成功！已添加 ${result.addedCount} 个应用';
        if (result.skippedCount != null && result.skippedCount! > 0) {
          message += '，跳过 ${result.skippedCount} 个已存在的应用';
        }

        Get.snackbar(
          '导入成功',
          message,
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
        );

        // 刷新数据
        await loadStatistics();
      } else {
        state.isImporting.value = false;

        Get.snackbar(
          '导入失败',
          result.error ?? '未知错误',
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      state.isImporting.value = false;

      // 确保关闭对话框
      Navigator.of(context, rootNavigator: true).pop();

      Get.snackbar(
        '导入失败',
        '导入失败: $e',
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  // ==================== WebDAV 功能 ====================

  /// 上传到 WebDAV
  Future<void> uploadToWebDav(BuildContext context, {bool compressed = false}) async {
    try {
      appLog.info('BackupLogic: 开始上传到 WebDAV');
      state.isUploadingWebDav.value = true;

      // 检查配置
      final config = await WebDavConfigManager.instance.loadConfig();
      if (config == null) {
        Get.snackbar(
          '未配置',
          '请先配置 WebDAV 信息',
          duration: const Duration(seconds: 2),
          snackPosition: SnackPosition.BOTTOM,
        );
        state.isUploadingWebDav.value = false;
        return;
      }

      // 上传备份
      final remotePath = await _backupService.uploadToWebDav(
        config: config,
        compressed: compressed,
        includeAppConfig: state.includeAppConfig.value,
      );

      appLog.info('BackupLogic: 上传成功 - $remotePath');
      state.isUploadingWebDav.value = false;

      if (context.mounted) {
        Get.snackbar(
          '上传成功',
          '备份已上传到：${config.backupPath}',
          duration: const Duration(seconds: 5),
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.success.withOpacity(0.9),
          colorText: Colors.white,
        );
      }
    } catch (e, stackTrace) {
      appLog.error('BackupLogic: 上传失败 - $e');
      appLog.error('BackupLogic: 堆栈跟踪: $stackTrace');
      state.isUploadingWebDav.value = false;

      if (context.mounted) {
        Get.snackbar(
          '上传失败',
          '上传到 WebDAV 失败：$e',
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    }
  }

  /// 从 WebDAV 下载并导入
  Future<void> downloadFromWebDav(
    BuildContext context, {
    String? remotePath,
  }) async {
    try {
      appLog.info('BackupLogic: 从 WebDAV 下载备份');
      state.isImporting.value = true;

      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const PopScope(
          canPop: false,
          child: Center(
            child: AppLoading(size: AppLoadingSize.medium),
          ),
        ),
      );

      // 检查配置
      final config = await WebDavConfigManager.instance.loadConfig();
      if (config == null) {
        Navigator.pop(context);
        state.isImporting.value = false;

        Get.snackbar(
          '未配置',
          '请先配置 WebDAV 信息',
          duration: const Duration(seconds: 2),
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      // 如果没有指定路径，列出所有备份文件让用户选择
      // 生成当前时间戳的备份文件名
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      String targetPath = remotePath ?? '${config.backupPath}/gstore_backup_$timestamp.tar.gz';

      if (remotePath == null) {
        debugPrint('BackupLogic: 获取备份文件列表...');

        try {
          final client = WebDavClient(config);
          final files = await client.listFiles(
            config.backupPath,
            pattern: 'gstore_backup_*.tar.gz',
          );

          if (files.isEmpty) {
            Navigator.pop(context);
            state.isImporting.value = false;

            Get.snackbar(
              '未找到备份',
              '在 WebDAV 服务器上未找到备份文件',
              duration: const Duration(seconds: 2),
              snackPosition: SnackPosition.BOTTOM,
            );
            return;
          }

          // 按修改时间倒序排序（最新的在前）
          files.sort((a, b) => b.modified.compareTo(a.modified));

          debugPrint('BackupLogic: 找到 ${files.length} 个备份文件');

          // 关闭进度对话框
          Navigator.pop(context);

          // 显示文件选择对话框
          final selectedFile = await showDialog<WebDavFile>(
            context: context,
            builder: (context) => _BackupFileSelector(files: files),
          );

          // 如果用户取消选择
          if (selectedFile == null) {
            state.isImporting.value = false;
            debugPrint('BackupLogic: 用户取消选择备份文件');
            return;
          }

          targetPath = selectedFile.path;
          debugPrint('BackupLogic: 用户选择备份 - ${selectedFile.name} (${selectedFile.modified})');

          // 重新显示进度对话框
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const PopScope(
              canPop: false,
              child: Center(
                child: AppLoading(size: AppLoadingSize.medium),
              ),
            ),
          );
        } catch (e) {
          Navigator.pop(context);
          state.isImporting.value = false;

          appLog.error('BackupLogic: 获取备份列表失败: $e');

          Get.snackbar(
            '获取备份列表失败',
            e.toString(),
            duration: const Duration(seconds: 3),
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: AppColors.error.withOpacity(0.9),
            colorText: Colors.white,
          );
          return;
        }
      }

      // 下载并导入
      final result = await _backupService.downloadFromWebDav(
        config: config,
        remotePath: targetPath,
        mode: _convertRestoreMode(state.restoreMode.value),
        restoreAppConfig: state.restoreAppConfig.value,
      );

      Navigator.pop(context); // 关闭进度对话框

      if (result.success) {
        state.isImporting.value = false;

        // 发送数据库变化事件
        DatabaseEventBus.instance.send(const DatabaseChangeEvent(
          type: DatabaseChangeType.batchImport,
        ));

        // 显示成功消息 - 详细显示导入结果
        String message = '导入完成！\n';
        message += '总共: ${result.totalCount} 个应用\n';
        message += '新添加: ${result.addedCount} 个';
        if (result.skippedCount != null && result.skippedCount! > 0) {
          message += '\n已存在跳过: ${result.skippedCount} 个';
        }

        appLog.info('BackupLogic: 导入成功 - ${result.addedCount} 个新应用, ${result.skippedCount} 个已存在');

        Get.snackbar(
          '导入成功',
          message,
          duration: const Duration(seconds: 5),
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.success.withOpacity(0.9),
          colorText: Colors.white,
        );

        // 刷新数据
        await loadStatistics();
      } else {
        state.isImporting.value = false;

        Get.snackbar(
          '导入失败',
          result.error ?? '未知错误',
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      state.isImporting.value = false;

      // 确保关闭对话框
      Navigator.of(context, rootNavigator: true).pop();

      Get.snackbar(
        '导入失败',
        '从 WebDAV 导入失败：$e',
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  @override
  void onClose() {
    // TODO: implement dispose
    super.onClose();
  }
}

/// 备份文件选择对话框
class _BackupFileSelector extends StatelessWidget {
  final List<WebDavFile> files;

  const _BackupFileSelector({required this.files});

  String _formatDateTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allXL,
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: AppSpacing.allXL,
              child: Row(
                children: [
                  Icon(
                    Icons.backup,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      '选择备份文件',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: theme.colorScheme.outlineVariant.withOpacity(0.3),
            ),
            // 文件列表
            Flexible(
              child: ListView.separated(
                padding: AppSpacing.allLG,
                itemCount: files.length,
                separatorBuilder: (context, index) => SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) {
                  final file = files[index];
                  final isLatest = index == 0;

                  return _buildFileCard(context, file, isLatest, theme);
                },
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: theme.colorScheme.outlineVariant.withOpacity(0.3),
            ),
            // 底部按钮
            Padding(
              padding: AppSpacing.allXL,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: AppRadius.allSM,
                      ),
                      side: BorderSide(
                        color: theme.colorScheme.outline,
                        width: 1,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(
                        fontSize: AppTypography.sizeMD,
                        fontWeight: AppTypography.weightMedium,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileCard(BuildContext context, WebDavFile file, bool isLatest, ThemeData theme) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(file),
      borderRadius: AppRadius.allLG,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: AppRadius.allLG,
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Padding(
          padding: AppSpacing.allLG,
          child: Row(
            children: [
              // 图标
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.5),
                  borderRadius: AppRadius.allMD,
                ),
                child: Icon(
                  Icons.backup,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
              ),
              SizedBox(width: AppSpacing.md),
              // 文件信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 文件名和标签
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            file.name,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: AppTypography.weightMedium,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isLatest) ...[
                          SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.success.withOpacity(0.15),
                              borderRadius: AppRadius.allSM,
                              border: Border.all(
                                color: AppColors.success.withOpacity(0.5),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              '最新',
                              style: TextStyle(
                                fontSize: AppTypography.sizeXXS,
                                fontWeight: AppTypography.weightMedium,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: AppSpacing.xs),
                    // 时间和大小
                    Text(
                      '${_formatDateTime(file.modified)} · ${file.formattedSize}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              // 选择图标
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.outline,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
