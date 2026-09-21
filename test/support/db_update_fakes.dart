import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfoDao.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试用 path_provider：返回注入的文档目录。
///
/// MethodChannel mock 在部分平台上无效（path_provider_linux 注册了平台实例），
/// 直接替换 [PathProviderPlatform.instance] 与 settings_script_import_test 同款。
class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// 假 DAO：版本可控，其余查询返回空。
class FakeAppInfoDao extends AppInfoDao {
  FakeAppInfoDao({this.version});

  /// 当前数据库版本（null → 无版本记录）
  String? version;

  @override
  Future<List<AppInfo>> getAllApps() async => const [];

  @override
  Future<AppInfo?> getAppInfo(String appId) async => null;

  @override
  Future<List<AppInfo>> searchWord(String word) async => const [];

  @override
  Future<List<AppInfo>> searchFts(String word) async => const [];

  @override
  Future<AppInfoConfig?> getVersion() async =>
      version == null ? null : AppInfoConfig(version!, null);

  @override
  Future<void> insertConfig(AppInfoConfig config) async {}

  @override
  Future<List<AppCategory>> getAllCategory() async => const [];

  @override
  Future<List<AppInfo>> searchCategoryLike(String word) async => const [];
}

/// 假数据库：只暴露注入的 DAO；close 为 no-op（真实 Floor 连接未建立）。
class FakeAppInfoDatabase extends AppInfoDatabase {
  FakeAppInfoDatabase(this._dao);

  final AppInfoDao _dao;

  @override
  AppInfoDao get dao => _dao;

  @override
  Future<void> close() async {}
}

/// 构造 GitHub releases 响应 JSON（与真实 GitHub REST 返回形状一致）。
String releaseJson({
  required String version,
  bool withAsset = true,
}) {
  return jsonEncode([
    {
      'name': version,
      'assets': withAsset
          ? [
              {
                'browser_download_url': 'https://example.com/apps.db',
                'name': 'apps.db',
                'size': 100,
              }
            ]
          : <Map<String, dynamic>>[],
    }
  ]);
}

/// 用假 Dio 适配器构造真实 [GithubRestClient]：每次 releases 请求返回
/// [jsonProvider] 的 JSON。避免手写 retrofit 抽象类（HttpResponse 等类型）。
GithubRestClient fakeGithubClient(String Function() jsonProvider) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.resolve(Response<String>(
        requestOptions: options,
        statusCode: 200,
        data: jsonProvider(),
      ));
    },
  ));
  return GithubRestClient(dio);
}

DownloadTask buildTask({
  int id = 1,
  String appId = 'com.sunO2.gstore.db',
  String appName = 'GStore.db',
  String version = '9.9.9',
  String fileName = 'apps.db',
  String url = 'https://example.com/apps.db',
  String filePath = '/tmp/apps.db',
  DownloadStatusEnum status = DownloadStatusEnum.queued,
  int received = 0,
  int total = 0,
  bool installAfterDownload = false,
}) {
  final now = DateTime.now();
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
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    installAfterDownload: installAfterDownload,
    createdAt: now,
    updatedAt: now,
  );
}

/// 可编排的假下载服务。
///
/// - [autoComplete]=true：`getTask` 直接返回终态任务（驱动 awaitDownloadTerminal
///   的竞态兜底分支）。
/// - [autoComplete]=false：`getTask` 返回 queued，测试用 [emitTerminal] 推送终态，
///   验证真正由 watch 事件完成等待。
class FakeDownloadService implements IDownloadService {
  FakeDownloadService({
    this.onDownload,
    this.autoComplete = true,
    this.terminalStatus = DownloadStatusEnum.completed,
  });

  /// 下载时落盘回调（saveFileName 路径）；null → 不写文件（模拟缺失）。
  final Future<void> Function(String saveFileName)? onDownload;
  final bool autoComplete;
  final DownloadStatusEnum terminalStatus;

  int downloadCalls = 0;
  bool? capturedInstallAfterDownload;
  DownloadTask? lastTask;

  final StreamController<DownloadTask> _controller =
      StreamController<DownloadTask>.broadcast();
  final Map<int, DownloadTask> _tasks = <int, DownloadTask>{};

  DownloadTask terminalTask() {
    final base = lastTask ?? buildTask();
    return base.copyWith(
      status: terminalStatus,
      received: 1,
      total: 1,
    );
  }

  /// 推送终态事件（autoComplete=false 时使用）。
  void emitTerminal() => _controller.add(terminalTask());

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) async {
    downloadCalls++;
    capturedInstallAfterDownload = installAfterDownload;
    if (onDownload != null && saveFileName != null) {
      await onDownload!(saveFileName);
    }
    final task = buildTask(
      id: downloadCalls,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      filePath: saveFileName ?? '/tmp/$fileName',
      installAfterDownload: installAfterDownload,
    );
    _tasks[downloadCalls] = task;
    lastTask = task;
    return task;
  }

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  }) async {
    return buildTask(
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: request.url,
      filePath: saveFileName ?? '/tmp/$fileName',
      installAfterDownload: installAfterDownload,
    );
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    final task = _tasks[id];
    if (task == null) return null;
    if (!autoComplete) return task;
    return task.copyWith(status: terminalStatus, received: 1, total: 1);
  }

  @override
  Stream<DownloadTask> watch(int id) => _controller.stream;

  @override
  Stream<DownloadTask> watchAll() => _controller.stream;

  @override
  Future<List<DownloadTask>> listTasks() async => _tasks.values.toList();

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> remove(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<void> restart(int id) async {}

  /// 释放广播流（测试 tearDown 调用，避免 pending 资源）。
  Future<void> dispose() => _controller.close();
}
