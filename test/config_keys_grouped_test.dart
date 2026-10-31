/// Todo 15 静态守卫：分组 `module.key` 配置键。
///
/// 事实来源：`rust/gstore_core/src/config/schema.rs`。本测试对照由 Rust
/// 注册表生成的 `test/fixtures/config_registry_keys.json` 检查：
/// - 所有 `ConfigKeys` 值都是 `module.key`，且存在于 Rust 注册表；
/// - 无重复/空白/旧裸 key；
/// - `LegacyConfigKeys` 只含旧值且不与运行时 key 重叠；
/// - `ConfigModules` 覆盖所有 key 的模块前缀；
/// - Dart 元数据（类型/默认值/敏感/Agent 可见性/描述/范围/枚举）与 Rust 一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';

typedef _RustEntry = Map<String, dynamic>;

List<_RustEntry> _loadRustRegistry() {
  final file = File('test/fixtures/config_registry_keys.json');
  expect(
    file.existsSync(),
    isTrue,
    reason: '缺少 Rust 注册表 fixture：${file.path}',
  );
  final decoded = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  return decoded.cast<Map<String, dynamic>>();
}

String _moduleOf(String wireKey) => wireKey.split('.').first;

/// Dart 枚举 → Rust `ConfigValueType` wire code（snake_case）。
String _typeCode(ConfigValueType type) {
  switch (type) {
    case ConfigValueType.bool:
      return 'bool';
    case ConfigValueType.int:
      return 'int';
    case ConfigValueType.double:
      return 'double';
    case ConfigValueType.string:
      return 'string';
    case ConfigValueType.stringList:
      return 'string_list';
    case ConfigValueType.json:
      return 'json';
  }
}

void _expectNum(Object? actual, Object? expected, String reason) {
  if (expected == null) {
    expect(actual, isNull, reason: reason);
    return;
  }
  expect(actual, isNotNull, reason: reason);
  expect((actual! as num).toDouble(), (expected as num).toDouble(),
      reason: reason);
}

