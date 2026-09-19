// Task 19：`lib/main.dart` 挂载顶部「模块安装中」横幅（`ModuleInstallBanner`）
// 并注册统一 llm 安装确认处理器（`confirmLargeModuleInstall`）。
//
// 全部用例为**密闭式**：无 FFI、无网络、无真实下载；状态流经
// `moduleBootstrapStatesProvider.overrideWith` 注入。
//
// 运行时执行按环境要求延后（系统盘故障：不执行 `flutter test`）。
//
// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/module_install_banner.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/main.dart' as app;

/// 被叠加内容（`SizedBox.expand` 填满可用约束 → 尺寸可断言）。
const Key contentKey = ValueKey<String>('mount-content');

ModuleBootstrapState _downloading(String module, {double? progress}) =>
    ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.downloading,
      progress: progress,
    );

/// 与 `lib/main.dart` 的 `MaterialApp.builder` 完全一致的挂载结构：
/// `ModuleInstallBanner(child: Material(child: SafeArea(child: ...)))`。
Widget _builderHarness(
  Stream<List<ModuleBootstrapState>> stream, {
  Widget? child,
}) {
  return ProviderScope(
    overrides: <Override>[
      moduleBootstrapStatesProvider.overrideWith((ref) => stream),
    ],
    child: MaterialApp(
      home: ModuleInstallBanner(
        child: Material(
          child: SafeArea(
            top: false,
            bottom: false,
            child: child ?? const SizedBox.expand(key: contentKey),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('进行中状态时横幅可见，且被覆盖的 child 仍全尺寸布局', (tester) async {
    final controller =
        StreamController<List<ModuleBootstrapState>>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(_builderHarness(controller.stream));
    await tester.pump();

    final idleSize = tester.getSize(find.byKey(contentKey));
    expect(idleSize, const Size(800, 600));

    controller.add(<ModuleBootstrapState>[
      _downloading('llm', progress: 0.3),
    ]);
    await tester.pump();

    expect(find.byType(ModuleInstallBanner), findsOneWidget);
    expect(find.text('本地大模型'), findsOneWidget);
    expect(find.text('下载中 30%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    final activeSize = tester.getSize(find.byKey(contentKey));
    expect(activeSize, idleSize, reason: '横幅叠加不得位移/缩放被覆盖内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('无进行中安装时覆盖层不渲染，child 仍在', (tester) async {
    await tester.pumpWidget(
      _builderHarness(Stream.value(const <ModuleBootstrapState>[])),
    );
    await tester.pump();

    expect(find.byType(ModuleInstallBanner), findsOneWidget);
    expect(find.byKey(contentKey), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  test('appNavigatorKey 无宿主 context 时确认处理器返回 false 且不抛错', () async {
    expect(
      appNavigatorKey.currentContext,
      isNull,
      reason: '本用例不挂载带 appNavigatorKey 的 Navigator',
    );

    final result = await app.confirmLargeModuleInstall('llm');
    expect(result, isFalse);
  });

  test('main.dart 启动装配注册处理器，且 builder 用 ModuleInstallBanner 包裹 Material', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      source.contains('setConfirmHandler(confirmLargeModuleInstall)'),
      isTrue,
      reason: '启动时必须注册 llm 确认处理器',
    );
    expect(
      RegExp(r'ModuleInstallBanner\(\s*child:\s*Material\(').hasMatch(source),
      isTrue,
      reason: 'MaterialApp.builder 必须将 Material 挂到 ModuleInstallBanner 之下',
    );
    expect(source.contains("'下载并继续'"), isTrue);
    expect(source.contains("'取消'"), isTrue);
  });
}
