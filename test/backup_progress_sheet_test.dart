import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/page/backup/widgets/backup_progress_sheet.dart';

/// BackupProgressSheet 进度面板 widget 测试
///
/// 验证：
/// - 任务进行中：日志逐行流式出现（onLog 回调驱动）
/// - 任务成功 → ✓ 图标 + "完成"按钮
/// - 任务失败（抛异常）→ ✗ 图标 + 红色错误日志 + "重试"/"关闭"按钮
/// - 重试 → 日志清空重跑（任务闭包调用次数 +1）
/// - 日志过多时自动滚动到底部
/// - 集成 showModalBottomSheet：成功弹出并返回结果
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('任务进行中：日志逐行出现，完成后显示 ✓ + 完成按钮', (tester) async {
    await tester.pumpWidget(wrap(BackupProgressSheet(
      title: '备份到网盘',
      task: (onLog) async {
        onLog('开始导出数据...');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        onLog('已添加应用 3 个');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        onLog('上传成功: /GStore/gstore_backup.tar.gz');
      },
    )));

    // 初始帧：标题 + 第一条日志已出现（loading 期间）
    await tester.pump();
    expect(find.text('备份到网盘'), findsOneWidget);
    expect(find.text('开始导出数据...'), findsOneWidget);

    // 任务推进：第二条日志出现
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已添加应用 3 个'), findsOneWidget);

    // 任务完成：✓ + 完成按钮 + 最后一条日志
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('上传成功: /GStore/gstore_backup.tar.gz'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('关闭'), findsNothing);
  });

  testWidgets('任务失败：错误日志 + ✗ + 重试/关闭按钮', (tester) async {
    await tester.pumpWidget(wrap(BackupProgressSheet(
      title: '从网盘恢复备份',
      task: (onLog) async {
        onLog('连接 WebDAV 服务器...');
        throw Exception('连接超时');
      },
    )));

    await tester.pump();
    await tester.pump();

    expect(find.text('连接 WebDAV 服务器...'), findsOneWidget);
    expect(find.textContaining('连接超时'), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
  });

  testWidgets('重试：任务闭包调用次数 +1 且日志清空重显', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(BackupProgressSheet(
      title: '备份到网盘',
      task: (onLog) async {
        calls++;
        onLog('第 $calls 次执行');
        if (calls == 1) throw Exception('首次失败');
      },
    )));

    // 第一次执行失败
    await tester.pump();
    await tester.pump();
    expect(calls, 1);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('第 1 次执行'), findsOneWidget);
    expect(find.textContaining('首次失败'), findsOneWidget);

    // 点击重试 → 清空日志重新执行（第二次成功）
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(calls, 2);
    expect(find.text('第 2 次执行'), findsOneWidget);
    expect(find.text('第 1 次执行'), findsNothing);
    expect(find.textContaining('首次失败'), findsNothing);
    expect(find.text('完成'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('日志过多时自动滚动到底部', (tester) async {
    await tester.pumpWidget(wrap(BackupProgressSheet(
      title: '备份到网盘',
      task: (onLog) async {
        for (var i = 0; i < 60; i++) {
          onLog('日志第 $i 行');
        }
      },
    )));

    await tester.pump();
    await tester.pump(); // 处理 postFrame 跳转

    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable));
    expect(
      scrollable.controller!.position.pixels,
      scrollable.controller!.position.maxScrollExtent,
    );
  });

  testWidgets('集成 showModalBottomSheet：成功弹出返回 true，失败返回 false', (tester) async {
    bool? sheetResult;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                sheetResult = await showModalBottomSheet<bool>(
                  context: context,
                  isDismissible: false,
                  enableDrag: false,
                  builder: (_) => BackupProgressSheet(
                    title: '备份到网盘',
                    task: (onLog) async {
                      onLog('开始...');
                      await Future<void>.delayed(
                          const Duration(milliseconds: 100));
                      onLog('上传成功');
                    },
                  ),
                );
              },
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 任务完成
    await tester.pump(const Duration(milliseconds: 300)); // sheet 滑入动画
    expect(find.text('上传成功'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle(); // 关闭动画（此时无 loading 动画）

    expect(sheetResult, isTrue);
    expect(find.text('备份到网盘'), findsNothing);
  });
}
