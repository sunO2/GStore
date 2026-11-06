import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_inline_cards.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_provider.dart';
import 'package:gstore/core/theme/theme_state_store.dart';
import 'package:gstore/page/agent/widgets/agent_control_card.dart';

/// 可编程的假网关，用于覆盖读取 / 写入 / 外部变更。
class _FakeValueGateway implements AgentValueConfigGateway {
  Object? value;
  bool failWrite = false;
  int writes = 0;
  final StreamController<Object?> controller =
      StreamController<Object?>.broadcast();

  @override
  Future<Object?> read(String key) async => value;

  @override
  Future<AgentValueWriteResult> write(String key, Object? newValue) async {
    writes++;
    if (failWrite) {
      return const AgentValueWriteResult.failure('保存失败');
    }
    value = newValue;
    controller.add(newValue);
    return const AgentValueWriteResult.success();
  }

  @override
  Stream<Object?> watch(String key) => controller.stream;
}

Widget _app(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  final sliderSpec =
      AgentInlineCards.controlForKey(ConfigKeys.downloadMaxConcurrent)!;
  final stringSegSpec =
      AgentInlineCards.controlForKey(ConfigKeys.updateAutoUpdatePolicy)!;
  final intSegSpec = AgentInlineCards.controlForKey(ConfigKeys.themeMode)!;

  tearDown(() async {
    ThemeStateStore.instance.resetForTest();
    await ConfigService.instance.resetForTest();
    ConfigStore.instance.resetForTest();
  });

  testWidgets('dispatcher renders switch / slider / segmented per spec kind', (
    tester,
  ) async {
    final switchSpec =
        AgentInlineCards.controlForKey(ConfigKeys.downloadWifiOnly)!;

    // 开关卡片走生产网关，先初始化内存配置后端，避免真实 FFI 依赖。
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();

    await tester.pumpWidget(_app(AgentControlCard(spec: switchSpec)));
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(SegmentedButton<String>), findsNothing);

    final sliderFake = _FakeValueGateway()..value = 4;
    addTearDown(sliderFake.controller.close);
    await tester.pumpWidget(
      _app(AgentControlCard(spec: sliderSpec, gateway: sliderFake)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(SegmentedButton<String>), findsNothing);

    final segFake = _FakeValueGateway()..value = 'never';
    addTearDown(segFake.controller.close);
    await tester.pumpWidget(
      _app(AgentControlCard(spec: stringSegSpec, gateway: segFake)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
  });

  testWidgets('slider renders title/subtitle/value and writes on change end', (
    tester,
  ) async {
    final fake = _FakeValueGateway()..value = 4;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSliderCard(spec: sliderSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    expect(find.text(sliderSpec.title), findsOneWidget);
    expect(find.text(sliderSpec.subtitle), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 4);

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(7);
    await tester.pump();
    slider.onChangeEnd!(7);
    await tester.pumpAndSettle();

    expect(fake.writes, 1);
    expect(fake.value, 7);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 7);
  });

  testWidgets('slider failed write reverts to the previous value', (
    tester,
  ) async {
    final fake = _FakeValueGateway()
      ..value = 4
      ..failWrite = true;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSliderCard(spec: sliderSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(9);
    await tester.pump();
    slider.onChangeEnd!(9);
    await tester.pumpAndSettle();

    expect(fake.writes, 1);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 4);
  });

  testWidgets('slider external stream emission updates the value', (
    tester,
  ) async {
    final fake = _FakeValueGateway()..value = 4;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSliderCard(spec: sliderSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    fake.controller.add(9);
    await tester.pump();
    await tester.pump();

    expect(tester.widget<Slider>(find.byType(Slider)).value, 9);
  });

  testWidgets('segmented renders labels and writes the selected string', (
    tester,
  ) async {
    final fake = _FakeValueGateway()..value = 'never';
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSegmentedCard(spec: stringSegSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    expect(find.text('总是'), findsOneWidget);

    await tester.tap(find.text('总是'));
    await tester.pumpAndSettle();

    expect(fake.writes, 1);
    expect(fake.value, 'always');
  });

  testWidgets('segmented int enum writes an int for theme.mode',
      (tester) async {
    final fake = _FakeValueGateway()..value = 0;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSegmentedCard(spec: intSegSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(fake.writes, 1);
    expect(fake.value, isA<int>());
    expect(fake.value, 2);
  });

  testWidgets('segmented external stream emission updates the selection', (
    tester,
  ) async {
    final fake = _FakeValueGateway()..value = 'never';
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(AgentSegmentedCard(spec: stringSegSpec, gateway: fake)),
    );
    await tester.pumpAndSettle();

    fake.controller.add('always');
    await tester.pump();
    await tester.pump();

    final segmented = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(segmented.selected, contains('always'));
  });

  testWidgets('two cards sharing one gateway both update on change', (
    tester,
  ) async {
    final fake = _FakeValueGateway()..value = 4;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(
      _app(
        Column(
          children: [
            AgentSliderCard(spec: sliderSpec, gateway: fake),
            AgentSliderCard(spec: sliderSpec, gateway: fake),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.widgetList<Slider>(find.byType(Slider)).first;
    first.onChanged!(8);
    await tester.pump();
    first.onChangeEnd!(8);
    await tester.pumpAndSettle();

    final values = tester
        .widgetList<Slider>(find.byType(Slider))
        .map((slider) => slider.value);
    expect(values, everyElement(8));
  });

  testWidgets('theme.mode segmented card updates themeProvider immediately', (
    tester,
  ) async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeProvider);

    await tester.pumpWidget(_app(AgentSegmentedCard(spec: intSegSpec)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('深色'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(await ConfigService.instance.getT<int>(ConfigKeys.themeMode), 2);
    expect(container.read(themeProvider).mode, AppThemeMode.dark);
  });

  testWidgets(
      'theme.mode AgentControlCard uses themeProvider and switches immediately',
      (
    tester,
  ) async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(AgentControlCard(spec: intSegSpec)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('深色'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(container.read(themeProvider).mode, AppThemeMode.dark);
    expect(await ConfigService.instance.getT<int>(ConfigKeys.themeMode), 2);
  });

  test('ThemeModeConfigGateway writes through the authoritative theme notifier',
      () async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeProvider);

    const gateway = ThemeModeConfigGateway();
    final result = await gateway.write(ConfigKeys.themeMode, 2);

    expect(result.success, isTrue);
    expect(container.read(themeProvider).mode, AppThemeMode.dark);
    expect(await ConfigService.instance.getT<int>(ConfigKeys.themeMode), 2);
    expect(ThemeStateStore.instance.state.value.mode, AppThemeMode.dark);
  });

  testWidgets('theme.mode AgentControlCard reads persisted value on init', (
    tester,
  ) async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[MemoryConfigStorage()],
    );
    await ConfigService.instance.ensureReady();
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      2,
      source: ConfigChangeSource.user,
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(AgentControlCard(spec: intSegSpec)),
      ),
    );
    await tester.pumpAndSettle();

    final segmented = tester.widget<SegmentedButton<String>>(
      find.byType(SegmentedButton<String>),
    );
    expect(segmented.selected, contains('2'));
  });
}
