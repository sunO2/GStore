import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart';

/// Real-native FRB smoke test for the spike [CoreApi] handle.
///
/// Requires `rust/gstore_host/target/release/libgstore_host.so` to exist; build
/// it with:
/// `cargo build --manifest-path rust/gstore_host/Cargo.toml --release`
void main() {
  late Directory root;
  late String dataDir;
  late String filesDir;
  late String cacheDir;
  late CoreApi api;

  setUpAll(() async {
    // 本文件是真实原生 FRB 冒烟测试：解除全局测试配置的「原生桥不可用」默认。
    RustBridge.debugForceUnavailable = false;
    root = await Directory.systemTemp.createTemp('gstore_core_api_dart_');
    dataDir = '${root.path}/data';
    filesDir = '${root.path}/files';
    cacheDir = '${root.path}/cache';
    for (final dir in <String>[dataDir, filesDir, cacheDir]) {
      await Directory(dir).create(recursive: true);
    }
    api = await CoreApiFacade.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  });

  tearDownAll(() async {
    api.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('init and migratePaths return schema v2', () async {
    final result = await api.migratePaths();

    expect(result.schemaVersion, 2);
    expect(result.dbPath, '$dataDir/gstore_core.db');
    expect(result.dbPath.endsWith('gstore_core.db'), isTrue);
    expect(File(result.dbPath).existsSync(), isTrue);
    expect(Directory('$filesDir/migration').existsSync(), isTrue);
  });

  test('snapshot round-trip', () async {
    final payload = <int>[1, 2, 3, 4, 5, 6, 7, 8];
    final file = File('${root.path}/payload.bin');
    await file.writeAsBytes(payload);

    final importedBytes = await api.importFile(pathOrFd: file.path);
    expect(importedBytes, BigInt.from(payload.length));

    final snap = '${root.path}/snapshot.db';
    final snapshotBytes = await api.exportSnapshot(path: snap);
    expect(snapshotBytes > BigInt.zero, isTrue);
    expect(File(snap).existsSync(), isTrue);

    expect(await api.importSnapshot(path: snap), 2);
  });

  test('missing import path is a typed stable error', () async {
    await expectLater(
      api.importFile(pathOrFd: '${root.path}/missing.bin'),
      throwsA(
        predicate(
          (Object e) => e.toString().contains('CORE_E_IMPORT_NOT_FOUND'),
        ),
      ),
    );
  });

  test('init, migrate and import leave core_writes empty', () async {
    const domains = <String>['channel', 'update', 'download'];

    for (final domain in domains) {
      expect(await api.coreWrites(domain: domain), isNull,
          reason: 'init must not arm $domain');
    }

    await api.migratePaths();
    for (final domain in domains) {
      expect(await api.coreWrites(domain: domain), isNull,
          reason: 'migratePaths must not arm $domain');
    }

    final channelDoc = File('${root.path}/channel_env.json');
    await channelDoc.writeAsString(jsonEncode(<String, Object?>{
      'version': 1,
      'channel_key': 'js.wave01',
      'env': <String, String>{'USER': 'alice'},
    }));
    expect(
      await api.importMigrationFile(
        kind: 'channel_env',
        path: channelDoc.path,
      ),
      1,
    );

    final prefsDoc = File('${root.path}/update_prefs.json');
    await prefsDoc.writeAsString(jsonEncode(<String, Object?>{
      'version': 1,
      'prefs': <String, String>{'update_last_checked_at': '1700000000000'},
    }));
    expect(
      await api.importMigrationFile(
        kind: 'update_prefs',
        path: prefsDoc.path,
      ),
      1,
    );

    final snap = '${root.path}/markers.db';
    await api.exportSnapshot(path: snap);
    expect(await api.importSnapshot(path: snap), 2);

    for (final domain in domains) {
      expect(await api.coreWrites(domain: domain), isNull,
          reason: 'import/snapshot must not arm $domain');
    }
  });
}
