import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/channel_build_history_sheet.dart';
import 'package:gstore/core/design/channel_version_picker_sheet.dart';

/// ChannelBuildHistorySheet 通用构建历史选择器 widget 测试
///
/// 覆盖：
/// ① 渲染：标题（版本/env）+ 构建列表（num/时间/大小/更新日志）
/// ② 单选构建 → 确认 → 返回选中 BuildOption
/// ③ 取消 → null
/// ④ 构建多（25+）→ 弹框不超屏、确认/取消按钮固定可见、列表内部滚动
/// ⑤ 空构建列表 → 空提示 + 确认禁用
void main() {
  final builds = [
    BuildOption(
      num: 12,
      publishedAt: DateTime(2026, 8, 1, 10, 30),
      size: 1024 * 1024,
      changelog: '修复崩溃',
      installTimes: 42,
      builtBy: 'ci',
      ipaName: 'app-1.2.0-12.ipa',
    ),
    BuildOption(
      num: 11,
      publishedAt: DateTime(2026, 7, 30, 9, 0),
      size: 512 * 1024,
      changelog: '新增功能',
      installTimes: 10,
      builtBy: 'ci',
      ipaName: 'app-1.2.0-11.ipa',
    ),
  ];

  /// 挂具：集成 showModalBottomSheet，捕获面板 pop 返回值
  ({Widget app, Future<BuildOption?> Function() open}) buildHarness({
    String? version,
    String? env,
    List<BuildOption>? buildsOverride,
  }) {
    late Future<BuildOption?> result;
    final app = MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                result = ChannelBuildHistorySheet.show(
                  context: context,
                  version: version ?? '1.2.0',
                  env: env ?? 'uat',
                  builds: buildsOverride ?? builds,
                );
              },
              child: const Text('打开构建历史'),
            ),
          ),
        ),
      ),
    );
    return (app: app, open: () => result);
  }

  Future<void> openSheet(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.tap(find.text('打开构建历史'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 面板滑入动画
  }

  testWidgets('① 渲染：标题（版本/env）+ 构建列表（num/时间/大小/更新日志）', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    // 标题携带版本/env
    expect(find.text('历史构建 · 1.2.0'), findsOneWidget);
    expect(find.text('uat'), findsOneWidget);

    // 构建列表：num/时间/大小/更新日志
    expect(find.text('构建 #12'), findsOneWidget);
    expect(find.text('构建 #11'), findsOneWidget);
    expect(find.textContaining('08-01 10:30'), findsOneWidget);
    expect(find.textContaining('1.0 MB'), findsOneWidget);
    expect(find.text('修复崩溃'), findsOneWidget);
    expect(find.text('新增功能'), findsOneWidget);

    // 未选中时确认按钮禁用
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认下载'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('② 单选构建 → 确认 → 返回选中 BuildOption', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    // 点构建 #12 → 确认按钮启用
    await tester.tap(find.text('构建 #12'));
    await tester.pump();

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认下载'),
    );
    expect(confirm.onPressed, isNotNull);

    await tester.tap(find.text('确认下载'));
    await tester.pumpAndSettle();

    final result = await h.open();
    expect(result, isNotNull);
    expect(result!.num, 12);
    expect(result.ipaName, 'app-1.2.0-12.ipa');
    expect(result.changelog, '修复崩溃');
  });

  testWidgets('③ 取消 → null', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final result = await h.open();
    expect(result, isNull);
  });

  testWidgets('④ 构建多（25+）→ 弹框不超屏、按钮固定可见、列表内部滚动', (tester) async {
    final manyBuilds = [
      for (var i = 0; i < 25; i++)
        BuildOption(num: i + 1, publishedAt: DateTime(2026, 8, 1), size: 100),
    ];
    final h = buildHarness(buildsOverride: manyBuilds);
    await openSheet(tester, h.app);

    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    final confirm = find.text('确认下载');
    final cancel = find.text('取消');
    expect(confirm, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(screenH));
    expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(screenH));
    expect(tester.getRect(confirm).top, greaterThan(0));
    expect(tester.takeException(), isNull);

    // 列表内部滚动：首项滚出、按钮固定可见
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('构建 #1'), findsNothing);
    expect(find.text('确认下载'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑤ 空构建列表 → 空提示 + 确认禁用', (tester) async {
    final h = buildHarness(buildsOverride: const <BuildOption>[]);
    await openSheet(tester, h.app);

    expect(find.text('暂无构建记录'), findsOneWidget);

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认下载'),
    );
    expect(confirm.onPressed, isNull);
  });
}
