import 'dart:io';

import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/a2ui_lab_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final samples = <String, String>{
    for (final asset in const [
      'assets/a2ui/app_card.json',
      'assets/a2ui/filter_form.json',
      'assets/a2ui/results_list.json',
    ])
      asset: File(asset).readAsStringSync(),
  };

  Widget host() => MaterialApp(
        home: A2uiLabPage(
          loadSample: (asset) => SynchronousFuture(samples[asset]!),
        ),
      );

  testWidgets('A2UI lab renders the app card sample and captures actions',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('A2UI 实验室'), findsOneWidget);
    expect(find.text('应用卡片'), findsOneWidget);
    expect(find.byType(A2uiSurface), findsOneWidget);

    // Data model binding: the app name comes from /app/name.
    expect(find.text('Termux'), findsOneWidget);

    await tester.tap(find.text('安装').first);
    await tester.pumpAndSettle();

    expect(find.text('Action 日志'), findsOneWidget);
    expect(find.text('install_app'), findsOneWidget);
  });

  testWidgets('A2UI lab form submits the bound data model', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('筛选表单'));
    await tester.pumpAndSettle();

    expect(find.text('筛选应用'), findsOneWidget);
    expect(find.text('应用筛选'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'termux');
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();

    expect(find.text('apply_filter'), findsOneWidget);
    expect(find.textContaining('termux'), findsWidgets);
  });

  testWidgets('A2UI lab renders the templated result list', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('结果列表'));
    await tester.pumpAndSettle();

    expect(find.text('搜索结果（5）'), findsOneWidget);
    expect(find.text('Termux'), findsOneWidget);
    expect(find.text('F-Droid'), findsOneWidget);
    expect(find.text('OsmAnd'), findsOneWidget);
  });

  testWidgets('A2UI lab fits a 360x640 viewport', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(A2uiSurface), findsOneWidget);
  });
}
