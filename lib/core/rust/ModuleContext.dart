import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 模块上下文：宿主 → 模块 `create(config)` 的标准约定（JSON）。
///
/// 对应 `rust/gstore_contract/src/context.rs`。通道复用既有的 create 字节流，
/// **不需要新增 ABI 槽位、不需要递增 ABI 版本**。
///
/// 兼容性：模块侧解析失败时会退化为"裸路径"旧约定，因此老调用方行为不变。
class ModuleContext {
  const ModuleContext({
    this.dataDir,
    this.cacheDir,
    this.dbPath,
    this.abi,
    this.extras,
  });

  /// 模块私有数据目录（宿主分配，模块自管其下文件/DB）
  final String? dataDir;

  /// 可清理的缓存目录
  final String? cacheDir;

  /// 显式 DB 路径（优先级高于 dataDir 推导）
  final String? dbPath;

  /// 当前 ABI（诊断用）
  final String? abi;

  /// 预留扩展键值
  final Map<String, String>? extras;

  Map<String, dynamic> toJson() => {
        if (dataDir != null && dataDir!.isNotEmpty) 'data_dir': dataDir,
        if (cacheDir != null && cacheDir!.isNotEmpty) 'cache_dir': cacheDir,
        if (dbPath != null && dbPath!.isNotEmpty) 'db_path': dbPath,
        if (abi != null && abi!.isNotEmpty) 'abi': abi,
        if (extras != null && extras!.isNotEmpty) 'extras': extras,
      };

  /// 编码为 `create(config)` 的字节
  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// 按模块名构造标准上下文：`<docs>/gstore_mods/<name>` 作为数据目录。
  ///
  /// [dbPath] 显式给出时优先生效（保证既有数据库路径不变）。
  static Future<ModuleContext> forModule(
    String moduleName, {
    String? dbPath,
  }) async {
    String? dataDir;
    String? cacheDir;
    try {
      final docs = await getApplicationDocumentsDirectory();
      dataDir = '${docs.path}/gstore_mods/$moduleName';
    } catch (_) {
      dataDir = null;
    }
    try {
      final tmp = await getTemporaryDirectory();
      cacheDir = '${tmp.path}/gstore_mods/$moduleName';
    } catch (_) {
      cacheDir = null;
    }
    return ModuleContext(
      dataDir: dataDir,
      cacheDir: cacheDir,
      dbPath: dbPath,
      abi: _currentAbi(),
    );
  }

  /// 当前 ABI（Dart 侧直接可得，无需平台通道）
  static String _currentAbi() {
    if (!Platform.isAndroid) return '';
    return switch (Abi.current()) {
      Abi.androidArm64 => 'arm64-v8a',
      Abi.androidArm => 'armeabi-v7a',
      Abi.androidX64 => 'x86_64',
      Abi.androidIA32 => 'x86',
      _ => '',
    };
  }
}
