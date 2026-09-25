// D13：日志降噪 + 导出遵循过滤。
//
// * `[ModuleEvent]` 逐条 debug 日志（proxy.stats/proxy.request 秒级刷屏）必须消失；
// * 日志导出必须只导出「当前过滤后的集合」，且 actionSheet 文案与成功提示
//   显示过滤后的条数并标注「已应用过滤」。
//
// 密闭式：假 [FilePicker] 拦截系统保存对话框，断言真实落到文件的字节内容。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;
import 'package:gstore/page/log_viewer/view.dart';

/// 假文件选择器：记录 saveFile 入参并返回固定路径（[result] 为 null = 取消）。
///
/// `FilePicker.platform` 是带 setter 的静态接缝，测试注入后走真实 `_exportLogs`
/// 路径，无需改生产 API。
class _FakeFilePicker extends FilePicker {
  String? result;
  int calls = 0;
  Uint8List? lastBytes;
  String? lastFileName;
  List<String>? lastExtensions;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    lastFileName = fileName;
    lastExtensions = allowedExtensions;
    lastBytes = bytes;
    return result;
  }
}

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('导出遵循过滤：内容与计数均为过滤后集合', (tester) async {
    LogManager.instance.clear();
    LogManager.instance.info('alpha 命中');
    LogManager.instance.info('beta 不命中');
    final fake = _FakeFilePicker()..result = '/tmp/gstore_log.txt';
    FilePicker.platform = fake;

    await tester.pumpWidget(
      ProviderScope(child: _host(const LogViewerPage())),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 应用内容过滤 alpha
    await tester.tap(find.byIcon(TablerIcons.dots_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('target 过滤'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    // 再次打开「更多」→ 下载日志：文案应显示过滤后条数 + 标注
    await tester.tap(find.byIcon(TablerIcons.dots_vertical));
    await tester.pumpAndSettle();
    expect(find.textContaining('导出当前 1 条'), findsOneWidget);
    expect(find.textContaining('（已应用过滤）'), findsOneWidget);
    await tester.tap(find.text('下载日志'));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    final text = utf8.decode(fake.lastBytes!);
    expect(text, contains('alpha 命中'));
    expect(text, isNot(contains('beta 不命中')),
        reason: '被内容过滤排除的日志绝不能出现在导出文件里');
    expect(find.textContaining('已导出 1 条'), findsOneWidget);
    expect(find.textContaining('已应用过滤'), findsOneWidget);
  });

  testWidgets('无过滤时导出全量且不标注过滤', (tester) async {
    LogManager.instance.clear();
    LogManager.instance.info('alpha 命中');
    LogManager.instance.info('beta 不命中');
    final fake = _FakeFilePicker()..result = '/tmp/gstore_log.txt';
    FilePicker.platform = fake;

    await tester.pumpWidget(
      ProviderScope(child: _host(const LogViewerPage())),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(TablerIcons.dots_vertical));
    await tester.pumpAndSettle();
    expect(find.textContaining('（已应用过滤）'), findsNothing);
    await tester.tap(find.text('下载日志'));
    await tester.pumpAndSettle();

    final text = utf8.decode(fake.lastBytes!);
    expect(text, contains('alpha 命中'));
    expect(text, contains('beta 不命中'));
  });

  test('exportToText：默认全量、显式集合仅导出该集合', () {
    LogManager.instance.clear();
    LogManager.instance.info('keep me');
    LogManager.instance.info('drop me');
    final all = LogManager.instance.logs;
    final only = all.where((e) => e.message == 'keep me').toList();

    final allText = LogManager.instance.exportToText();
    expect(allText, contains('keep me'));
    expect(allText, contains('drop me'));

    final filteredText = LogManager.instance.exportToText(entries: only);
    expect(filteredText, contains('keep me'));
    expect(filteredText, isNot(contains('drop me')),
        reason: '显式传入集合时不得混入集合外条目');
  });

  test('ModuleManager 不再逐条输出 [ModuleEvent] 高频日志', () {
    final source = File('lib/core/rust/ModuleManager.dart').readAsStringSync();
    expect(source.contains('[ModuleEvent]'), isFalse,
        reason: 'proxy.stats/proxy.request 秒级刷屏，禁止逐条 ModuleEvent 日志');
  });

  test('handleModuleEvent 处理高频 proxy.stats 不写 [ModuleEvent] 日志', () {
    LogManager.instance.clear();
    RustModuleManager.instance.handleModuleEvent(ModuleEvent(
      moduleId: BigInt.zero,
      instanceId: BigInt.one,
      eventType: 'proxy.stats',
      data: Uint8List(0),
      timestampMs: 0,
    ));
    final messages = LogManager.instance.logs.map((e) => e.message);
    expect(messages.any((m) => m.contains('[ModuleEvent]')), isFalse,
        reason: '事件处理不得逐条打 [ModuleEvent] 日志');
    expect(messages.any((m) => m.contains('proxy.stats')), isFalse,
        reason: 'proxy.stats 秒级事件不得写入日志');
  });
}
