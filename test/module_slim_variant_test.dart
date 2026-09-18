// Todo 1（slim-modules-apk-variant）：「内置存在 = 真实 .so 产物」语义。
//
// 覆盖精简包（排除 `libgstore_mod_*.so`）与完整包（内含产物）两条路径：
// * 清单声明内置但无产物 → 不得报告 builtin，ensureModule 必须远程下载而非降级；
// * 内置真实产物存在 → 挂载内置、零网络（完整包行为不变）；
// * `download` 内核在无内置/无本地时允许经 Dart 下载器自举；
// * 普通模块无内置/无本地时同样走有界远程；
// * 声明版本仍可读用于展示，但不构成可用性。
//
// 全部用例经 `debugConfigure` 注入临时 `supportDir`/清单/下载器/挂载覆盖，
// 不触发 FFI、path_provider 或真实网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:path/path.dart' as p;

/// 计数/固定字节的 [ModuleFetcher] 测试替身。
class _Fetcher implements ModuleFetcher {
  _Fetcher(this.bytes);

  final Uint8List? bytes;
  int calls = 0;
  final List<String> urls = [];

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    calls++;
    urls.add(url);
    return bytes;
  }
}

/// 固定清单的 [ModuleManifestSource] 测试替身（统计调用次数）。
class _FakeManifestSource implements ModuleManifestSource {
  _FakeManifestSource(this.manifest);

  final ModuleManifestV2? manifest;
  int loadCalls = 0;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async {
    loadCalls++;
    return manifest;
  }
}

