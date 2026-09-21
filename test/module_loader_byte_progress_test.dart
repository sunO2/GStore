// `RustModuleLoader` 字节进度端到端测试（经 `debugConfigure` 注入清单来源 +
// 下载器，无 FFI / 无网络）。
//
// 证明：实现 `ProgressAwareModuleFetcher` 的下载器会产生多个递增、位于
// `(0.05, 0.70)` 的下载阶段进度（而非旧实现的固定 0.05 → 0.7 跳变），且每个
// 进度都携带清单声明的权威体积 `sizeBytes`；未实现该接口的下载器退化为分步进度。
//
// ignore_for_file: file_names

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

/// 解析固定模块资产的假清单客户端（size 由清单声明）。
class _FakeManifestClient extends ModuleManifestClient {
  _FakeManifestClient({required this.manifest, required this.url});

  final ModuleManifestV2 manifest;
  final String url;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async => manifest;

  @override
  Future<ModuleAssetLocation?> locateModuleAsset(
    String moduleName, {
    bool forceRefresh = false,
  }) async {
    final entry = manifest.entry(moduleName);
    if (entry == null) return null;
    final asset = entry.forAbi('arm64-v8a');
    if (asset == null) return null;
    return ModuleAssetLocation(
      url: url,
      asset: asset.asset,
      sha256: asset.sha256,
      size: asset.size,
      version: entry.version,
      abi: 'arm64-v8a',
    );
  }
}

/// 逐字节上报进度的下载器（4 个采样点）。
class _ProgressFetcher implements ProgressAwareModuleFetcher {
  _ProgressFetcher(this.bytes);

  final Uint8List bytes;
  int fetchCalls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    fetchCalls++;
    return bytes;
  }

  @override
  Future<Uint8List?> fetchWithProgress(
    String url, {
    int? maxBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    fetchCalls++;
    final total = bytes.length;
    for (var i = 1; i <= 4; i++) {
      onProgress?.call((total * i) ~/ 4, total);
    }
    return bytes;
  }
}

/// 普通下载器：不实现进度子接口 → 应退化为无字节进度。
class _PlainFetcher implements ModuleFetcher {
  _PlainFetcher(this.bytes);

  final Uint8List bytes;
  int fetchCalls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    fetchCalls++;
    return bytes;
  }
}

ModuleManifestV2 _manifest(Uint8List bytes) {
  final sha = sha256.convert(bytes).toString();
  return ModuleManifestV2.fromJson(<String, dynamic>{
    'version': 2,
    'modules': <String, dynamic>{
      'qr': <String, dynamic>{
        'version': '0.5.0',
        'abi': <String, dynamic>{
          'arm64-v8a': <String, dynamic>{
            'asset': 'libgstore_mod_qr_0.5.0-arm64-v8a.so',
            'sha256': sha,
            'size': bytes.length,
          },
        },
      },
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final loader = RustModuleLoader.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gstore_byte_progress_');
    loader.debugReset();
    loader.resetDeviceAbiCache();
  });

  tearDown(() async {
    loader.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('ProgressAwareModuleFetcher：下载阶段产生多个递增且落在 (0.05, 0.70) 的进度',
      () async {
    final bytes = Uint8List.fromList(List<int>.generate(96, (i) => i));
    const url = 'https://example.invalid/libgstore_mod_qr_0.5.0-arm64-v8a.so';
    final source = _FakeManifestClient(manifest: _manifest(bytes), url: url);
    final fetcher = _ProgressFetcher(bytes);
    final fractions = <double>[];
    final sizes = <int?>[];

    loader.debugConfigure(
      supportDir: tmp.path,
      manifestSource: source,
      downloader: fetcher,
      isLoadedOverride: (_) async => false,
      mountOverride: (_) async => true,
    );

    final ok = await loader.ensureModule(
      'qr',
      onProgress: (fraction, {sizeBytes}) {
        fractions.add(fraction);
        sizes.add(sizeBytes);
      },
    );

    expect(ok, isTrue);
    expect(fetcher.fetchCalls, 1);

    // 起点 0.05，随后多个严格位于下载区间的字节进度。
    expect(fractions.first, 0.05);
    final downloadPhase =
        fractions.where((f) => f > 0.05 && f < 0.70).toList();
    expect(downloadPhase.length, greaterThanOrEqualTo(2),
        reason: '字节级下载应产生多次中间进度，而非仅 0.05 → 0.7 跳变');

    // 全程单调不减，并保留既有阶段点 0.7 / 0.85 / 1.0。
    for (var i = 1; i < fractions.length; i++) {
      expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
    }
    expect(fractions, containsAllInOrder(<double>[0.05, 0.7, 0.85, 1.0]));

    // sizeBytes：清单声明的权威体积出现在每个进度状态上。
    expect(sizes, everyElement(bytes.length));
  });

  test('普通 ModuleFetcher：无字节进度，退化为分步 [0.05, 0.7, 0.85, 1.0]',
      () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i + 1));
    const url = 'https://example.invalid/libgstore_mod_qr_0.5.0-arm64-v8a.so';
    final source = _FakeManifestClient(manifest: _manifest(bytes), url: url);
    final fetcher = _PlainFetcher(bytes);
    final fractions = <double>[];
    final sizes = <int?>[];

    loader.debugConfigure(
      supportDir: tmp.path,
      manifestSource: source,
      downloader: fetcher,
      isLoadedOverride: (_) async => false,
      mountOverride: (_) async => true,
    );

    final ok = await loader.ensureModule(
      'qr',
      onProgress: (fraction, {sizeBytes}) {
        fractions.add(fraction);
        sizes.add(sizeBytes);
      },
    );

    expect(ok, isTrue);
    expect(fetcher.fetchCalls, 1);
    expect(fractions, <double>[0.05, 0.7, 0.85, 1.0]);
    expect(sizes, everyElement(bytes.length));
  });
}
