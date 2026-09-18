import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:path/path.dart' as p;

/// 4 个 ABI 的确定性 SHA-256（各 64 位十六进制）。
final _shaArm64 = List.filled(32, 'a1').join();
final _shaArmv7 = List.filled(32, 'b2').join();
final _shaX86 = List.filled(32, 'c3').join();
final _shaX64 = List.filled(32, 'd4').join();

Map<String, dynamic> _asset(String name, String sha, int size) => {
      'asset': name,
      'sha256': sha,
      'size': size,
    };

/// 全 4 ABI 的 v2 清单 fixture。
Map<String, dynamic> _fixtureV2() => {
      'version': 2,
      'modules': {
        'qr': {
          'version': '1.2.3',
          'min_host_abi': '1.0.0',
          'abi': {
            'arm64-v8a': _asset(
                'libgstore_mod_qr_1.2.3-arm64-v8a.so', _shaArm64, 111),
            'armeabi-v7a': _asset(
                'libgstore_mod_qr_1.2.3-armeabi-v7a.so', _shaArmv7, 222),
            'x86': _asset('libgstore_mod_qr_1.2.3-x86.so', _shaX86, 333),
            'x86_64': _asset('libgstore_mod_qr_1.2.3-x86_64.so', _shaX64, 444),
          },
        },
      },
    };

