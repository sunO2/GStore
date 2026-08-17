import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/design/app_components.dart';

/// 用指定 cardTheme 构建主题，并捕获主题上下文供 AppBorders 读取。
Future<BuildContext> pumpContext(
  WidgetTester tester, {
  CardThemeData? cardTheme,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(cardTheme: cardTheme),
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('AppBorders.sideOf', () {
    testWidgets('默认主题回退 outlineVariant + width 1.0', (tester) async {
      final context = await pumpContext(tester);
      final scheme = Theme.of(context).colorScheme;

      final side = AppBorders.sideOf(context);

      expect(side.width, 1.0);
      expect(side.color, scheme.outlineVariant);
    });

    testWidgets('宽度/颜色跟随主题 cardTheme.shape.side', (tester) async {
      final context = await pumpContext(
        tester,
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 1.5, color: Colors.red),
          ),
        ),
      );

      final side = AppBorders.sideOf(context);

      expect(side.width, 1.5);
      expect(side.color, Colors.red);
    });

    testWidgets('borderStyle none（width 0）也跟随主题', (tester) async {
      final context = await pumpContext(
        tester,
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 0),
          ),
        ),
      );

      expect(AppBorders.sideOf(context).width, 0);
    });

    testWidgets('color 参数覆盖主题颜色，宽度仍随主题', (tester) async {
      final context = await pumpContext(
        tester,
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 1.5, color: Colors.red),
          ),
        ),
      );

      final side = AppBorders.sideOf(context, color: Colors.green);

      expect(side.width, 1.5);
      expect(side.color, Colors.green);
    });
  });

  group('AppBorders.all', () {
    testWidgets('四边统一边框宽度/颜色随主题', (tester) async {
      final context = await pumpContext(
        tester,
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 0.5, color: Colors.blue),
          ),
        ),
      );

      final border = AppBorders.all(context);

      expect(border.top.width, 0.5);
      expect(border.bottom.width, 0.5);
      expect(border.left.width, 0.5);
      expect(border.right.width, 0.5);
      expect(border.top.color, Colors.blue);
    });
  });

  group('AppCard 边框跟随主题', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      CardThemeData? cardTheme,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(cardTheme: cardTheme),
          home: Scaffold(
            body: AppCard(
              border: Border.all(color: Colors.red, width: 3),
              child: const Text('card'),
            ),
          ),
        ),
      );
    }

    RoundedRectangleBorder cardShape(WidgetTester tester) =>
        tester.widget<Card>(find.byType(Card)).shape! as RoundedRectangleBorder;

    testWidgets('非 BorderSide border fallback 宽度随主题（默认 1.0）',
        (tester) async {
      await pumpCard(tester);

      final shape = cardShape(tester);
      expect(shape.side.width, 1.0);
      expect(
        shape.side.color,
        Theme.of(tester.element(find.byType(Card)))
            .colorScheme
            .outlineVariant,
      );
    });

    testWidgets('非 BorderSide border fallback 宽度随主题（bold 1.5）',
        (tester) async {
      await pumpCard(
        tester,
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 1.5, color: Colors.orange),
          ),
        ),
      );

      final shape = cardShape(tester);
      expect(shape.side.width, 1.5);
      expect(shape.side.color, Colors.orange);
    });
  });
}
