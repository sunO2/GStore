import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_trace.dart';
import 'package:gstore/core/agent/agent_trace_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgentTurnTrace _trace(String id, {String? error, bool cancelled = false}) {
  final trace = AgentTurnTrace(
    turnId: id,
    provider: 'openai',
    model: 'hy4-flash-free',
    toolsEnabled: true,
    promptChars: 1234,
    messageCount: 9,
    toolsOffered: 16,
  );
  trace
    ..modelSteps = 2
    ..toolRequests = 1
    ..toolResponses = 1
    ..responseChars = 21
    ..reasoningChars = 88
    ..inputTokens = 6000
    ..outputTokens = 40
    ..finishReason = 'stop'
    ..error = error
    ..cancelled = cancelled;
  trace.finishedAt = trace.startedAt.add(const Duration(milliseconds: 4321));
  trace.markFirstToken();
  return trace;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('记录回合：状态推导 + SharedPreferences 兜底往返', () async {
    final store = AgentTraceStore();

    await store.record(AgentTurnRecord.fromTrace(_trace('t1')));
    await store.record(
      AgentTurnRecord.fromTrace(_trace('t2', error: '网络异常')),
    );
    await store.record(
      AgentTurnRecord.fromTrace(_trace('t3', cancelled: true)),
    );

    final recent = await store.recent(limit: 10);
    expect(recent.map((r) => r.turnId), ['t3', 't2', 't1']);
    expect(recent[0].isCancelled, isTrue);
    expect(recent[1].isError, isTrue);
    expect(recent[2].status, 'ok');
    expect(recent[2].totalMs, 4321);
    expect(recent[2].firstTokenMs, isNotNull);
    expect(recent[2].detail, isNotNull);
    expect(recent[2].parsedDetail['turnId'], 't1');

    // 重新加载（模拟重启）仍能读到
    final reloaded = AgentTraceStore.load();
    final restored = await (await reloaded).recent(limit: 10);
    expect(restored.map((r) => r.turnId), ['t3', 't2', 't1']);
  });

  test('会话 id 随记录保留，裁剪只保留最近 N 条', () async {
    final store = AgentTraceStore();
    for (var i = 0; i < 6; i++) {
      await store.record(
        AgentTurnRecord.fromTrace(_trace('t$i'), sessionId: 's1'),
      );
    }
    var recent = await store.recent(limit: 10);
    expect(recent, hasLength(6));
    expect(recent.every((r) => r.sessionId == 's1'), isTrue);

    await store.prune(keep: 3);
    recent = await store.recent(limit: 10);
    expect(recent.map((r) => r.turnId), ['t5', 't4', 't3']);

    await store.clear();
    expect(await store.recent(limit: 10), isEmpty);
  });

  test('SharedPreferences 缓存不超过上限', () async {
    final store = AgentTraceStore();
    for (var i = 0; i < AgentTraceStore.defaultKeep + 5; i++) {
      await store.record(AgentTurnRecord.fromTrace(_trace('t$i')));
    }
    final recent = await store.recent(limit: AgentTraceStore.defaultKeep + 10);
    expect(recent, hasLength(AgentTraceStore.defaultKeep));
    expect(recent.first.turnId, 't${AgentTraceStore.defaultKeep + 4}');
  });
}
