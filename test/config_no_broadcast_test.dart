// Behavioral gate for plan C4 / Todo 36: config changes must never use the
// legacy AppEventBus broadcast downlink. The Rust ABI v5 filtered subscription
// is the only path a module uses to observe config changes.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/event/app_event_bus_bootstrap.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

generated.ConfigEntryDto _entry({
  required String module,
  required String key,
  required String valueType,
  required String defaultJson,
  String category = '',
  List<String> enumValues = const <String>[],
}) {
  return generated.ConfigEntryDto(
    module: module,
    key: key,
    wireKey: '$module.$key',
    valueType: valueType,
    valueJson: defaultJson,
    masked: false,
    revision: BigInt.zero,
    sensitive: false,
    agentAccessible: true,
    visibility: 'owner',
    defaultJson: defaultJson,
    descriptionZh: '$module.$key',
    descriptionEn: '$module.$key',
    category: category,
    enumValues: enumValues,
  );
}

class _FakeConfigApi implements ConfigApiClient {
  final StreamController<generated.ConfigChangeDto> _changes =
      StreamController<generated.ConfigChangeDto>.broadcast();
  final List<String> watchFilters = <String>[];
  final List<generated.ConfigEntryDto> _entries = <generated.ConfigEntryDto>[
    _entry(
      module: 'download',
      key: 'max_concurrent',
      valueType: 'int',
      defaultJson: '3',
      category: 'download',
    ),
    _entry(
      module: 'theme',
      key: 'mode',
      valueType: 'int',
      defaultJson: '0',
      category: 'theme',
      enumValues: const <String>['0', '1', '2'],
    ),
  ];
  int _revision = 0;

  generated.ConfigEntryDto? _find(String module, String key) {
    for (final entry in _entries) {
      if (entry.module == module && entry.key == key) return entry;
    }
    return null;
  }

  Future<void> close() => _changes.close();

  void emit(String module, String key, Object? value) {
    _changes.add(generated.ConfigChangeDto(
      module: module,
      key: key,
      wireKey: '$module.$key',
      valueJson: value == null ? null : jsonEncode(value),
      oldValueJson: null,
      revision: BigInt.from(++_revision),
      source: 'user',
    ));
  }

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    return _entries
        .where((entry) => module == null || entry.module == module)
        .toList();
  }

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) async {
    return null;
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    return <generated.ConfigSnapshotDto>[];
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async {
    final entry = _find(module, key);
    if (entry == null) throw StateError('unknown config key $module.$key');
    return entry.defaultJson;
  }

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async {
    throw UnimplementedError('not used by the no-broadcast test');
  }

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async {
    throw UnimplementedError('not used by the no-broadcast test');
  }

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async {
    throw UnimplementedError('not used by the no-broadcast test');
  }

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) {
    watchFilters.add('$module/${key ?? '*'}');
    return _changes.stream.where(
      (change) => change.module == module && (key == null || change.key == key),
    );
  }
}

const Set<String> _configTypes = <String>{
  AppEventTypes.configChanged,
  AppEventTypes.themeChanged,
};

Future<void> _settle([int ms = 25]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ConfigService.instance;
  final bus = AppEventBus.instance;
  late _FakeConfigApi fake;

  setUp(() async {
    await service.resetForTest();
    await AppEventBusBootstrap.dispose();
    bus.registerDownlinkSink(null);
    bus.resetGuards();
    fake = _FakeConfigApi();
    service.debugSetApi(ConfigRustApi(fake));
    await service.ensureReady();
    AppEventBusBootstrap.initialize();
  });

  tearDown(() async {
    await AppEventBusBootstrap.dispose();
    bus.registerDownlinkSink(null);
    await service.resetForTest();
    await fake.close();
    bus.resetGuards();
  });

  test('config/theme stay upstream while download keeps its filtered delivery',
      () async {
    final broadcastDeliveries = <String>[];
    bus.registerDownlinkSink((event) => broadcastDeliveries.add(event.type));

    final seen = <AppEvent>[];
    final seenSub = bus.stream.listen(seen.add);
    final downloadEvents = <ConfigChangeEvent>[];
    final downloadSub =
        service.watchModule('download').listen(downloadEvents.add);
    await _settle(0);

    fake.emit('download', 'max_concurrent', 5);
    await _settle();
    fake.emit('theme', 'mode', 2);
    await _settle();

    final configEvents = seen.where((e) => _configTypes.contains(e.type));
    expect(configEvents, isNotEmpty,
        reason: 'config changes still fan out to Dart listeners upstream');
    expect(configEvents.where((e) => e.downlink), isEmpty,
        reason: 'no config/theme AppEvent may be marked downlink');
    expect(broadcastDeliveries.where(_configTypes.contains), isEmpty,
        reason: 'the broadcast/downlink boundary receives zero config events');

    expect(
      downloadEvents.map((e) => e.key),
      contains('download.max_concurrent'),
      reason: 'the ABI-filtered download watch still delivers its own key',
    );
    expect(
      downloadEvents.map((e) => e.key),
      isNot(contains('theme.mode')),
      reason: 'the filtered download stream must not receive theme changes',
    );

    await seenSub.cancel();
    await downloadSub.cancel();
  });

  test('a non-config downlink event still reaches the broadcast boundary',
      () async {
    final broadcastDeliveries = <AppEvent>[];
    bus.registerDownlinkSink(broadcastDeliveries.add);

    bus.emit('demo.changed', data: <String, dynamic>{'n': 1}, downlink: true);
    await _settle(0);

    expect(broadcastDeliveries.map((e) => e.type), <String>['demo.changed']);
  });

  test('legacy config broadcast never fires after bootstrap disposal (stale)',
      () async {
    final broadcastDeliveries = <AppEvent>[];
    bus.registerDownlinkSink(broadcastDeliveries.add);
    final seen = <AppEvent>[];
    final seenSub = bus.stream.listen(seen.add);

    await AppEventBusBootstrap.dispose();
    fake.emit('download', 'max_concurrent', 6);
    fake.emit('theme', 'mode', 1);
    await _settle();

    expect(seen.where((e) => _configTypes.contains(e.type)), isEmpty,
        reason: 'a disposed bootstrap must not keep republishing config');
    expect(broadcastDeliveries, isEmpty,
        reason: 'the stale legacy downlink handler must never fire');

    await seenSub.cancel();
  });
}
