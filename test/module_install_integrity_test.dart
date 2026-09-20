// Task 4：原子配对安装 + 挂载期哈希复核 + `requireSignature` 开关。
//
// 全部用例经 `debugConfigure` 注入临时 `supportDir`/清单/下载器/挂载覆盖，
// 不触发 FFI、path_provider 或真实网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:path/path.dart' as p;

/// 固定字节的 [ModuleFetcher] 测试替身（统计调用次数/URL）。
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

/// 带闸门的 [ModuleFetcher]：首次/每次下载都被 [gate] 挂起，用于制造
/// 「同一模块安装仍在途」的并发窗口（单飞测试）。
class _GatedFetcher implements ModuleFetcher {
  _GatedFetcher(this.bytes);

  final Uint8List? bytes;
  int calls = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    calls++;
    await gate.future;
    return bytes;
  }
}

/// 并发可见的闸门下载器：统计调用次数与**同时在途**的下载数。
///
/// 用于证明「同一模块的安装串行化」——若不同入口的安装未被同一把锁串行，
/// 第二次下载会在第一次仍被 [gate] 挂起时就开始，从而 [maxActive] 达到 2。
class _ConcurrencyFetcher implements ModuleFetcher {
  _ConcurrencyFetcher(this.bytes);

  final Uint8List? bytes;
  int calls = 0;
  int active = 0;
  int maxActive = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await gate.future;
      return bytes;
    } finally {
      active--;
    }
  }
}

/// 首次下载失败（返回 `null`）、此后成功的下载器（失败非粘滞测试）。
class _FlakyFetcher implements ModuleFetcher {
  _FlakyFetcher(this.bytes);

  final Uint8List bytes;
  int calls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    calls++;
    return calls == 1 ? null : bytes;
  }
}

/// 首次 fetch **永不完成**（模拟挂起的传输），此后返回固定字节。
///
/// 用于证明「挂起的下载会被有界超时打断、释放安装锁，且后续调用可真正重试」。
class _HangingThenOkFetcher implements ModuleFetcher {
  _HangingThenOkFetcher(this.bytes);

  final Uint8List bytes;
  int calls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) {
    calls++;
    if (calls == 1) {
      return Completer<Uint8List?>().future; // 永不完成
    }
    return Future<Uint8List?>.value(bytes);
  }
}

/// 反复泵事件队列直到 [condition] 成立（或超时失败），用于等待真实异步
/// 文件 IO 推进到下载阶段。
Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await pumpEventQueue(times: 1);
  }
  expect(condition(), isTrue, reason: '条件在超时前未满足');
}

