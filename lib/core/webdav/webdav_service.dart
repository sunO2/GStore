import 'dart:typed_data';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';

/// WebDAV 传输服务（纯传输层）
///
/// 依赖注入备份模块（[IBackupService]）：
/// - 上传：生成备份压缩包（备份模块）→ WebDavClient 传网盘
/// - 下载：WebDavClient 拉取压缩包 → 备份模块恢复
///
/// 任务防重复：经 [WebDavTaskManager]（tryStart 失败 → [BackupException]）。
/// [clientFactory] 可注入（测试用 mock client）。
class WebDavService implements IWebDavService {
  WebDavService(this._backup, {WebDavClient Function(WebDavConfig)? clientFactory})
      : _clientFactory = clientFactory ?? WebDavClient.new;

  static WebDavService? _instance;
  static WebDavService get instance {
    _instance ??= WebDavService(BackupService.instance);
    return _instance!;
  }

  final IBackupService _backup;
  final WebDavClient Function(WebDavConfig) _clientFactory;

  WebDavClient _client(WebDavConfig config) => _clientFactory(config);

  /// 测试 WebDAV 连接
  @override
  Future<bool> testWebDavConnection(WebDavConfig config) async {
    try {
      return await _client(config).testConnection();
    } catch (e) {
      appLog.error('WebDavService: WebDAV 连接测试失败 - $e');
      return false;
    }
  }

  /// 列出 WebDAV 目录文件（使用已保存的 WebDAV 配置）
  @override
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async {
    final config = await WebDavConfigManager.instance.loadConfig();
    if (config == null) return const [];
    return _client(config).listFiles(dirPath, pattern: pattern);
  }

  /// 上传备份到 WebDAV
  ///
  /// [config] WebDAV 配置
  /// [compressed] 是否压缩（保留参数，当前始终打包为 tar.gz）
  /// [options] 导出选项
  /// [channels] 指定导出的渠道
  /// [includeAppConfig] 是否包含应用配置
  @override
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async {
    appLog.info('WebDavService: 开始上传到 WebDAV');
    if (!WebDavTaskManager.instance.tryStart(WebDavTaskType.upload)) {
      throw BackupException('已有备份任务进行中，请稍候');
    }
    try {
      // 生成备份压缩包（备份模块）
      final uploadBytes = await _backup.exportCompressedBackup(
        options: options,
        channels: channels,
        includeAppConfig: includeAppConfig,
        onLog: onLog,
      );

      // 连接 WebDAV 并上传
      onLog?.call('连接 WebDAV 服务器...');
      final client = _client(config);

      // 确保备份目录存在
      await client.ensureDirectory(config.backupPath);

      // 生成文件名（统一格式）
      final timestamp =
          DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final fileName = 'gstore_backup_$timestamp.tar.gz';
      final remotePath = '${config.backupPath}/$fileName'.replaceAll('//', '/');

      // 上传文件
      await client.uploadFile(remotePath, uploadBytes);

      appLog.info('WebDavService: 上传到 WebDAV 成功 - $remotePath');
      onLog?.call('上传成功: $remotePath');
      return remotePath;
    } catch (e) {
      appLog.error('WebDavService: 上传到 WebDAV 失败 - $e');
      onLog?.call('上传失败: $e', isError: true);
      rethrow;
    } finally {
      WebDavTaskManager.instance.finish(WebDavTaskType.upload);
    }
  }

  /// 从 WebDAV 下载备份并导入
  ///
  /// [config] WebDAV 配置
  /// [remotePath] 远程文件路径
  /// [mode] 导入模式
  /// [restoreAppConfig] 是否恢复应用配置
  @override
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    appLog.info('WebDavService: 从 WebDAV 下载备份 - $remotePath');
    if (!WebDavTaskManager.instance.tryStart(WebDavTaskType.download)) {
      throw BackupException('已有备份任务进行中，请稍候');
    }
    try {
      // 创建 WebDAV 客户端
      final client = _client(config);

      // 下载文件
      onLog?.call('下载备份文件: $remotePath');
      final bytes = await client.downloadFile(remotePath);
      onLog?.call('下载完成（${bytes.length} 字节）');

      // 解压并恢复（备份模块）
      final result = await _backup.importBackupBytes(
        bytes,
        mode: mode,
        restoreAppConfig: restoreAppConfig,
        onLog: onLog,
      );
      return result;
    } catch (e) {
      appLog.error('WebDavService: 从 WebDAV 下载导入失败 - $e');
      onLog?.call('恢复失败: $e', isError: true);
      rethrow;
    } finally {
      WebDavTaskManager.instance.finish(WebDavTaskType.download);
    }
  }
}
