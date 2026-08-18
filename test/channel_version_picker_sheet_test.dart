import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/channel_version_picker_sheet.dart';

/// ChannelVersionPickerSheet 通用版本/环境选择器 widget 测试
///
/// 覆盖：
/// ① 渲染：env chips + 版本列表（含构建数）
/// ② 选 env → 版本列表过滤
/// ③ 选版本 → 确认 → 返回 VersionSelection{env, version}
/// ④ 点历史构建 → onBuildHistory 被调（mock 返回 builds）→ 显示构建列表 → 点某项 → onBuildSelect
/// ⑤ 取消 → null
/// ⑥ 当前选择高亮（currentEnv/currentVersion）
void main() {
  final envs = ['sit', 'uat', 'prd', 'rge', 'tmp'];

  final versions = [
    const VersionOption(
      version: '1.2.0',
      envs: ['sit', 'uat', 'prd'],
      buildCount: 5,
    ),
    const VersionOption(
      version: '1.1.0',
      envs: ['sit', 'uat'],
      buildCount: 3,
    ),
    const VersionOption(
      version: '1.0.0',
      envs: ['prd'],
      buildCount: 8,
    ),
  ];

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
  ({Widget app, Future<VersionSelection?> Function() open})
      buildHarness({
    String? currentEnv,
    String? currentVersion,
    Future<List<BuildOption>> Function({
      required String version,
      required String env,
    })? onBuildHistory,
    void Function(BuildOption build)? onBuildSelect,
  }) {
    late Future<VersionSelection?> result;
    final app = MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                result = ChannelVersionPickerSheet.show(
                  context: context,
                  title: '切换版本',
                  envs: envs,
                  versions: versions,
                  currentEnv: currentEnv,
                  currentVersion: currentVersion,
                  onBuildHistory: onBuildHistory,
                  onBuildSelect: onBuildSelect,
                );
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );
    return (app: app, open: () => result);
  }

  Future<void> openSheet(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.tap(find.text('打开选择器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 面板滑入动画
  }

  testWidgets('① 渲染：env chips + 版本列表（含构建数）', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    // 标题
    expect(find.text('切换版本'), findsOneWidget);

    // env chips
    for (final env in envs) {
      expect(find.text(env), findsOneWidget);
    }

    // 默认选中第一个 env（sit）→ 过滤出 sit 的版本
    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsOneWidget);
    expect(find.text('1.0.0'), findsNothing); // 1.0.0 不在 sit

    // 构建数
    expect(find.text('(5 个构建)'), findsOneWidget);
    expect(find.text('(3 个构建)'), findsOneWidget);

    // 历史构建按钮
    expect(find.text('历史构建'), findsNWidgets(2));

    // 确认按钮（未选版本时禁用）
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认切换'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('② 选 env → 版本列表过滤', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    // 切到 prd
    await tester.tap(find.text('prd'));
    await tester.pump();

    // prd 只有 1.2.0 和 1.0.0
    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsNothing);
    expect(find.text('(8 个构建)'), findsOneWidget);
  });

  testWidgets('③ 选版本 → 确认 → 返回 VersionSelection{env, version}', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    // 选版本 1.1.0
    await tester.tap(find.text('1.1.0'));
    await tester.pump();

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认切换'),
    );
    expect(confirm.onPressed, isNotNull);

    await tester.tap(find.text('确认切换'));
    await tester.pumpAndSettle();

    final result = await h.open();
    expect(result, isNotNull);
    expect(result!.env, 'sit');
    expect(result.version, '1.1.0');
  });

  testWidgets('④ 点历史构建 → onBuildHistory 被调 → 显示构建列表 → 点某项 → onBuildSelect',
      (tester) async {
    final historyCalls = <({String version, String env})>[];
    final selectedBuilds = <BuildOption>[];

    final h = buildHarness(
      onBuildHistory: ({required version, required env}) async {
        historyCalls.add((version: version, env: env));
        return builds;
      },
      onBuildSelect: (build) => selectedBuilds.add(build),
    );
    await openSheet(tester, h.app);

    // 点 1.2.0 行的历史构建
    await tester.tap(find.text('历史构建').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // onBuildHistory 被调
    expect(historyCalls, hasLength(1));
    expect(historyCalls.first.version, '1.2.0');
    expect(historyCalls.first.env, 'sit');

    // 构建列表显示（num/时间/大小/更新日志）
    expect(find.text('构建 #12'), findsOneWidget);
    expect(find.text('构建 #11'), findsOneWidget);
    expect(find.textContaining('08-01 10:30'), findsOneWidget);
    expect(find.textContaining('1.0 MB'), findsOneWidget);
    expect(find.text('修复崩溃'), findsOneWidget);

    // 点某项 → onBuildSelect
    await tester.tap(find.text('构建 #12'));
    await tester.pump();
    expect(selectedBuilds, hasLength(1));
    expect(selectedBuilds.first.num, 12);
  });

  testWidgets('⑤ 取消 → null', (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final result = await h.open();
    expect(result, isNull);
  });

  testWidgets('⑥ 当前选择高亮（currentEnv/currentVersion）', (tester) async {
    final h = buildHarness(
      currentEnv: 'prd',
      currentVersion: '1.0.0',
    );
    await openSheet(tester, h.app);

    // 当前 env 高亮 → prd 被选中 → 版本列表按 prd 过滤
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsNothing);

    // 当前版本行高亮（选中态圆点）
    final versionRow = find.ancestor(
      of: find.text('1.0.0'),
      matching: find.byType(InkWell),
    );
    expect(versionRow, findsWidgets);

    // 确认按钮已启用（env+version 均已选中）
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认切换'),
    );
    expect(confirm.onPressed, isNotNull);
  });
}