void main() {
  late final List<_RustEntry> rust;
  late final Map<String, _RustEntry> rustByKey;
  late final Map<String, ConfigEntry> dartByKey;

  setUpAll(() {
    rust = _loadRustRegistry();
    rustByKey = <String, _RustEntry>{
      for (final entry in rust) entry['key'] as String: entry,
    };
    dartByKey = <String, ConfigEntry>{
      for (final entry in ConfigRegistry.entries) entry.key: entry,
    };
  });

  test('spot check: grouped wire values across modules', () {
    expect(ConfigKeys.proxyUrl, 'network.proxy_url');
    expect(ConfigKeys.themeMode, 'theme.mode');
    expect(ConfigKeys.themeConfig, 'theme.config');
    expect(ConfigKeys.catalogUrl, 'catalog.source_url');
    expect(ConfigKeys.downloadMultiSegmentEnabled,
        'download.multi_segment.enabled');
    expect(ConfigKeys.downloadMaxRetries, 'download.max_retries');
    expect(ConfigKeys.updateAutoUpdatePolicy, 'update.auto_update_policy');
    expect(ConfigKeys.webdavPassword, 'webdav.password');
    expect(ConfigKeys.agentModels, 'agent.models');
    expect(ConfigKeys.selectedChannels, 'discovery.selected_channels');
    expect(ConfigKeys.perfProfilesEnabled, 'perf.profiles.enabled');
    expect(ConfigKeys.moduleAgentToolsEnabled, 'module.agent_tools.enabled');
    expect(ConfigKeys.proxyEngineStack, 'proxy.engine_stack');
    expect(ConfigKeys.proxyLogLevel, 'proxy.log_level');
  });

  test('every ConfigKeys value is a non-empty module.key with no legacy bare '
      'name', () {
    final legacy = LegacyConfigKeys.all.toSet();
    for (final key in ConfigKeys.all) {
      expect(key.trim(), isNotEmpty, reason: '空白 key');
      expect(key.contains('.'), isTrue,
          reason: '$key 不是 module.key 分组形式');
      expect(key.startsWith('.'), isFalse, reason: '$key 以点开头');
      expect(key.endsWith('.'), isFalse, reason: '$key 以点结尾');
      expect(key.contains('..'), isFalse, reason: '$key 含连续点');
      expect(_moduleOf(key).isNotEmpty, isTrue, reason: '$key 缺少模块前缀');
      expect(legacy.contains(key), isFalse,
          reason: '$key 仍然是旧裸 key，不能出现在运行时 ConfigKeys');
    }
  });

  test('runtime keys match the committed Rust registry exactly', () {
    expect(ConfigKeys.all.length, 53,
        reason: 'Rust 注册表应恰好有 53 个条目');
    expect(rust.length, 53, reason: 'fixture 与 Rust 注册表条目数不一致');
    expect(ConfigKeys.all.toSet(), rustByKey.keys.toSet(),
        reason: 'ConfigKeys 与 Rust 注册表 key 集合不一致');
    for (final key in ConfigKeys.all) {
      expect(rustByKey.containsKey(key), isTrue,
          reason: '$key 不存在于 Rust 注册表 fixture');
    }
  });

  test('duplicate wire keys are rejected', () {
    expect(ConfigKeys.all.toSet().length, ConfigKeys.all.length,
        reason: 'ConfigKeys.all 存在重复 wire key');
    expect(dartByKey.length, ConfigRegistry.entries.length,
        reason: 'ConfigRegistry.entries 存在重复 wire key');
    expect(rustByKey.length, rust.length,
        reason: 'Rust fixture 存在重复 wire key');
    expect(dartByKey.keys.toSet(), ConfigKeys.all.toSet(),
        reason: '元数据列表与 ConfigKeys.all 不一致');
  });

  test('LegacyConfigKeys holds the old bare strings and never a runtime key',
      () {
    const expectedLegacy = <String>{
      'theme_config',
      'theme_mode',
      'download_config',
      'update_config',
      'webdav_config',
      'proxy_url',
      'catalog_url',
      'agent_models',
      'agent_selected_model_id',
      'agent_model_catalog',
      'fdroid_sources',
      'last_source_id',
      'selected_channels',
      'webdav_url',
      'webdav_username',
      'webdav_password',
      'webdav_backup_path',
      'webdav_enable_https',
    };
    expect(LegacyConfigKeys.all.toSet(), expectedLegacy);
    expect(LegacyConfigKeys.all.toSet().length, LegacyConfigKeys.all.length,
        reason: 'LegacyConfigKeys.all 存在重复值');

    final runtime = ConfigKeys.all.toSet();
    for (final legacy in LegacyConfigKeys.all) {
      expect(legacy.contains('.'), isFalse,
          reason: '$legacy 是分组 key，不应放在 LegacyConfigKeys');
      expect(runtime.contains(legacy), isFalse,
          reason: '$legacy 同时是运行时 key，破坏单一事实来源');
    }
  });

  test('ConfigModules covers every module prefix used by ConfigKeys', () {
    expect(ConfigModules.all, <String>{
      'theme',
      'download',
      'update',
      'webdav',
      'network',
      'catalog',
      'agent',
      'fdroid',
      'discovery',
      'perf',
      'module',
      'proxy',
      'misc',
    });
    final usedModules = ConfigKeys.all.map(_moduleOf).toSet();
    expect(usedModules.difference(ConfigModules.all), isEmpty,
        reason: '存在未声明的模块前缀：'
            '${usedModules.difference(ConfigModules.all)}');
    // 运行时 key 不应使用预留的 misc 模块。
    expect(usedModules.contains(ConfigModules.misc), isFalse);
  });

  test('Dart metadata matches the Rust registry for every key', () {
    for (final key in ConfigKeys.all) {
      final dart = dartByKey[key];
      final rust = rustByKey[key];
      expect(dart, isNotNull, reason: '$key 缺少 Dart ConfigEntry 元数据');
      expect(rust, isNotNull, reason: '$key 缺少 Rust fixture 元数据');

      expect(_typeCode(dart!.type), rust!['value_type'],
          reason: '$key 类型不一致');
      expect(jsonEncode(dart.defaultValue), jsonEncode(rust['default_json']),
          reason: '$key 默认值不一致');
      expect(dart.sensitive, rust['sensitive'],
          reason: '$key sensitive 不一致');
      expect(dart.agentAccessible, rust['agent_accessible'],
          reason: '$key agentAccessible 不一致');
      expect(dart.description, rust['description_zh'],
          reason: '$key 中文描述不一致');
      expect(dart.descriptionEn, rust['description_en'],
          reason: '$key 英文描述不一致');
      expect(dart.category, rust['category'], reason: '$key 分组不一致');
      expect(dart.unit, rust['unit'], reason: '$key 单位不一致');
      _expectNum(dart.min, rust['min'], '$key 最小值不一致');
      _expectNum(dart.max, rust['max'], '$key 最大值不一致');
      expect(
        dart.enumValues ?? const <String>[],
        (rust['enum_values'] as List<dynamic>).cast<String>(),
        reason: '$key 枚举值不一致',
      );
      expect(dart.example, rust['example'], reason: '$key 示例不一致');
    }
  });

  test('Rust visibility policy survives in the fixture', () {
    final publicRead = <String>{
      for (final entry in rust)
        if (entry['visibility'] == 'public_read') entry['key'] as String,
    };
    final secret = <String>{
      for (final entry in rust)
        if (entry['visibility'] == 'secret') entry['key'] as String,
    };
    expect(publicRead,
        <String>{'network.proxy_url', 'theme.mode', 'catalog.source_url'});
    expect(secret, <String>{'webdav.password', 'agent.models'});
    for (final key in secret) {
      expect(dartByKey[key]!.sensitive, isTrue,
          reason: 'Secret key $key 必须敏感');
    }
  });
}
