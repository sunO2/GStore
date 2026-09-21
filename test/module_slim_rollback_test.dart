// slim 变体回归：`rollbackToBuiltin` 必须是**非破坏性**的。
//
// 精简包（slim）排除了 `libgstore_mod_*.so`，模块仅可下载。修复前
// `rollbackToBuiltin` 先 `clearDownloadedModule` 再查内置：无内置时把下载模块
// 删掉后才返回 false，导致模块被**不可逆清除**（bricked）。本文件锁定新顺序：
// * 有下载产物 + **无内置** ⇒ 返回 false，且下载产物**原样保留**（绝不删除）；
// * 有下载产物 + **有内置** ⇒ 返回 true，挂载内置且下载产物被清除；
// * `probe` 在**已下载**分支也必须如实报告 `hasBuiltin`（供 UI 门控）。
//
// 全部用例经 `debugConfigure` 注入临时 `supportDir` / `builtinSoPathOverride` /
// `mountOverride`，不触发 FFI、path_provider 或网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeSupportDir() {
    final dir = Directory.systemTemp.createTempSync('gstore_slim_rollback_');
    tempDirs.add(dir);
    return dir;
  }

  Directory moduleDir(Directory supportDir, String name) =>
      Directory(p.join(supportDir.path, 'gstore_modules', name));

  /// 写入「合法 .so + 匹配 .meta」的已验证下载产物。
  File writeVerified(
    Directory dir,
    String name,
    String version,
    String bytes,
  ) {
    dir.createSync(recursive: true);
    final so = File(p.join(dir.path, 'libgstore_mod_${name}_$version.so'))
      ..writeAsBytesSync(utf8.encode(bytes));
    File('${so.path}.meta').writeAsStringSync(jsonEncode({
      'name': name,
      'version': version,
      'abi': 'x86_64',
      'sha256': sha256.convert(utf8.encode(bytes)).toString(),
      'source': 'remote',
    }));
    return so;
  }

  setUp(() {
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
  });

  tearDown(() {
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
    for (final dir in tempDirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    tempDirs.clear();
  });

  group('rollbackToBuiltin 非破坏性（slim 回归）', () {
    test('有下载产物但无内置 → 返回 false 且下载文件原样保留', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'qr');
      final so = writeVerified(dir, 'qr', '1.0.0', 'SLIM_DOWNLOADED');
      var mountCalls = 0;

      loader.debugConfigure(
        supportDir: supportDir.path,
        // 精简包：随包无内置 .so（override 恒 null）。
        builtinSoPathOverride: (_) async => null,
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async {
          mountCalls++;
          return true;
        },
      );

      final ok = await loader.rollbackToBuiltin('qr');

      expect(ok, isFalse, reason: '无内置可挂载 → 必须非破坏性失败');
      // 关键对抗断言：无内置时**绝不**删除任何已下载文件。
      expect(File(so.path).existsSync(), isTrue,
          reason: '下载 .so 必须原样保留（旧实现会先删除导致 bricked）');
      expect(File('${so.path}.meta').existsSync(), isTrue,
          reason: '.meta 必须原样保留');
      expect(dir.existsSync(), isTrue, reason: '模块下载目录必须原样保留');
      expect(mountCalls, 0, reason: '无内置不得尝试挂载');
    });

    test('有下载产物且内置存在 → 返回 true、挂载内置且下载文件被清除', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'qr');
      final downloaded = writeVerified(dir, 'qr', '1.0.0', 'DOWNLOADED_V1');
      final builtinFile =
          File(p.join(supportDir.path, 'builtin_libgstore_mod_qr.so'))
            ..writeAsBytesSync(utf8.encode('BUILTIN_QR'));
      String? mountedPath;

      loader.debugConfigure(
        supportDir: supportDir.path,
        builtinSoPathOverride: (name) async =>
            name == 'qr' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mountedPath = soPath;
          return true;
        },
      );

      final ok = await loader.rollbackToBuiltin('qr');

      expect(ok, isTrue, reason: '内置真实存在 → 回退成功');
      expect(mountedPath, builtinFile.path, reason: '必须挂载内置产物');
      expect(File(downloaded.path).existsSync(), isFalse,
          reason: '内置存在时回退必须清除下载产物');
      expect(dir.existsSync(), isFalse, reason: '整个模块下载目录应被删除');
    });

    test('无下载产物且无内置 → 返回 false 且不抛异常（无副作用）', () async {
      final supportDir = makeSupportDir();
      loader.debugConfigure(
        supportDir: supportDir.path,
        builtinSoPathOverride: (_) async => null,
        isLoadedOverride: (_) async => false,
      );

      expect(await loader.rollbackToBuiltin('ghost'), isFalse);
    });
  });

  group('probe.hasBuiltin：已下载分支也如实报告', () {
    test('有效下载 + 内置真实存在 → downloaded 且 hasBuiltin=true', () async {
      final supportDir = makeSupportDir();
      writeVerified(moduleDir(supportDir, 'qr'), 'qr', '1.0.0', 'DL_WITH_BUILTIN');
      final builtinFile =
          File(p.join(supportDir.path, 'builtin_libgstore_mod_qr.so'))
            ..writeAsBytesSync(utf8.encode('BUILTIN_QR'));

      loader.debugConfigure(
        supportDir: supportDir.path,
        builtinSoPathOverride: (name) async =>
            name == 'qr' ? builtinFile.path : null,
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr');
      expect(status.source, 'downloaded');
      expect(status.hasDownloaded, isTrue);
      expect(status.hasBuiltin, isTrue,
          reason: '已下载模块也必须报告存在可回退的内置版本');
    });

    test('有效下载 + 无内置（slim）→ downloaded 且 hasBuiltin=false', () async {
      final supportDir = makeSupportDir();
      writeVerified(moduleDir(supportDir, 'qr'), 'qr', '1.0.0', 'DL_NO_BUILTIN');

      loader.debugConfigure(
        supportDir: supportDir.path,
        builtinSoPathOverride: (_) async => null,
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr');
      expect(status.source, 'downloaded');
      expect(status.hasDownloaded, isTrue);
      expect(status.hasBuiltin, isFalse,
          reason: 'slim 无内置产物 → hasBuiltin 必须为 false');
    });
  });
}
