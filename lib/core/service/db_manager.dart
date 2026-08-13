import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart' as db;

class DBRepository {
  final String target;
  final String user;
  final String repositroy;
  final AppInfoDatabase db;

  DBRepository(this.target, this.user, this.repositroy, this.db);

  copyWith(
      {String? target, String? user, String? repositroy, AppInfoDatabase? db}) {
    return DBRepository(target ?? this.target, user ?? this.user,
        repositroy ?? this.repositroy, db ?? this.db);
  }
}

class DbManager extends GetxService {
  final githubApi = Get.find<GithubRestClient>();
  var dbRepositroies = <String, DBRepository>{};

  Future<DbManager> init() async {
    // 使用应用私有目录（Android 11+ 外部共享目录受作用域存储限制，可能返回 null 导致 ANR）
    final dir = await getApplicationDocumentsDirectory();
    var dbDir = Directory("${dir.path}/gstore");
    await dbDir.create(recursive: true);
    var dbFile = File("${dbDir.path}/apps.db");

    // 旧版本数据库在下载目录，迁移到新位置（若存在）
    try {
      final oldDir = await getDownloadsDirectory();
      if (oldDir != null) {
        final oldFile = File("${oldDir.path}/gstore/apps.db");
        if (await oldFile.exists() && !(await dbFile.exists())) {
          await oldFile.copy(dbFile.path);
          appLog.info('DbManager: 已迁移旧数据库到应用私有目录');
        }
      }
    } catch (e) {
      appLog.error('DbManager: 迁移旧数据库失败（忽略）- $e');
    }

    if (!(await dbFile.exists())) {
      var bytes = await rootBundle.load("assets/app/db/apps.db");
      ByteBuffer buffer = bytes.buffer;
      await dbFile.writeAsBytes(
          buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    }
    // 构建数据库（加超时保护，避免启动卡死）
    try {
      dbRepositroies["gstore"] = (DBRepository("gstore", "sunO2",
          "GStore-Repositorys", await db.Builder("gstore/apps.db").build()));
    } catch (e) {
      appLog.error('DbManager: 数据库构建失败 - $e');
      rethrow;
    }

    // 从数据库恢复版本配置到内存（代理配置走 ConfigService B 轨）
    try {
      final dbConfig = await dbRepositroies["gstore"]!.db.dao.getVersion();
      if (dbConfig != null) {
        updateConfig(dbConfig.version);
        appLog.info('DbManager: 已恢复配置（版本: ${dbConfig.version}）');
      }
    } catch (e) {
      appLog.error('DbManager: 恢复配置失败 - $e');
    }
    return this;
  }

  DBRepository _getDB(String name) {
    return dbRepositroies[name]!;
  }

  Future<void> downloadDB() async {
    return;
  }

  Future<void> addDBRepositroy(DBRepository dbRepositroy) async {
    return;
  }

  /// 持久化配置到数据库
  Future<void> persistConfig(AppInfoConfig config) async {
    final repo = dbRepositroies["gstore"];
    if (repo != null) {
      await repo.db.dao.insertConfig(config);
    }
  }

  /// 检查数据库是否有更新（仅检测，不下载）
  /// 返回 true 表示有新版本
  Future<bool> _checkUpdateOnly(String target) async {
    final info = await _getLatestReleaseInfo(target);
    return info != null;
  }

  /// 获取当前数据库版本
  Future<String> getDBVersion(String target) async {
    final repo = dbRepositroies[target];
    if (repo == null) return '0.0.0.0';
    try {
      return (await repo.db.dao.getVersion())?.version ?? '0.0.0.0';
    } catch (e) {
      appLog.error('DbManager: 获取数据库版本失败 - $e');
      return '0.0.0.0';
    }
  }

  /// 检查数据库更新并返回 [当前版本, 可更新版本]
  /// 无更新或失败时返回 null
  Future<Map<String, String>?> checkUpdateInfo(String target) async {
    final info = await _getLatestReleaseInfo(target);
    if (info == null) return null;
    return {
      'current': await getDBVersion(target),
      'latest': info['version'] as String,
    };
  }

  /// 获取最新版本信息
  /// 返回 null 表示无更新或获取失败
  Future<Map<String, dynamic>?> _getLatestReleaseInfo(String target) async {
    appLog.info('DbManager: ===== 开始检查数据库更新 ($target) =====');
    DBRepository dbRepositroy = dbRepositroies[target]!;
    var dbVersion =
        (await dbRepositroy.db.dao.getVersion())?.version ?? "0.0.0.0";
    debugPrint('DbManager: 当前数据库版本: $dbVersion');

    var task;
    try {
      debugPrint('DbManager: 请求 GitHub releases API...');
      task = await githubApi
          .releases("sunO2", "GStore-Repositorys", 1, CancelToken())
          .timeout(const Duration(seconds: 15));
      debugPrint('DbManager: GitHub releases API 请求成功, 响应长度: ${task?.length}');
    } catch (e) {
      appLog.error("DbManager: ❌ 获取仓库信息失败: $e");
      return null;
    }
    try {
      List<dynamic> gstoreRepositorys = jsonDecode(task);
      debugPrint('DbManager: 解析到 ${gstoreRepositorys.length} 个 release');
      dynamic release =
          (gstoreRepositorys.isNotEmpty) ? gstoreRepositorys[0] ?? {} : {};
      var version = release["name"];
      debugPrint('DbManager: 最新 release 版本: $version');
      debugPrint('DbManager: 版本比较 (当前$dbVersion vs 最新$version): ${compareVersion(dbVersion, version)}');
      if (compareVersion(dbVersion, version) == 1) {
        appLog.info('DbManager: ✅ 发现新版本，返回更新信息');
        return {'release': release, 'version': version};
      }
      debugPrint('DbManager: 无新版本（当前已是最新）');
    } catch (e) {
      appLog.error("DbManager: ❌ 解析仓库信息失败: $e");
    }
    return null;
  }

  /// 检查数据库更新
  Future<int> _checkUpdateDBOfRepositroy(String target) async {
    DBRepository dbRepositroy = dbRepositroies[target]!;
    appLog.info('DbManager: ===== 开始下载数据库更新 ($target) =====');
    final info = await _getLatestReleaseInfo(target);
    if (info == null) {
      debugPrint('DbManager: 无更新，跳过下载');
      return -2; // 无更新
    }

    final release = info['release'] as Map<String, dynamic>;
    final version = info['version'] as String;
    var assets = release["assets"][0];
    final downloadUrl = "${getProxy()}${assets["browser_download_url"]}";
    appLog.info('DbManager: 开始下载新版本: $version');
    debugPrint('DbManager: 代理: ${getProxy()}');
    debugPrint('DbManager: 原始下载URL: ${assets["browser_download_url"]}');
    debugPrint('DbManager: 最终下载URL: $downloadUrl');
    debugPrint('DbManager: 文件大小: ${assets["size"]}');

    return Get.showOverlay(
        asyncFunction: () async {
          debugPrint('DbManager: 调用 DownloadService.download...');
          // 下载到独立的临时文件（避免旧数据库连接占用导致覆盖失败）
          final appDir = await getApplicationDocumentsDirectory();
          final dbDownloadPath = '${appDir.path}/gstore/apps.db.download';
          await File(dbDownloadPath).parent.create(recursive: true);
          debugPrint('DbManager: 数据库下载临时文件: $dbDownloadPath');
          // download() 会阻塞到下载完成返回，返回的 status 已包含最终状态
          var status = await Get.find<DownloadService>().download(
              "com.sunO2.gstore.db",
              "GStore.db",
              version,
              downloadUrl,
              assets["name"],
              downloadSize: assets["size"],
              saveFileName: dbDownloadPath,
              forceDownload: true); // 强制重新下载，确保数据库更新
          appLog.info('DbManager: 下载完成，状态: ${status.status}, 保存路径: ${status.savePath}');
          return status;
        },
        loadingWidget: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: Container(
              decoration: const BoxDecoration(
                  color: Color.fromARGB(126, 0, 0, 0),
                  borderRadius: BorderRadius.all(Radius.circular(16))),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CupertinoActivityIndicator(
                    color: Color.fromARGB(255, 244, 244, 244),
                    radius: 18.0,
                  ),
                  SizedBox(
                    height: 16,
                  ),
                  Text("数据更新中... ",
                      style: TextStyle(
                          color: Color.fromARGB(255, 215, 215, 215),
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ),
        opacity: .0,
      ).then((value) async {
        if (value.status == DownloadStatus.DOWNLOAD_SUCCESS) {
          appLog.info('DbManager: 下载成功，准备替换数据库');
          final appDir = await getApplicationDocumentsDirectory();
          final dbDownloadPath = '${appDir.path}/gstore/apps.db.download';
          final dbTargetPath = '${appDir.path}/gstore/apps.db';

          // 校验下载的临时文件确实是有效 SQLite
          final downloadFile = File(dbDownloadPath);
          final exists = await downloadFile.exists();
          final len = exists ? await downloadFile.length() : 0;
          debugPrint('DbManager: 下载临时文件存在=$exists 大小=$len');
          if (exists) {
            final bytes = await downloadFile.readAsBytes();
            final isSqlite = bytes.length > 15 &&
                String.fromCharCodes(bytes.sublist(0, 15)) == 'SQLite format 3';
            debugPrint('DbManager: 文件头校验=${isSqlite ? "有效SQLite" : "无效文件!"}');
            if (!isSqlite) {
              appLog.error('DbManager: 下载文件无效，保留原数据库');
              return value.status;
            }
          } else {
            appLog.error('DbManager: 下载临时文件不存在，保留原数据库');
            return value.status;
          }

          // 关键步骤（用户提示的正确顺序）：
          // 1. 先关闭旧数据库连接，释放文件句柄和 WAL
          debugPrint('DbManager: 关闭旧数据库连接...');
          try {
            await dbRepositroy.db.close();
          } catch (e) {
            appLog.error('DbManager: 关闭旧连接异常（忽略继续）- $e');
          }

          // 2. 删除旧数据库文件及其 WAL/SHM 附属文件（确保不被残留连接污染）
          final dbFile = File(dbTargetPath);
          try {
            await Future.wait([
              dbFile.exists().then((e) => e ? dbFile.delete() : Future.value()),
              File('$dbTargetPath-wal').exists().then((e) => e ? File('$dbTargetPath-wal').delete() : Future.value()),
              File('$dbTargetPath-shm').exists().then((e) => e ? File('$dbTargetPath-shm').delete() : Future.value()),
            ]);
            appLog.info('DbManager: 旧数据库文件已删除');
          } catch (e) {
            appLog.error('DbManager: 删除旧数据库文件失败 - $e');
          }

          // 3. 用下载的新文件覆盖
          try {
            await downloadFile.rename(dbTargetPath);
            appLog.info('DbManager: 新数据库文件已就位');
          } catch (e) {
            appLog.error('DbManager: 覆盖新数据库失败 - $e');
            return value.status;
          }

          // 4. 重新打开新的数据库连接
          dbRepositroies[target] = dbRepositroy.copyWith(
              db: await db.Builder("gstore/apps.db")
                  .build());
          appLog.info('DbManager: 数据库已重建（新版本）');
          // 验证重建后数据库内容
          try {
            final appCount = await dbRepositroies[target]!.db.dao.getAllApps();
            final cfg = await dbRepositroies[target]!.db.dao.getVersion();
            debugPrint('DbManager: 重建后 apps 数量=${appCount.length}, 版本=${cfg?.version}');
          } catch (e) {
            appLog.error('DbManager: 重建后内容验证失败 - $e');
          }

          // 更新 LocalDbChannel 的数据库引用（避免使用已关闭的旧数据库）
          try {
            final channelManager = Get.find<ChannelManager>(tag: 'channelManager');
            final localDb = channelManager.getChannel(ChannelType.localDb);
            if (localDb is LocalDbChannel) {
              localDb.updateDatabase(dbRepositroies[target]!.db);
              appLog.info('DbManager: LocalDbChannel 数据库引用已更新');
            }
          } catch (e) {
            appLog.error('DbManager: 更新 LocalDbChannel 引用失败 - $e');
          }

          // 通知发现页刷新数据（数据库已更新，重新加载应用列表）
          try {
            final discovery = Get.find<DiscoveryLogic>();
            await discovery.loadData();
            appLog.info('DbManager: 已通知发现页刷新');
          } catch (e) {
            appLog.error('DbManager: 通知发现页刷新失败（可能未打开）- $e');
          }

          // 数据库已更新到最新，清除红点
          BadgeService.instance.setBadge(BadgeKey.dbUpdate, 0);
        } else {
          appLog.error('DbManager: 下载未成功，状态=${value.status}，保留原数据库');
        }
        return value.status;
      });
  }
}

extension DBRepositoryExtension on String {
  DBRepository get repoDB => Get.find<DbManager>()._getDB(this);
  Future<int> checkUpdate() =>
      Get.find<DbManager>()._checkUpdateDBOfRepositroy(this);
  Future<bool> checkUpdateOnly() =>
      Get.find<DbManager>()._checkUpdateOnly(this);
}
