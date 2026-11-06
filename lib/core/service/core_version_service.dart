import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';

/// GStore Rust 内核版本（当前暴露的是核心数据库 schema 版本）。
///
/// 版本真源在 Rust 侧：`CoreApi.migratePaths()` 读取 `PRAGMA user_version`
/// 并返回 `CoreInitResult.schemaVersion`。这里只做一次惰性读取 + 进程内缓存，
/// 供「关于」页展示；任何失败都返回 `null`，绝不把异常抛给 UI。
class CoreVersionService {
  CoreVersionService._();

  static Future<int?>? _pending;
  static int? _schemaVersion;

  /// 内核数据库 schema 版本；读取失败 → `null`。
  static Future<int?> schemaVersion() {
    final int? cached = _schemaVersion;
    if (cached != null) return Future<int?>.value(cached);
    final Future<int?> pending = _pending ??= _load();
    return pending;
  }

  static Future<int?> _load() async {
    try {
      final (String dataDir, String filesDir, String cacheDir) =
          await CutoverPaths.defaultCoreDirs();
      final api = await CoreApiFacade.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
      final result = await api.migratePaths();
      _schemaVersion = result.schemaVersion;
      return _schemaVersion;
    } catch (error) {
      appLog.warning(
        'CoreVersionService: 读取内核版本失败（关于页将显示未知）',
        data: {'error': error.toString()},
      );
      return null;
    } finally {
      _pending = null;
    }
  }

  /// 测试重置（清除内存缓存）。
  @visibleForTesting
  static void resetForTest() {
    _pending = null;
    _schemaVersion = null;
  }
}
