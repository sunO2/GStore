import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 确认工具持久化回归测试（多选框选择后重启不应残留 running 待确认）
///
/// 背景：确认消息选完写 done 记录时，若 session 中仍残留 running 记录，
/// 重启后 _restorePendingConfirmations 会把旧记录恢复成"待确认"UI。
/// 修复：resolveConfirmation 完成后 _clearPendingConfirmation 删除 running 记录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  test('多选确认完成后持久化无 running 残留', () async {
    final agent = AgentService();
    await agent.initialize(); // 无模型 → false 无妨，session 已建

    // 发起多选确认（内部阻塞等待用户选择）
    final future = agent.runTool('confirmAction', {
      'question': '请勾选要清理的内容',
      'options': ['缓存A', '缓存B', '下载文件C'],
      'multiSelect': true,
    });

    // 等待工具消息落库并进入等待态
    AgentMessage? confirmMsg;
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final m in agent.messages.value) {
        if (m.isToolResult &&
            m.toolType == AgentToolType.confirm &&
            m.toolStatus == AgentToolStatus.running) {
          confirmMsg = m;
          break;
        }
      }
      if (confirmMsg != null) break;
    }
    expect(confirmMsg, isNotNull, reason: '应存在 running 的确认消息');

    // 此时 session 持久化应含 running 确认
    final store = agent.sessionStore;
    expect(store, isNotNull);
    expect(
      store!.current!.messages.where((m) =>
          m.isToolResult &&
          m.toolType == AgentToolType.confirm.name &&
          m.toolStatus == AgentToolStatus.running.name),
      isNotEmpty,
      reason: '等待期间应持久化 running 确认（重启可恢复）',
    );

    // 用户勾选确认
    agent.resolveConfirmation(confirmMsg!.id, '缓存A、缓存B');
    final result = await future;
    expect(result, contains('用户已选择'));

    // 完成后：持久化中不应残留 running 确认
    final runningAfter = store.current!.messages.where((m) =>
        m.isToolResult &&
        m.toolType == AgentToolType.confirm.name &&
        m.toolStatus == AgentToolStatus.running.name);
    expect(runningAfter, isEmpty,
        reason: '选择完成后必须清除 running 记录，否则重启后仍显示多选框');

    // 应存在一条 done 记录（结果状态）
    expect(
      store.current!.messages.any((m) =>
          m.isToolResult &&
          m.toolType == AgentToolType.confirm.name &&
          m.toolStatus == AgentToolStatus.done.name),
      isTrue,
      reason: '应持久化 done 结果记录',
    );
  });

  test('二选一确认完成后持久化无 running 残留', () async {
    final agent = AgentService();
    await agent.initialize();

    final future = agent.runTool('confirmAction', {'question': '确认删除？'});

    AgentMessage? confirmMsg;
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final m in agent.messages.value) {
        if (m.isToolResult &&
            m.toolType == AgentToolType.confirm &&
            m.toolStatus == AgentToolStatus.running) {
          confirmMsg = m;
          break;
        }
      }
      if (confirmMsg != null) break;
    }
    expect(confirmMsg, isNotNull);

    agent.resolveConfirmation(confirmMsg!.id, '取消');
    final result = await future;
    expect(result, contains('取消'));

    final store = agent.sessionStore!;
    expect(
      store.current!.messages.where((m) =>
          m.isToolResult &&
          m.toolType == AgentToolType.confirm.name &&
          m.toolStatus == AgentToolStatus.running.name),
      isEmpty,
      reason: '取消后也不应残留 running 记录',
    );
  });
}
