// Task 6：Phase 2 迁移——清理 Phase 1 无签名下载产物。
//
// 全部用例经 `debugConfigure` 注入临时 `supportDir`/挂载覆盖，不触发 FFI、
// path_provider 或真实网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeSupportDir() {
    final dir = Directory.systemTemp.createTempSync('gstore_migration_test_');
    tempDirs.add(dir);
    return dir;
  }

  Directory moduleDir(Directory support, String name) =>
      Directory(p.join(support.path, 'gstore_modules', name));

  /// 结构有效的 Ed25519 侧车：64 字节 → 128 位十六进制。
  String validSig() => List.filled(64, 'ab').join();

  /// 写入一个本地落盘命名的模块产物：`libgstore_mod_<name>_<version>.so`
  /// + 可选 `.meta`（默认写入，模拟远程安装提交标记）+ 可选 `.sig`。
  File writeArtifact(
    Directory dir,
    String name,
    String version,
    String bytes, {
    bool meta = true,
    String? sig,
  }) {
    dir.createSync(recursive: true);
    final so = File(p.join(dir.path, 'libgstore_mod_${name}_$version.so'))
      ..writeAsBytesSync(utf8.encode(bytes));
    if (meta) {
      File('${so.path}.meta').writeAsStringSync(jsonEncode({
        'name': name,
        'version': version,
        'abi': 'x86_64',
        'sha256': sha256.convert(utf8.encode(bytes)).toString(),
        'source': 'remote',
      }));
    }
    if (sig != null) {
      File('${so.path}.sig').writeAsStringSync(sig);
    }
    return so;
  }

  Map<String, dynamic> readQuarantine(Directory dir) {
    final f = File(p.join(dir.path, 'quarantine.json'));
    if (!f.existsSync()) return <String, dynamic>{};
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }

  /// 递归快照（相对路径 → 文件大小），用于「零副作用」断言。
  Map<String, int> snapshot(Directory root) {
    final out = <String, int>{};
    if (!root.existsSync()) return out;
    for (final e in root.listSync(recursive: true)) {
      if (e is File) out[p.relative(e.path, from: root.path)] = e.lengthSync();
    }
    return out;
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

  group('requireSignature=false → 零副作用', () {
    test('无签名下载产物不被隔离，目录内容与文件原样', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      final so = writeArtifact(dir, 'x', '1.0.0', 'UNSIGNED_BODY');
      final before = snapshot(support);

      loader.requireSignature = false;
      loader.debugConfigure(supportDir: support.path);
      final migrated = await loader.migrateUnsignedDownloadedModules();

      expect(migrated, 0);
      expect(File(p.join(dir.path, 'quarantine.json')).existsSync(), isFalse,
          reason: 'requireSignature=false 绝不写 quarantine');
      expect(so.existsSync(), isTrue);
      expect(snapshot(support), before, reason: 'false 路径不得改写任何文件');
    });

    test('ensureModule 在 false 时不触发迁移', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      writeArtifact(dir, 'x', '1.0.0', 'UNSIGNED_BODY');
      final before = snapshot(support);

      loader.requireSignature = false;
      loader.debugConfigure(
        supportDir: support.path,
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async => true,
      );

      // false 路径允许无签名产物挂载，但迁移必须零副作用。
      expect(await loader.ensureModule('x'), isTrue);
      expect(File(p.join(dir.path, 'quarantine.json')).existsSync(), isFalse);
      expect(snapshot(support), before, reason: 'false 路径目录内容不得变化');
    });
  });

  group('requireSignature=true → 迁移无签名下载产物', () {
    test('无 .sig 下载产物被隔离；解析回退内置且不挂载 unsigned 文件', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      final unsigned = writeArtifact(dir, 'x', '1.0.0', 'UNSIGNED');
      final builtin = File(p.join(support.path, 'builtin_x.so'))
        ..writeAsBytesSync(utf8.encode('BUILTIN'));
      final mounted = <String>[];

      loader.requireSignature = true;
      loader.debugConfigure(
        supportDir: support.path,
        builtinManifestOverride: {
          'x': {'version': '0.1.0'},
        },
        builtinSoPathOverride: (name) async =>
            name == 'x' ? builtin.path : null,
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      // 显式迁移：写入 quarantine 标记。
      expect(await loader.migrateUnsignedDownloadedModules(), 1);
      final q = readQuarantine(dir);
      expect(q.containsKey('1.0.0'), isTrue);
      expect(q['1.0.0']['reason'], 'unsigned_migration');
      expect(q['1.0.0']['file'], 'libgstore_mod_x_1.0.0.so');
      expect(unsigned.existsSync(), isTrue, reason: '迁移只隔离，不删除产物');

      // 后续解析：必须回退内置，绝不挂载无签名下载产物（misleading-success 守卫）。
      expect(await loader.ensureModule('x'), isTrue);
      expect(mounted.single, builtin.path,
          reason: '解析必须跳过被隔离的无签名文件，命中内置');
      expect(mounted, isNot(contains(unsigned.path)));
      expect(unsigned.existsSync(), isTrue);
    });

    test('ensureModule 启动路径自动执行一次迁移', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      writeArtifact(dir, 'x', '1.0.0', 'UNSIGNED');

      loader.requireSignature = true;
      loader.debugConfigure(
        supportDir: support.path,
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async => true,
      );

      await loader.ensureModule('x'); // 不显式调用迁移
      expect(File(p.join(dir.path, 'quarantine.json')).existsSync(), isTrue,
          reason: '首次 ensureModule 必须自动完成签名迁移');
    });

    test('无 .meta 的产物（内置解压语义）不被隔离/不删除', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      final noMeta =
          writeArtifact(dir, 'x', '1.0.0', 'BUILTIN_EXTRACT', meta: false);
      final outside = File(p.join(support.path, 'builtin_libgstore_mod_x.so'))
        ..writeAsBytesSync(utf8.encode('OUTSIDE'));

      loader.requireSignature = true;
      loader.debugConfigure(supportDir: support.path);

      expect(await loader.migrateUnsignedDownloadedModules(), 0);
      expect(File(p.join(dir.path, 'quarantine.json')).existsSync(), isFalse,
          reason: '无 .meta 不属于 downloaded-module set');
      expect(noMeta.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue, reason: '内置产物绝不触碰');
    });

    test('download 模块无签名产物同样被隔离且不挂载', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'download');
      final unsigned = writeArtifact(dir, 'download', '1.0.0', 'DL_UNSIGNED');
      var mountCalls = 0;

      loader.requireSignature = true;
      loader.debugConfigure(
        supportDir: support.path,
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async {
          mountCalls++;
          return true;
        },
      );

      expect(await loader.migrateUnsignedDownloadedModules(), 1);
      expect(readQuarantine(dir).containsKey('1.0.0'), isTrue);

      // 无内置 + 下载被隔离 + download 禁止自举 → false 且零挂载。
      expect(await loader.ensureModule('download'), isFalse);
      expect(mountCalls, 0);
      expect(unsigned.existsSync(), isTrue);
    });

    test('幂等：调用两次不重复迁移，quarantine.json 内容不变', () async {
      final support = makeSupportDir();
      final dirX = moduleDir(support, 'x');
      final dirY = moduleDir(support, 'y');
      writeArtifact(dirX, 'x', '1.0.0', 'X_BODY');
      writeArtifact(dirY, 'y', '2.0.0', 'Y_BODY');

      loader.requireSignature = true;
      loader.debugConfigure(supportDir: support.path);

      expect(await loader.migrateUnsignedDownloadedModules(), 2);
      final qX1 = File(p.join(dirX.path, 'quarantine.json')).readAsStringSync();
      final qY1 = File(p.join(dirY.path, 'quarantine.json')).readAsStringSync();

      expect(await loader.migrateUnsignedDownloadedModules(), 0,
          reason: '已隔离条目不得重复迁移');
      expect(File(p.join(dirX.path, 'quarantine.json')).readAsStringSync(), qX1,
          reason: '幂等：第二次不得重写 quarantine.json');
      expect(File(p.join(dirY.path, 'quarantine.json')).readAsStringSync(), qY1);
      expect(readQuarantine(dirX).keys.length, 1);
      expect(readQuarantine(dirY).keys.length, 1);
    });

    test('畸形/有效 .sig 矩阵：缺失/空白/短无效→隔离，128 位十六进制→保留',
        () async {
      final support = makeSupportDir();
      final missingDir = moduleDir(support, 'a');
      final emptyDir = moduleDir(support, 'b');
      final shortDir = moduleDir(support, 'c');
      final validDir = moduleDir(support, 'd');
      final missingSo = writeArtifact(missingDir, 'a', '1.0.0', 'A');
      final emptySo =
          writeArtifact(emptyDir, 'b', '1.0.0', 'B', sig: '   \n');
      final shortSo =
          writeArtifact(shortDir, 'c', '1.0.0', 'C', sig: 'deadbeef');
      final validSo =
          writeArtifact(validDir, 'd', '1.0.0', 'D', sig: validSig());

      loader.requireSignature = true;
      loader.debugConfigure(supportDir: support.path);

      expect(await loader.migrateUnsignedDownloadedModules(), 3);
      expect(File(p.join(missingDir.path, 'quarantine.json')).existsSync(), isTrue,
          reason: '缺失 .sig → 隔离');
      expect(File(p.join(emptyDir.path, 'quarantine.json')).existsSync(), isTrue,
          reason: '空白 .sig → 隔离');
      expect(File(p.join(shortDir.path, 'quarantine.json')).existsSync(), isTrue,
          reason: '畸形 .sig → 隔离');
      expect(File(p.join(validDir.path, 'quarantine.json')).existsSync(), isFalse,
          reason: '结构有效 .sig 不得被隔离');
      for (final f in [missingSo, emptySo, shortSo, validSo]) {
        expect(f.existsSync(), isTrue, reason: '迁移绝不删除产物');
      }
    });

    test('有效 .sig 的下载产物不被隔离并可被解析挂载（非一刀切）', () async {
      final support = makeSupportDir();
      final dir = moduleDir(support, 'x');
      final so = writeArtifact(dir, 'x', '1.0.0', 'SIGNED_BODY',
          sig: validSig());
      final mounted = <String>[];

      loader.requireSignature = true;
      loader.debugConfigure(
        supportDir: support.path,
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
        mountOverride: (soPath) async {
          mounted.add(soPath);
          return true;
        },
      );

      expect(await loader.ensureModule('x'), isTrue);
      expect(mounted.single, so.path,
          reason: '有效签名产物应正常解析/挂载（证明迁移是判别的）');
      expect(File(p.join(dir.path, 'quarantine.json')).existsSync(), isFalse);
    });
  });
}
