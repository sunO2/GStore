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

  testWidgets('legacy dollar bindings are normalized before rendering',
      (tester) async {
    const legacy = r'''
[
  {
    "version": "1.0",
    "createSurface": {
      "surfaceId": "legacy",
      "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
      "dataModel": {"products": [{"name": "稳稳盈 A", "acc": "1.23%"}]},
      "components": [
        {"id": "root", "component": "List",
         "children": {"path": "/products", "componentId": "tpl"}},
        {"id": "tpl", "component": "Column", "children": ["name", "acc"]},
        {"id": "name", "component": "Text", "text": "$name"},
        {"id": "acc", "component": "Text", "text": "累计 $acc"}
      ]
    }
  }
]
''';
    await tester.pumpWidget(_host(A2uiToolCard(payload: legacy)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('稳稳盈 A'), findsOneWidget);
    expect(find.text('累计'), findsOneWidget);
    expect(find.text('1.23%'), findsOneWidget);
    expect(find.textContaining(r'$name'), findsNothing);
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
