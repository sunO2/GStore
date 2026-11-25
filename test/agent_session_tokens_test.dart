import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/agent/agent_trace.dart';

GenerateResult<dynamic> _response(
  List<Part> content, {
  required List<Message> requestMessages,
  GenerationUsage? usage,
}) {
  return GenerateResult<dynamic>(
    ModelResponse(
      message: Message(role: Role.model, content: content),
      finishReason: FinishReason.stop,
      usage: usage,
    ),
    request: ModelRequest(messages: requestMessages),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  test('AgentSessionTokenStats JSON 往返', () {
    const stats = AgentSessionTokenStats(
      inputTokens: 1200,
      outputTokens: 340,
      contextTokens: 500000,
      compactCount: 2,
      updatedAt: 123456,
    );
    final restored = AgentSessionTokenStats.fromJson(stats.toJson());
    expect(restored.inputTokens, 1200);
    expect(restored.outputTokens, 340);
    expect(restored.contextTokens, 500000);
    expect(restored.compactCount, 2);
    expect(restored.updatedAt, 123456);
    expect(restored.totalTokens, 1540);
    expect(restored.ratio(), closeTo(0.5, 1e-9));
    expect(restored.isOverLimit(), isFalse);
  });

  test('模型 usage 累加到当前会话统计', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize(); // 未配置模型也会创建会话

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      return _response(
        [TextPart(text: 'ok')],
        requestMessages: messages,
        usage: GenerationUsage(
          inputTokens: 120,
          outputTokens: 30,
          totalTokens: 150,
        ),
      );
    };

    final trace = AgentTurnTrace(
      turnId: 'token-turn',
      provider: 'test',
      model: 'm',
      toolsEnabled: false,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 0,
    );
    await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: 'hi')]),
      ],
      toolNames: const [],
      trace: trace,
    );

    expect(agent.sessionTokens.value.inputTokens, 120);
    expect(agent.sessionTokens.value.outputTokens, 30);
    expect(agent.sessionTokens.value.totalTokens, 150);
  });

  test('统计落库后新实例可恢复', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize();

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      return _response(
        [TextPart(text: 'ok')],
        requestMessages: messages,
        usage: GenerationUsage(
          inputTokens: 80,
          outputTokens: 20,
          totalTokens: 100,
        ),
      );
    };

    final trace = AgentTurnTrace(
      turnId: 'persist-turn',
      provider: 'test',
      model: 'm',
      toolsEnabled: false,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 0,
    );
    await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: 'hi')]),
      ],
      toolNames: const [],
      trace: trace,
    );
    // 直接走收尾：落库 + 压缩判断
    await agent.debugFinalizeSessionTokens();

    final sessionId = agent.sessionStore!.current!.id;
    final raw = await agent.sessionStore!
        .readMeta('session_tokens:$sessionId');
    expect(raw, isNotNull);
    expect(raw, contains('"inputTokens":80'));

    final reloaded = AgentService();
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.sessionTokens.value.inputTokens, 80);
    expect(reloaded.sessionTokens.value.outputTokens, 20);
  });

  test('上下文超过阈值自动压缩：保留最近回合 + 摘要', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize();

    final store = agent.sessionStore!;
    final session = store.current!;
    session.messages.clear();
    var seq = 1;
    for (var i = 0; i < 6; i++) {
      session.messages.add(SessionMessage(
        isUser: true,
        text: '用户问题 $i ${'x' * 300}',
        seq: seq++,
      ));
      session.messages.add(SessionMessage(
        isUser: false,
        text: '助手回答 $i ${'y' * 300}',
        seq: seq++,
      ));
    }
    await store.save();

    // 人为压低阈值，确保触发压缩
    agent.debugSessionContextLimitTokens = 100;
    await agent.debugFinalizeSessionTokens();

    expect(agent.sessionTokens.value.compactCount, 1);
    expect(agent.debugSessionSummary, isNotEmpty);
    // 只保留最近 4 个用户回合（8 条）+ 1 条压缩提示
    final kept = session.messages
        .where((m) => !m.text.startsWith('（上下文已压缩'))
        .toList();
    expect(kept, hasLength(8));
    expect(session.messages.length, 9);

    // 压缩后上下文估算应明显回落（仍可能高于人为压低的测试阈值）
    expect(agent.sessionTokens.value.contextTokens, lessThan(2500));

    // 摘要仍然会作为 system message 发给模型
    final systemTexts = agent.debugRequestMessages
        .where((m) => m.role == Role.system)
        .map((m) => m.text)
        .join('\n');
    expect(systemTexts, contains('[早期对话摘要]'));
  });

  test('消息不足 4 个用户回合时不压缩', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize();

    final session = agent.sessionStore!.current!;
    session.messages
      ..clear()
      ..add(SessionMessage(isUser: true, text: '只有一个问题', seq: 1))
      ..add(SessionMessage(isUser: false, text: '只有一个回答', seq: 2));
    await agent.sessionStore!.save();

    agent.debugSessionContextLimitTokens = 1;
    await agent.debugFinalizeSessionTokens();

    expect(agent.sessionTokens.value.compactCount, 0);
    expect(session.messages.length, 2);
  });

  test('手动压缩在短会话（<4 个用户回合）也会生效', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize();

    final store = agent.sessionStore!;
    final session = store.current!;
    session.messages.clear();
    var seq = 1;
    for (var i = 0; i < 3; i++) {
      session.messages.add(SessionMessage(
        isUser: true,
        text: '问题 $i',
        seq: seq++,
      ));
      session.messages.add(SessionMessage(
        isUser: false,
        text: '回答 $i',
        seq: seq++,
      ));
    }
    await store.save();

    expect(session.messages.length, 6);
    final compacted = await agent.compactSessionNow();
    expect(compacted, isTrue);
    expect(agent.sessionTokens.value.compactCount, 1);
    // 手动压缩只保留最近 1 个用户回合（2 条）+ 1 条压缩提示
    expect(
      session.messages
          .where((m) => !m.text.startsWith('（上下文已压缩'))
          .length,
      2,
    );
    expect(session.messages.length, 3);

    // 只剩一个回合时再次压缩：无需压缩
    final again = await agent.compactSessionNow();
    expect(again, isFalse);
    expect(agent.sessionTokens.value.compactCount, 1);
  });
}
