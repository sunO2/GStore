import 'dart:io';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/a2ui_tool_card.dart';

String _sample(String name) =>
    File('assets/a2ui/$name.json').readAsStringSync();

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('renders the surface and forwards actions', (tester) async {
    final actions = <A2uiRendererAction>[];
    await tester.pumpWidget(
      _host(
        A2uiToolCard(
          payload: _sample('app_card'),
          title: '应用卡片',
          onAction: actions.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('应用卡片'), findsOneWidget);
    expect(find.text('A2UI'), findsOneWidget);
    expect(find.text('Termux'), findsOneWidget);

    await tester.tap(find.text('安装').first);
    await tester.pumpAndSettle();

    expect(actions, hasLength(1));
    expect(actions.single.name, 'install_app');
    expect(actions.single.context['package'], 'com.termux');
    expect(find.textContaining('已提交'), findsOneWidget);
  });

  testWidgets('does not forward actions when disabled', (tester) async {
    final actions = <A2uiRendererAction>[];
    await tester.pumpWidget(
      _host(
        A2uiToolCard(
          payload: _sample('app_card'),
          enabled: false,
          onAction: actions.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('安装').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    expect(find.textContaining('暂不可操作'), findsOneWidget);
  });

  testWidgets('shows a validation error for a broken payload', (tester) async {
    await tester.pumpWidget(
      _host(const A2uiToolCard(payload: '{not json')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('INVALID_JSON'), findsOneWidget);
  });
}
