import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';
import 'package:gstore/page/home/tab/applist/widgets/horizontal_app_row.dart';

/// 无边框档（borderStyle=none）真无边框 + 分段选择器最小边框（≥0.5）测试
///
/// 覆盖：
/// ① borderStyle=none 的 ThemeData → cardTheme/outlinedButton/input 的 side 为
///    BorderStyle.none（真无边框，非 BorderSide(width:0) 的 hairline）
/// ② AppBorders.sideOf/all 在 none 主题返回 style none（Border.all style none）
/// ③ 首页"最近添加"卡片（HorizontalAppRow）在 none 主题渲染无边框
/// ④ AppSegmentedButton 在 none 主题 side width 0.5（非 hairline），标准档 1.0
/// ⑤ 原生 SegmentedButton（segmentedButtonTheme）在 none 主题有 ≥0.5 边框

ThemeData _theme(AppBorderStyle style) =>
    ThemeDataBuilder.buildLightTheme(null, config: AppThemeConfig(borderStyle: style));

ThemeData _darkTheme(AppBorderStyle style) =>
    ThemeDataBuilder.buildDarkTheme(null, config: AppThemeConfig(borderStyle: style));

RoundedRectangleBorder _cardShape(ThemeData theme) =>
    theme.cardTheme.shape! as RoundedRectangleBorder;

