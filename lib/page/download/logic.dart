import 'dart:io';

import 'package:app_installer/app_installer.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/core/service/downloadService.dart';

import 'state.dart';

/// 下载筛选类型
enum DownloadFilter {
  /// 全部
  all,
  /// 下载中
  downloading,
  /// 已完成
  completed,
  /// 失败
  failed,
}

class DownloadManagerLogic extends GetxController with GithubRequestMix {
  final DownloadManagerState state = DownloadManagerState();
  final Future<DownloadDatabase> database = downloadStatusDatabase;
  final AppInfoDatabase appInfoDB = "gstore".repoDB.db;
  final StreamController<List<List<DownloadStatus>>> controller =
      StreamController();

  /// 当前筛选类型
  final Rx<DownloadFilter> currentFilter = DownloadFilter.all.obs;

  @override
  void onReady() async {
    _initDownloadStream();
    super.onReady();
  }

  /// 初始化下载流
  void _initDownloadStream() async {
    var db = await database;
    var downloadList = db.downloadStatusDao.getAllDownload();
    downloadList.listen((items) {
      var map = <String, List<DownloadStatus>>{};
      for (var item in items) {
        var key = "${item.appId}_${item.version}";
        var list = map[key] ??= [];
        list.add(item);
      }
      controller.sink.add(List.from(map.values));
    });
  }

  /// 获取应用信息
  Future<AppInfo?> getAppInfo(String appId) async {
    return (await appInfoDB).dao.getAppInfo(appId);
  }

  /// 安装应用
  void installApp(DownloadStatus downStatus) {
    if (GetPlatform.isAndroid && downStatus.fileName.endsWith(".apk")) {
      AppInstaller.installApk(downStatus.savePath);
    }
  }

  /// 恢复下载
  void resumeDownload(DownloadStatus downStatus) {
    retryDownload(downStatus, restartCount: downStatus.count);
  }

  /// 重新下载
  void retryDownload(DownloadStatus downStatus, {int restartCount = 0}) async {
    downStatus.updateDownload(restartCount, downStatus.total);
    await Get.find<DownloadService>().download(
        downStatus.appId,
        downStatus.appName,
        downStatus.version,
        downStatus.downloadUrl,
        downStatus.fileName,
        downloadSize: downStatus.total);
  }

  /// 暂停下载
  void pauseDownload(DownloadStatus downStatus) {
    downStatus.cancelDownload();
    Get.snackbar(
      '已暂停',
      '已暂停 ${downStatus.appName} 的下载',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  /// 删除单个下载记录
  Future<void> deleteDownload(DownloadStatus downStatus) async {
    try {
      // 1. 取消正在下载的任务
      if (downStatus.status == DownloadStatus.DOWNLOAD_LOADING) {
        downStatus.cancelDownload();
      }

      // 2. 删除已下载的文件
      final file = File(downStatus.savePath);
      final tempFile = File("${downStatus.savePath}.temp");

      if (await file.exists()) {
        await file.delete();
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      // 3. 从数据库删除记录
      if (downStatus.id != null) {
        final db = await database;
        await db.downloadStatusDao.deleteDownload(downStatus.id!);
      }

      Get.snackbar(
        '已删除',
        '已删除 ${downStatus.appName} 的下载记录',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '删除失败',
        '删除下载记录失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.errorContainer,
      );
    }
  }

  /// 删除指定应用的所有下载记录
  Future<void> deleteDownloadsByAppId(String appId) async {
    try {
      final db = await database;
      await db.downloadStatusDao.deleteDownloadsByAppId(appId);

      Get.snackbar(
        '已删除',
        '已删除该应用的所有下载记录',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '删除失败',
        '删除下载记录失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.errorContainer,
      );
    }
  }

  /// 清理已完成的下载记录
  Future<void> clearCompleted() async {
    try {
      final db = await database;
      final items = await db.downloadStatusDao.getCompletedItems();

      // 删除文件
      for (var item in items) {
        try {
          final file = File(item.savePath);
          final tempFile = File("${item.savePath}.temp");

          if (await file.exists()) {
            await file.delete();
          }
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          // 忽略单个文件删除失败
        }
      }

      // 删除数据库记录
      await db.downloadStatusDao.deleteCompletedDownloads();

      final count = items.length;
      Get.snackbar(
        '清理完成',
        count > 0 ? '已清理 $count 条已完成记录' : '没有需要清理的记录',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '清理失败',
        '清理下载记录失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.errorContainer,
      );
    }
  }

  /// 清空所有下载记录
  Future<void> clearAll() async {
    // 显示确认对话框
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有下载记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            style: FilledButton.styleFrom(
              backgroundColor: Get.theme.colorScheme.error,
            ),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final db = await database;
      final items = await db.downloadStatusDao.getAllDownload().first ?? [];

      // 取消所有正在下载的任务
      for (var item in items) {
        if (item.status == DownloadStatus.DOWNLOAD_LOADING) {
          item.cancelDownload();
        }
      }

      // 删除所有文件
      for (var item in items) {
        try {
          final file = File(item.savePath);
          final tempFile = File("${item.savePath}.temp");

          if (await file.exists()) {
            await file.delete();
          }
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          // 忽略单个文件删除失败
        }
      }

      // 清空数据库
      await db.downloadStatusDao.deleteAllDownloads();

      Get.snackbar(
        '清空完成',
        '已清空所有下载记录',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '清空失败',
        '清空下载记录失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.errorContainer,
      );
    }
  }

  /// 切换筛选类型
  void setFilter(DownloadFilter filter) {
    currentFilter.value = filter;
  }

  /// 获取筛选后的流
  Stream<List<List<DownloadStatus>>> getFilteredStream() {
    if (currentFilter.value == DownloadFilter.all) {
      return controller.stream;
    }

    // TODO: 实现其他筛选类型的流
    return controller.stream;
  }

  @override
  void onClose() async {
    await controller.close();
    super.onClose();
  }
}
