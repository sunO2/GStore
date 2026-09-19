import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

class _FakeManifestClient extends ModuleManifestClient {
  _FakeManifestClient({required this.manifest, required this.url});

  final ModuleManifestV2 manifest;
  final String url;
  int loadCalls = 0;
  int locateCalls = 0;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async {
    loadCalls++;
    return manifest;
  }

  @override
  Future<ModuleAssetLocation?> locateModuleAsset(
    String moduleName, {
    bool forceRefresh = false,
  }) async {
    locateCalls++;
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

class _FakeFetcher implements ModuleFetcher {
  _FakeFetcher(this.bytes);

  final Uint8List bytes;
  final List<String> urls = <String>[];

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    urls.add(url);
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final loader = RustModuleLoader.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gstore_remote_wiring_');
    loader.debugReset();
    loader.resetDeviceAbiCache();
  });

  tearDown(() async {
    loader.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('configureRemote 接线远程源后：probe 报 remote，ensureModule 下载并挂载', () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final sha = sha256.convert(bytes).toString();
    const url = 'https://example.invalid/libgstore_mod_qr_0.2.0-arm64-v8a.so';
    final manifest = ModuleManifestV2.fromJson(<String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'qr': <String, dynamic>{
          'version': '0.2.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_qr_0.2.0-arm64-v8a.so',
              'sha256': sha,
              'size': bytes.length,
            },
          },
        },
      },
    });
    final source = _FakeManifestClient(manifest: manifest, url: url);
    final fetcher = _FakeFetcher(bytes);
    final mounted = <String>[];

    loader.debugConfigure(
      supportDir: tmp.path,
      isLoadedOverride: (_) async => false,
      mountOverride: (soPath) async {
        mounted.add(soPath);
        return true;
      },
    );

    final before = await loader.probe('qr', withRemote: true);
    expect(before.source, 'none');
    expect(before.remoteVersion, isNull);
    expect(await loader.ensureModule('qr'), isFalse);

    loader.configureRemote(manifestSource: source, downloader: fetcher);

    final after = await loader.probe('qr', withRemote: true);
    expect(after.source, 'remote');
    expect(after.remoteVersion, '0.2.0');
    expect(after.updateAvailable, isTrue);

    expect(await loader.ensureModule('qr'), isTrue);
    expect(source.locateCalls, greaterThanOrEqualTo(1));
    expect(fetcher.urls, <String>[url]);
    expect(mounted, hasLength(1));
    expect(File(mounted.single).existsSync(), isTrue);

    final status = await loader.probe('qr', withRemote: true);
    expect(status.source, 'downloaded');
    expect(status.version, '0.2.0');
  });

  test('slim：内置声明版本与远端相同但无真实内置产物 → downloadAndInstall 仍安装', () async {
    final bytes = Uint8List.fromList(List<int>.generate(48, (i) => i + 1));
    final sha = sha256.convert(bytes).toString();
    const url = 'https://example.invalid/libgstore_mod_qr_0.1.0-arm64-v8a.so';
    final manifest = ModuleManifestV2.fromJson(<String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'qr': <String, dynamic>{
          'version': '0.1.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_qr_0.1.0-arm64-v8a.so',
              'sha256': sha,
              'size': bytes.length,
            },
          },
        },
      },
    });
    final source = _FakeManifestClient(manifest: manifest, url: url);
    final fetcher = _FakeFetcher(bytes);

    loader.debugConfigure(
      supportDir: tmp.path,
      builtinManifestOverride: <String, dynamic>{
        'qr': <String, dynamic>{'version': '0.1.0'},
      },
      isLoadedOverride: (_) async => false,
      mountOverride: (_) async => true,
    );
    loader.configureRemote(manifestSource: source, downloader: fetcher);

    final status = await loader.probe('qr', withRemote: true);
    expect(status.source, 'remote');
    expect(status.remoteVersion, '0.1.0');
    expect(status.updateAvailable, isFalse);

    expect(await loader.downloadAndInstall('qr'), isTrue);
    expect(fetcher.urls, <String>[url]);
  });

  test('allowDownload=false：本地/内置皆无时不联网，返回 false', () async {
    final bytes = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final sha = sha256.convert(bytes).toString();
    const url = 'https://example.invalid/libgstore_mod_qr_0.1.0-arm64-v8a.so';
    final manifest = ModuleManifestV2.fromJson(<String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'qr': <String, dynamic>{
          'version': '0.1.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_qr_0.1.0-arm64-v8a.so',
              'sha256': sha,
              'size': bytes.length,
            },
          },
        },
      },
    });
    final source = _FakeManifestClient(manifest: manifest, url: url);
    final fetcher = _FakeFetcher(bytes);

    loader.debugConfigure(
      supportDir: tmp.path,
      isLoadedOverride: (_) async => false,
      mountOverride: (_) async => true,
    );
    loader.configureRemote(manifestSource: source, downloader: fetcher);

    expect(await loader.ensureModule('qr', allowDownload: false), isFalse);
    expect(fetcher.urls, isEmpty, reason: '启动路径禁止下载：不得产生网络请求');

    expect(await loader.ensureModule('qr'), isTrue);
    expect(fetcher.urls, hasLength(1));
  });

  test('download 内核：默认禁止自举，allowBootstrap=true 才下载', () async {
    final bytes = Uint8List.fromList(List<int>.generate(40, (i) => i + 2));
    final sha = sha256.convert(bytes).toString();
    const url =
        'https://example.invalid/libgstore_mod_download_0.1.0-arm64-v8a.so';
    final manifest = ModuleManifestV2.fromJson(<String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'download': <String, dynamic>{
          'version': '0.1.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_download_0.1.0-arm64-v8a.so',
              'sha256': sha,
              'size': bytes.length,
            },
          },
        },
      },
    });
    final source = _FakeManifestClient(manifest: manifest, url: url);
    final fetcher = _FakeFetcher(bytes);

    loader.debugConfigure(
      supportDir: tmp.path,
      isLoadedOverride: (_) async => false,
      mountOverride: (_) async => true,
    );
    loader.configureRemote(manifestSource: source, downloader: fetcher);

    expect(await loader.downloadAndInstall('download'), isFalse);
    expect(fetcher.urls, isEmpty, reason: '未显式允许时 download 内核不得自举');

    expect(
      await loader.downloadAndInstall('download', allowBootstrap: true),
      isTrue,
    );
    expect(fetcher.urls, <String>[url]);
  });
}
