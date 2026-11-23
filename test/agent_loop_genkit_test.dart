import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_trace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实 Genkit 流 + returnToolRequests：工具不执行，由 loop 接管', () async {
    final ai = Genkit(plugins: const [], promptDir: null);
    var toolRan = false;
    ai.defineTool<Map<String, dynamic>, String>(
      name: 'searchApp',
      description: 'test tool',
      fn: (input, _) async {
        toolRan = true;
        return ToolResult.response('builtin-ran');
      },
    );

    var calls = 0;
    List<Message>? secondRequestMessages;
    ai.defineModel(
      name: 'debug/agent-model',
      fn: (request, ctx) async {
        calls++;
        if (calls == 1) {
          return ModelResponse(
            message: Message(role: Role.model, content: [
              ToolRequestPart(
                toolRequest: ToolRequest(
                  name: 'searchApp',
                  input: {'keyword': 'termux'},
                  ref: 'r1',
                ),
              ),
            ]),
            finishReason: FinishReason.stop,
          );
        }
        secondRequestMessages = request.messages;
        return ModelResponse(
          message: Message(role: Role.model, content: [TextPart(text: 'final')]),
          finishReason: FinishReason.stop,
        );
      },
    );

    final agent = AgentService()
      ..debugAiOverride = ai
      ..debugExecuteToolsOverride = (requests) async => [
            for (final request in requests)
              ToolResponsePart(
                toolResponse: ToolResponse(
                  name: request.toolRequest.name,
                  ref: request.toolRequest.ref,
                  output: 'loop-ran',
                ),
              ),
          ];

    final trace = AgentTurnTrace(
      turnId: 'g1',
      provider: 'test',
      model: 'debug/agent-model',
      toolsEnabled: true,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 1,
    );
    final result = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: 'find termux')]),
      ],
      toolNames: const ['searchApp'],
      trace: trace,
    );

    expect(result!.text, 'final');
    expect(calls, 2);
    expect(toolRan, isFalse, reason: 'returnToolRequests 不应让 Genkit 执行工具');
    expect(trace.modelSteps, 2);
    expect(trace.toolRequests, 1);
    expect(trace.toolResponses, 1);

    // 第二轮模型请求里应带 Role.tool 的工具结果消息
    final toolMessages = secondRequestMessages!
        .where((m) => m.role == Role.tool)
        .toList();
    expect(toolMessages, hasLength(1));
    expect(toolMessages.single.content.single.toolResponse!.output, 'loop-ran');
  });
}
