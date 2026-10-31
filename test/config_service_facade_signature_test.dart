// Facade compatibility contract (Todo 14).
//
// Asserts every public member that existed before the Rust `ConfigApi` swap is
// still present with a compatible signature. Nothing here touches FFI, so the
// test runs under the default (bridge-unavailable) harness.

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_provider.dart';
import 'package:gstore/core/config/config_service.dart';

/// Minimal [ConfigModule] implementation used to prove the abstract contract.
class _SignatureModule extends ConfigModule {
  @override
  String get moduleName => 'signature_module';

  @override
  List<ConfigEntry> get configs => const <ConfigEntry>[];
}

class _SignatureProvider extends ConfigProvider<Object?> {
  @override
  String get configKey => 'signature.key';

  @override
  Future<Object?> load() async => null;

  @override
  Future<bool> save(Object? value) async => true;

  @override
  Future<bool> clear() async => true;

  @override
  Stream<Object?> watch() => const Stream<Object?>.empty();

  @override
  Future<bool> exists() async => false;

  @override
  Future<bool> importFromJson(Map<String, dynamic> json) async => true;
}

void main() {
  group('ConfigService facade signature', () {
    test('singleton + value objects are preserved', () {
      final service = ConfigService.instance;
      expect(identical(service, ConfigService.instance), isTrue);

      const entry = ConfigEntry(
        key: 'theme.mode',
        type: ConfigValueType.int,
        defaultValue: 0,
        sensitive: false,
        agentAccessible: true,
        description: '主题模式',
        descriptionEn: 'Theme mode',
        enumValues: <String>['0', '1', '2'],
        category: 'theme',
        unit: 'mode',
        min: 0,
        max: 2,
        example: '2',
      );
      expect(entry.key, 'theme.mode');
      expect(entry.type, ConfigValueType.int);
      expect(entry.defaultValue, 0);
      expect(entry.sensitive, isFalse);
      expect(entry.agentAccessible, isTrue);
      expect(entry.description, '主题模式');
      expect(entry.descriptionEn, 'Theme mode');
      expect(entry.enumValues, <String>['0', '1', '2']);
      expect(entry.category, 'theme');
      expect(entry.unit, 'mode');
      expect(entry.min, 0);
      expect(entry.max, 2);
      expect(entry.example, '2');

      const snapshot = ConfigSnapshot(
        key: 'theme.mode',
        type: 'int',
        value: 2,
        defaultValue: 0,
        description: '主题模式',
        descriptionEn: 'Theme mode',
        sensitive: false,
        agentAccessible: true,
        enumValues: <String>['0', '1', '2'],
        category: 'theme',
        unit: 'mode',
        min: 0,
        max: 2,
        example: '2',
      );
      final json = snapshot.toJson();
      expect(json['key'], 'theme.mode');
      expect(json['type'], 'int');
      expect(json['value'], 2);
      expect(json['defaultValue'], 0);
      expect(json['sensitive'], isFalse);
      expect(json['agentAccessible'], isTrue);
      expect(json['enumValues'], <String>['0', '1', '2']);
      expect(json['category'], 'theme');
      expect(json['unit'], 'mode');
      expect(json['min'], 0);
      expect(json['max'], 2);
      expect(json['example'], '2');

      const change = ConfigChangeEvent(
        key: 'theme.mode',
        oldValue: 0,
        newValue: 2,
        source: ConfigChangeSource.user,
      );
      expect(change.key, 'theme.mode');
      expect(change.oldValue, 0);
      expect(change.newValue, 2);
      expect(change.source, ConfigChangeSource.user);
      expect(change.toString(), contains('theme.mode'));

      const ok = ConfigOpResult.success(
        'ok',
        key: 'theme.mode',
        value: 2,
        defaultValue: 0,
      );
      expect(ok.success, isTrue);
      expect(ok.message, 'ok');
      expect(ok.key, 'theme.mode');
      expect(ok.value, 2);
      expect(ok.defaultValue, 0);

      const failed = ConfigOpResult.failure('bad', key: 'theme.mode');
      expect(failed.success, isFalse);
      expect(failed.message, 'bad');
      expect(failed.key, 'theme.mode');

      expect(ConfigChangeSource.values, <ConfigChangeSource>[
        ConfigChangeSource.user,
        ConfigChangeSource.agent,
        ConfigChangeSource.internal,
      ]);
      expect(ConfigValueType.values, <ConfigValueType>[
        ConfigValueType.bool,
        ConfigValueType.int,
        ConfigValueType.double,
        ConfigValueType.string,
        ConfigValueType.stringList,
        ConfigValueType.json,
      ]);
    });

    test('every pre-Rust public method still exists with a compatible type', () {
      final service = ConfigService.instance;

      final Future<void> Function() ensureReady = service.ensureReady;
      final void Function(ConfigEntry) register = service.register;
      final void Function(List<ConfigEntry>) registerAll = service.registerAll;
      final void Function(ConfigModule) registerModule = service.registerModule;
      final void Function(String) unregisterModule = service.unregisterModule;
      final bool Function(String) hasModule = service.hasModule;
      final List<String> moduleNames = service.moduleNames;
      final void Function<T>(ConfigProvider<T>) bridgeProvider =
          service.bridgeProvider;
      final void Function() initialize = service.initialize;
      final ConfigEntry? Function(String) entry = service.entry;
      final bool Function(String) has = service.has;
      final List<ConfigEntry> Function() list = service.list;
      final bool Function(String) isAgentAccessible = service.isAgentAccessible;
      final Future<Object?> Function(String) getRaw = service.getRaw;
      final Future<Object?> Function(String, {bool masked}) get = service.get;
      final Future<T?> Function<T>(String) getT = service.getT;
      final Future<ConfigSnapshot?> Function(String) snapshot = service.snapshot;
      final Future<List<ConfigSnapshot>> Function() snapshots = service.snapshots;
      final Future<ConfigOpResult> Function(
        String,
        Object?, {
        ConfigChangeSource source,
      }) set = service.set;
      final Future<ConfigOpResult> Function(
        String, {
        ConfigChangeSource source,
      }) reset = service.reset;
      final Future<ConfigOpResult> Function(
        String, {
        ConfigChangeSource source,
      }) clear = service.clear;
      final Stream<ConfigChangeEvent> Function(String) watch = service.watch;
      final Stream<ConfigChangeEvent> Function(String) watchModule =
          service.watchModule;
      final Stream<ConfigChangeEvent> Function(List<String>) watchMany =
          service.watchMany;
      final Stream<ConfigChangeEvent> onChange = service.onChange;
      final void Function() dispose = service.dispose;

      expect(ensureReady, isNotNull);
      expect(register, isNotNull);
      expect(registerAll, isNotNull);
      expect(registerModule, isNotNull);
      expect(unregisterModule, isNotNull);
      expect(hasModule, isNotNull);
      expect(moduleNames, isA<List<String>>());
      expect(bridgeProvider, isNotNull);
      expect(initialize, isNotNull);
      expect(entry, isNotNull);
      expect(has, isNotNull);
      expect(list, isNotNull);
      expect(isAgentAccessible, isNotNull);
      expect(getRaw, isNotNull);
      expect(get, isNotNull);
      expect(getT, isNotNull);
      expect(snapshot, isNotNull);
      expect(snapshots, isNotNull);
      expect(set, isNotNull);
      expect(reset, isNotNull);
      expect(clear, isNotNull);
      expect(watch, isNotNull);
      expect(watchModule, isNotNull);
      expect(watchMany, isNotNull);
      expect(onChange, isNotNull);
      expect(dispose, isNotNull);
    });

    test('ConfigModule abstract contract is preserved', () {
      final module = _SignatureModule();
      expect(module.moduleName, 'signature_module');
      expect(module.configs, isEmpty);
      // Default implementation exists and is a no-op.
      module.registerProviders(ConfigService.instance);

      final provider = _SignatureProvider();
      expect(provider.configKey, 'signature.key');
    });
  });
}
