// Task 18：顶部「模块安装中」横幅（`ModuleInstallBanner`）的可见性、进度绑定、
// 阶段切换、并发多模块、覆盖层不影响 child 布局、触摸穿透与主题合规。
//
// 全部用例经 `moduleBootstrapStatesProvider.overrideWith` 注入受控状态流，
// **不触发 FFI、不触发网络、不触发真实下载**（运行时执行按环境要求延后）。
//
// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/module_install_banner.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

/// 被叠加内容（无子节点时 `SizedBox.expand` 填满可用约束 → 尺寸可断言）。
const Key contentKey = ValueKey<String>('banner-content');

/// 触摸穿透测试用的按钮键。
const Key tapButtonKey = ValueKey<String>('banner-tap-button');

ModuleBootstrapState _downloading(String module, {double? progress}) =>
    ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.downloading,
      progress: progress,
    );

ModuleBootstrapState _initializing(String module) => ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.initializing,
    );

ModuleBootstrapState _ready(String module) => ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.ready,
      progress: 1.0,
    );

ModuleBootstrapState _failed(String module) => ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.failed,
      error: StateError('boom'),
    );

ModuleBootstrapState _absent(String module) => ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.absent,
    );

/// 测试宿主：注入状态流 + 主题 + 被叠加内容。
Widget _harness(
  Stream<List<ModuleBootstrapState>> stream, {
  Widget? child,
}) {
  return ProviderScope(
    overrides: <Override>[
      moduleBootstrapStatesProvider.overrideWith((ref) => stream),
    ],
    child: MaterialApp(
      home: ModuleInstallBanner(
        child: child ?? const SizedBox.expand(key: contentKey),
      ),
    ),
  );
}