/// 旧 schema（模块条目含 `file_name`）。
Map<String, dynamic> _legacyFixture() => {
      'version': 2,
      'modules': {
        'qr': {
          'version': '1.0.0',
          'file_name': 'libgstore_mod_qr.so',
          'sha256': _shaArm64,
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeTempDir() {
    final dir = Directory.systemTemp.createTempSync('gstore_manifest_test_');
    tempDirs.add(dir);
    return dir;
  }

  tearDown(() {
    loader.debugReset();
    loader.remoteBaseUrl = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gstore/apk_source'), null);
    for (final dir in tempDirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    tempDirs.clear();
  });

  group('ModuleManifestV2 解析', () {
    test('4 ABI fixture：每个资产的 asset/sha256/size 均正确', () {
      final manifest = ModuleManifestV2.fromJson(_fixtureV2());
      expect(manifest.version, 2);

      final entry = manifest.entry('qr');
      expect(entry, isNotNull);
      expect(entry!.version, '1.2.3');
      expect(entry.minHostAbi, '1.0.0');

      final arm64 = entry.forAbi('arm64-v8a');
      expect(arm64, isNotNull);
      expect(arm64!.asset, 'libgstore_mod_qr_1.2.3-arm64-v8a.so');
      expect(arm64.sha256, _shaArm64);
      expect(arm64.size, 111);

      final armv7 = entry.forAbi('armeabi-v7a');
      expect(armv7!.asset, 'libgstore_mod_qr_1.2.3-armeabi-v7a.so');
      expect(armv7.sha256, _shaArmv7);
      expect(armv7.size, 222);

      final x86 = entry.forAbi('x86');
      expect(x86!.asset, 'libgstore_mod_qr_1.2.3-x86.so');
      expect(x86.sha256, _shaX86);
      expect(x86.size, 333);

      final x64 = entry.forAbi('x86_64');
      expect(x64!.asset, 'libgstore_mod_qr_1.2.3-x86_64.so');
      expect(x64.sha256, _shaX64);
      expect(x64.size, 444);
    });

    test('缺失 abi / abi 非 Map → forAbi 返回 null，不崩溃', () {
      final noAbi = ModuleManifestV2.fromJson({
        'version': 2,
        'modules': {
          'qr': {'version': '1.0.0'},
        },
      });
      expect(noAbi.entry('qr')!.forAbi('arm64-v8a'), isNull);

      final badAbi = ModuleManifestV2.fromJson({
        'version': 2,
        'modules': {
          'qr': {'version': '1.0.0', 'abi': 'not-a-map'},
        },
      });
      expect(badAbi.entry('qr')!.forAbi('arm64-v8a'), isNull);

      final listAbi = ModuleManifestV2.fromJson({
        'version': 2,
        'modules': {
          'qr': {
            'version': '1.0.0',
            'abi': ['arm64-v8a'],
          },
        },
      });
      expect(listAbi.entry('qr')!.forAbi('arm64-v8a'), isNull);
    });

    test('缺失 sha256/asset/size → 该资产无效，其他 ABI 不受影响', () {
      final manifest = ModuleManifestV2.fromJson({
        'version': 2,
        'modules': {
          'qr': {
            'version': '1.0.0',
            'abi': {
              'arm64-v8a': {'asset': 'a.so', 'size': 10}, // 缺 sha256
              'armeabi-v7a': {'sha256': _shaArmv7, 'size': 10}, // 缺 asset
              'x86': {'asset': 'c.so', 'sha256': _shaX86}, // 缺 size
              'x86_64': _asset('d.so', _shaX64, 444), // 合法
            },
          },
        },
      });

      final entry = manifest.entry('qr')!;
      expect(entry.forAbi('arm64-v8a'), isNull);
      expect(entry.forAbi('armeabi-v7a'), isNull);
      expect(entry.forAbi('x86'), isNull);
      expect(entry.forAbi('x86_64'), isNotNull);
      expect(entry.forAbi('x86_64')!.sha256, _shaX64);
    });

    test('size 允许数字字符串，非法/负数/空 sha256 → 无效', () {
      final manifest = ModuleManifestV2.fromJson({
        'version': 2,
        'modules': {
          'qr': {
            'version': '1.0.0',
            'abi': {
              'arm64-v8a': _asset('a.so', _shaArm64, 128)..['size'] = '128',
              'armeabi-v7a': _asset('b.so', _shaArmv7, 1)..['size'] = 'abc',
              'x86': _asset('c.so', _shaX86, 1)..['size'] = -1,
              'x86_64': {'asset': 'd.so', 'sha256': '', 'size': 10},
            },
          },
        },
      });

      final entry = manifest.entry('qr')!;
      expect(entry.forAbi('arm64-v8a')!.size, 128);
      expect(entry.forAbi('armeabi-v7a'), isNull);
      expect(entry.forAbi('x86'), isNull);
      expect(entry.forAbi('x86_64'), isNull);
    });

    test('旧 file_name schema → 抛 ModuleManifestFormatException（可断言）', () {
      expect(
        () => ModuleManifestV2.fromJson(_legacyFixture()),
        throwsA(
          isA<ModuleManifestFormatException>().having(
            (e) => e.message,
            'message',
            contains('file_name'),
          ),
        ),
      );

      // 顶层 file_name 同样显式拒绝
      expect(
        () => ModuleManifestV2.fromJson({
          'version': 1,
          'file_name': 'libgstore_mod_qr.so',
        }),
        throwsA(
          isA<ModuleManifestFormatException>().having(
            (e) => e.message,
            'message',
            contains('file_name'),
          ),
        ),
      );

      // entry 级 file_name 同样显式拒绝
      expect(
        () => ModuleManifestV2.fromJson({
          'version': 2,
          'modules': {
            'qr': {
              'version': '1.0.0',
              'file_name': 'libgstore_mod_qr.so',
              'abi': {'arm64-v8a': _asset('a.so', _shaArm64, 1)},
            },
          },
        }),
        throwsA(isA<ModuleManifestFormatException>()),
      );
    });

    test('version != 2 → 显式拒绝；modules 非对象 → 显式拒绝', () {
      expect(
        () => ModuleManifestV2.fromJson({'version': 3, 'modules': {}}),
        throwsA(
          isA<ModuleManifestFormatException>()
              .having((e) => e.message, 'message', contains('version')),
        ),
      );
      expect(
        () => ModuleManifestV2.fromJson({'version': 2, 'modules': 'nope'}),
        throwsA(isA<ModuleManifestFormatException>()),
      );
      expect(
        () => ModuleManifestV2.fromJson({'version': 'not-int', 'modules': {}}),
        throwsA(isA<ModuleManifestFormatException>()),
      );
    });
  });

  group('debugConfigure 测试接缝', () {
    test('isLoadedOverride=true 短路 ensureModule：零通道、零挂载', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      var channelCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('gstore/apk_source'),
        (call) async {
          channelCalls++;
          return null;
        },
      );
      var mountCalls = 0;

      loader.debugConfigure(
        isLoadedOverride: (name) async => true,
        mountOverride: (soPath) async {
          mountCalls++;
          return true;
        },
      );

      expect(await loader.ensureModule('qr'), isTrue);
      expect(channelCalls, 0, reason: 'isLoaded 短路后不得触碰平台通道');
      expect(mountCalls, 0, reason: '已加载模块不得再次挂载');
    });

    test('supportDir + mountOverride：本地产物经注入挂载，无网络', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final supportDir = makeTempDir();
      final moduleDir = Directory(p.join(supportDir.path, 'gstore_modules', 'qr'))
        ..createSync(recursive: true);
      File(p.join(moduleDir.path, 'libgstore_mod_qr_1.0.0.so'))
          .writeAsBytesSync(utf8.encode('FAKE_SO'));

      final mountedPaths = <String>[];
      var fetchCalls = 0;
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (name) async => false,
        mountOverride: (soPath) async {
          mountedPaths.add(soPath);
          return true;
        },
        downloader: _CountingFetcher(onFetch: () => fetchCalls++),
      );

      expect(await loader.ensureModule('qr'), isTrue);
      expect(mountedPaths, hasLength(1));
      expect(mountedPaths.single, endsWith('libgstore_mod_qr_1.0.0.so'));
      expect(fetchCalls, 0, reason: '已有本地产物 → 零网络/零下载');
    });

    test('manifestOverride 版本更新 + downloader 注入：真实安装路径无网络', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final supportDir = makeTempDir();
      final moduleDir = Directory(p.join(supportDir.path, 'gstore_modules', 'qr'))
        ..createSync(recursive: true);
      File(p.join(moduleDir.path, 'libgstore_mod_qr_1.0.0.so'))
          .writeAsBytesSync(utf8.encode('OLD'));
      File(p.join(moduleDir.path, 'version')).writeAsStringSync('1.0.0');

      final payload = Uint8List.fromList(utf8.encode('NEW_SO_BYTES'));
      final payloadSha = sha256.convert(payload).toString();
      loader.remoteBaseUrl = 'https://example.com/release';

      final fetchedUrls = <String>[];
      final mountedPaths = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: {
          'version': 2,
          'modules': {
            'qr': {
              'version': '2.0.0',
              'abi': {
                'x86_64': {
                  'asset': 'libgstore_mod_qr_2.0.0-x86_64.so',
                  'sha256': payloadSha,
                  'size': payload.length,
                  'signature': 'deadbeef',
                },
              },
            },
          },
        },
        downloader: _CountingFetcher(
          onFetch: () {},
          result: payload,
          onUrl: fetchedUrls.add,
        ),
        isLoadedOverride: (name) async => false,
        mountOverride: (soPath) async {
          mountedPaths.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('qr'), isTrue);
      expect(
        fetchedUrls.single,
        'https://example.com/release/x86_64/libgstore_mod_qr_2.0.0-x86_64.so',
      );
      expect(mountedPaths, hasLength(1));
      expect(
        File(p.join(moduleDir.path, 'libgstore_mod_qr_2.0.0.so')).existsSync(),
        isTrue,
      );
    });

    test('manifestSource 注入生效（Todo 8 接口契约）', () async {
      final source = _FakeManifestSource(ModuleManifestV2.fromJson(_fixtureV2()));
      loader.debugConfigure(manifestSource: source);

      final loaded = await loader.debugLoadManifest();
      expect(loaded, isNotNull);
      expect(loaded!.entry('qr')!.forAbi('x86')!.sha256, _shaX86);

      // 缓存命中：同一次流程只调用来源一次
      await loader.debugLoadManifest();
      expect(source.loadCalls, 1);
    });

    test('debugReset 还原默认，manifestOverride 不泄漏', () async {
      loader.debugConfigure(
        manifestOverride: _fixtureV2(),
        supportDir: makeTempDir().path,
        isLoadedOverride: (name) async => true,
        mountOverride: (soPath) async => true,
        clock: () => DateTime.utc(2026),
      );
      expect(loader.debugSeamActive, isTrue);
      expect(await loader.debugLoadManifest(), isNotNull);

      loader.debugReset();
      expect(loader.debugSeamActive, isFalse);
      expect(loader.debugClock, isNull);
      // 无 remoteBaseUrl、无覆盖 → 不再命中旧 manifest
      expect(await loader.debugLoadManifest(), isNull);
    });

    test('重新 debugConfigure 会清掉旧清单缓存', () async {
      loader.debugConfigure(manifestOverride: _fixtureV2());
      expect((await loader.debugLoadManifest())!.entry('qr')!.version, '1.2.3');

      loader.debugConfigure(
        manifestOverride: {
          'version': 2,
          'modules': {
            'qr': {'version': '9.9.9', 'abi': {}},
          },
        },
      );
      expect((await loader.debugLoadManifest())!.entry('qr')!.version, '9.9.9');
    });
  });
}

/// 计数/可注入返回值的 [ModuleFetcher] 测试替身。
class _CountingFetcher implements ModuleFetcher {
  _CountingFetcher({
    required this.onFetch,
    this.result,
    this.onUrl,
  });

  final void Function() onFetch;
  final Uint8List? result;
  final void Function(String url)? onUrl;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    onFetch();
    onUrl?.call(url);
    return result;
  }
}

/// 固定返回一份清单的 [ModuleManifestSource] 测试替身。
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
