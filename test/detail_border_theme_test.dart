import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/view.dart' as detail_view;
import 'package:gstore/page/detail/widgets.dart';

/// 反复推进真实异步 + 刷新帧，直到不再出现 AppLoading 占位（README 转换完成）。
Future<void> _pumpUntilConverted(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(AppLoading).evaluate().isEmpty) return;
  }
}

/// 详情页边框主题一致性（Wave 2）：
/// 卡片/区块边框宽度应响应主题 cardTheme.shape.side（borderStyle 配置），
/// 语义色（primary/outlineVariant 系）保留，仅宽度/透明度随主题。
///
/// 主题约定：cardTheme.shape.side.width = 1.5 模拟"粗犷"边框风格。
const _themeSide = BorderSide(width: 1.5, color: Colors.red);

ThemeData _theme() => ThemeData(
      cardTheme: CardThemeData(
        shape: RoundedRectangleBorder(side: _themeSide),
      ),
    );

/// 读取指定 widget 的 BoxDecoration 边框（四边统一时取 top）。
BorderSide _borderOf(Widget widget) {
  final decoration = switch (widget) {
    Container(:final decoration?) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => throw StateError('not a decorated widget: $widget'),
  } as BoxDecoration;
  final border = decoration.border;
  expect(border, isNotNull, reason: 'widget 应带边框');
  return (border as Border).top;
}

/// 找到包含 [text] 的最内层带边框 Container（SectionCard/VersionBadge 的卡片容器）。
Finder _borderedContainerOf(WidgetTester tester, String text) {
  return find
      .ancestor(of: find.text(text), matching: find.byType(Container))
      .first;
}

/// 最小 IDetailInfo 假实现（仅 README 区块测试需要）。
class _FakeDetailInfo extends IDetailInfo {
  _FakeDetailInfo({this.readme});

  @override
  final String? readme;

  @override
  String get packageName => 'com.test.app';

  @override
  String get appName => 'Test App';

  @override
  String get icon => '';

  @override
  String get description => '';

  @override
  String get appId => 'test';

  @override
  String get channelId => 'local_db';

  @override
  ChannelType get channelType => ChannelType.localDb;

  @override
  String? get version => null;

  @override
  String? get developer => null;

  @override
  String? get projectUrl => null;

  @override
  List<DownloadInfo> get downloads => const [];

  @override
  List<DetailSection> get sections => const [];

  @override
  Map<String, dynamic> get extra => {'readme': readme};

  @override
  List<ScreenshotInfo>? get screenshots => null;

  @override
  String? get changelog => null;

  @override
  List<String>? get permissions => null;

  @override
  StatisticsInfo? get statistics => null;

  @override
  List<StatTag> buildStatTags() => const [];
}

void main() {
  group('SectionCard 边框宽度随主题', () {
    testWidgets('cardTheme width 1.5 → 卡片边框宽度 1.5', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: SectionCard(
              title: '测试区块',
              children: const [Text('content')],
            ),
          ),
        ),
      );

      final container =
          tester.widget<Container>(_borderedContainerOf(tester, 'content'));
      expect(_borderOf(container).width, 1.5);
    });

    testWidgets('默认主题 → 回退宽度 1.0', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SectionCard(
              title: '测试区块',
              children: const [Text('content')],
            ),
          ),
        ),
      );

      final container =
          tester.widget<Container>(_borderedContainerOf(tester, 'content'));
      expect(_borderOf(container).width, 1.0);
    });
  });

  group('VersionBadge 边框宽度随主题', () {
    testWidgets('cardTheme width 1.5 → 角标边框宽度 1.5', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: VersionBadge(latestVersion: '1.0.0', installedVersion: null),
          ),
        ),
      );

      final container =
          tester.widget<Container>(_borderedContainerOf(tester, '1.0.0'));
      expect(_borderOf(container).width, 1.5);
    });
  });

  group('detail view border(context)', () {
    testWidgets('返回 BorderSide 宽度随主题 cardTheme', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );

      final side = detail_view.border(captured);
      expect(side.width, 1.5);
    });

    testWidgets('默认主题 → 回退宽度 1.0', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(detail_view.border(captured).width, 1.0);
    });
  });

  group('README 引用块（语义色强调）', () {
    testWidgets('左边框 width 4 保留，不随主题', (tester) async {
      final info = _FakeDetailInfo(readme: '> 引用内容');
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Scaffold(body: ReadmeSection(info: info)),
        ),
      );
      // HTML→markdown 转换在后台 isolate（compute）完成；转换完成前渲染
      // AppLoading 占位（无限动画，pumpAndSettle 永不 settle）→ 先轮询真实
      // 异步等转换结果回写，再推进动画帧。
      await _pumpUntilConverted(tester);
      await tester.pump(const Duration(milliseconds: 100));

      final quote = find.byWidgetPredicate((w) {
        final decoration = switch (w) {
          Container(:final decoration?) => decoration,
          DecoratedBox(:final decoration) => decoration,
          _ => null,
        };
        if (decoration is! BoxDecoration) return false;
        final border = decoration.border;
        return border is Border && border.left.width == 4;
      });

      expect(quote, findsWidgets,
          reason: '引用块应渲染且左边框保持语义强调宽度 4');
    });
  });
}