/// 捕获指定主题下的 BuildContext（供 AppBorders 读取）
Future<BuildContext> _pumpContext(
  WidgetTester tester,
  ThemeData theme,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
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

AggregatedAppInfo _app(String id) => AggregatedAppInfo(
      addedAppInfo: AddedAppInfo(channelId: 'github', appId: id),
      appInfo: AppSummary(
        appId: id,
        packageName: 'com.example.$id',
        name: 'App $id',
        user: 'owner',
        repositories: 'owner/$id',
        icon: '',
        des: 'desc',
      ),
      channel: ChannelType.github,
    );

/// 横向卡片中带边框的 Container（唯一：角标/图标容器均无边框）
Container _borderedContainer(WidgetTester tester) {
  final containers = tester.widgetList<Container>(find.byType(Container));
  return containers.firstWhere(
    (c) =>
        c.decoration is BoxDecoration &&
        (c.decoration as BoxDecoration).border != null,
  );
}

Border _borderOf(Container container) =>
    ((container.decoration! as BoxDecoration).border! as Border);

void main() {
  group('① borderStyle=none 主题真无边框（BorderSide.none）', () {
    test('亮色 none：cardTheme side 为 BorderStyle.none', () {
      final theme = _theme(AppBorderStyle.none);
      expect(_cardShape(theme).side.style, BorderStyle.none);
    });

    test('暗色 none：cardTheme side 为 BorderStyle.none', () {
      final theme = _darkTheme(AppBorderStyle.none);
      expect(_cardShape(theme).side.style, BorderStyle.none);
    });

    test('亮色 none：outlinedButtonTheme side 为 BorderStyle.none', () {
      final theme = _theme(AppBorderStyle.none);
      final side = theme.outlinedButtonTheme.style!.side!.resolve({})!;
      expect(side.style, BorderStyle.none);
    });

    test('亮色 none：inputDecorationTheme border/enabled/focused 均 BorderStyle.none', () {
      final theme = _theme(AppBorderStyle.none);
      final input = theme.inputDecorationTheme;
      expect((input.border! as OutlineInputBorder).borderSide.style, BorderStyle.none);
      expect((input.enabledBorder! as OutlineInputBorder).borderSide.style, BorderStyle.none);
      expect((input.focusedBorder! as OutlineInputBorder).borderSide.style, BorderStyle.none);
    });

    test('标准档保持既有语义：cardTheme side solid width 1.0', () {
      final theme = _theme(AppBorderStyle.standard);
      final side = _cardShape(theme).side;
      expect(side.style, BorderStyle.solid);
      expect(side.width, 1.0);
    });

    test('bold 档保持既有语义：cardTheme side solid width 1.5', () {
      final theme = _theme(AppBorderStyle.bold);
      final side = _cardShape(theme).side;
      expect(side.style, BorderStyle.solid);
      expect(side.width, 1.5);
    });
  });

  group('② AppBorders style 传递', () {
    testWidgets('none 主题：sideOf 返回 style none', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.none));
      expect(AppBorders.sideOf(context).style, BorderStyle.none);
    });

    testWidgets('none 主题：all() 的 Border 各边 style none（真无边框）', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.none));
      final border = AppBorders.all(context);
      expect(border.top.style, BorderStyle.none);
      expect(border.bottom.style, BorderStyle.none);
      expect(border.left.style, BorderStyle.none);
      expect(border.right.style, BorderStyle.none);
    });

    testWidgets('标准主题：all() 的 Border 各边 style solid width 1.0', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.standard));
      final border = AppBorders.all(context);
      expect(border.top.style, BorderStyle.solid);
      expect(border.top.width, 1.0);
    });

    testWidgets('none 主题：sideOf 颜色覆盖时仍保留 none style', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.none));
      final side = AppBorders.sideOf(context, color: Colors.red);
      expect(side.style, BorderStyle.none);
      expect(side.color, Colors.red);
    });
  });

  group('③ 首页最近添加卡片（HorizontalAppRow）none 主题无边框', () {
    testWidgets('none 主题：卡片边框 style none（不绘制）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(AppBorderStyle.none),
          home: Scaffold(
            body: HorizontalAppRow(
              apps: [_app('a')],
              onTap: (_) {},
            ),
          ),
        ),
      );

      final border = _borderOf(_borderedContainer(tester));
      expect(border.top.style, BorderStyle.none);
      expect(border.bottom.style, BorderStyle.none);
      expect(border.left.style, BorderStyle.none);
      expect(border.right.style, BorderStyle.none);
    });

    testWidgets('标准主题：卡片边框 style solid width 1.0（回归）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(AppBorderStyle.standard),
          home: Scaffold(
            body: HorizontalAppRow(
              apps: [_app('a')],
              onTap: (_) {},
            ),
          ),
        ),
      );

      final border = _borderOf(_borderedContainer(tester));
      expect(border.top.style, BorderStyle.solid);
      expect(border.top.width, 1.0);
    });
  });

  group('④ AppSegmentedButton 最小边框 floor', () {
    Future<BorderSide> appSegmentSide(
      WidgetTester tester,
      ThemeData theme,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AppSegmentedButton<String>(
              value: 'a',
              segments: const [
                AppSegment(value: 'a', label: 'A'),
                AppSegment(value: 'b', label: 'B'),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      );
      final button = tester.widget<SegmentedButton<Object>>(
        find.byWidgetPredicate((w) => w is SegmentedButton),
      );
      return button.style!.side!.resolve({})!;
    }

    testWidgets('none 主题：side width 0.5（非 hairline 语义）', (tester) async {
      final side = await appSegmentSide(tester, _theme(AppBorderStyle.none));
      expect(side.width, 0.5);
      expect(side.style, BorderStyle.solid);
    });

    testWidgets('none 主题：颜色回退 outlineVariant（随主题）', (tester) async {
      final theme = _theme(AppBorderStyle.none);
      final side = await appSegmentSide(tester, theme);
      expect(side.color, theme.colorScheme.outlineVariant);
    });

    testWidgets('标准档：width 1.0（保持既有语义）', (tester) async {
      final side = await appSegmentSide(tester, _theme(AppBorderStyle.standard));
      expect(side.width, 1.0);
    });

    testWidgets('bold 档：width 1.5（保持既有语义）', (tester) async {
      final side = await appSegmentSide(tester, _theme(AppBorderStyle.bold));
      expect(side.width, 1.5);
    });
  });

  group('⑤ 原生 SegmentedButton（segmentedButtonTheme）最小边框', () {
    testWidgets('none 主题：segmentedButtonTheme side width ≥0.5', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.none));
      final theme = Theme.of(context);
      final side = theme.segmentedButtonTheme.style!.side!.resolve({})!;
      expect(side.width, greaterThanOrEqualTo(0.5));
      expect(side.style, BorderStyle.solid);
    });

    testWidgets('none 主题：原生 SegmentedButton 渲染无异常且消费主题 side', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(AppBorderStyle.none),
          home: Scaffold(
            body: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'a', label: Text('A')),
                ButtonSegment(value: 'b', label: Text('B')),
              ],
              selected: const {'a'},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final theme = Theme.of(
        tester.element(find.byWidgetPredicate((w) => w is SegmentedButton)),
      );
      final side = theme.segmentedButtonTheme.style!.side!.resolve({})!;
      expect(side.width, greaterThanOrEqualTo(0.5));
    });

    testWidgets('标准档：segmentedButtonTheme side width 1.0（保持既有语义）', (tester) async {
      final context = await _pumpContext(tester, _theme(AppBorderStyle.standard));
      final theme = Theme.of(context);
      final side = theme.segmentedButtonTheme.style!.side!.resolve({})!;
      expect(side.width, 1.0);
    });
  });
}