import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/lazy_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

/// 模拟「清单缺少 `download` 条目」的清单来源。
///
/// 真实 `ModuleManifestClient.locateModuleAsset('download')` 会走到
/// `manifest.entry('download') == null` 的条目缺失分支
/// （`ModuleManifestClient.dart:369-373`）——不触及 Release 资产表/ABI 提供者，
/// 因此本测试全程离线、无网络。
class _ManifestWithoutDownloadSource implements ModuleManifestSource {
  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async =>
      _manifestWithoutDownload;
}

/// 模拟网络/解析失败：`load` 返回 null。
///
/// 与 `_ManifestWithoutDownloadSource`（条目缺失）在调用侧**不可区分**：
/// `locateModuleAsset` 两者都返回 null（`ModuleManifestClient.dart:415-418`）。
class _FailingSource implements ModuleManifestSource {
  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async => null;
}

/// 用注入来源替换 [ModuleManifestClient.load] 的解析器（离线）。
class _SourceBackedClient extends ModuleManifestClient {
  _SourceBackedClient(this._source)
      : super(
          releasesUrl: Uri.parse('http://127.0.0.1:1/releases/latest'),
          downloadsBaseUrl: 'https://example.test/latest/download',
        );

  final ModuleManifestSource _source;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) =>
      _source.load(forceRefresh: forceRefresh);
}

Map<String, dynamic> _entry(String version) => <String, dynamic>{
      'version': version,
      'abi': <String, dynamic>{
        'arm64-v8a': <String, dynamic>{
          'asset': 'libgstore_mod_x_$version-arm64-v8a.so',
          'sha256': 'a' * 64,
          'size': 10,
        },
      },
    };

/// 与仓库 release 副本（analyzer/llm/qr/repo）同构、**刻意不含 `download`**。
final ModuleManifestV2 _manifestWithoutDownload =
    ModuleManifestV2.fromJson(<String, dynamic>{
  'version': 2,
  'modules': <String, dynamic>{
    'analyzer': _entry('0.1.0'),
    'qr': _entry('0.1.0'),
    'repo': _entry('0.1.0'),
  },
});

DownloadTask _task(int id, {String source = 'dart'}) => DownloadTask(
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
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

/// 记录调用次数的假下载服务（无 FFI / 无网络）。
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService(this.tag);

  final String tag;

  int downloadCalls = 0;
  int downloadWithContextCalls = 0;
  int pauseCalls = 0;

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
  }) async {
    downloadWithContextCalls++;
    return _task(1, source: tag);
  }

  @override
  Future<void> pause(int id) async {
    pauseCalls++;
  }

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
  Future<List<DownloadTask>> listTasks() async => <DownloadTask>[
        _task(1, source: tag),
      ];

  @override
  Stream<DownloadTask> watch(int id) => const Stream<DownloadTask>.empty();

  @override
  Stream<DownloadTask> watchAll() => const Stream<DownloadTask>.empty();
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

  group('download 清单可用性（离线、无网络）', () {
    test('模拟清单缺少 download → locateModuleAsset 返回 null（条目缺失分支）',
        () async {
      final client = _SourceBackedClient(_ManifestWithoutDownloadSource());

      final manifest = await client.load();
      expect(manifest, isNotNull);
      expect(
        manifest!.modules.containsKey('download'),
        isFalse,
        reason: '模拟来源确实不含 download 条目（与 release modules.json 同构）',
      );

      expect(
        await client.locateModuleAsset('download'),
        isNull,
        reason: '条目缺失 → null；但 null 不代表远端真的没有 download',
      );
    });

    test('模拟网络/解析失败 → locateModuleAsset 同样返回 null（null 语义二义）',
        () async {
      final client = _SourceBackedClient(_FailingSource());

      expect(
        await client.locateModuleAsset('download'),
        isNull,
        reason: '“条目缺失”与“网络/解析失败”都返回 null，无法区分 → '
            'live 探针不得作为“不存在”的证据',
      );
    });

    test('模拟缺少 download 的清单驱动 LazyDownloadService 走 Dart 完成下载，'
        '无异常且只告警一次', () async {
      final logs = _captureDebugPrint();
      final client = _SourceBackedClient(_ManifestWithoutDownloadSource());
      final dart = _FakeDownloadService('dart');
      final rust = _FakeDownloadService('rust');
      var probes = 0;

      final lazy = LazyDownloadService(
        dart,
        // 内核门：清单无 download → 无法解析出任何远端目标 → 不可用。
        rustProbe: () async {
          probes++;
          return (await client.locateModuleAsset('download')) != null;
        },
        rustServiceFactory: () => rust,
      );

      final task = await lazy.download('a', 'n', '1', 'u', 'f.apk');

      expect(task.appName, 'dart', reason: '清单无 download → 回退 Dart 完成下载');
      expect(dart.downloadCalls, 1);
      expect(rust.downloadCalls, 0);
      expect(probes, 1, reason: '解析单飞，只探测一次');
      expect(
        logs.where((l) => l.contains('LazyDownloadService')).length,
        1,
        reason: '回退只应打印一条 LazyDownloadService 告警',
      );

      // 已回退：后续变更类调用不再探测，继续走 Dart。
      await lazy.pause(1);
      expect(probes, 1);
      expect(dart.pauseCalls, 1);
      expect(rust.pauseCalls, 0);
    });
  });
}
