// Todo 17: startup-order enforcement.
//
// The production boot sequence is:
//   CoreBootstrap.start() (creates CoreApi)
//   -> ConfigInitializer.initialize() (ConfigStore backend + ConfigService hydration)
//   -> ModuleToggleConfig.preApplyToggles(...)
//
// This test records the real call order through a recording ConfigApiClient:
// `ConfigApi.list()` (readiness) must complete before preApplyToggles reads the
// module toggles.

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_toggle_config.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

generated.ConfigEntryDto _boolEntry(String module, String key, bool value) {
  return generated.ConfigEntryDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueType: 'bool',
    valueJson: 'null',
    masked: false,
    revision: BigInt.zero,
    sensitive: false,
    agentAccessible: true,
    visibility: 'owner',
    defaultJson: '$value',
    descriptionZh: '$module.$key',
    descriptionEn: '$module.$key',
    category: module,
    enumValues: const <String>[],
  );
}

/// Records when ConfigApi becomes ready and answers the one toggle read.
class _OrderProbeClient implements ConfigApiClient {
  _OrderProbeClient(this.order);

  final List<String> order;

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    order.add('config-api-ready');
    return <generated.ConfigEntryDto>[
      _boolEntry('module', 'channel.enabled', true),
    ];
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async =>
      'true';

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) =>
      const Stream<generated.ConfigChangeDto>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
    await ModuleManager.instance.clear();
  });

  tearDown(() {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
  });

  test('CoreApi ready -> ConfigStore/ConfigService ready -> preApplyToggles',
      () async {
    final order = <String>[];
    final client = _OrderProbeClient(order);

    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        // Real ConfigStore backend seam (memory in tests).
        await ConfigStore.instance.initialize(storages: <ConfigStorage>[
          MemoryConfigStorage(),
          MemoryConfigStorage(),
        ]);
        // Swap in the recording client so ConfigApi.list() is observable.
        ConfigService.instance.debugSetApi(ConfigRustApi(client));
        order.add('config-store-ready');
      },
      // ensureServiceReady uses production hydration (list + subscribe).
    );

    // CoreBootstrap.start() already created CoreApi before config init.
    order.add('core-ready');
    await ConfigInitializer.initialize();
    order.add('config-service-ready');

    order.add('before-preapply');
    await ModuleToggleConfig.preApplyToggles(ModuleManager.instance);
    order.add('after-preapply');

    expect(order.first, 'core-ready');
    expect(
      order.indexOf('core-ready'),
      lessThan(order.indexOf('config-store-ready')),
      reason: 'CoreApi must be created before the config store is wired',
    );
    expect(
      order.indexOf('config-store-ready'),
      lessThan(order.indexOf('config-api-ready')),
      reason: 'ConfigStore becomes ready before ConfigApi hydration completes',
    );
    expect(
      order.indexOf('config-api-ready'),
      lessThan(order.indexOf('config-service-ready')),
      reason: 'ConfigApi.list() must complete before ConfigService is ready',
    );
    expect(
      order.indexOf('config-api-ready'),
      lessThan(order.indexOf('before-preapply')),
      reason: 'ConfigApi must be ready before ModuleToggleConfig.preApplyToggles',
    );
    expect(
      order.indexOf('config-service-ready'),
      lessThan(order.indexOf('before-preapply')),
      reason: 'ConfigService must be ready before module toggles are applied',
    );
  });
}
