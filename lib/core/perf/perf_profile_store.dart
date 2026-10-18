/// 每应用性能档案的持久化存储（配置键 `perf.profiles`，todo 22）。
///
/// ## 持久化路径判定（决定：**走注册表路径**）
/// `config_registry.dart` 的 [ConfigEntry] 支持 [ConfigValueType.json]，
/// 且 [ConfigStore] 对 `Map` / `List` 值统一 `jsonEncode` + `decodeIfJsonString`
/// （见 `config_storage.dart`），足以承载「包名 → 档案」的 JSON map。
/// 因此**不新建平行存储**：新增配置键 [ConfigKeys.perfProfiles]（安全默认空 map）
/// 并经由 [ConfigStore] 读写。
///
/// ## 存储形态与安全默认
/// * 存储值 = `{"<package>": <PerfProfile.toJson>}`。
/// * 无记录 / 空串 / 未知（非 Map）/ **畸形 JSON** / 部分损坏的条目
///   → 退化为空 map（损坏条目 best-effort 跳过），**绝不抛异常**。
///
/// ## 解耦
/// 本层只读写配置，**不**执行任何 Shizuku 命令、**不**依赖控制会话（todo 20）
/// 或能力探测（todo 15）——自动应用引擎（todo 24）/ 编辑器 UI（todo 25）在其之上构建。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_store.dart';

import 'perf_profile.dart';

/// 将存储原始值解码为「包名 → 档案」map（纯函数，**绝不抛**）。
///
/// [raw] 可为：`null`（无记录）、JSON 字符串、已解码的 `Map`。
/// 非 Map / 非法 JSON → 空 map；单个损坏条目 → 跳过。
Map<String, PerfProfile> decodePerfProfiles(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, PerfProfile>{};
    try {
      decoded = jsonDecode(trimmed);
    } catch (error) {
      debugPrint('[PerfProfileStore] JSON 解析失败，按空档案处理: $error');
      return <String, PerfProfile>{};
    }
  }
  if (decoded is! Map) return <String, PerfProfile>{};
  final result = <String, PerfProfile>{};
  decoded.forEach((key, value) {
    if (key is! String || key.isEmpty) return;
    if (value is! Map) return;
    try {
      final profile = PerfProfile.fromJson(
        value.map((k, v) => MapEntry(k.toString(), v)),
      );
      // 档案身份以 map 键为准（缺省 / 不一致时归一）。
      result[key] =
          profile.package.isEmpty ? profile.copyWith(package: key) : profile;
    } catch (error) {
      debugPrint('[PerfProfileStore] 跳过损坏档案 $key: $error');
    }
  });
  return result;
}

/// 将「包名 → 档案」map 编码为可 JSON 序列化的 map（**绝不抛**）。
Map<String, dynamic> encodePerfProfiles(Map<String, PerfProfile> profiles) {
  final out = <String, dynamic>{};
  profiles.forEach((key, profile) {
    if (key.isEmpty) return;
    out[key] = profile.toJson();
  });
  return out;
}

/// 每应用性能档案持久化接口。
abstract class PerfProfileStore {
  /// 读取全部档案；无记录 / 失败 → 空 map。
  Future<Map<String, PerfProfile>> loadAll();

  /// 覆盖保存全部档案；返回是否写入成功。
  Future<bool> saveAll(Map<String, PerfProfile> profiles);

  /// 读取单个包的档案；不存在 → `null`。
  Future<PerfProfile?> load(String package);

  /// 新增 / 覆盖单个档案；[PerfProfile.package] 为空 → `false`（不写）。
  Future<bool> save(PerfProfile profile);

  /// 删除单个包的档案；不存在视为成功。
  Future<bool> remove(String package);

  /// 清空全部档案（写空 map）。
  Future<bool> clear();
}

/// 生产实现：经由 [ConfigStore] 读写配置键 [ConfigKeys.perfProfiles]。
class ConfigPerfProfileStore implements PerfProfileStore {
  const ConfigPerfProfileStore();

  @override
  Future<Map<String, PerfProfile>> loadAll() async {
    try {
      final raw = await ConfigStore.instance.readValue(ConfigKeys.perfProfiles);
      return decodePerfProfiles(raw);
    } catch (error) {
      debugPrint('[PerfProfileStore] 读取档案失败: $error');
      return <String, PerfProfile>{};
    }
  }

  @override
  Future<bool> saveAll(Map<String, PerfProfile> profiles) async {
    try {
      return await ConfigStore.instance.write(
        ConfigKeys.perfProfiles,
        encodePerfProfiles(profiles),
      );
    } catch (error) {
      debugPrint('[PerfProfileStore] 保存档案失败: $error');
      return false;
    }
  }

  @override
  Future<PerfProfile?> load(String package) async {
    if (package.isEmpty) return null;
    final all = await loadAll();
    return all[package];
  }

  @override
  Future<bool> save(PerfProfile profile) async {
    if (profile.package.isEmpty) return false;
    final all = await loadAll();
    all[profile.package] = profile;
    return saveAll(all);
  }

  @override
  Future<bool> remove(String package) async {
    final all = await loadAll();
    if (!all.containsKey(package)) return true;
    all.remove(package);
    return saveAll(all);
  }

  @override
  Future<bool> clear() => saveAll(<String, PerfProfile>{});
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryPerfProfileStore implements PerfProfileStore {
  InMemoryPerfProfileStore([Map<String, PerfProfile>? seed])
      : _profiles = <String, PerfProfile>{...?seed};

  final Map<String, PerfProfile> _profiles;

  @override
  Future<Map<String, PerfProfile>> loadAll() async =>
      <String, PerfProfile>{..._profiles};

  @override
  Future<bool> saveAll(Map<String, PerfProfile> profiles) async {
    _profiles
      ..clear()
      ..addAll(profiles);
    return true;
  }

  @override
  Future<PerfProfile?> load(String package) async => _profiles[package];

  @override
  Future<bool> save(PerfProfile profile) async {
    if (profile.package.isEmpty) return false;
    _profiles[profile.package] = profile;
    return true;
  }

  @override
  Future<bool> remove(String package) async {
    _profiles.remove(package);
    return true;
  }

  @override
  Future<bool> clear() async {
    _profiles.clear();
    return true;
  }
}
