import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/page/about/widgets/about_brand_header.dart';
import 'package:gstore/page/about/widgets/dot_matrix.dart';

void main() {
  testWidgets('DotMatrix 可渲染并暴露图片语义', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DotMatrix(
              rows: kGStoreGlyph,
              semanticLabel: 'GStore',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(DotMatrix), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.bySemanticsLabel('GStore'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Reduce motion 下直接呈现静态终态', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(child: DotMatrix(rows: kGStoreGlyph)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(DotMatrix), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点按点阵不会抛异常（涟漪/触感路径）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: DotMatrix(rows: kGStoreGlyph)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(DotMatrix));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
