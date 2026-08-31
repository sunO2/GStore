import 'dart:async';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/download/logic.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// sqlite3 为 sqflite_common_ffi 传递依赖，仅用其 `open` 覆写动态库加载路径。
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// 可编程假下载服务：watch(id) 返回可控制的广播流，测试手动 push 更新。
class _FakeDownloadService implements IDownloadService {
  final _controllers = <int, StreamController<DownloadTask>>{};

  StreamController<DownloadTask> _controller(int id) =>
      _controllers.putIfAbsent(
          id, () => StreamController<DownloadTask>.broadcast());

  @override
  Stream<DownloadTask> watch(int id) => _controller(id).stream;

  void push(DownloadTask task) {
    _controllers[task.id]?.add(task);
  }

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
  }) =>
      throw UnimplementedError();

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> pause(int id) => throw UnimplementedError();

  @override
  Future<void> resume(int id) => throw UnimplementedError();

  @override
  Future<void> cancel(int id) => throw UnimplementedError();

  @override
  Future<void> retry(int id) => throw UnimplementedError();

  @override
  Future<DownloadTask?> getTask(int id) => throw UnimplementedError();
}

DownloadTask _task({int? id}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    appId: 'com.example.live',
    appName: 'Live App',
    version: '1.0.0',
    fileName: 'live.apk',
    url: 'https://example.com/live.apk',
    filePath: '/data/media/0/Download/live.apk',
    total: 1000,
    received: 100,
    status: DownloadStatusEnum.downloading,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: now,
    updatedAt: now,
  );
}

/// 回归测试：下载管理页「实时进度不刷新，退出重进才出现」。
///
/// 根因：GetX `Rx.value` 在 `_value == val`（同一引用）时直接返回不通知；
/// 旧 `_onTaskUpdate` 原地改写 `_latestGroups[i][j]` 后把同一引用赋给
/// `downloadGroups`（筛选为全部时 `_applyFilter` 原样返回），Obx 永不重建。
/// 修复：改为复制内层/外层列表，保证赋值的是“新引用”→ Rx 必然通知。
///
/// 无法直接调用私有 `_onTaskUpdate`，改走公开路径：
/// `loadTasks()` → `_resubscribeWatches` → `service.watch(id).listen(_onTaskUpdate)`，
/// 用假 `IDownloadService` 手动 push 一个 `received` 更大的任务，
/// 断言 `downloadGroups` 的 Rx 发生了通知（emit 计数 +1）且值已更新。
void main() {
  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库；
    // 与 migration_test 一致：不主动 sqfliteFfiInit，Floor 1.5 在
    // Linux/macOS 自动选择 sqflite_common_ffi 工厂（显式 init 会因 ffi
    // 隔离岛错误不进入 await 捕获路径，导致跳过守卫失效）。
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    Get.reset();
    await ModuleManager.instance.clear();

    // 满足 DownloadManagerLogic 构造期依赖：
    //   GithubRequestMix.githubApi = Get.find<GithubRestClient>()
    //   appInfoDB = "gstore".repoDB.db = Get.find<DbManager>()._getDB("gstore")
    Get.put(GithubRestClient(DioClient().get()));
    final dm = DbManager();
    dm.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      await ($FloorAppInfoDatabase.inMemoryDatabaseBuilder()).build(),
    );
    Get.put(dm);
  });

  tearDown(() async {
    await closeDownloadTaskDatabase();
    try {
      final path = p.join(
          await databaseFactoryFfi.getDatabasesPath(), 'download_task.db');
      await databaseFactoryFfi.deleteDatabase(path);
    } catch (_) {
      // 文件可能不存在，忽略
    }
    Get.reset();
    await ModuleManager.instance.clear();
  });

  test('筛选=全部时 watch 推送更大 received：Rx 必须通知且列表值更新', () async {
    // 0. 宿主环境 sqflite(Floor) 不可用时安全跳过（同 migration_test）
    try {
      await downloadTaskDatabase;
    } catch (e) {
      markTestSkipped('宿主环境无法打开 sqflite(Floor) 数据库: $e');
      return;
    }

    // 1. 绑定假下载服务（onReady 里 _service = get<IDownloadService>()）
    final fake = _FakeDownloadService();
    ModuleManager.instance.bind<IDownloadService>(fake);

    // 2. 种子一条真实 Floor 任务（loadTasks 依赖 repository.all()）
    final saved = await DownloadRepository().save(_task());
    expect(saved, isNotNull, reason: '种子任务应拿到自增 id');
    final seededId = saved!.id!;

    // 3. 预取应用信息，避免 loadTasks 尾部 _prefetchAppInfos 的额外 emit 干扰计数
    final logic = DownloadManagerLogic();
    await logic.getAppInfo(saved.appId);

    // 4. 监听 downloadGroups 流：只数 _onTaskUpdate 之后的通知次数
    var emissions = 0;
    final sub = logic.downloadGroups.stream.listen((_) => emissions++);
    addTearDown(sub.cancel);

    logic.onReady(); // _service + loadTasks + watch 订阅（void，内部 async）
    await _waitUntil(() => logic.downloadGroups.value.isNotEmpty);

    // 初始加载完成、列表就绪
    expect(logic.downloadGroups.value, hasLength(1));
    final baseline = emissions;

    // 5. push 一个 received 更大的任务（相当于下载进度推进）
    fake.push(saved.copyWith(received: saved.received + 200));
    await _waitUntil(() => emissions > baseline);

    // 回归断言：Rx 必须发生通知（旧实现同一引用 → 0 次 emit → Obx 不刷新）
    expect(emissions, greaterThan(baseline),
        reason: '筛选=全部时 watch 更新必须通知 Obx（新引用）');
    // 数据本身也要更新
    expect(
      logic.downloadGroups.value.first.first.id,
      seededId,
      reason: '更新应落在同一任务上',
    );
    expect(
      logic.downloadGroups.value.first.first.received,
      saved.received + 200,
    );

    addTearDown(logic.onClose);
  });
}

/// 轮询等待条件成立（真实异步：sqflite ffi 的 I/O 在事件循环中完成）。
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
