// 与 lib/core/rust/ 既有桥接文件命名约定一致（PascalCase）。
// `file_names` 是项目既有噪音（同目录 11 个文件同样触发），此处显式豁免，
// 避免新增分析诊断。
// ignore_for_file: file_names

import 'dart:typed_data' show Uint8List;

/// 清单格式错误（旧 schema / 不支持的版本 / 结构不可解析）。
///
/// 显式、可断言：调用方（加载器）捕获后安全降级，绝不因缺字段崩溃。
class ModuleManifestFormatException implements Exception {
  final String message;

  const ModuleManifestFormatException(this.message);

  @override
  String toString() => 'ModuleManifestFormatException: $message';
}

/// 单个 ABI 的资产描述（清单 v2 `abi.<abi>` 条目）。
class ModuleAbiAsset {
  /// Release 资产名（如 `libgstore_mod_qr_1.0.0-arm64-v8a.so`）。
  final String asset;

  /// 该资产的 SHA-256（十六进制小写）。
  final String sha256;

  /// 资产字节数。
  final int size;

  /// 可选签名（本阶段未启用；保留迁移路径）。
  final String? signature;

  const ModuleAbiAsset({
    required this.asset,
    required this.sha256,
    required this.size,
    this.signature,
  });

  /// 防御式解析：任一必填字段缺失/类型错误 → 返回 null（视为该资产无效），
  /// 不做任何 `as` 强转，绝不抛异常。
  static ModuleAbiAsset? tryFromJson(Object? json) {
    if (json is! Map) return null;

    final asset = json['asset'];
    final hash = json['sha256'];
    if (asset is! String || asset.isEmpty) return null;
    if (hash is! String || hash.isEmpty) return null;

    final size = _asInt(json['size']);
    if (size == null || size < 0) return null;

    final signature = json['signature'];
    return ModuleAbiAsset(
      asset: asset,
      sha256: hash,
      size: size,
      signature: signature is String && signature.isNotEmpty ? signature : null,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 清单 v2 模块条目（`modules.<name>`）。
class ModuleEntryV2 {
  final String version;

  /// 宿主最低 ABI 版本（可选；缺失 → null）。
  final String? minHostAbi;

  /// ABI 名 → 资产。缺失/非法的 `abi` → 空 map（`forAbi` 返回 null）。
  final Map<String, ModuleAbiAsset> abi;

  const ModuleEntryV2({
    required this.version,
    this.minHostAbi,
    required this.abi,
  });

  /// 取指定 ABI 的资产；缺失/非法 → null，绝不抛异常。
  ModuleAbiAsset? forAbi(String abiName) => abi[abiName];

  /// 防御式解析：非 Map / 缺 `version` → null（跳过该模块条目）。
  /// 单个 ABI 条目非法（缺 asset/sha256/size）→ 跳过该 ABI，不影响其他 ABI。
  static ModuleEntryV2? tryFromJson(Object? json) {
    if (json is! Map) return null;

    final version = json['version'];
    if (version is! String || version.isEmpty) return null;

    final abi = <String, ModuleAbiAsset>{};
    final rawAbi = json['abi'];
    if (rawAbi is Map) {
      for (final entry in rawAbi.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final asset = ModuleAbiAsset.tryFromJson(entry.value);
        if (asset != null) abi[key] = asset;
      }
    }

    final minHostAbi = json['min_host_abi'];
    return ModuleEntryV2(
      version: version,
      minHostAbi:
          minHostAbi is String && minHostAbi.isNotEmpty ? minHostAbi : null,
      abi: abi,
    );
  }
}

/// 模块清单 v2：
/// `{ version: 2, modules: { <name>: { version, min_host_abi, abi: { <abi>: {...} } } } }`。
class ModuleManifestV2 {
  static const int schemaVersion = 2;

  final int version;
  final Map<String, ModuleEntryV2> modules;

  const ModuleManifestV2({required this.version, required this.modules});

  /// 取模块条目；缺失 → null。
  ModuleEntryV2? entry(String name) => modules[name];

  /// 严格解析：旧 schema（含 `file_name`）或 `version != 2` **显式拒绝**并抛
  /// [ModuleManifestFormatException]。其余字段防御式解析（跳过非法条目）。
  factory ModuleManifestV2.fromJson(Map<String, dynamic> json) {
    if (json['file_name'] != null) {
      throw const ModuleManifestFormatException(
        'legacy manifest schema detected (`file_name`); expected v2',
      );
    }

    final rawVersion = json['version'];
    final version = rawVersion is int
        ? rawVersion
        : (rawVersion is String ? int.tryParse(rawVersion) : null);
    if (version != schemaVersion) {
      throw ModuleManifestFormatException(
        'unsupported manifest version: ${rawVersion ?? 'null'} '
        '(expected $schemaVersion)',
      );
    }

    final rawModules = json['modules'];
    if (rawModules is! Map) {
      throw const ModuleManifestFormatException(
        'manifest `modules` must be an object',
      );
    }

    final modules = <String, ModuleEntryV2>{};
    for (final entry in rawModules.entries) {
      final name = entry.key;
      if (name is! String || name.isEmpty) continue;
      final rawEntry = entry.value;
      if (rawEntry is! Map) continue;
      if (rawEntry.containsKey('file_name')) {
        throw ModuleManifestFormatException(
          'legacy manifest entry for "$name" uses `file_name`; expected v2',
        );
      }
      final parsed = ModuleEntryV2.tryFromJson(rawEntry);
      if (parsed != null) modules[name] = parsed;
    }

    // `version == schemaVersion` 已在上面校验，此处非空。
    return ModuleManifestV2(version: version!, modules: modules);
  }
}

/// 清单来源抽象（Todo 8 由 `ModuleManifestClient` 实现：独立、校验证书、
/// 不走代理的通道）。已校验缓存/网络失败时返回 null。
abstract class ModuleManifestSource {
  Future<ModuleManifestV2?> load({bool forceRefresh = false});
}

/// 资产下载抽象（Todo 3 由 `ModuleDownloader` 实现：自举、来源校验、原子）。
/// 失败返回 null，绝不抛异常给调用方以外。
abstract class ModuleFetcher {
  Future<Uint8List?> fetch(String url, {int? maxBytes});
}
