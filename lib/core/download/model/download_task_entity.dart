import 'dart:convert';

import 'package:floor/floor.dart';
import 'package:gstore/core/download/model/download_task.dart';

@Entity()
class DownloadTaskEntity {
  @PrimaryKey(autoGenerate: true)
  final int? id;
  final String appId;
  final String appName;
  final String version;
  final String fileName;
  final String url;
  final String filePath;
  final int total;
  final int received;
  final int status;
  final int speedBps;
  final int? etaSec;
  final String? error;
  final String? segments;
  final int createdAt;
  final int updatedAt;

  const DownloadTaskEntity({
    this.id,
    required this.appId,
    required this.appName,
    required this.version,
    required this.fileName,
    required this.url,
    required this.filePath,
    required this.total,
    required this.received,
    required this.status,
    required this.speedBps,
    this.etaSec,
    this.error,
    this.segments,
    required this.createdAt,
    required this.updatedAt,
  });

  factory DownloadTaskEntity.fromTask(DownloadTask task) {
    return DownloadTaskEntity(
      id: task.id,
      appId: task.appId,
      appName: task.appName,
      version: task.version,
      fileName: task.fileName,
      url: task.url,
      filePath: task.filePath,
      total: task.total,
      received: task.received,
      status: task.status.index,
      speedBps: task.speedBps,
      etaSec: task.etaSec,
      error: task.error,
      segments: task.segments == null
          ? null
          : jsonEncode(task.segments!.map((s) => s.toMap()).toList()),
      createdAt: task.createdAt.millisecondsSinceEpoch,
      updatedAt: task.updatedAt.millisecondsSinceEpoch,
    );
  }

  DownloadTask toTask() {
    return DownloadTask(
      id: id,
      appId: appId,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      filePath: filePath,
      total: total,
      received: received,
      status: DownloadStatusEnum.values[status],
      speedBps: speedBps,
      etaSec: etaSec,
      error: error,
      segments: segments == null
          ? null
          : (jsonDecode(segments!) as List<dynamic>)
              .map((e) => SegmentInfo.fromMap(e as Map<String, dynamic>))
              .toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
    );
  }
}