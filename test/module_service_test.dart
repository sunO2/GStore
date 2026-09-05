import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_proxy.dart';

/// 构造最小 DownloadTask
DownloadTask _task(String appid, String appName, String version, String fileName,
    {String? url}) {
  return DownloadTask(
    id: 1,
    appId: appid,
    appName: appName,
    version: version,
    fileName: fileName,
    url: url ?? 'https://example.com/$fileName',
    filePath: '/tmp/$fileName',
    total: 0,
    received: 0,
    status: DownloadStatusEnum.queued,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 测试下载服务实现
class _FakeDownloadService implements IDownloadService {
  final String tag;
  _FakeDownloadService(this.tag);

  @override
  Future<DownloadTask> download(String appid, String appName, String version,
      String url, String fileName,
      {int? downloadSize, bool breakPoint = true, String? saveFileName, bool forceDownload = false, bool installAfterDownload = true}) async {
    return _task(appid, appName, version, fileName, url: url);
  }

  @override
  Future<DownloadTask> downloadWithContext(
      DownloadRequest request,
      String appid,
      String appName,
      String version,
      String fileName,
      {bool breakPoint = true,
      String? saveFileName,
      bool installAfterDownload = true}) async {
    return _task(appid, appName, version, fileName, url: request.url);
  }

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<DownloadTask?> getTask(int id) async => null;

  @override
  Stream<DownloadTask> watch(int id) => const Stream.empty();

  /// 测试标记（模拟执行结果）
  String get marker => tag;
}

/// 绑定服务的下载模块
class _DownloadModule extends AppModule {
  _DownloadModule(this.service);

  final IDownloadService service;
  bool unregisterCalled = false;

  @override
  String get moduleName => 'download';

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService!(IDownloadService, service);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    unregisterCalled = true;
    context.unbindService!(IDownloadService);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  group('服务模块上下线联动', () {
    test('上线绑定服务，下线解绑', () async {
      final manager = ModuleManager.instance;
      final service = _FakeDownloadService('A');
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bindByType(t, impl),
        unbindService: (t) => manager.unbindByType(t),
      ));

      final module = _DownloadModule(service);
      await manager.registerModule(module);
      await manager.initializeModule('download');

      // 上线后服务可用（0 损耗编译期绑定）
      expect(manager.hasModule('download'), true);
      expect(manager.hasService<IDownloadService>(), true);
      final ref = manager.get<IDownloadService>();
      expect(ref, same(service));

      // 下线后服务解绑
      await manager.unregisterModule('download');
      expect(module.unregisterCalled, true);
      expect(manager.hasService<IDownloadService>(), false);
      expect(manager.get<IDownloadService>(), isNull);
    });

    test('require 在下线后抛异常', () async {
      final manager = ModuleManager.instance;
      final service = _FakeDownloadService('A');
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bindByType(t, impl),
        unbindService: (t) => manager.unbindByType(t),
      ));

      await manager.registerModule(_DownloadModule(service));
      await manager.initializeModule('download');
      expect(manager.require<IDownloadService>(), same(service));

      await manager.unregisterModule('download');
      expect(() => manager.require<IDownloadService>(),
          throwsA(isA<StateError>()));
    });

    test('动态代理跟随模块上下线（热插拔）', () async {
      final manager = ModuleManager.instance;
      final service = _FakeDownloadService('A');
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bindByType(t, impl),
        unbindService: (t) => manager.unbindByType(t),
      ));

      // 代理延迟解析：每次调用从 ModuleManager 取当前实现
      final proxy = _DownloadProxy(
        () => manager.get<IDownloadService>(),
      );

      await manager.registerModule(_DownloadModule(service));
      await manager.initializeModule('download');
      final result = await proxy.download('app', 'name', '1.0', 'url', 'a.apk');
      expect(result.fileName, 'a.apk');

      // 下线后代理调用抛错（未注册）
      await manager.unregisterModule('download');
      expect(
        () => proxy.download('app', 'name', '1.0', 'url', 'a.apk'),
        throwsA(isA<StateError>()),
      );
    });

    test('动态代理 fallback 降级', () async {
      final manager = ModuleManager.instance;
      final fallback = _FakeDownloadService('FB');
      final proxy = _DownloadProxy(
        () => manager.get<IDownloadService>(),
        fallback: fallback,
      );
      final result = await proxy.download('a', 'b', '1.0', 'u', 'x.apk');
      expect(result.fileName, 'x.apk');
    });
  });
}

/// 下载服务动态代理
class _DownloadProxy extends DynamicProxy implements IDownloadService {
  _DownloadProxy(IDownloadService? Function() resolver, {Object? fallback}) {
    this.resolver = resolver;
    this.fallback = fallback;
    register('download', (
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
    }) {
      final svc = resolveT<IDownloadService>();
      return svc.download(
        appid,
        appName,
        version,
        url,
        fileName,
        downloadSize: downloadSize,
        breakPoint: breakPoint,
        saveFileName: saveFileName,
        forceDownload: forceDownload,
        installAfterDownload: installAfterDownload,
      );
    });
  }
}