/// 构造单模块单 ABI 的 v2 清单。
Map<String, dynamic> _manifest({
  required String module,
  required String version,
  required String asset,
  required String sha256Hex,
  required int size,
  String? signature,
  String abi = 'x86_64',
}) =>
    {
      'version': 2,
      'modules': {
        module: {
          'version': version,
          'abi': {
            abi: {
              'asset': asset,
              'sha256': sha256Hex,
              'size': size,
              if (signature != null) 'signature': signature,
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
    final dir = Directory.systemTemp.createTempSync('gstore_install_test_');
    tempDirs.add(dir);
    return dir;
  }

  Directory moduleDir(Directory supportDir, String name) =>
      Directory(p.join(supportDir.path, 'gstore_modules', name));

  List<String> listBase(Directory dir) {
    if (!dir.existsSync()) return const [];
    return dir.listSync().map((e) => p.basename(e.path)).toList();
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

  group('原子配对安装', () {
    test('requireSignature=false 安装成功且不创建 .sig', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_V1'));
      final sha = sha256.convert(payload).toString();

      loader.requireSignature = false;
      loader.remoteBaseUrl = 'https://example.com/release';
      final fetcher = _Fetcher(payload);
      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
          signature: 'deadbeef', // 清单有签名，但 requireSignature=false 不写 .sig
        ),
        downloader: fetcher,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      final dir = moduleDir(supportDir, 'x');
      final so = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so'));
      expect(so.existsSync(), isTrue, reason: '最终 .so 必须存在');
      expect(File('${so.path}.meta').existsSync(), isTrue,
          reason: '提交标记 .meta 必须存在');
      expect(File('${so.path}.sig').existsSync(), isFalse,
          reason: 'requireSignature=false 绝不创建 .sig');
      expect(fetcher.calls, 1);
      expect(mounted, hasLength(1));
      expect(mounted.single, endsWith('libgstore_mod_x_1.0.0.so'));
    });

    test('requireSignature=true 且清单缺 signature → 拒绝且无最终产物', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_V1'));
      final sha = sha256.convert(payload).toString();

      loader.requireSignature = true;
      loader.remoteBaseUrl = 'https://example.com/release';
      final fetcher = _Fetcher(payload);
      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
          // 无 signature
        ),
        downloader: fetcher,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(fetcher.calls, 0, reason: '签名缺失必须在下载前拒绝');
      expect(mounted, isEmpty);
      final files = listBase(moduleDir(supportDir, 'x'));
      expect(files.where((f) => f.endsWith('.so')), isEmpty);
      expect(files.where((f) => f.endsWith('.meta')), isEmpty);
      expect(files.where((f) => f.endsWith('.sig')), isEmpty);
      expect(files.where((f) => f.endsWith('.tmp')), isEmpty);
    });

    test('requireSignature=true 且清单有签名 → 写非空 .sig 并挂载', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_SIGNED'));
      final sha = sha256.convert(payload).toString();

      loader.requireSignature = true;
      loader.remoteBaseUrl = 'https://example.com/release';
      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '2.0.0',
          asset: 'libgstore_mod_x_2.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
          signature: 'cafebabe',
        ),
        downloader: _Fetcher(payload),
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      final so = File(p.join(
          moduleDir(supportDir, 'x').path, 'libgstore_mod_x_2.0.0.so'));
      final sig = File('${so.path}.sig');
      expect(sig.existsSync(), isTrue);
      expect(sig.readAsStringSync().trim().isNotEmpty, isTrue,
          reason: '不得写出空 .sig');
      expect(mounted, hasLength(1));
    });

    test('SHA-256 与清单不符 → 无最终 .so、无 .meta、无残留 .tmp', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('TAMPERED_BYTES'));
      final wrongSha = sha256
          .convert(Uint8List.fromList(utf8.encode('EXPECTED_BYTES')))
          .toString();

      final mounted = <String>[];
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: wrongSha,
          size: payload.length,
        ),
        downloader: _Fetcher(payload),
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(mounted, isEmpty);
      final files = listBase(moduleDir(supportDir, 'x'));
      expect(files.where((f) => f.endsWith('.so')), isEmpty,
          reason: 'SHA 不符绝无最终 .so');
      expect(files.where((f) => f.endsWith('.meta')), isEmpty,
          reason: 'SHA 不符绝无 .meta');
      expect(files.where((f) => f.endsWith('.tmp')), isEmpty,
          reason: '失败后 .tmp 必须清理');
    });

    test('版本 1.0.0+1 → 文件名三段 libgstore_mod_x_1.0.0.so，.meta 存真实版本',
        () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_BUILD'));
      final sha = sha256.convert(payload).toString();

      final mounted = <String>[];
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0+1', // 真实版本
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
        ),
        downloader: _Fetcher(payload),
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      final dir = moduleDir(supportDir, 'x');
      final files = listBase(dir);
      expect(files, contains('libgstore_mod_x_1.0.0.so'));
      expect(
        files.any((f) =>
            f.contains('+') || f.contains('-x86_64.so') || f.contains('_1.0.0+1')),
        isFalse,
        reason: '本地文件名不得含 +build 或 ABI 后缀',
      );

      final meta = jsonDecode(
          File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so.meta'))
              .readAsStringSync()) as Map;
      expect(meta['version'], '1.0.0+1', reason: '.meta 保留真实版本');
      expect(meta['name'], 'x');
      expect(meta['sha256'], sha);
      expect(meta['source'], 'remote');
      expect(mounted, hasLength(1));
    });

    test('requireSignature=false 安装后删除同名遗留 .sig', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final staleSig = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so.sig'));
      staleSig.writeAsStringSync('STALE_SIGNATURE\n');

      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_V1'));
      final sha = sha256.convert(payload).toString();

      loader.requireSignature = false;
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
          signature: 'deadbeef',
        ),
        downloader: _Fetcher(payload),
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async => true,
      );

      expect(await loader.ensureModule('x'), isTrue);
      expect(
        File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so')).existsSync(),
        isTrue,
      );
      expect(staleSig.existsSync(), isFalse,
          reason: 'requireSignature=false 必须删除遗留 .sig，避免宿主走空公钥分支');
    });

    test('.meta 只在 .so 已存在后才写入（顺序证明）', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_BYTES_ORDER'));
      final sha = sha256.convert(payload).toString();

      var soExistedBeforeMeta = false;
      var metaExistedAtHook = true;
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
        ),
        downloader: _Fetcher(payload),
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async => true,
        beforeMetaWrite: (name, soPath) {
          soExistedBeforeMeta = File(soPath).existsSync();
          metaExistedAtHook = File('$soPath.meta').existsSync();
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      expect(soExistedBeforeMeta, isTrue,
          reason: '写 .meta 时最终 .so 必须已 rename 就位');
      expect(metaExistedAtHook, isFalse,
          reason: '写 .meta 之前不得存在最终 .meta');
    });
  });

  group('挂载期 fail-closed（崩溃注入/半写态）', () {
    test('.so 存在但无 .meta → 不挂载', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so'))
          .writeAsBytesSync(utf8.encode('CRASH_SO'));

      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(mounted, isEmpty, reason: '缺 .meta 的产物不得挂载');
      // 文件仍在（需等待修复/回退），但不可用
      expect(await loader.isAvailable('x'), isFalse);
    });

    test('.meta 的 sha256 与 .so 字节不符 → 不挂载', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final so = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so'))
        ..writeAsBytesSync(utf8.encode('REAL_BYTES'));
      File('${so.path}.meta').writeAsStringSync(jsonEncode({
        'name': 'x',
        'version': '1.0.0',
        'abi': 'x86_64',
        'sha256': sha256.convert(utf8.encode('OTHER_BYTES')).toString(),
        'source': 'remote',
      }));

      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(mounted, isEmpty, reason: '哈希复核失败不得挂载');
    });

    test('仅遗留 .tmp → 启动清理且不挂载', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final tmp = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so.tmp'))
        ..writeAsBytesSync(utf8.encode('HALF_WRITTEN'));
      // 模拟「上次中断遗留」：把 mtime 回拨到启动清理的年龄阈值之前，
      // 否则新近的 .tmp 会被年龄过滤跳过（那是刻意的并发保护）。
      tmp.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));

      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(tmp.existsSync(), isFalse, reason: '遗留 .tmp 必须被清理');
      expect(mounted, isEmpty);
    });

    test('启动清理不删除新近的 .tmp（并发安装正在写入，绝不误删）', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final freshTmp = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so.tmp'))
        ..writeAsBytesSync(utf8.encode('IN_PROGRESS'));

      loader.debugConfigure(supportDir: supportDir.path);
      // 年龄过滤下的启动清理：新近创建的 .tmp 必须保留。
      await loader.cleanupLeftoverTemp(minAge: const Duration(minutes: 10));

      expect(freshTmp.existsSync(), isTrue,
          reason: '并发安装正在写入的新近 .tmp 绝不能被启动清理删除');

      // 显式零年龄清理仍会删除它（默认路径行为不变）。
      await loader.cleanupLeftoverTemp();
      expect(freshTmp.existsSync(), isFalse);
    });

    test('启动清理删除 .tmp/.meta.tmp/.sig.tmp，保留 .so/.meta/.sig', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final so = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so'))
        ..writeAsBytesSync(utf8.encode('SO'));
      final meta = File('${so.path}.meta')..writeAsStringSync('{}');
      final sig = File('${so.path}.sig')..writeAsStringSync('sig');
      final tmpSo = File('${so.path}.tmp')..writeAsStringSync('tmp');
      final tmpMeta = File('${so.path}.meta.tmp')..writeAsStringSync('tmp');
      final tmpSig = File('${so.path}.sig.tmp')..writeAsStringSync('tmp');

      loader.debugConfigure(supportDir: supportDir.path);
      await loader.cleanupLeftoverTemp();

      expect(tmpSo.existsSync(), isFalse);
      expect(tmpMeta.existsSync(), isFalse);
      expect(tmpSig.existsSync(), isFalse);
      expect(so.existsSync(), isTrue);
      expect(meta.existsSync(), isTrue);
      expect(sig.existsSync(), isTrue);
    });
  });

  group('挂载期 .sig 卫生（requireSignature 开关）', () {
    /// 写入一个「已验证」的本地产物（合法 `.meta` + 匹配 sha256）。
    File writeVerifiedLocal(Directory dir, {String sigContent = 'STALE_SIG'}) {
      final bytes = utf8.encode('LOCAL_SO_BYTES');
      final so = File(p.join(dir.path, 'libgstore_mod_x_1.0.0.so'))
        ..writeAsBytesSync(bytes);
      File('${so.path}.meta').writeAsStringSync(jsonEncode({
        'name': 'x',
        'version': '1.0.0',
        'abi': 'x86_64',
        'sha256': sha256.convert(bytes).toString(),
        'source': 'remote',
      }));
      File('${so.path}.sig').writeAsStringSync('$sigContent\n');
      return so;
    }

    test('本地产物 + 遗留 .sig + requireSignature=false：挂载前删除 .sig', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final so = writeVerifiedLocal(dir);

      loader.requireSignature = false;
      var sigExistedAtMount = true;
      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          // 若挂载时 .sig 仍在 → 返回 false，令本用例失败（证明删除先于挂载）。
          sigExistedAtMount = File('$soPath.sig').existsSync();
          if (sigExistedAtMount) return false;
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue,
          reason: '已验证本地产物应挂载成功（.sig 已被删除）');
      expect(sigExistedAtMount, isFalse,
          reason: '挂载时必须已删除遗留 .sig');
      expect(mounted, hasLength(1));
      expect(so.existsSync(), isTrue);
      expect(File('${so.path}.sig').existsSync(), isFalse,
          reason: 'ensureModule 后遗留 .sig 必须不存在');
    });

    test('本地产物 + 遗留 .sig + requireSignature=true：保留 .sig 并尝试挂载', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'x')..createSync(recursive: true);
      final so = writeVerifiedLocal(
        dir,
        // 结构有效的 Ed25519 侧车（128 位十六进制）：Phase 2 迁移不得隔离它。
        sigContent: List.filled(64, 'ab').join(),
      );

      loader.requireSignature = true;
      var sigExistedAtMount = false;
      final mounted = <String>[];
      loader.debugConfigure(
        supportDir: supportDir.path,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          sigExistedAtMount = File('$soPath.sig').existsSync();
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      expect(sigExistedAtMount, isTrue,
          reason: 'requireSignature=true 时不得在挂载前删除 .sig');
      expect(mounted, hasLength(1));
      expect(File('${so.path}.sig').existsSync(), isTrue,
          reason: 'requireSignature=true 时必须保留 .sig（Todo 6 负责迁移）');
    });
  });

  group('对抗输入（版本/ABI 解析）', () {
    test('版本归一化：三段纯数字，剥离 +build/预发布', () {
      expect(loader.debugSanitizeVersion('1.0.0+1'), '1.0.0');
      expect(loader.debugSanitizeVersion('2.3.4-rc.1'), '2.3.4');
      expect(loader.debugSanitizeVersion('3'), '3.0.0');
      expect(loader.debugSanitizeVersion('1.2'), '1.2.0');
      expect(loader.debugSanitizeVersion(' 1.2.3 '), '1.2.3');
      // 非数字/空/仅元数据 → 拒绝
      expect(loader.debugSanitizeVersion('abc'), isNull);
      expect(loader.debugSanitizeVersion('1.x'), isNull);
      expect(loader.debugSanitizeVersion('1.2.3.4.bad'), '1.2.3');
      expect(loader.debugSanitizeVersion(''), isNull);
      expect(loader.debugSanitizeVersion('+1'), isNull);
    });

    test('清单缺当前设备 ABI（仅有 arm64-v8a）→ 拒绝安装，无产物', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_ARM'));
      final sha = sha256.convert(payload).toString();

      final mounted = <String>[];
      final fetcher = _Fetcher(payload);
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-arm64-v8a.so',
          sha256Hex: sha,
          size: payload.length,
          abi: 'arm64-v8a', // 设备为 x86_64
        ),
        downloader: fetcher,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isFalse);
      expect(fetcher.calls, 0, reason: '缺 ABI 资产不得发起下载');
      expect(mounted, isEmpty);
      final files = listBase(moduleDir(supportDir, 'x'));
      expect(files.where((f) => f.endsWith('.so')), isEmpty);
      expect(files.where((f) => f.endsWith('.meta')), isEmpty);
    });

    test('ModuleManager 三段式 .so 命名解析', () {
      expect(
        RustModuleManager.debugModuleNameFromSoPath('/m/libgstore_mod_x_1.0.0.so'),
        'x',
      );
      expect(
        RustModuleManager.debugModuleNameFromSoPath(
            '/m/libgstore_mod_download_12.34.56.so'),
        'download',
      );
      expect(
        RustModuleManager.debugModuleNameFromSoPath('/m/libgstore_mod_x.so'),
        'x',
      );
      // ABI 后缀 / 非三段版本不是本地合法命名 → 不误判为模块名
      expect(
        RustModuleManager.debugModuleNameFromSoPath(
            '/m/libgstore_mod_x_1.0.0-arm64-v8a.so'),
        isNull,
      );
    });
  });

  group('ensureModule 单飞（并发去重 / 失败非粘滞）', () {
    test('concurrent ensureModule calls for the same module share one install',
        () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_SINGLEFLIGHT'));
      final sha = sha256.convert(payload).toString();

      final fetcher = _GatedFetcher(payload);
      final mounted = <String>[];
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
        ),
        downloader: fetcher,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      // 第一次调用：下载被闸门挂起 → 安装仍在途。
      final first = loader.ensureModule('x');
      await _waitFor(() => fetcher.calls == 1);
      expect(loader.debugEnsureInFlightCount, 1, reason: '首次安装进行中应恰好有 1 个单飞条目');

      // 第二次调用（同一模块，仍在途）：必须复用同一在途 Future。
      final second = loader.ensureModule('x');
      expect(identical(first, second), isTrue,
          reason: '并发调用必须共享同一在途 Future，而非各自启动安装');
      expect(fetcher.calls, 1, reason: '第二次调用不得发起第二次下载');
      expect(loader.debugEnsureInFlightCount, 1, reason: '并发调用仍只计 1 个单飞条目');

      // 放行下载：两个调用观察同一结果。
      fetcher.gate.complete();
      final results = await Future.wait<bool>(<Future<bool>>[first, second]);

      expect(results, everyElement(isTrue));
      expect(fetcher.calls, 1, reason: '底层下载恰好一次');
      expect(mounted, hasLength(1), reason: '底层安装/挂载恰好一次');
      expect(loader.debugEnsureInFlightCount, 0, reason: '完成后单飞条目必须释放');
    });

    test('a failed ensureModule does not poison later retries', () async {
      final supportDir = makeSupportDir();
      final payload = Uint8List.fromList(utf8.encode('SO_RETRY_BYTES'));
      final sha = sha256.convert(payload).toString();

      final fetcher = _Fetcher(payload);
      var failFirstIsLoaded = true;
      loader.remoteBaseUrl = 'https://example.com/release';
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(
          module: 'x',
          version: '1.0.0',
          asset: 'libgstore_mod_x_1.0.0-x86_64.so',
          sha256Hex: sha,
          size: payload.length,
        ),
        downloader: fetcher,
        isLoadedOverride: (_) async {
          if (failFirstIsLoaded) {
            failFirstIsLoaded = false;
            throw StateError('isLoaded boom');
          }
          return false;
        },
        mountOverride: (soPath) async => true,
      );

      // 首次以异常失败：单飞条目必须即时释放（非粘滞）。
      await expectLater(loader.ensureModule('x'), throwsA(isA<StateError>()));
      expect(loader.debugEnsureInFlightCount, 0,
          reason: '失败后单飞条目必须移除，不得永久污染模块');

      // 后续调用必须真实重试并成功。
      expect(await loader.ensureModule('x'), isTrue, reason: '失败后的重试必须重新尝试安装');
      expect(fetcher.calls, 1, reason: '重试必须真实触发一次下载');
      expect(loader.debugEnsureInFlightCount, 0);
    });

    test(
      'concurrent ensureModule and downloadAndInstall for the same module serialize installs',
      () async {
        final supportDir = makeSupportDir();
        final payload = Uint8List.fromList(utf8.encode('SO_CROSS_ENTRY'));
        final sha = sha256.convert(payload).toString();

        final fetcher = _ConcurrencyFetcher(payload);
        final mounted = <String>[];
        loader.remoteBaseUrl = 'https://example.com/release';
        loader.debugConfigure(
          supportDir: supportDir.path,
          manifestOverride: _manifest(
            module: 'x',
            version: '1.0.0',
            asset: 'libgstore_mod_x_1.0.0-x86_64.so',
            sha256Hex: sha,
            size: payload.length,
          ),
          downloader: fetcher,
          isLoadedOverride: (_) async => false,
          mountOverride: (soPath) async {
            mounted.add(soPath);
            return true;
          },
        );

        // 入口 A（后台更新）先启动：持有该模块的安装锁，下载被闸门挂起。
        final bg = loader.downloadAndInstall('x');
        await _waitFor(() => fetcher.calls == 1);
        expect(loader.debugInstallLockCount, 1,
            reason: '后台更新进行中应持有该模块的安装锁');

        // 入口 B（按需安装）随后启动。它必须**等待**该锁，而不是并发进入落盘。
        final ensure = loader.ensureModule('x');
        // 充分泵事件队列，让按需路径推进到锁前；此时第二次下载绝不应开始。
        for (var i = 0; i < 100; i++) {
          await pumpEventQueue(times: 1);
        }
        expect(fetcher.calls, 1,
            reason: '后台更新持锁期间，按需安装不得开始第二次下载（必须等待）');
        expect(fetcher.active, 1, reason: '同一模块任意时刻至多一个在途下载');
        expect(loader.debugInstallLockCount, 1);

        // 放行：后台更新完成并释放锁，按需安装随后**真正执行**自己的下载并挂载。
        fetcher.gate.complete();
        final results = await Future.wait<bool>(<Future<bool>>[ensure, bg]);

        expect(results, everyElement(isTrue));
        expect(fetcher.calls, 2,
            reason: '按需安装等待后必须真正执行自己的下载（而非被跳过）');
        expect(fetcher.maxActive, 1,
            reason: '两个入口的下载在任意时刻至多一个在途：已串行化，绝不交错');
        expect(mounted, hasLength(1), reason: '仅按需安装挂载，后台更新绝不挂载');
        expect(loader.debugInstallLockCount, 0, reason: '全部完成后安装锁必须释放');
      },
    );

    test(
      'background downloadAndInstall during an ensure re-checks under the lock and skips a duplicate download',
      () async {
        final supportDir = makeSupportDir();
        final payload = Uint8List.fromList(utf8.encode('SO_DEDUP'));
        final sha = sha256.convert(payload).toString();

        final fetcher = _ConcurrencyFetcher(payload);
        final mounted = <String>[];
        loader.remoteBaseUrl = 'https://example.com/release';
        loader.debugConfigure(
          supportDir: supportDir.path,
          manifestOverride: _manifest(
            module: 'x',
            version: '1.0.0',
            asset: 'libgstore_mod_x_1.0.0-x86_64.so',
            sha256Hex: sha,
            size: payload.length,
          ),
          downloader: fetcher,
          isLoadedOverride: (_) async => false,
          mountOverride: (soPath) async {
            mounted.add(soPath);
            return true;
          },
        );

        // 按需安装先启动并持有安装锁（下载被闸门挂起）。
        final ensure = loader.ensureModule('x');
        await _waitFor(() => fetcher.calls == 1);
        expect(loader.debugInstallLockCount, 1);

        // 后台更新在按需安装进行中到达：必须等锁，然后在**锁内**复检「无需更新」。
        final bg = loader.downloadAndInstall('x');
        for (var i = 0; i < 100; i++) {
          await pumpEventQueue(times: 1);
        }
        expect(fetcher.calls, 1, reason: '后台更新在获得锁之前不得开始下载');

        fetcher.gate.complete();
        expect(await ensure, isTrue, reason: '按需安装应完成并挂载');
        expect(await bg, isFalse,
            reason: '锁内复检发现同版本已落盘，必须跳过重复下载（返回 false）');
        expect(fetcher.calls, 1, reason: '后台更新绝不重复下载同一版本');
        expect(fetcher.maxActive, 1, reason: '同一模块任意时刻至多一个在途下载');
        expect(mounted, hasLength(1), reason: '仅按需安装挂载，后台更新绝不挂载');
        expect(loader.debugInstallLockCount, 0);
      },
    );

    test(
      'a hung download times out, releases the install lock, and a later call retries',
      () async {
        final supportDir = makeSupportDir();
        final payload = Uint8List.fromList(utf8.encode('SO_TIMEOUT_RETRY'));
        final sha = sha256.convert(payload).toString();

        final fetcher = _HangingThenOkFetcher(payload);
        final mounted = <String>[];
        loader.remoteBaseUrl = 'https://example.com/release';
        loader.debugConfigure(
          supportDir: supportDir.path,
          manifestOverride: _manifest(
            module: 'x',
            version: '1.0.0',
            asset: 'libgstore_mod_x_1.0.0-x86_64.so',
            sha256Hex: sha,
            size: payload.length,
          ),
          downloader: fetcher,
          isLoadedOverride: (_) async => false,
          mountOverride: (soPath) async {
            mounted.add(soPath);
            return true;
          },
          installTimeout: const Duration(milliseconds: 50),
        );
        expect(loader.debugInstallTimeout, const Duration(milliseconds: 50));

        final stopwatch = Stopwatch()..start();
        expect(await loader.ensureModule('x'), isFalse,
            reason: '挂起的下载必须在有界超时内失败（返回 false，而非永久挂起）');
        stopwatch.stop();
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
            reason: '必须在短超时内终止，而非永久挂起');
        expect(loader.debugInstallLockCount, 0,
            reason: '下载超时后每模块安装锁必须释放（不得永久阻塞同模块安装）');
        expect(loader.debugEnsureInFlightCount, 0,
            reason: '超时后单飞条目必须释放（失败非粘滞）');

        // 后续调用必须真实重试：同一配置/同一锁表下，第二次 fetch 立即成功。
        expect(await loader.ensureModule('x'), isTrue,
            reason: '超时非粘滞：后续调用必须真正重试并成功');
        expect(fetcher.calls, 2, reason: '重试必须真实重新发起下载');
        expect(mounted, hasLength(1));
        expect(loader.debugInstallLockCount, 0);
      },
    );

    test(
      'a failed downloadAndInstall releases the install lock for later retries',
      () async {
        final supportDir = makeSupportDir();
        final payload = Uint8List.fromList(utf8.encode('SO_BG_RETRY'));
        final sha = sha256.convert(payload).toString();

        final fetcher = _FlakyFetcher(payload);
        loader.remoteBaseUrl = 'https://example.com/release';
        loader.debugConfigure(
          supportDir: supportDir.path,
          manifestOverride: _manifest(
            module: 'x',
            version: '1.0.0',
            asset: 'libgstore_mod_x_1.0.0-x86_64.so',
            sha256Hex: sha,
            size: payload.length,
          ),
          downloader: fetcher,
          isLoadedOverride: (_) async => false,
          mountOverride: (soPath) async => true,
        );

        // 首次：下载失败 → 安装锁必须释放（非粘滞）。
        expect(await loader.downloadAndInstall('x'), isFalse);
        expect(loader.debugInstallLockCount, 0, reason: '失败后安装锁必须释放');

        // 第二次：真实重试并成功（失败未粘滞）。
        expect(await loader.downloadAndInstall('x'), isTrue);
        expect(fetcher.calls, 2, reason: '失败后的重试必须真实重新下载');
        expect(loader.debugInstallLockCount, 0);
      },
    );
  });
}