/// 单模块单 ABI 的 v2 远端清单（x86_64）。
Map<String, dynamic> _manifest({
  required String module,
  required String version,
  required String sha256Hex,
  required int size,
  String abi = 'x86_64',
}) =>
    {
      'version': 2,
      'modules': {
        module: {
          'version': version,
          'abi': {
            abi: {
              'asset': 'libgstore_mod_${module}_$version-$abi.so',
              'sha256': sha256Hex,
              'size': size,
            },
          },
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeSupportDir() {
    final dir = Directory.systemTemp.createTempSync('gstore_slim_test_');
    tempDirs.add(dir);
    return dir;
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux; // deviceAbi=x86_64
  });

  tearDown(() {
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
    debugDefaultTargetPlatformOverride = null;
    for (final dir in tempDirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    tempDirs.clear();
  });

  group('slim 变体：声明内置但无产物', () {
    test('isAvailable/probe 不报告 builtin；ensureModule 远程下载而非降级', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('REMOTE_QR_SO'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        // 远端清单提供可安装资产（版本高于内置声明）。
        manifestOverride: _manifest(
          module: 'qr',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        // 精简包：声明仍在，但 APK 不含 libgstore_mod_qr.so。
        builtinManifestOverride: {
          'qr': {'version': '0.1.0'},
        },
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      // 可用性不得由清单声明推断。
      expect(await loader.isAvailable('qr'), isFalse,
          reason: '无真实内置产物 → 不可用（远程不算本地可用）');
      final status = await loader.probe('qr', withRemote: true);
      expect(status.source, isNot('builtin'),
          reason: '无产物不得报告 builtin');
      expect(status.source, 'remote', reason: '有可解析远端 → 展示为可下载');
      expect(status.exists, isTrue);
      // 声明版本仍可读用于展示，但不代表可用。
      expect(status.version, '0.1.0');
      expect(status.remoteVersion, '0.2.0');

      // 关键：必须走一次有界远程安装 + 挂载，而不是「有声明就降级」。
      expect(await loader.ensureModule('qr'), isTrue,
          reason: '声明但无产物必须回退远程下载，不得降级');
      expect(fetcher.calls, 1, reason: '恰好一次有界远程下载');
      expect(mounted, hasLength(1), reason: '安装后恰好一次挂载');
      expect(mounted.single, endsWith('libgstore_mod_qr_0.2.0.so'));
    });
  });

  group('完整包：内置真实产物存在', () {
    test('挂载内置且零网络（完整包行为不变）', () async {
      final supportDir = makeSupportDir();
      final builtinFile = File(
        p.join(supportDir.path, 'extracted_libgstore_mod_qr.so'),
      )..writeAsBytesSync(utf8.encode('BUILTIN_QR_BYTES'));
      final payload = Uint8List.fromList(utf8.encode('SHOULD_NOT_DOWNLOAD'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        manifestOverride: _manifest(
          module: 'qr',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: {
          'qr': {'version': '0.1.0'},
        },
        // 内置产物真实存在（桌面测试经 override 模拟随包 .so）。
        builtinSoPathOverride: (name) async =>
            name == 'qr' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.isAvailable('qr'), isTrue);
      final status = await loader.probe('qr', withRemote: true);
      expect(status.source, 'builtin');
      expect(status.exists, isTrue);
      expect(status.soPath, builtinFile.path);
      expect(status.version, '0.1.0');

      expect(await loader.ensureModule('qr'), isTrue);
      expect(mounted.single, builtinFile.path, reason: '必须挂载内置产物');
      expect(fetcher.calls, 0, reason: '内置存在：零下载');
      expect(source.loadCalls, 0, reason: '内置存在：零清单网络');
    });

    test('内置产物存在但挂载失败 → 降级且零网络（绝不回退远程）', () async {
      final supportDir = makeSupportDir();
      final builtinFile = File(
        p.join(supportDir.path, 'extracted_libgstore_mod_qr.so'),
      )..writeAsBytesSync(utf8.encode('UNMOUNTABLE_BUILTIN'));
      final payload = Uint8List.fromList(utf8.encode('MUST_NOT_DOWNLOAD'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      var mountCalls = 0;

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        manifestOverride: _manifest(
          module: 'qr',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: {
          'qr': {'version': '0.1.0'},
        },
        builtinSoPathOverride: (name) async =>
            name == 'qr' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async {
          mountCalls++;
          return false; // 内置挂载失败
        },
      );

      // 有内置真实产物即降级（完整包语义），绝不因挂载失败而远程下载。
      expect(await loader.ensureModule('qr'), isFalse);
      expect(mountCalls, 1);
      expect(fetcher.calls, 0, reason: '内置存在：挂载失败也不得联网');
      expect(source.loadCalls, 0);
    });
  });

  group('slim 变体：无内置且无本地', () {
    test('download 内核允许经 Dart 下载器自举（fetch/mount 各一次）', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('DL_KERNEL_SO'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestOverride: _manifest(
          module: 'download',
          version: '0.1.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        // 精简包仍保留 download 的声明，但无产物。
        builtinManifestOverride: {
          'download': {'version': '0.1.0'},
        },
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('download'), isTrue,
          reason: 'slim 场景下 download 内核必须可自举');
      expect(fetcher.calls, 1, reason: '恰好一次有界自举下载');
      expect(mounted, hasLength(1), reason: '自举后必须挂载');
      expect(mounted.single, endsWith('libgstore_mod_download_0.1.0.so'));
    });

    test('qr 等普通模块无内置/无本地 → 仍然远程自举（行为不变）', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('QR_REMOTE_SO'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestOverride: _manifest(
          module: 'qr',
          version: '1.0.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('qr'), isTrue);
      expect(fetcher.calls, 1);
      expect(mounted, hasLength(1));
      expect(mounted.single, endsWith('libgstore_mod_qr_1.0.0.so'));
    });
  });

  group('download 内核收窄守卫：已有产物不联网（回归）', () {
    test('download 已有内置产物 + 配置远端 → 使用内置、零远程自举', () async {
      final supportDir = makeSupportDir();
      final builtinFile = File(
        p.join(supportDir.path, 'extracted_libgstore_mod_download.so'),
      )..writeAsBytesSync(utf8.encode('BUILTIN_DOWNLOAD'));
      final payload = Uint8List.fromList(utf8.encode('MUST_NOT_DOWNLOAD_DL'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        manifestOverride: _manifest(
          module: 'download',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: {
          'download': {'version': '0.1.0'},
        },
        builtinSoPathOverride: (name) async =>
            name == 'download' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      final result = await loader.ensureModule('download');
      // 实际观察到的行为：已有内置产物 → 直接挂载内置，绝不进入远程自举。
      expect(mounted, [builtinFile.path], reason: '必须使用已存在的内置产物');
      expect(result, isTrue, reason: '内置可挂载 → ready（未触发自举）');
      expect(fetcher.calls, 0, reason: '已有产物：零远程下载');
      expect(source.loadCalls, 0, reason: '已有产物：零清单网络');
      // 未发生远程安装：不得创建模块下载目录/远端产物。
      expect(
        Directory(p.join(supportDir.path, 'gstore_modules', 'download'))
            .existsSync(),
        isFalse,
        reason: '未发生远程安装，不得创建下载目录',
      );
    });

    test('download 已有有效本地产物 + 配置远端 → 使用本地、零远程自举', () async {
      final supportDir = makeSupportDir();
      final dir = Directory(
        p.join(supportDir.path, 'gstore_modules', 'download'),
      )..createSync(recursive: true);
      final localBytes = utf8.encode('LOCAL_DOWNLOAD_SO');
      final localSo =
          File(p.join(dir.path, 'libgstore_mod_download_0.1.0.so'))
            ..writeAsBytesSync(localBytes);
      File('${localSo.path}.meta').writeAsStringSync(jsonEncode({
        'name': 'download',
        'version': '0.1.0',
        'abi': 'x86_64',
        'sha256': sha256.convert(localBytes).toString(),
        'source': 'remote',
      }));
      final payload = Uint8List.fromList(utf8.encode('MUST_NOT_DOWNLOAD_DL'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      final mounted = <String>[];

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        manifestOverride: _manifest(
          module: 'download',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      final result = await loader.ensureModule('download');
      expect(mounted, [localSo.path], reason: '必须使用已存在的本地产物');
      expect(result, isTrue, reason: '本地可挂载 → ready（未触发自举）');
      expect(fetcher.calls, 0, reason: '已有本地有效产物：零远程下载');
      expect(source.loadCalls, 0, reason: '已有本地有效产物：零清单网络');
      expect(
        File(p.join(dir.path, 'libgstore_mod_download_0.2.0.so')).existsSync(),
        isFalse,
        reason: '不得发生远程安装（无 0.2.0 产物）',
      );
    });

    test('download 已有内置产物且未配置远端 → 仍使用内置、零远程', () async {
      final supportDir = makeSupportDir();
      final builtinFile = File(
        p.join(supportDir.path, 'extracted_libgstore_mod_download.so'),
      )..writeAsBytesSync(utf8.encode('BUILTIN_DOWNLOAD_NO_REMOTE'));
      final fetcher = _Fetcher(null);
      final mounted = <String>[];

      // 明确不配置 remoteBaseUrl / manifestSource / manifestOverride。
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        builtinManifestOverride: {
          'download': {'version': '0.1.0'},
        },
        builtinSoPathOverride: (name) async =>
            name == 'download' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      final result = await loader.ensureModule('download');
      expect(mounted, [builtinFile.path]);
      expect(result, isTrue, reason: '无远端也应以内置产物就绪');
      expect(fetcher.calls, 0, reason: '已有产物：零下载');
    });

    test('download 已有内置产物但挂载失败 → false 且零远程（不降级为自举）', () async {
      final supportDir = makeSupportDir();
      final builtinFile = File(
        p.join(supportDir.path, 'extracted_libgstore_mod_download.so'),
      )..writeAsBytesSync(utf8.encode('UNMOUNTABLE_DOWNLOAD'));
      final payload = Uint8List.fromList(utf8.encode('MUST_NOT_DOWNLOAD_DL'));
      final sha = sha256.convert(payload).toString();
      final fetcher = _Fetcher(payload);
      final source = _FakeManifestSource(null);
      var mountCalls = 0;

      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        downloader: fetcher,
        manifestSource: source,
        manifestOverride: _manifest(
          module: 'download',
          version: '0.2.0',
          sha256Hex: sha,
          size: payload.length,
        ),
        builtinManifestOverride: {
          'download': {'version': '0.1.0'},
        },
        builtinSoPathOverride: (name) async =>
            name == 'download' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async {
          mountCalls++;
          return false; // 内置挂载失败
        },
      );

      // 有内置真实产物即降级，绝不因挂载失败而远程自举。
      expect(await loader.ensureModule('download'), isFalse);
      expect(mountCalls, 1);
      expect(fetcher.calls, 0, reason: '已有内置产物：挂载失败也不得联网');
      expect(source.loadCalls, 0);
    });
  });

  group('声明版本仅用于展示', () {
    test('无产物时 version 可读，但 isAvailable=false 且 source != builtin', () async {
      final supportDir = makeSupportDir();
      loader.debugConfigure(
        supportDir: supportDir.path,
        builtinManifestOverride: {
          'qr': {'version': '1.2.3'},
        },
        isLoadedOverride: (_) async => false,
      );

      expect(await loader.isAvailable('qr'), isFalse);
      final status = await loader.probe('qr');
      expect(status.source, isNot('builtin'));
      expect(status.exists, isFalse,
          reason: '版本可读不代表产物存在/可用');
      expect(status.version, '1.2.3',
          reason: 'manifest 版本仍应可用于展示/比较');
    });
  });
}
