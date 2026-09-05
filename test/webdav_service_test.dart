import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/BackupData.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/webdav/webdav_service.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';

/// Fake IBackupService：仅实现 WebDAV 传输层依赖的两个方法
class FakeBackupService implements IBackupService {
  Uint8List? exportBytes;
  BackupImportResult? importResult;
  int exportCalls = 0;
  Uint8List? importedBytes;
  int importCalls = 0;

  @override
  Future<Uint8List> exportCompressedBackup({
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async {
    exportCalls++;
    return exportBytes ?? Uint8List(0);
  }

  @override
  Future<BackupImportResult> importBackupBytes(
    Uint8List bytes, {
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    importCalls++;
    importedBytes = bytes;
    return importResult ?? BackupImportResult();
  }

  @override
  Future<BackupData> exportData({BackupOptions? options}) =>
      throw UnimplementedError();

  @override
  Future<BackupImportResult> importFromFile(
    String filePath, {
    BackupImportMode mode = BackupImportMode.merge,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<BackupFile>> getBackupFiles() => throw UnimplementedError();

  @override
  Future<void> deleteBackupFile(String filePath) =>
      throw UnimplementedError();
}

/// Fake WebDavClient：记录上传字节 / 返回下载字节
class FakeWebDavClient extends WebDavClient {
  FakeWebDavClient(super.config);

  Uint8List? uploadedData;
  String? uploadedPath;
  Uint8List? downloadedBytes;
  bool ensureDirectoryThrows = false;

  @override
  Future<void> ensureDirectory(String dirPath) async {
    if (ensureDirectoryThrows) throw Exception('目录创建失败');
  }

  @override
  Future<String> uploadFile(String remotePath, Uint8List data,
      {int maxRetries = 3}) async {
    uploadedPath = remotePath;
    uploadedData = data;
    return remotePath;
  }

  @override
  Future<Uint8List> downloadFile(String remotePath) async =>
      downloadedBytes ?? Uint8List(0);

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async =>
      const [];
}

/// WebDavService 单测（mock IBackupService + mock clientFactory）
void main() {
  final config = WebDavConfig(
    url: 'http://example.com/dav',
    username: 'u',
    password: 'p',
    backupPath: '/GStore',
  );

  late FakeBackupService fakeBackup;
  late FakeWebDavClient fakeClient;
  late WebDavService service;

  setUp(() {
    fakeBackup = FakeBackupService();
    fakeClient = FakeWebDavClient(config);
    service = WebDavService(
      fakeBackup,
      clientFactory: (_) => fakeClient,
    );
  });

  tearDown(() {
    // 复位任务管理器单例
    WebDavTaskManager.instance.finish(WebDavTaskType.upload);
    WebDavTaskManager.instance.finish(WebDavTaskType.download);
  });

  group('uploadToWebDav', () {
    test('成功：调 exportCompressedBackup + uploadFile 收到 bytes，任务复位', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      fakeBackup.exportBytes = bytes;

      final remotePath = await service.uploadToWebDav(config: config);

      expect(fakeBackup.exportCalls, 1);
      expect(fakeClient.uploadedData, bytes);
      expect(fakeClient.uploadedPath, startsWith('/GStore/gstore_backup_'));
      expect(fakeClient.uploadedPath, endsWith('.tar.gz'));
      expect(remotePath, fakeClient.uploadedPath);
      expect(WebDavTaskManager.instance.isUploading, isFalse);
      expect(WebDavTaskManager.instance.isBusy, isFalse);
    });

    test('tryStart 拒绝（已有任务）时抛 BackupException', () async {
      WebDavTaskManager.instance.tryStart(WebDavTaskType.upload);

      await expectLater(
        service.uploadToWebDav(config: config),
        throwsA(isA<BackupException>()
            .having((e) => e.message, 'message', contains('进行中'))),
      );

      // 未进入导出/上传
      expect(fakeBackup.exportCalls, 0);
      expect(fakeClient.uploadedData, isNull);
      // 拒绝路径未污染任务状态（upload 仍由预置保持）
      expect(WebDavTaskManager.instance.isUploading, isTrue);
      WebDavTaskManager.instance.finish(WebDavTaskType.upload);
    });

    test('传输失败：finally 仍复位任务状态并 rethrow', () async {
      fakeClient.ensureDirectoryThrows = true;

      await expectLater(
        service.uploadToWebDav(config: config),
        throwsA(anything),
      );
      expect(WebDavTaskManager.instance.isUploading, isFalse);
      expect(WebDavTaskManager.instance.isBusy, isFalse);
    });
  });

  group('downloadFromWebDav', () {
    test('成功：调 importBackupBytes 收到下载字节，任务复位', () async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      fakeClient.downloadedBytes = bytes;
      final result = BackupImportResult()..success = true;
      fakeBackup.importResult = result;

      final ret = await service.downloadFromWebDav(
        config: config,
        remotePath: '/GStore/x.tar.gz',
      );

      expect(fakeBackup.importCalls, 1);
      expect(fakeBackup.importedBytes, bytes);
      expect(ret, same(result));
      expect(WebDavTaskManager.instance.isDownloading, isFalse);
      expect(WebDavTaskManager.instance.isBusy, isFalse);
    });

    test('tryStart 拒绝（同类型进行中）时抛 BackupException', () async {
      WebDavTaskManager.instance.tryStart(WebDavTaskType.download);

      await expectLater(
        service.downloadFromWebDav(
          config: config,
          remotePath: '/GStore/x.tar.gz',
        ),
        throwsA(isA<BackupException>()),
      );
      expect(fakeBackup.importCalls, 0);
    });

    test('testWebDavConnection 走注入 client', () async {
      expect(await service.testWebDavConnection(config), isTrue);
    });
  });
}