double? _barValue(WidgetTester tester) {
  final bar = tester.widget<LinearProgressIndicator>(
    find.byType(LinearProgressIndicator),
  );
  return bar.value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空闲（无任何状态）时不渲染横幅', (tester) async {
    await tester.pumpWidget(_harness(Stream.value(const <ModuleBootstrapState>[])));
    await tester.pump();

    expect(find.byType(ModuleInstallBanner), findsOneWidget);
    expect(find.byKey(contentKey), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(AppLoading), findsNothing);
  });

  testWidgets('downloading 时可见且进度条绑定正确比例', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('qr', progress: 0.4),
      ])),
    );
    await tester.pump();

    expect(find.text('二维码解码'), findsOneWidget);
    expect(find.text('下载中 40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(_barValue(tester), closeTo(0.4, 1e-9));
  });

  testWidgets('downloading 无 progress 时使用不定量进度且不崩溃', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('repo'),
      ])),
    );
    await tester.pump();

    expect(find.text('F-Droid 仓库'), findsOneWidget);
    expect(find.text('下载中'), findsOneWidget);
    expect(_barValue(tester), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阶段文案随 initializing 变化', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('repo', progress: 0.2),
    ]);
    await tester.pump();
    expect(find.text('下载中 20%'), findsOneWidget);

    controller.add(<ModuleBootstrapState>[_initializing('repo')]);
    await tester.pump();

    expect(find.text('初始化中'), findsOneWidget);
    expect(find.text('下载中 20%'), findsNothing);
  });

  testWidgets('ready 时自动隐藏横幅', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('analyzer', progress: 0.5),
    ]);
    await tester.pump();
    expect(find.text('APK 分析'), findsOneWidget);

    controller.add(<ModuleBootstrapState>[_ready('analyzer')]);
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('APK 分析'), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);
  });

  testWidgets('failed 状态不抛异常并隐藏横幅（先下载后失败）', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.9),
    ]);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    controller.add(<ModuleBootstrapState>[_failed('qr')]);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('未知模块 downloading 回退为模块名，failed 后隐藏', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('mystery', progress: 0.1),
    ]);
    await tester.pump();

    expect(find.text('mystery'), findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.add(<ModuleBootstrapState>[_failed('mystery')]);
    await tester.pump();

    expect(find.text('mystery'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多个模块并发时每个模块渲染一行', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('qr', progress: 0.1),
        _initializing('llm'),
      ])),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.byType(AppLoading), findsNWidgets(2));
    expect(find.text('二维码解码'), findsOneWidget);
    expect(find.text('本地大模型'), findsOneWidget);
    expect(find.text('下载中 10%'), findsOneWidget);
    expect(find.text('初始化中'), findsOneWidget);
  });

  testWidgets('覆盖层不改变 child 的布局尺寸', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    await tester.pump();

    final idleSize = tester.getSize(find.byKey(contentKey));
    expect(idleSize, const Size(800, 600));

    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.5),
    ]);
    await tester.pump();

    final activeSize = tester.getSize(find.byKey(contentKey));
    expect(activeSize, idleSize, reason: '横幅叠加不得位移/缩放被覆盖内容');
  });

  testWidgets('覆盖层包裹 IgnorePointer，触摸穿透到应用内容', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    var taps = 0;
    await tester.pumpWidget(_harness(
      controller.stream,
      child: Align(
        alignment: Alignment.topCenter,
        child: TextButton(
          key: tapButtonKey,
          onPressed: () => taps++,
          child: const Text('tap'),
        ),
      ),
    ));
    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.5),
    ]);
    await tester.pump();

    await tester.tap(find.byKey(tapButtonKey));
    await tester.pump();

    expect(taps, 1, reason: '覆盖层应忽略指针，让点击落到应用内容');
  });

  testWidgets('absent 阶段（显式空闲状态）同样不渲染横幅', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _absent('qr'),
        _absent('llm'),
      ])),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(AppLoading), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready 与 downloading 并存时仅渲染进行中的模块', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _ready('analyzer'),
        _downloading('qr', progress: 0.3),
      ])),
    );
    await tester.pump();

    // 仅 qr 一行可见；已就绪的 analyzer 行被过滤隐藏。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('二维码解码'), findsOneWidget);
    expect(find.text('APK 分析'), findsNothing);
    expect(find.text('下载中 30%'), findsOneWidget);
  });

  testWidgets('失败后再次进入 downloading 可重新显示（失败不粘滞）', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.9),
    ]);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    controller.add(<ModuleBootstrapState>[_failed('qr')]);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.1),
    ]);
    await tester.pump();

    expect(find.text('二维码解码'), findsOneWidget);
    expect(find.text('下载中 10%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('多行覆盖层仍不改变 child 的布局尺寸', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    await tester.pump();
    final idleSize = tester.getSize(find.byKey(contentKey));
    expect(idleSize, const Size(800, 600));

    controller.add(<ModuleBootstrapState>[
      _downloading('qr', progress: 0.5),
      _initializing('llm'),
      _downloading('download', progress: 0.2),
    ]);
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    final activeSize = tester.getSize(find.byKey(contentKey));
    expect(activeSize, idleSize, reason: '多行叠加不得位移/缩放被覆盖内容');
  });

  testWidgets('进度比例按四舍五入渲染百分比（0.756 → 76%）', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('qr', progress: 0.756),
      ])),
    );
    await tester.pump();

    expect(find.text('下载中 76%'), findsOneWidget);
    expect(_barValue(tester), closeTo(0.756, 1e-9));
  });

  test('源码仅使用主题令牌，不含硬编码颜色', () {
    final source =
        File('lib/compent/module_install_banner.dart').readAsStringSync();

    expect(RegExp(r'Colors\.').hasMatch(source), isFalse,
        reason: '不得使用 Colors.*');
    expect(RegExp(r'AppColors\.').hasMatch(source), isFalse,
        reason: '不得使用 AppColors.*');
    expect(RegExp(r'Color\(0x').hasMatch(source), isFalse,
        reason: '不得使用 Color(0x...) 字面量');
    expect(RegExp(r'Color\.fromARGB').hasMatch(source), isFalse,
        reason: '不得使用 Color.fromARGB 字面量');
    expect(RegExp(r'Color\.fromRGBO').hasMatch(source), isFalse,
        reason: '不得使用 Color.fromRGBO 字面量');
  });
}
