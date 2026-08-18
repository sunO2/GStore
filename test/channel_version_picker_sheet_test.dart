import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/channel_version_picker_sheet.dart';
import 'package:gstore/core/design/design_tokens.dart';

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
    List<VersionOption>? versionsOverride,
    Future<List<BuildOption>> Function({
      required String version,
      required String env,
    })? onBuildHistory,
    void Function(
      BuildOption build, {
      required String version,
      required String env,
    })? onBuildSelect,
    Future<List<VersionOption>> Function(String env)? onEnvChanged,
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
                  versions: versionsOverride ?? versions,
                  currentEnv: currentEnv,
                  currentVersion: currentVersion,
                  onBuildHistory: onBuildHistory,
                  onBuildSelect: onBuildSelect,
                  onEnvChanged: onEnvChanged,
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
      onBuildSelect: (build, {required version, required env}) =>
          selectedBuilds.add(build),
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

  testWidgets('⑦ onEnvChanged 提供：点 env chip → 回调被调 + 加载态 + 版本列表刷新',
      (tester) async {
    final envCalls = <String>[];
    final uatVersions = [
      const VersionOption(
        version: '2.0.0',
        envs: ['uat'],
        buildCount: 2,
      ),
      const VersionOption(
        version: '1.5.0',
        envs: ['uat'],
        buildCount: 1,
      ),
    ];
    final h = buildHarness(
      onEnvChanged: (env) async {
        envCalls.add(env);
        // 模拟异步拉取：先挂起一帧，验证加载态
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return uatVersions;
      },
    );
    await openSheet(tester, h.app);

    // 初始（sit）：初始 versions 列表
    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsOneWidget);

    // 切到 uat → 回调被调
    await tester.tap(find.text('uat'));
    await tester.pump();
    expect(envCalls, ['uat']);

    // 加载态（AppLoading 显示，旧版本列表隐藏）
    expect(find.byType(AppLoading), findsOneWidget);
    expect(find.text('1.2.0'), findsNothing);

    // 拉回后刷新版本列表
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AppLoading), findsNothing);
    expect(find.text('2.0.0'), findsOneWidget);
    expect(find.text('1.5.0'), findsOneWidget);
    expect(find.text('1.2.0'), findsNothing);
    expect(find.text('(2 个构建)'), findsOneWidget);
  });

  testWidgets('⑧ onEnvChanged 提供：切换后保留仍在新列表的已选版本', (tester) async {
    final h = buildHarness(
      onEnvChanged: (env) async => [
        VersionOption(
          version: '1.2.0',
          envs: [env],
          buildCount: 5,
        ),
        VersionOption(
          version: '9.9.9',
          envs: [env],
          buildCount: 1,
        ),
      ],
    );
    await openSheet(tester, h.app);

    // 先选 1.2.0
    await tester.tap(find.text('1.2.0'));
    await tester.pump();

    // 切到 uat（新列表仍含 1.2.0）→ 选中保留
    await tester.tap(find.text('uat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认切换'),
    );
    expect(confirm.onPressed, isNotNull);

    await tester.tap(find.text('确认切换'));
    await tester.pumpAndSettle();
    final result = await h.open();
    expect(result, isNotNull);
    expect(result!.env, 'uat');
    expect(result.version, '1.2.0');
  });

  testWidgets('⑨ onEnvChanged 提供：新列表不含已选版本 → 清空选中', (tester) async {
    final h = buildHarness(
      onEnvChanged: (env) async => [
        VersionOption(
          version: '9.9.9',
          envs: [env],
          buildCount: 1,
        ),
      ],
    );
    await openSheet(tester, h.app);

    // 先选 1.2.0
    await tester.tap(find.text('1.2.0'));
    await tester.pump();

    // 切到 uat（新列表不含 1.2.0）→ 选中清空 → 确认按钮禁用
    await tester.tap(find.text('uat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认切换'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('⑩ 无 onEnvChanged：点 env chip → 维持现状（本地过滤，无加载态）',
      (tester) async {
    final h = buildHarness();
    await openSheet(tester, h.app);

    await tester.tap(find.text('prd'));
    await tester.pump();

    // 无加载态
    expect(find.byType(AppLoading), findsNothing);
    // 本地过滤生效
    expect(find.text('1.2.0'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('1.1.0'), findsNothing);
  });

  testWidgets('⑪ 版本多（25+）→ 弹框不超屏、确认/取消按钮固定可见、列表内部滚动',
      (tester) async {
    final manyVersions = [
      for (var i = 0; i < 25; i++)
        VersionOption(version: '1.$i.0', envs: ['sit'], buildCount: 1),
    ];
    final h = buildHarness(versionsOverride: manyVersions);
    await openSheet(tester, h.app);

    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    // 按钮可见且在屏幕内（弹框被限高，不顶出屏幕）
    final confirm = find.text('确认切换');
    final cancel = find.text('取消');
    expect(confirm, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(screenH));
    expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(screenH));
    expect(tester.getRect(confirm).top, greaterThan(0));
    expect(tester.takeException(), isNull);

    // 版本列表内部滚动（拖列表）：首版本滚出、按钮与 env chips 仍固定可见
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('1.0.0'), findsNothing);
    expect(find.text('确认切换'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('sit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑫ 点历史构建 → onBuildHistory 传当前选中 env + 该行 version',
      (tester) async {
    final historyCalls = <({String version, String env})>[];
    final h = buildHarness(
      onBuildHistory: ({required version, required env}) async {
        historyCalls.add((version: version, env: env));
        return builds;
      },
    );
    await openSheet(tester, h.app);

    // 先切 env 到 uat（当前选中 env = uat）
    await tester.tap(find.text('uat'));
    await tester.pump();

    // 点第一行（1.2.0）的历史构建 → 传参应为 (1.2.0, uat)
    await tester.tap(find.text('历史构建').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(historyCalls, hasLength(1));
    expect(historyCalls.first.version, '1.2.0');
    expect(historyCalls.first.env, 'uat');
  });

  testWidgets('⑬ 多行展开：onBuildSelect 携带各自行的 version/env（不复用最近展开）',
      (tester) async {
    final selected = <({int num, String version, String env})>[];
    final h = buildHarness(
      onBuildHistory: ({required version, required env}) async => builds,
      onBuildSelect: (build, {required version, required env}) {
        selected.add((num: build.num, version: version, env: env));
      },
    );
    await openSheet(tester, h.app);

    // 展开第一行（1.2.0）与第二行（1.1.0）的历史
    await tester.tap(find.text('历史构建').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('历史构建').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 点第一行（1.2.0）里的构建 #12 → 应携带 (1.2.0, sit)，而非最近展开的 1.1.0
    await tester.tap(find.text('构建 #12').first);
    await tester.pump();

    expect(selected, hasLength(1));
    expect(selected.first.num, 12);
    expect(selected.first.version, '1.2.0');
    expect(selected.first.env, 'sit');
  });
}
