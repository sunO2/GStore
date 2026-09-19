import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_provider.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/download_core_config.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// 构造最小 [DownloadTask]；[source] 用于区分实现（dart / rust）。
DownloadTask _task(int id, {String source = 'x'}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    appId: 'app$id',
    appName: source,
    version: '1',
    fileName: 'file$id',
    url: 'https://example.com/file$id',
    filePath: '/tmp/file$id',
    total: 100,
    received: 0,
    status: DownloadStatusEnum.queued,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: now,
    updatedAt: now,
  );
}

/// 记录调用次数、可手动推事件的假下载服务（无 FFI / 无网络）。
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService(this.tag);

  final String tag;
  int downloadCalls = 0;

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
    return _task(1, source: tag);
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
      _task(1, source: tag);

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<void> restart(int id) async {}

  @override
  Future<void> remove(int id) async {}

  @override
  Future<DownloadTask?> getTask(int id) async => _task(id, source: tag);

  @override
  Future<List<DownloadTask>> listTasks() async => <DownloadTask>[_task(1, source: tag)];

  @override
  Stream<DownloadTask> watch(int id) => const Stream<DownloadTask>.empty();

  @override
  Stream<DownloadTask> watchAll() => const Stream<DownloadTask>.empty();
}

/// `download.core` 的可变假 provider，避免触碰真实 [ConfigStore]。
class _CoreConfigProvider extends ConfigProvider<String> {
  String? value;

  @override
  String get configKey => DownloadCoreConfig.configKey;

  @override
  Future<String?> load() async => value;

  @override
  Future<bool> save(String config) async {
    value = config;
    return true;
  }

  @override
  Future<bool> clear() async {
    value = null;
    return true;
  }

  @override
  Stream<String?> watch() => const Stream<String?>.empty();
}

/// 把假 provider 注册进全局 [ConfigService]，测试后注销。
class _CoreConfigModule extends ConfigModule {
  _CoreConfigModule(this.provider);

  final _CoreConfigProvider provider;

  @override
  String get moduleName => 'test_download_core_config';

  @override
  List<ConfigEntry> get configs => <ConfigEntry>[
        const ConfigEntry(
          key: DownloadCoreConfig.configKey,
          type: ConfigValueType.string,
          description: '测试用 download.core',
        ),
      ];

  @override
  void registerProviders(ConfigService service) {
    service.bridgeProvider(provider);
  }
}

/// 捕获 `debugPrint` 输出，测试结束自动还原。
List<String> _captureDebugPrint() {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logs.add(message);
  };
  addTearDown(() => debugPrint = original);
  return logs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ConfigService.instance;
  late _CoreConfigProvider provider;
  late _CoreConfigModule module;

  setUp(() {
    provider = _CoreConfigProvider();
    module = _CoreConfigModule(provider);
    service.registerModule(module);
  });

  tearDown(() {
    service.unregisterModule(module.moduleName);
  });

  group('DownloadCoreConfig.resolve 惰性路由', () {
    test('默认配置下 resolve 不做任何内核探测并返回惰性路由', () async {
      provider.value = null;
      var probes = 0;
      final dart = _FakeDownloadService('dart');

      final impl = await DownloadCoreConfig.resolve(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
        rustServiceFactory: () => _FakeDownloadService('rust'),
      );

      expect(impl, isA<LazyDownloadService>());
      expect(probes, 0, reason: '启动期 resolve 不得触发模块探测/下载');
    });

    test('运行时强制 dart 直接返回 dartImpl，绕过惰性路由', () async {
      provider.value = 'dart';
      var probes = 0;
      final dart = _FakeDownloadService('dart');

      final impl = await DownloadCoreConfig.resolve(
        dart,
        rustProbe: () async {
          probes++;
          return true;
        },
      );

      expect(identical(impl, dart), isTrue, reason: '硬回退必须返回同一个 dartImpl');
      expect(impl, isNot(isA<LazyDownloadService>()));
      expect(probes, 0);
    });

    test('Rust 不可用时 resolve 不抛错并返回路由，使用时回落 Dart', () async {
      final logs = _captureDebugPrint();
      provider.value = null;
      var probes = 0;
      final dart = _FakeDownloadService('dart');

      final impl = await DownloadCoreConfig.resolve(
        dart,
        rustProbe: () async {
          probes++;
          throw StateError('rust unavailable');
        },
      );

      expect(impl, isA<LazyDownloadService>());
      expect(probes, 0, reason: '探测应推迟到首次变更类调用，而非 resolve');

      final task = await impl.download('a', 'n', '1', 'u', 'f.apk');
      expect(task.appName, 'dart', reason: '内核不可用时应静默回落 Dart');
      expect(probes, 1, reason: '首次变更类调用才触发一次探测');
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        1,
        reason: '回退只应打印一条告警',
      );
    });
  });
}
