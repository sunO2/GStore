import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/page/log_viewer/providers.dart';
import 'package:gstore/page/log_viewer/view.dart';

/// LogViewer 实时刷新回归测试
///
/// 历史缺陷：logEntriesStreamProvider 用 StreamProvider + `async*` 种子流，
/// Riverpod 将单订阅生成器转 broadcast 后 `yield* logsStream` 的事件丢失——
/// 页面内新增日志/清空不实时刷新（重进页面才显示）。修复后改为
/// NotifierProvider 在 build 订阅 logsStream，每次变更同步更新 state。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// provider 层：追加/清空应实时反映到 filteredLogs 并推送监听者
  test('filteredLogsProvider 实时响应新增与清空', () async {
    LogManager.instance.clear();
    LogManager.instance.debug('初始日志');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final pushed = <List<LogEntry>>[];
    // listen 保持 provider 活跃（等价页面 watch）
    final sub = container.listen<List<LogEntry>>(
      filteredLogsProvider,
      (_, next) => pushed.add(next),
    );
    addTearDown(sub.close);

    // 完成首次求值（Notifier build 同步返回当前快照）
    container.read(logEntriesProvider);

    // 追加 → 应实时反映
    LogManager.instance.info('新增日志');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final current = container.read(filteredLogsProvider);
    expect(current.any((e) => e.message == '新增日志'), isTrue,
        reason: '追加日志后 filteredLogs 应实时包含新日志');
    expect(
      pushed.any((list) => list.any((e) => e.message == '新增日志')),
      isTrue,
      reason: '追加日志后监听者应实时收到推送',
    );

    // 清空 → 应实时变短（clear 只留"日志已清空"提示）
    LogManager.instance.clear();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final afterClear = container.read(filteredLogsProvider);
    expect(afterClear.length, lessThan(current.length),
        reason: '清空后列表应变短（clear 只留"日志已清空"提示）');
    expect(afterClear.any((e) => e.message == '新增日志'), isFalse,
        reason: '清空后旧日志应实时消失');
  });

  /// 真实 LogViewerPage：打开后新增日志实时出现、清空后实时消失
  testWidgets('LogViewerPage 打开后实时刷新新增日志与清空', (tester) async {
    LogManager.instance.clear();
    LogManager.instance.debug('页面打开前日志');

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LogViewerPage()),
      ),
    );
    // 等待 provider 求值 + 首帧渲染
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('页面打开前日志'), findsOneWidget);

    // 页面打开后追加 → 应实时出现
    LogManager.instance.info('页面内新增');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('页面内新增'), findsOneWidget,
        reason: '页面打开后新增日志应实时刷新');

    // 清空 → 旧日志应实时消失（仅留"日志已清空"提示）
    LogManager.instance.clear();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('页面内新增'), findsNothing,
        reason: '清空后旧日志应实时消失');
    expect(find.text('日志已清空'), findsOneWidget,
        reason: '清空提示本身应显示');
  });

  /// 最新日志贴底：反转列表后，底部渲染最新、顶部渲染最旧
  testWidgets('LogViewerPage 最新日志在底部（chat 反转）', (tester) async {
    LogManager.instance.clear();
    LogManager.instance.debug('最旧日志');
    LogManager.instance.debug('中间日志');
    LogManager.instance.debug('最新日志');

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LogViewerPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 三条日志都可见（列表很短无需滚动）
    final oldest = tester.getTopLeft(find.text('最旧日志'));
    final middle = tester.getTopLeft(find.text('中间日志'));
    final latest = tester.getTopLeft(find.text('最新日志'));
    expect(latest.dy, greaterThan(oldest.dy),
        reason: '最新日志应在底部（dy 更大 = 更靠下）');
    expect(middle.dy, greaterThan(oldest.dy),
        reason: '中间日志应在最旧之上');
    expect(latest.dy, greaterThan(middle.dy),
        reason: '最新日志应在中间日志之下');
  });
}
