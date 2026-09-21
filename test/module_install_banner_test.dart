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
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

/// 被叠加内容（无子节点时 `SizedBox.expand` 填满可用约束 → 尺寸可断言）。
const Key contentKey = ValueKey<String>('banner-content');

/// 触摸穿透测试用的按钮键。
const Key tapButtonKey = ValueKey<String>('banner-tap-button');

ModuleBootstrapState _downloading(
  String module, {
  double? progress,
  int? sizeBytes,
}) =>
    ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.downloading,
      progress: progress,
      sizeBytes: sizeBytes,
    );

TaskProgressState _task({
  String id = 'fdroid-sync',
  String cardKey = 'module:repo',
  TaskPhase phase = TaskPhase.running,
  String label = 'F-Droid 仓库',
  String? stage,
  String? detail,
  double? progress,
  int? sizeBytes,
  Object? error,
  int generation = 1,
}) =>
    TaskProgressState(
      id: id,
      cardKey: cardKey,
      phase: phase,
      label: label,
      stage: stage,
      detail: detail,
      progress: progress,
      sizeBytes: sizeBytes,
      error: error,
      generation: generation,
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
///
/// [taskStream] 非空时覆盖 [taskProgressStatesProvider]（通用任务来源）；
/// 否则沿用真实 hub（默认为空），因此既有仅覆盖模块流的用例行为不变。
Widget _harness(
  Stream<List<ModuleBootstrapState>> stream, {
  Stream<List<TaskProgressState>>? taskStream,
  Widget? child,
}) {
  return ProviderScope(
    overrides: <Override>[
      moduleBootstrapStatesProvider.overrideWith((ref) => stream),
      if (taskStream != null)
        taskProgressStatesProvider.overrideWith((ref) => taskStream),
    ],
    child: MaterialApp(
      home: ModuleInstallBanner(
        child: child ?? const SizedBox.expand(key: contentKey),
      ),
    ),
  );
}

/// 广播流事件经 Riverpod 通知需跨微任务/帧传递；连泵数帧确保稳定。
Future<void> _pumpFrames(WidgetTester tester, [int frames = 3]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
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
    expect(find.text('正在下载模块 40%'), findsOneWidget);
    expect(
      find.text('首次使用需下载，用于扫描识别二维码'),
      findsOneWidget,
      reason: '「为什么」详情行：解释一次性的下载用途',
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(_barValue(tester), closeTo(0.4, 1e-9));
  });

  testWidgets('sizeBytes 渲染为含用途与「约 X MB · 仅需一次」的「why」详情行', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('repo', progress: 0.4, sizeBytes: 12897485),
      ])),
    );
    await tester.pump();

    expect(find.text('F-Droid 仓库'), findsOneWidget);
    expect(find.text('正在下载模块 40%'), findsOneWidget);
    const String whyLine =
        '首次使用需下载，用于 F-Droid 仓库搜索 · 约 12.3 MB · 仅需一次';
    expect(find.text(whyLine), findsOneWidget);
    expect(whyLine.contains('用于 F-Droid 仓库搜索'), isTrue);
    expect(whyLine.contains('约 12.3 MB · 仅需一次'), isTrue);
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
    expect(find.text('正在下载模块'), findsOneWidget);
    expect(find.text('首次使用需下载，用于 F-Droid 仓库搜索'), findsOneWidget);
    expect(_barValue(tester), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阶段动作句随 initializing 变化：下载中 → 下载完成，正在准备使用', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_harness(controller.stream));
    controller.add(<ModuleBootstrapState>[
      _downloading('repo', progress: 0.2),
    ]);
    await tester.pump();
    expect(find.text('正在下载模块 20%'), findsOneWidget);

    controller.add(<ModuleBootstrapState>[_initializing('repo')]);
    await tester.pump();

    expect(find.text('下载完成，正在准备使用'), findsOneWidget);
    expect(find.text('正在下载模块 20%'), findsNothing);
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

  testWidgets('多个模块并发时每个模块渲染一张卡片', (tester) async {
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
    expect(find.text('正在下载模块 10%'), findsOneWidget);
    expect(find.text('下载完成，正在准备使用'), findsOneWidget);
    // 每张卡片保留各自的「为什么」详情行，互不串味。
    expect(find.text('首次使用需下载，用于扫描识别二维码'), findsOneWidget);
    expect(find.text('首次使用需下载，用于本地模型推理'), findsOneWidget);
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
    expect(find.text('正在下载模块 30%'), findsOneWidget);
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
    expect(find.text('正在下载模块 10%'), findsOneWidget);
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
    // 广播流事件与 Riverpod 通知跨两轮微任务/帧传递：
    // 在已泵过一帧（空闲态）后，第一帧仅投递事件，第二帧才反映新状态。
    await tester.pump();
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

    expect(find.text('正在下载模块 76%'), findsOneWidget);
    expect(_barValue(tester), closeTo(0.756, 1e-9));
  });

  testWidgets('任务来源（F-Droid 索引同步）无模块时渲染独立卡片', (tester) async {
    await tester.pumpWidget(
      _harness(
        Stream.value(const <ModuleBootstrapState>[]),
        taskStream: Stream.value(<TaskProgressState>[
          _task(
            stage: '解析入库…',
            detail: '约 15.0 MB · 仅需一次',
            progress: 0.6,
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('F-Droid 仓库'), findsOneWidget);
    expect(find.text('解析入库…'), findsOneWidget);
    expect(find.text('约 15.0 MB · 仅需一次'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(_barValue(tester), closeTo(0.6, 1e-9));
    expect(find.byType(AppLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模块与同键任务归并为一张卡片：模块阶段优先，结束后任务接管', (tester) async {
    final moduleController =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    final taskController =
        StreamController<List<TaskProgressState>>.broadcast();
    addTearDown(moduleController.close);
    addTearDown(taskController.close);

    await tester.pumpWidget(_harness(
      moduleController.stream,
      taskStream: taskController.stream,
    ));
    await _pumpFrames(tester);

    // 任务先启动（索引同步在后台跑），随后模块开始安装同一仓库。
    taskController.add(<TaskProgressState>[_task(stage: '解析入库…', progress: 0.9)]);
    moduleController.add(<ModuleBootstrapState>[
      _downloading('repo', progress: 0.42),
    ]);
    await _pumpFrames(tester);

    // 模块胜出：只有一张卡片，显示模块阶段，任务阶段被抑制。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('F-Droid 仓库'), findsOneWidget);
    expect(find.text('正在下载模块 42%'), findsOneWidget);
    expect(find.text('解析入库…'), findsNothing);
    expect(_barValue(tester), closeTo(0.42, 1e-9));

    // 安装就绪后，同键任务接管同一张卡片，卡片不消失、不重复。
    moduleController.add(<ModuleBootstrapState>[
      const ModuleBootstrapState(
        module: 'repo',
        phase: ModuleBootstrapPhase.ready,
      ),
    ]);
    await _pumpFrames(tester);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('F-Droid 仓库'), findsOneWidget);
    expect(find.text('解析入库…'), findsOneWidget);
    expect(find.text('正在下载模块 42%'), findsNothing);
    expect(_barValue(tester), closeTo(0.9, 1e-9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务终态（failed/ready）不渲染卡片', (tester) async {
    await tester.pumpWidget(
      _harness(
        Stream.value(const <ModuleBootstrapState>[]),
        taskStream: Stream.value(<TaskProgressState>[
          _task(phase: TaskPhase.failed, error: StateError('boom')),
          _task(id: 'other', cardKey: 'task:db', phase: TaskPhase.ready),
        ]),
      ),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(AppLoading), findsNothing);
    expect(find.byKey(contentKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片用 primaryContainer 表面 + 阴影且无重描边，文字呈三级强调', (tester) async {
    await tester.pumpWidget(
      _harness(Stream.value(<ModuleBootstrapState>[
        _downloading('qr', progress: 0.4),
      ])),
    );
    await tester.pump();

    final BuildContext context =
        tester.element(find.byType(ModuleInstallBanner));
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 卡片底色必须与页面背景（surface）不同，才能从页面里「浮」出来。
    expect(scheme.primaryContainer, isNot(scheme.surface));

    final Finder surfaces = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Material && widget.color == scheme.primaryContainer,
    );
    expect(surfaces, findsOneWidget,
        reason: '卡片必须使用 primaryContainer 高对比底色，而非与页面近似的表面色');

    final Material card = tester.widget<Material>(surfaces);
    expect(card.elevation, greaterThanOrEqualTo(4),
        reason: '阴影需明显高于同页普通表面（0–2），才会读作浮起卡片');

    // 去掉原先 4px `primary` 粗描边：`primaryContainer` 底色 + 阴影已足够把
    // 卡片从页面背景中分离，在已着色表面再套粗描边显生硬。仅保留圆角。
    final ShapeBorder? shape = card.shape;
    expect(shape, isA<RoundedRectangleBorder>());
    final RoundedRectangleBorder rounded = shape! as RoundedRectangleBorder;
    expect(rounded.borderRadius, AppRadius.allLG);
    expect(rounded.side, BorderSide.none,
        reason: '卡片不得再带任何显式描边，尤其不是 primary 粗描边');

    // 文字三级强调：标题（onPrimaryContainer 全强度）> 阶段 > 详情；
    // 三者同色系、按不透明度递减，绝不出现三条同等强度的实色或饱和 primary。
    Color colorOf(String text) {
      final Text widget = tester.widget<Text>(find.text(text));
      return widget.style!.color!;
    }

    final Color titleColor = colorOf('二维码解码');
    final Color stageColor = colorOf('正在下载模块 40%');
    final Color detailColor = colorOf('首次使用需下载，用于扫描识别二维码');

    expect(titleColor, scheme.onPrimaryContainer,
        reason: '标题为最高强调，使用与底色成对的 onPrimaryContainer 全强度');
    expect(stageColor, isNot(titleColor));
    expect(detailColor, isNot(titleColor));
    expect(detailColor, isNot(stageColor));
    expect(titleColor.a, greaterThan(stageColor.a),
        reason: '标题不透明度高于阶段（标题 > 阶段）');
    expect(stageColor.a, greaterThan(detailColor.a),
        reason: '阶段不透明度高于详情（阶段 > 详情）');
    expect(stageColor, isNot(scheme.primary),
        reason: '阶段不再使用饱和 primary，避免刺眼');
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
