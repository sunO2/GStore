import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/page/backup/widgets/backup_restore_sheet.dart';

/// BackupRestoreSheet 恢复面板 widget 测试
///
/// 三阶段状态机验证：
/// - 阶段1 准备（prepareTask：加载配置+列文件）转圈 + 日志 → 阶段2
/// - 阶段2 选择：文件列表（Radio 单选）+ "开始恢复"（未选禁用）/ "取消"
/// - 阶段3 恢复（restoreTask）：日志流 → ✓"完成"（pop true）
/// - 空列表 → 红色"未找到备份" + 仅"关闭"
/// - prepareTask 失败 → 红色日志 + "重试"（重跑 prepareTask）
/// - 阶段1/2 "取消" → 面板关闭（pop false）
void main() {
  final file1 = WebDavFile(
    name: 'gstore_backup_2026-08-01.tar.gz',
    path: '/GStore/gstore_backup_2026-08-01.tar.gz',
    size: 1024 * 1024,
    modified: DateTime(2026, 8, 1, 10, 30),
    isDirectory: false,
  );
  final file2 = WebDavFile(
    name: 'gstore_backup_2026-07-01.tar.gz',
    path: '/GStore/gstore_backup_2026-07-01.tar.gz',
    size: 512 * 1024,
    modified: DateTime(2026, 7, 1, 9, 0),
    isDirectory: false,
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 集成 showModalBottomSheet 的挂具：捕获面板 pop 返回值
  ({Widget app, bool? Function() result}) buildHarness({
    required Future<List<WebDavFile>> Function(BackupLogCallback onLog)
        prepareTask,
    required Future<void> Function(WebDavFile file, BackupLogCallback onLog)
        restoreTask,
  }) {
    bool? sheetResult;
    final app = MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                sheetResult = await showModalBottomSheet<bool>(
                  context: context,
                  isDismissible: false,
                  enableDrag: false,
                  builder: (_) => BackupRestoreSheet(
                    title: '从网盘恢复备份',
                    prepareTask: prepareTask,
                    restoreTask: restoreTask,
                  ),
                );
              },
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    );
    return (app: app, result: () => sheetResult);
  }

  testWidgets('阶段1 准备成功 → 阶段2 显示备份文件列表（名称/大小/时间）', (tester) async {
    await tester.pumpWidget(wrap(BackupRestoreSheet(
      title: '从网盘恢复备份',
      prepareTask: (onLog) async {
        onLog('连接 WebDAV...');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        onLog('找到 2 个备份文件');
        return [file1, file2];
      },
      restoreTask: (file, onLog) async {},
    )));

    await tester.pump();
    // 阶段1 准备中：转圈 + 日志行
    expect(find.byType(AppLoading), findsOneWidget);
    expect(find.text('连接 WebDAV...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    // 阶段2：文件列表（日志区隐藏）
    expect(find.text('gstore_backup_2026-08-01.tar.gz'), findsOneWidget);
    expect(find.text('gstore_backup_2026-07-01.tar.gz'), findsOneWidget);
    expect(find.textContaining('1.0 MB'), findsOneWidget);
    expect(find.textContaining('08-01 10:30'), findsOneWidget);
    expect(find.text('开始恢复'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('连接 WebDAV...'), findsNothing);
  });

  testWidgets('阶段2 选文件 + 开始恢复 → 阶段3 日志流 → 完成返回 true', (tester) async {
    final h = buildHarness(
      prepareTask: (onLog) async {
        onLog('加载 WebDAV 配置...');
        return [file1, file2];
      },
      restoreTask: (file, onLog) async {
        onLog('下载备份文件: ${file.name}');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        onLog('恢复完成');
      },
    );
    await tester.pumpWidget(h.app);
    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 面板滑入动画

    // 阶段2：未选择 → "开始恢复"禁用
    final startBtn =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始恢复'));
    expect(startBtn.onPressed, isNull);

    // 选择文件 → 按钮启用
    await tester.tap(find.text(file1.name));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始恢复'))
          .onPressed,
      isNotNull,
    );

    // 开始恢复 → 阶段3 日志流（无取消入口）
    await tester.tap(find.text('开始恢复'));
    await tester.pump();
    expect(find.text('下载备份文件: ${file1.name}'), findsOneWidget);
    expect(find.text('取消'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('恢复完成'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('重试'), findsNothing);

    // 完成 → pop(true)
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(h.result(), isTrue);
    expect(find.text('从网盘恢复备份'), findsNothing);
  });

  testWidgets('空列表 → 红色"未找到备份" + 仅"关闭"', (tester) async {
    final h = buildHarness(
      prepareTask: (onLog) async {
        onLog('列出备份文件...');
        return <WebDavFile>[];
      },
      restoreTask: (file, onLog) async {},
    );
    await tester.pumpWidget(h.app);
    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final notice = tester.widget<Text>(find.text('未找到备份'));
    expect(notice.style?.color, AppColors.error);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('开始恢复'), findsNothing);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(h.result(), isFalse);
    expect(find.text('从网盘恢复备份'), findsNothing);
  });

  testWidgets('阶段1 失败 → 红色日志 + 重试 → 重试成功进入阶段2', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(BackupRestoreSheet(
      title: '从网盘恢复备份',
      prepareTask: (onLog) async {
        calls++;
        onLog('第 $calls 次加载配置');
        if (calls == 1) throw Exception('连接超时');
        return [file1];
      },
      restoreTask: (file, onLog) async {},
    )));

    await tester.pump();
    await tester.pump();

    // 阶段1 失败：✗ + 红色错误日志 + 重试/关闭
    expect(find.byIcon(Icons.error), findsOneWidget);
    final errorLog = tester.widget<Text>(find.textContaining('连接超时'));
    expect(errorLog.style?.color, AppColors.error);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    // 重试 → prepareTask 重新执行（第 2 次成功）→ 阶段2
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(find.text(file1.name), findsOneWidget);
    expect(find.text('开始恢复'), findsOneWidget);
  });

  testWidgets('阶段1 准备中"取消" → 面板关闭（pop false）', (tester) async {
    final h = buildHarness(
      prepareTask: (onLog) async {
        onLog('加载配置中...');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return [file1];
      },
      restoreTask: (file, onLog) async {},
    );
    await tester.pumpWidget(h.app);
    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 阶段1 准备中：转圈 + "取消"
    expect(find.byType(AppLoading), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(h.result(), isFalse);
    expect(find.text('从网盘恢复备份'), findsNothing);

    // 推进时间让挂起的 prepareTask 完成（面板已关闭，无副作用）
    await tester.pump(const Duration(milliseconds: 800));
  });

  testWidgets('阶段2"取消" → 面板关闭（pop false）', (tester) async {
    final h = buildHarness(
      prepareTask: (onLog) async => [file1, file2],
      restoreTask: (file, onLog) async {},
    );
    await tester.pumpWidget(h.app);
    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('开始恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(h.result(), isFalse);
    expect(find.text('从网盘恢复备份'), findsNothing);
  });
}
