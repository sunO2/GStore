import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/page/about/widgets/about_brand_header.dart';

void main() {
  test('GS 点阵字形保持 11×7，且 G/S 之间的间隔列始终为空', () {
    expect(kGStoreGlyph, hasLength(7));
    for (final String row in kGStoreGlyph) {
      expect(row.length, 11, reason: '每一行必须是 11 列：$row');
      expect(row[5], '.', reason: 'G 与 S 之间的间隔列必须为空：$row');
    }
    // S 的左侧竖笔从第 7 列（index 6）开始，不能落到间隔列上。
    expect(kGStoreGlyph[1][6], '#');
    expect(kGStoreGlyph[2][6], '#');
    // S 的右侧竖笔在最右列。
    expect(kGStoreGlyph[4][10], '#');
    expect(kGStoreGlyph[5][10], '#');
    // 右下角保留强调点。
    expect(kGStoreGlyph[6][10], 'o');
  });

  testWidgets('品牌头展示应用名、描述、版本与内核版本', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutBrandHeader(
            appVersion: Future<String?>.value('1.0.24'),
            coreVersion: Future<int?>.value(6),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('GStore'), findsOneWidget);
    expect(find.text('开源 Android 应用商店'), findsOneWidget);
    expect(find.text('v1.0.24'), findsOneWidget);
    expect(find.text('GStore Core v6'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('版本读取中显示占位，失败显示未知但不抛异常', (WidgetTester tester) async {
    final Completer<String?> version = Completer<String?>();
    final Completer<int?> core = Completer<int?>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutBrandHeader(
            appVersion: version.future,
            coreVersion: core.future,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('v…'), findsOneWidget);
    expect(find.text('GStore Core v…'), findsOneWidget);

    version.complete(null);
    core.complete(null);
    await tester.pump();
    await tester.pump();

    expect(find.text('v—'), findsOneWidget);
    expect(find.text('GStore Core —'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
