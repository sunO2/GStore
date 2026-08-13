import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/page/detail/widgets.dart';

/// SectionCard 组件测试
///
/// 验证详情页统一 Section 卡片容器：
/// - 容器：surface 背景 + outlineVariant 细边框(1) + AppRadius.lg 圆角
/// - 间距：margin=AppSpacing.onlyBottomSM、padding=AppSpacing.allLG
/// - 标题行：icon(iconMD, primary) + SizedBox(sm) + 标题(titleSmall 加粗) + count + Spacer + trailing
/// - 可选参数（icon/count/trailing）不传时不渲染
/// - children 全部渲染
Future<void> pumpSectionCard(
  WidgetTester tester, {
  String title = '测试标题',
  IconData? icon,
  Widget? count,
  Widget? trailing,
  List<Widget> children = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SectionCard(
            title: title,
            icon: icon,
            count: count,
            trailing: trailing,
            children: children,
          ),
        ),
      ),
    ),
  );
}

/// 取 SectionCard 根 Container 的 BoxDecoration 与 colorScheme
(BoxDecoration, ColorScheme) _containerInfo(WidgetTester tester) {
  final containerFinder = find
      .descendant(of: find.byType(SectionCard), matching: find.byType(Container))
      .first;
  final container = tester.widget<Container>(containerFinder);
  final decoration = container.decoration! as BoxDecoration;
  final colorScheme = Theme.of(tester.element(find.byType(SectionCard))).colorScheme;
  return (decoration, colorScheme);
}

void main() {
  testWidgets('容器装饰：surface 背景 + outlineVariant 边框(1) + AppRadius.lg 圆角', (tester) async {
    await pumpSectionCard(tester, children: const [Text('内容')]);

    final (decoration, colorScheme) = _containerInfo(tester);

    // 背景色 = colorScheme.surface（不是 primaryContainer 色块）
    expect(decoration.color, colorScheme.surface);
    // 边框 = outlineVariant 细边框
    final border = decoration.border! as Border;
    expect(border.top.color, colorScheme.outlineVariant);
    expect(border.top.width, 1);
    // 圆角 = AppRadius.lg
    expect(decoration.borderRadius, AppRadius.allLG);
    expect(tester.takeException(), isNull);
  });

  testWidgets('容器间距：margin=onlyBottomSM、padding=allLG', (tester) async {
    await pumpSectionCard(tester, children: const [Text('内容')]);

    final container = tester.widget<Container>(
      find
          .descendant(of: find.byType(SectionCard), matching: find.byType(Container))
          .first,
    );

    expect(container.margin, AppSpacing.onlyBottomSM);
    expect(container.padding, AppSpacing.allLG);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题行：icon 为 primary 色 iconMD 尺寸，标题 titleSmall 加粗', (tester) async {
    await pumpSectionCard(tester, icon: Icons.info_outline, children: const []);

    final colorScheme = Theme.of(tester.element(find.byType(SectionCard))).colorScheme;

    // 图标：primary 颜色 + iconMD 尺寸
    final icon = tester.widget<Icon>(find.byIcon(Icons.info_outline));
    expect(icon.size, AppTypography.iconMD);
    expect(icon.color, colorScheme.primary);

    // 标题：titleSmall 基础上加粗（weightSemiBold）
    final theme = Theme.of(tester.element(find.byType(SectionCard)));
    final title = tester.widget<Text>(find.text('测试标题'));
    expect(title.style?.fontWeight, AppTypography.weightSemiBold);
    expect(title.style?.fontSize, theme.textTheme.titleSmall?.fontSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('count 与 trailing：传入时渲染且顺序在标题之后', (tester) async {
    await pumpSectionCard(
      tester,
      icon: Icons.info_outline,
      count: const Text('(3)'),
      trailing: const Text('更多'),
      children: const [Text('内容')],
    );

    expect(find.text('测试标题'), findsOneWidget);
    expect(find.text('(3)'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);

    // 顺序：标题 → count → trailing（水平方向，标题与 count 相邻）
    final titleLeft = tester.getTopLeft(find.text('测试标题')).dx;
    final countLeft = tester.getTopLeft(find.text('(3)')).dx;
    final trailingLeft = tester.getTopLeft(find.text('更多')).dx;
    expect(countLeft, greaterThanOrEqualTo(titleLeft));
    expect(trailingLeft, greaterThan(countLeft));
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选参数（icon/count/trailing）：未传时不渲染', (tester) async {
    await pumpSectionCard(tester, children: const [Text('内容')]);

    expect(find.text('测试标题'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.text('(3)'), findsNothing);
    expect(find.text('更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('children：全部渲染', (tester) async {
    await pumpSectionCard(
      tester,
      children: const [Text('子内容一'), Text('子内容二')],
    );

    expect(find.text('子内容一'), findsOneWidget);
    expect(find.text('子内容二'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('布局：Column start 对齐，icon 在标题左侧(间距 sm)，标题行与内容间距 md', (tester) async {
    await pumpSectionCard(
      tester,
      icon: Icons.info_outline,
      count: const Text('(3)'),
      trailing: const Text('更多'),
      children: const [Text('子内容一')],
    );

    // Column 起始对齐
    final column = tester.widget<Column>(
      find
          .descendant(of: find.byType(SectionCard), matching: find.byType(Column))
          .first,
    );
    expect(column.crossAxisAlignment, CrossAxisAlignment.start);

    // 标题行是包含标题的 Row
    expect(
      find.ancestor(of: find.text('测试标题'), matching: find.byType(Row)),
      findsOneWidget,
    );

    // icon 在标题左侧，间距 sm
    final iconRight = tester.getTopRight(find.byIcon(Icons.info_outline)).dx;
    final titleLeft = tester.getTopLeft(find.text('测试标题')).dx;
    expect(titleLeft - iconRight, AppSpacing.sm);

    // 标题行底部与第一个 children 顶部间距 md
    final titleBottom = tester.getBottomLeft(find.text('测试标题')).dy;
    final contentTop = tester.getTopLeft(find.text('子内容一')).dy;
    expect(contentTop - titleBottom, moreOrLessEquals(AppSpacing.md, epsilon: 0.01));
    expect(tester.takeException(), isNull);
  });
}
