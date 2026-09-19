import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart' show DownloadTask;
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 伪造的宿主模块句柄：仅经 `loadOverride` 原样返回，绝不触碰 FFI。
class _FakeHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 伪造的模块实例：`callModule` 返回预置 JSON 字节并计数调用次数。
class _FakeInstance implements RustModuleInstance {
  _FakeInstance(this._response);

  final Uint8List _response;
  int callCalls = 0;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    callCalls++;
    methods.add(method);
    return _response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// `download.start` 成功响应的 JSON（映射契约要求的全量字段）。
Uint8List _startResponse({int id = 7}) => Uint8List.fromList(utf8.encode(
      jsonEncode(<String, dynamic>{
        'id': id,
        'appId': 'com.example.app',
        'appName': '示例',
        'version': '1.0.0',
        'fileName': 'app.apk',
        'url': 'https://x/app.apk',
        'filePath': '/tmp/app.apk',
        'total': 100,
        'received': 0,
        'status': 0,
        'speedBps': 0,
        'etaSec': null,
        'error': null,
        'segments': null,
        'createdAt': 1700000000000,
        'updatedAt': 1700000000000,
      }),
    ));

/// 走 `.so` 的下载入口（绝对 saveFileName 短路 path_provider）。
Future<DownloadTask> _startDownload(RustDownloadService svc) => svc.download(
      'com.example.app',
      '示例',
      '1.0.0',
      'https://x/app.apk',
      'app.apk',
      saveFileName: '/tmp/app.apk',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;

  setUp(() {
    bootstrap.debugReset();
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  group('todo 15 - download 内核经 ModuleBootstrap 门获取', () {
    test('download.start 路由到门获取的实例，第二次调用复用门缓存', () async {
      var ensureCalls = 0;
      var factoryCalls = 0;
      final instance = _FakeInstance(_startResponse());

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          expect(module, 'download', reason: 'download 走 download 模块');
          return true;
        },
        loadOverride: (String module) async => _FakeHandle(),
        factoryOverride: (ModuleHandle handle) async {
          factoryCalls++;
          return instance;
        },
      );

      final svc = RustDownloadService.instance;

      final first = await _startDownload(svc);
      expect(first.id, 7, reason: '应返回映射后的任务');
      expect(instance.methods, <String>['download.start'],
          reason: 'download.start 必须路由到门获取的实例');
      expect(factoryCalls, 1, reason: '首次使用创建一次实例');

      final second = await _startDownload(svc);
      expect(second.id, 7);
      expect(factoryCalls, 1, reason: '重复调用复用门缓存实例，不再创建');
      expect(ensureCalls, 1, reason: '重复调用不再触发 ensure');
    });

    test('未安装：安装期并发 download 调用等待同一次门获取，就绪后各自执行一次', () async {
      final gate = Completer<bool>();
      var ensureCalls = 0;
      var factoryCalls = 0;
      final instance = _FakeInstance(_startResponse());

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) {
          ensureCalls++;
          expect(module, 'download', reason: 'download 走 download 模块');
          return gate.future; // 安装挂起：模拟仍在下载
        },
        loadOverride: (String module) async => _FakeHandle(),
        factoryOverride: (ModuleHandle handle) async {
          factoryCalls++;
          return instance;
        },
      );

      final svc = RustDownloadService.instance;

      // 模块尚未安装（ensure 挂起）：并发发起两个真实变更调用。
      final f1 = _startDownload(svc);
      final f2 = _startDownload(svc);
      await pumpEventQueue();

      expect(ensureCalls, 1, reason: '并发调用在 ensure 阶段即单飞去重');
      expect(factoryCalls, 0, reason: '安装未完成前不得创建实例');
      expect(instance.callCalls, 0, reason: '实例未就绪前不得执行任务');

      gate.complete(true);
      final tasks = await Future.wait(<Future<DownloadTask>>[f1, f2]);

      expect(tasks.map((t) => t.id), <int>[7, 7], reason: '两个等待调用各自完成');
      expect(instance.methods, <String>['download.start', 'download.start'],
          reason: '就绪后每个等待的调用各执行一次');
      expect(ensureCalls, 1, reason: '两个调用共享一次安装确保');
      expect(factoryCalls, 1, reason: '两个调用共享一次实例创建');
      expect(instance.callCalls, 2, reason: '每个等待的调用各执行一次任务');
    });

    test('两个并发 isAvailable 仅触发一次门获取（单飞）', () async {
      final gate = Completer<bool>();
      var ensureCalls = 0;
      var factoryCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) {
          ensureCalls++;
          return gate.future;
        },
        loadOverride: (String module) async => _FakeHandle(),
        factoryOverride: (ModuleHandle handle) async {
          factoryCalls++;
          return _FakeInstance(_startResponse());
        },
      );

      final svc = RustDownloadService.instance;

      // 门仍在安装（ensure 挂起）时同时发起两次 isAvailable。
      final f1 = svc.isAvailable;
      final f2 = svc.isAvailable;
      await pumpEventQueue();

      expect(ensureCalls, 1, reason: '并发调用在 ensure 阶段即单飞去重');
      expect(factoryCalls, 0, reason: 'ensure 未完成前不得创建实例');

      gate.complete(true);
      final results = await Future.wait(<Future<bool>>[f1, f2]);

      expect(results, <bool>[true, true]);
      expect(ensureCalls, 1, reason: '两次 isAvailable 共享一次 ensure');
      expect(factoryCalls, 1, reason: '两次 isAvailable 共享一次实例创建');
    });

    test('门失败：isAvailable==false 且 download 抛 StateError', () async {
      var ensureCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          return false;
        },
        loadOverride: (String module) async => _FakeHandle(),
        factoryOverride: (ModuleHandle handle) async =>
            _FakeInstance(_startResponse()),
        delayOverride: (Duration duration) async {},
      );

      final svc = RustDownloadService.instance;

      // 不可用时不抛错，返回 false（面板据此降级）。
      expect(await svc.isAvailable, isFalse, reason: '门失败时 isAvailable 返回 false');
      expect(ensureCalls, greaterThan(0), reason: 'isAvailable 会触发门获取');

      await expectLater(
        _startDownload(svc),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('RustDownloadService: download 模块不可用'),
        )),
      );
    });
  });
}
