import 'dart:async';
import 'dart:convert';

import '../model/download_task.dart';
import '../model/download_task_database.dart';
import '../model/download_task_entity.dart';

class DownloadRepository {
  final Map<int, StreamController<DownloadTask>> _watchers = {};

  Future<DownloadTask?> getByKey(String appId, String version, String fileName) async {
    final dao = (await downloadTaskDatabase).downloadTaskDao;
    final entity = await dao.getTaskByKey(appId, version, fileName);
    return entity == null ? null : _toTask(entity);
  }

  Future<DownloadTask?> getById(int id) async {
    final dao = (await downloadTaskDatabase).downloadTaskDao;
    final entity = await dao.getTask(id);
    return entity == null ? null : _toTask(entity);
  }

  Future<DownloadTask?> save(DownloadTask task) async {
    final dao = (await downloadTaskDatabase).downloadTaskDao;
    final entity = DownloadTaskEntity.fromTask(task);
    if (entity.id == null) {
      final id = await dao.insertTask(entity);
      final saved = task.copyWith(id: id);
      _push(id, saved);
      return saved;
    }
    await dao.updateTask(entity);
    final saved = task.copyWith(id: entity.id);
    _push(entity.id!, saved);
    return saved;
  }

  Future<List<DownloadTask>> all() async {
    final dao = (await downloadTaskDatabase).downloadTaskDao;
    final entities = await dao.getAllTasks();
    return entities.map(_toTask).toList();
  }

  Future<List<DownloadTask>> active() async {
    final tasks = await all();
    return tasks.where((task) => task.isActive).toList();
  }

  Stream<DownloadTask> watch(int id) {
    return _watchers
        .putIfAbsent(id, () => StreamController<DownloadTask>.broadcast())
        .stream;
  }

  void disposeId(int id) {
    _watchers.remove(id)?.close();
  }

  void _push(int id, DownloadTask task) {
    _watchers[id]?.add(task);
  }

  DownloadTask _toTask(DownloadTaskEntity entity) {
    try {
      return entity.toTask();
    } on RangeError {
      final status = DownloadStatusEnum.failed;
      return DownloadTask(
        id: entity.id,
        appId: entity.appId,
        appName: entity.appName,
        version: entity.version,
        fileName: entity.fileName,
        url: entity.url,
        filePath: entity.filePath,
        total: entity.total,
        received: entity.received,
        status: status,
        speedBps: entity.speedBps,
        etaSec: entity.etaSec,
        error: entity.error,
        segments: _decodeSegments(entity.segments),
        createdAt: DateTime.fromMillisecondsSinceEpoch(entity.createdAt),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(entity.updatedAt),
      );
    }
  }

  List<SegmentInfo>? _decodeSegments(String? raw) {
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => SegmentInfo.fromMap(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }
}