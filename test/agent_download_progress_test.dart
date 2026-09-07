import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';

/// Agent 下载进度绑定测试
///
/// 验证：downloadApp 工具经 `service.download(url)` 启动后，
/// `_watchDownloadProgress` 订阅 watch 流，进度更新（onStatus）与终态（onFinished）
/// 正确回调——即"下载任务绑定到消息卡进度条"的服务侧链路。
///
/// 场景：URL 直下路径（无需渠道），fake IDownloadService 流式推送进度。
class _FakeDownloadService implements IDownloadService {
  /// 已启动的下载任务（key = taskId → 任务）
  final Map<int, DownloadTask> tasks = {};

  /// watch 流控制器（broadcast：多个订阅者共享）
  final Map<int, StreamController<DownloadTask>> _watchers = {};

  /// 收到的 onStatus 回调次数（进度推送）
  int progressPushes = 0;

  /// 最近一次 onStatus 收到的任务
  DownloadTask? lastStatusTask;

  /// 最近一次 download 调用收到的 installAfterDownload 透传值
  bool? lastInstallAfterDownload;

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
    lastInstallAfterDownload = installAfterDownload;
    final task = DownloadTask(
      id: 1,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      filePath: saveFileName ?? '/tmp/$fileName',
      total: 100,
      received: 0,
      status: DownloadStatusEnum.queued,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    tasks[1] = task;
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
  }) async =>
      throw UnimplementedError();

  @override
  Stream<DownloadTask> watch(int id) =>
      _watchers.putIfAbsent(id, () => StreamController<DownloadTask>.broadcast()).stream;

  @override
  Future<DownloadTask?> getTask(int id) async => tasks[id];

  /// 测试辅助：模拟下载进度推送
  void emitProgress(int received) {
    final task = tasks[1]!;
    final updated = task.copyWith(
      received: received,
      status: DownloadStatusEnum.downloading,
      updatedAt: DateTime.now(),
    );
    tasks[1] = updated;
    _watchers[1]?.add(updated);
    progressPushes++;
    lastStatusTask = updated;
  }

  /// 测试辅助：模拟下载完成
  void emitCompleted() {
    final task = tasks[1]!;
    final done = task.copyWith(
      received: task.total,
      status: DownloadStatusEnum.completed,
      updatedAt: DateTime.now(),
    );
    tasks[1] = done;
    _watchers[1]?.add(done);
  }

  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> resume(int id) async {}
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> retry(int id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDownloadService fakeService;

  setUp(() {
    ModuleManager.instance.injectContext(null);
    fakeService = _FakeDownloadService();
    // 绑定 IDownloadService（download 模块在线语义）
    ModuleManager.instance.bindByType(IDownloadService, fakeService);
  });

  tearDown(() {
    ModuleManager.instance.unbindByType(IDownloadService);
  });

  test('URL 直下路径：watch 流推送进度时 onStatus 收到下载中状态', () async {
    final agent = AgentService();
    // URL 直下（无需渠道）：走 service.download → _watchDownloadProgress 订阅 watch
    final result = await agent.runTool('downloadApp', {
      'appId': 'com.example.a',
      'channel': 'github',
      'url': 'https://example.com/a.apk',
      'name': 'App A',
      'version': '1.0.0',
    });

    expect(result, contains('已开始下载'));
    // 订阅已建立（watch 的 controller 已创建）
    expect(fakeService._watchers.containsKey(1), isTrue,
        reason: 'downloadApp 应订阅 watch 流以跟踪进度');

    // 推送下载进度 → onStatus 被调用（服务侧绑定进度数据）
    fakeService.emitProgress(50);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeService.progressPushes, greaterThan(0),
        reason: 'watch 流推送进度应触发 onStatus 回调');
    expect(fakeService.lastStatusTask?.received, 50);

    // 推送完成 → 终态（onFinished 触发 _finalizeAsyncTask）
    fakeService.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeService.tasks[1]?.status, DownloadStatusEnum.completed);
  });

  test('downloadApp 透传 installAfterDownload=true 到下载服务', () async {
    final agent = AgentService();
    // URL 直下路径（url 为 http(s) 开头）→ 必然走到 service.download
    final result = await agent.runTool('downloadApp', {
      'appId': 'com.example.b',
      'channel': 'github',
      'url': 'https://example.com/b.apk',
      'name': 'App B',
      'version': '1.0.0',
      'installAfterDownload': true,
    });

    expect(result, contains('已开始下载'));
    expect(fakeService.lastInstallAfterDownload, isTrue,
        reason: '_executeTool 应把 installAfterDownload=true 透传给 service.download');
  });

  test('downloadApp 缺省 installAfterDownload 透传 false（仅下载不安装）', () async {
    final agent = AgentService();
    // URL 直下路径：不传 installAfterDownload → _downloadApp 缺省 false
    final result = await agent.runTool('downloadApp', {
      'appId': 'com.example.c',
      'channel': 'github',
      'url': 'https://example.com/c.apk',
      'name': 'App C',
      'version': '1.0.0',
    });

    expect(result, contains('已开始下载'));
    expect(fakeService.lastInstallAfterDownload, isFalse,
        reason: '_downloadApp 缺省 installAfterDownload=false，应透传给 service.download');
  });
}