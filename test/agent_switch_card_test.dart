import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/inline_card_registry.dart';
import 'package:gstore/page/agent/widgets/agent_switch_card.dart';

/// 可编程的假网关，用于覆盖读取 / 写入 / 外部变更。
class _FakeGateway implements AgentSwitchConfigGateway {
  bool value = true;
  bool failWrite = false;
  bool throwOnRead = false;
  int writes = 0;
  final StreamController<bool?> controller = StreamController<bool?>.broadcast();

  @override
  Future<bool?> read(String key) async {
    if (throwOnRead) throw StateError('read failed');
    return value;
  }

  @override
  Future<AgentSwitchWriteResult> write(String key, bool newValue) async {
    writes++;
    if (failWrite) {
      return const AgentSwitchWriteResult.failure('写入失败');
    }
    value = newValue;
    controller.add(newValue);
    return const AgentSwitchWriteResult.success();
  }

  @override
  Stream<bool?> watch(String key) => controller.stream;
}

Widget _app(
  AgentInlineSwitchSpec spec,
  _FakeGateway gateway, {
  VoidCallback? onShowDetail,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AgentSwitchCard(
        spec: spec,
        gateway: gateway,
        onShowDetail: onShowDetail,
      ),
    ),
  );
}

void main() {
  final spec = AgentInlineCards.switchSpecs.first;

  testWidgets('renders title/subtitle and defaults to registry value', (
    tester,
  ) async {
    final fake = _FakeGateway();
    addTearDown(fake.controller.close);

    await tester.pumpWidget(_app(spec, fake));
    await tester.pumpAndSettle();

    expect(find.text(spec.title), findsOneWidget);
    expect(find.text(spec.subtitle), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('tapping switch writes once and toggles off', (tester) async {
    final fake = _FakeGateway();
    addTearDown(fake.controller.close);

    await tester.pumpWidget(_app(spec, fake));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump();

    expect(fake.writes, 1);
    expect(fake.value, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('failed write reverts switch state', (tester) async {
    final fake = _FakeGateway()..failWrite = true;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(_app(spec, fake));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump();

    expect(fake.writes, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('external stream emission updates switch', (tester) async {
    final fake = _FakeGateway();
    addTearDown(fake.controller.close);

    await tester.pumpWidget(_app(spec, fake));
    await tester.pumpAndSettle();

    fake.controller.add(false);
    await tester.pump();
    await tester.pump();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('tapping title invokes onShowDetail', (tester) async {
    final fake = _FakeGateway();
    addTearDown(fake.controller.close);
    var tapped = 0;

    await tester.pumpWidget(
      _app(spec, fake, onShowDetail: () => tapped++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(spec.title));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('read failure falls back to the registry default and stays '
      'interactive', (tester) async {
    final fake = _FakeGateway()..throwOnRead = true;
    addTearDown(fake.controller.close);

    await tester.pumpWidget(_app(spec, fake));
    await tester.pumpAndSettle();

    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);
    expect(sw.onChanged, isNotNull);
  });
}
