import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_trace.dart';

GenerateResult<dynamic> _modelResponse(
  List<Part> content, {
  required List<Message> requestMessages,
}) {
  return GenerateResult<dynamic>(
    ModelResponse(
      message: Message(role: Role.model, content: content),
      finishReason: FinishReason.stop,
    ),
    request: ModelRequest(messages: requestMessages),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('模型 confirmAction 暂停回合，用户确认后继续并返回最终文本', () async {
    final agent = AgentService();
    var step = 0;
    var toolExecutorCalled = false;

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      step++;
      if (step == 1) {
        return _modelResponse(
          [
            ToolRequestPart(
              toolRequest: ToolRequest(
                name: AgentService.confirmToolName,
                input: {'question': '确认继续？'},
                ref: 'confirm-r1',
              ),
            ),
          ],
          requestMessages: messages,
        );
      }
      return _modelResponse(
        [TextPart(text: '已继续完成')],
        requestMessages: messages,
      );
    };
    agent.debugExecuteToolsOverride = (requests) async {
      toolExecutorCalled = true;
      return const [];
    };

    final trace = AgentTurnTrace(
      turnId: 'confirm-turn',
      provider: 'test',
      model: 'm',
      toolsEnabled: true,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 1,
    );

    final first = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: '执行敏感操作')]),
      ],
      toolNames: const [AgentService.confirmToolName],
      trace: trace,
    );

    expect(first, isNull, reason: 'confirmAction 应暂停而不是返回最终响应');
    expect(agent.debugPendingModelConfirmationId, isNotNull);
    expect(toolExecutorCalled, isFalse, reason: '暂停时不得执行工具');

    final running = agent.messages.value.where(
      (m) =>
          m.isToolResult &&
          m.toolType == AgentToolType.confirm &&
          m.toolStatus == AgentToolStatus.running,
    );
    expect(running, hasLength(1));

    agent.resolveConfirmation(agent.debugPendingModelConfirmationId!, '确认');

    for (var i = 0; i < 100; i++) {
      if (agent.debugPendingModelConfirmationId == null &&
          trace.finishReason != null) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(agent.debugPendingModelConfirmationId, isNull);
    expect(trace.finishReason, 'stop');
    expect(toolExecutorCalled, isFalse);
    expect(trace.modelSteps, 2);
    expect(trace.toolRequests, 1);
    expect(trace.toolResponses, 1);
  });

  test('确认等待中停止生成：结束本轮并清理确认暂停', () async {
    final agent = AgentService();
    var modelSteps = 0;

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      modelSteps++;
      return _modelResponse(
        [
          ToolRequestPart(
            toolRequest: ToolRequest(
              name: AgentService.confirmToolName,
              input: {'question': '确认继续？'},
              ref: 'confirm-r1',
            ),
          ),
        ],
        requestMessages: messages,
      );
    };

    final trace = AgentTurnTrace(
      turnId: 'stop-confirm-turn',
      provider: 'test',
      model: 'm',
      toolsEnabled: true,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 1,
    );

    agent.busy.value = true;
    final first = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: '执行敏感操作')]),
      ],
      toolNames: const [AgentService.confirmToolName],
      trace: trace,
    );

    expect(first, isNull);
    final pendingId = agent.debugPendingModelConfirmationId;
    expect(pendingId, isNotNull);
    final pausedMsg = agent.messages.value.firstWhere((m) => m.id == pendingId);
    expect(pausedMsg.toolStatus, AgentToolStatus.running);

    agent.stopGenerating();

    expect(agent.debugPendingModelConfirmationId, isNull);
    expect(agent.busy.value, isFalse);
    expect(trace.cancelled, isTrue);
    expect(pausedMsg.toolStatus, AgentToolStatus.error);
    expect(pausedMsg.toolDetail, '已停止');

    // 停止后再点确认不应恢复模型回合
    agent.resolveConfirmation(pendingId!, '确认');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(modelSteps, 1);
    expect(agent.debugPendingModelConfirmationId, isNull);
  });
}
