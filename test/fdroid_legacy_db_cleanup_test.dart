import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart' as rust;
import 'package:path/path.dart' as path;

/// PART A 回归：升级用户遗留的旧槽位库文件（`url:` / `fp:`）清理。
///
/// 存储槽位刚与签名指纹解耦（`storageIdentity == 源 id`），旧的
/// `fdroid_<hash>.db`（按 `url:<归一化>` / `fp:<HEX>` 命名）永不再用。
///
/// 断言：只清已配置源的两个旧槽位与其边车、当前 `id:` 槽位分毫不动、
/// 幂等、任何失败都不抛出（best-effort，不阻塞启动）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  FdroidSource sourceWith(String url, {String? fingerprint}) => FdroidSource(
        id: 'official',
        name: 'Official',
        repoUrl: url,
        fingerprint: fingerprint,
      );

  // 旧身份 #2：url:<归一化地址>
  String legacyUrlPath(FdroidSource s) =>
      rust.FdroidRustRepoManager.dbPathForIdentity(
          rust.FdroidRustRepoManager.sourceIdentity(
              fingerprint: null, repoUrl: s.repoUrl),
          docs.path);

  // 旧身份 #1：fp:<HEX>
  String legacyFpPath(FdroidSource s) =>
      rust.FdroidRustRepoManager.dbPathForIdentity(
          rust.FdroidRustRepoManager.sourceIdentity(
              fingerprint: s.fingerprint, repoUrl: s.repoUrl),
          docs.path);

  // 当前槽位：id:<源 id>
  String currentPath(FdroidSource s) =>
      rust.FdroidRustRepoManager.dbPathForIdentity(
          rust.FdroidRustRepoManager.storageIdentity(s), docs.path);

  /// 落一个"库文件 + wal + shm"三件套。
  void seed(String p) {
    File(p).writeAsStringSync('x');
    File('$p-wal').writeAsStringSync('w');
    File('$p-shm').writeAsStringSync('s');
  }

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('fdroid_legacy_clean_');
  });

  tearDown(() async {
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  test('A1 清理旧 url:/fp: 槽位及边车，当前 id: 槽位原样保留', () async {
    final s = sourceWith('https://f-droid.org/repo', fingerprint: 'AB:CD');
    final urlPath = legacyUrlPath(s);
    final fpPath = legacyFpPath(s);
    final curPath = currentPath(s);

    expect({urlPath, fpPath, curPath}, hasLength(3),
        reason: '旧槽位与当前 id: 槽位是三个不同文件');

    seed(urlPath);
    seed(fpPath);
    seed(curPath);

    final r = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);

    expect(r.files, 6, reason: '两个旧槽位各 3 个文件被清');
    expect(r.bytes, greaterThan(0), reason: '应回报回收字节数');
    for (final p in [urlPath, fpPath]) {
      expect(File(p).existsSync(), isFalse);
      expect(File('$p-wal').existsSync(), isFalse);
      expect(File('$p-shm').existsSync(), isFalse);
    }
    expect(File(curPath).existsSync(), isTrue, reason: '当前 id: 槽位绝不能被删');
    expect(File('$curPath-wal').existsSync(), isTrue);
    expect(File('$curPath-shm').existsSync(), isTrue);
  });

  test('A2 无旧文件 ⇒ 静默 no-op、不抛', () async {
    final s = sourceWith('https://s.example/repo');

    final r = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);

    expect(r.files, 0);
    expect(r.bytes, 0);
  });

  test('A3 幂等：连续两次清理安全，第二次为 no-op', () async {
    final s = sourceWith('https://s.example/repo', fingerprint: 'DE:AD');
    seed(legacyUrlPath(s));
    seed(legacyFpPath(s));

    final first = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);
    final second = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);

    expect(first.files, 6);
    expect(second.files, 0, reason: '二次运行必须是无文件的静默 no-op');
  });

  test('A4 文件名像旧库但等于当前槽位 ⇒ 护栏判不可删、清理后仍在', () async {
    final s = sourceWith('https://s.example/repo');
    final curPath = currentPath(s);
    seed(curPath);

    // 显式断言安全总闸：候选等于当前槽位（或其主库）→ 拒删。
    expect(
      FdroidRepoManager.isDeletableLegacySlotPath(
        candidatePath: curPath,
        docsPath: docs.path,
        currentSlotPaths: {curPath},
      ),
      isFalse,
    );
    expect(
      FdroidRepoManager.isDeletableLegacySlotPath(
        candidatePath: '$curPath-wal',
        docsPath: docs.path,
        currentSlotPaths: {curPath},
      ),
      isFalse,
    );

    await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);

    expect(File(curPath).existsSync(), isTrue);
    expect(File('$curPath-wal').existsSync(), isTrue);
    expect(File('$curPath-shm').existsSync(), isTrue);
  });

  test('A5 缺失目录 / 目录占用候选路径 ⇒ 不抛、不中断启动', () async {
    final s = sourceWith('https://s.example/repo');

    // 1) docs 目录不存在
    final missing = path.join(docs.path, 'does_not_exist');
    final r1 = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: missing);
    expect(r1.files, 0);

    // 2) 候选路径被同名目录占用（不是普通文件）→ 不删、不崩
    final occupied = legacyUrlPath(s);
    Directory(occupied).createSync(recursive: true);
    final r2 = await FdroidRepoManager.cleanLegacyDbSlots(
        sources: [s], docsPath: docs.path);
    expect(r2.files, 0);
    expect(Directory(occupied).existsSync(), isTrue,
        reason: '目录绝不能被当作库文件删除');
  });
}
