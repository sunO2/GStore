/// 随包 seed 目录库的一次性自举。
///
/// 边界：Rust 拥有 `<data_dir>/catalog_repo` 的版本仓库；Dart 只负责把随包的
/// `assets/app/db/apps.db` 写成 `<files_dir>/catalog_seed.db`（tmp + rename），
/// 再交给 Rust 校验 + sha256 内容寻址去重（`repoEnsureSeed`），最后让 Rust
/// 在「core `apps` 为空 / 物化版本变化」时物化（`repoMaterialize`）。
///
/// 失败一律非致命：只 `debugPrint`，绝不阻塞启动；下次启动会重试。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show ByteData, rootBundle;

import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/migration/cutover_paths.dart';

/// 随包资产键（`pubspec.yaml` 的 `assets/app/db/`）。
typedef CatalogSeedAssetLoader = Future<ByteData> Function(String assetKey);

class CatalogSeedBootstrap {
  CatalogSeedBootstrap._();

  /// 随包 seed 资产键。
  static const String seedAssetKey = 'assets/app/db/apps.db';

  /// 写进 `<files_dir>` 的 seed 文件名（Rust 会重新做 sha256 命名）。
  static const String seedFileName = 'catalog_seed.db';

  /// 资产加载器：测试注入，避免依赖真实 asset bundle。
  @visibleForTesting
  static CatalogSeedAssetLoader assetLoader = rootBundle.load;

  /// 写入 seed → 登记 → 物化。永不抛出。
  ///
  /// [filesDir] 缺省取 core 默认目录（与 `CoreBootstrap` 的 `dirs.$2` 一致）。
  static Future<void> ensure({String? filesDir}) async {
    // Web 没有 dart:io 文件系统；catalog repo 仅移动端使用。
    if (kIsWeb) return;
    try {
      final dir = filesDir ?? (await CutoverPaths.defaultCoreDirs()).$2;
      final seedPath = await _writeSeed(dir);
      await CatalogFacade.instance.repoEnsureSeed(path: seedPath);
      await CatalogFacade.instance.repoMaterialize();
    } catch (error) {
      // 非致命：目录缺失时 GStore 页会显示空态，下次启动重试。
      debugPrint('[CatalogSeedBootstrap] seed 自举失败（忽略，继续启动）: $error');
    }
  }

  /// 把资产写到 `<filesDir>/catalog_seed.db`：先写 `.tmp`，再原子 rename。
  ///
  /// 每次启动都覆盖（约 90KB）；Rust 侧按 sha256 内容寻址去重，重复写入不会
  /// 产生新仓库条目。
  static Future<String> _writeSeed(String filesDir) async {
    final dir = Directory(filesDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final target = File('$filesDir/$seedFileName');
    final temp = File('${target.path}.tmp');

    final data = await assetLoader(seedAssetKey);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await temp.writeAsBytes(bytes, flush: true);
    // POSIX（Android/Linux/测试宿主）上 rename 原子覆盖目标。
    await temp.rename(target.path);
    return target.path;
  }

  /// 测试用：恢复默认资产加载器。
  @visibleForTesting
  static void resetForTest() {
    assetLoader = rootBundle.load;
  }
}
