import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/download/model/download_task_entity.dart';
import 'package:path/path.dart' as p;
// sqlite3 为 sqflite_common_ffi 传递依赖，仅用其 `open` 覆写动态库加载路径。
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 宿主环境 sqlite3 动态库是否可加载（仅影响 Floor 数据库用例）。
///
/// Floor 1.5 在 Linux/macOS 上自动选择 `sqflite_common_ffi` 工厂；Linux 常缺少
/// `libsqlite3.so` 符号链接，需要显式指定 `libsqlite3.so.0`。若本机连该库都没有，
/// 打开数据库会失败，此时 DB 用例标记 skip（纯 Dart 的实体映射用例不受影响）。
bool _sqliteReady = true;

void _initSqliteLibrary() {
  try {
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    } else if (Platform.isMacOS) {
      open.overrideFor(OperatingSystem.macOS,
          () => DynamicLibrary.open('libsqlite3.dylib'));
    }
    // Windows: sqflite_common_ffi 的 sqfliteFfiInit 会自动接管。
  } catch (_) {
    _sqliteReady = false;
  }
}

/// 组装一个覆盖全部字段（含 segments）的任务；时间戳用毫秒精度，
/// 保证经“毫秒 epoch → DateTime”往返后逐字段一致。
DownloadTask _sampleTask({int? id}) {
  final createdAt = DateTime(2026, 8, 30, 12, 0, 0, 123);
  final updatedAt = DateTime(2026, 8, 30, 12, 5, 30, 456);
  return DownloadTask(
    id: id,
    appId: 'com.example.hello',
    appName: 'Hello Example',
    version: '2.1.0',
    fileName: 'hello-2.1.0.apk',
    url: 'https://example.com/files/hello-2.1.0.apk',
    filePath: '/data/files/hello-2.1.0.apk',
    total: 10485760,
    received: 5242880,
    status: DownloadStatusEnum.downloading,
    speedBps: 20480,
    etaSec: 90,
    error: null,
    segments: [
      const SegmentInfo(
          index: 0, startByte: 0, endByte: 5242879, received: 5242880),
      const SegmentInfo(
          index: 1, startByte: 5242880, endByte: 10485759, received: 0),
    ],
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// 逐字段断言两个 DownloadTask 完全一致（list 依次为全部字段）。
void _expectSameTask(DownloadTask a, DownloadTask b) {
  expect(a.id, b.id, reason: 'id');
  expect(a.appId, b.appId, reason: 'appId');
  expect(a.appName, b.appName, reason: 'appName');
  expect(a.version, b.version, reason: 'version');
  expect(a.fileName, b.fileName, reason: 'fileName');
  expect(a.url, b.url, reason: 'url');
  expect(a.filePath, b.filePath, reason: 'filePath');
  expect(a.total, b.total, reason: 'total');
  expect(a.received, b.received, reason: 'received');
  expect(a.status, b.status, reason: 'status');
  expect(a.speedBps, b.speedBps, reason: 'speedBps');
  expect(a.etaSec, b.etaSec, reason: 'etaSec');
  expect(a.error, b.error, reason: 'error');

  final aSeg = a.segments;
  final bSeg = b.segments;
  if (aSeg == null || bSeg == null) {
    expect(aSeg, bSeg, reason: 'segments null 形态一致');
  } else {
    expect(
      aSeg.map((s) => s.toMap()).toList(),
      bSeg.map((s) => s.toMap()).toList(),
      reason: 'segments',
    );
  }

  expect(a.createdAt, b.createdAt, reason: 'createdAt');
  expect(a.updatedAt, b.updatedAt, reason: 'updatedAt');
}

Future<void> _deleteStoreFile() async {
  try {
    final path = p.join(
        await databaseFactoryFfi.getDatabasesPath(), 'download_task.db');
    await databaseFactoryFfi.deleteDatabase(path);
  } catch (_) {
    // 文件可能不存在，忽略
  }
}

void main() {
  _initSqliteLibrary();

  group('DownloadTaskEntity ↔ DownloadTask 映射（纯 Dart，始终可运行）', () {
    test('fromTask → toTask 逐字段还原', () {
      final task = _sampleTask(id: 7);
      final entity = DownloadTaskEntity.fromTask(task);
      final roundTrip = entity.toTask();
      _expectSameTask(roundTrip, task);
      expect(roundTrip.id, 7);
      expect(roundTrip.segments, isNotNull);
      expect(roundTrip.segments, hasLength(2));
      expect(entity.status, task.status.index);
      expect(entity.createdAt, task.createdAt.millisecondsSinceEpoch);
    });

    test('可选字段为 null（error/segments/etaSec）时 round-trip 保持 null', () {
      final task = _sampleTask(id: 9);
      final minimal = DownloadTask(
        id: task.id,
        appId: task.appId,
        appName: task.appName,
        version: task.version,
        fileName: task.fileName,
        url: task.url,
        filePath: task.filePath,
        total: task.total,
        received: 0,
        status: DownloadStatusEnum.failed,
        speedBps: 0,
        etaSec: null,
        error: 'download failed',
        segments: null,
        createdAt: task.createdAt,
        updatedAt: task.updatedAt,
      );
      final roundTrip = DownloadTaskEntity.fromTask(minimal).toTask();
      _expectSameTask(roundTrip, minimal);
      expect(roundTrip.segments, isNull);
      expect(roundTrip.etaSec, isNull);
      expect(roundTrip.error, 'download failed');
    });
  });

  group('Floor download_task.db（宿主环境受限）', () {
    tearDown(() async {
      await closeDownloadTaskDatabase();
      await _deleteStoreFile();
    });

    test('数据库可打开，DAO insert/update/query 一致', () async {
      if (!_sqliteReady) {
        markTestSkipped(
            '宿主环境缺少原生 sqlite3 动态库，跳过 Floor 数据库用例（sqflite_common_ffi）。');
        return;
      }

      GStoreDownloadDatabase db;
      try {
        db = await downloadTaskDatabase;
      } catch (e) {
        // 环境无法初始化 sqflite（缺 sqlite3 库 / ffi 初始化失败）时安全跳过。
        markTestSkipped('宿主环境无法打开 sqflite(Floor) 数据库: $e');
        return;
      }

      final dao = db.downloadTaskDao;
      final task = _sampleTask(id: null);
      try {
        final id = await dao.insertTask(DownloadTaskEntity.fromTask(task));
        expect(id, isPositive, reason: 'insertTask 应返回自增 id');

        final loaded = await dao.getTask(id);
        expect(loaded, isNotNull);
        final loadedTask = loaded!.toTask();
        expect(loadedTask.id, id);
        // 经 SQLite 列来回后应与内存任务一致（含 segments 的 JSON 存储）
        _expectSameTask(loadedTask, task.copyWith(id: id));

        // update：状态推进 + received 置满，再按业务键查询
        final completed = loadedTask.copyWith(
          id: id,
          received: loadedTask.total,
          status: DownloadStatusEnum.completed,
          speedBps: 0,
          etaSec: 0,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        await dao.updateTask(DownloadTaskEntity.fromTask(completed));
        final byKey = await dao.getTaskByKey(
            task.appId, task.version, task.fileName);
        expect(byKey, isNotNull);
        expect(byKey!.status, DownloadStatusEnum.completed.index);
        expect(byKey.received, task.total);

        expect(await dao.getAllTasks(), hasLength(1));
      } finally {
        await db.close();
        await closeDownloadTaskDatabase();
        await _deleteStoreFile();
      }
    });
  });
}