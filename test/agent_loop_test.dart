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

ToolRequestPart _request(String name, Map<String, dynamic> input, String ref) {
  return ToolRequestPart(
    toolRequest: ToolRequest(name: name, input: input, ref: ref),
  );
}

ToolResponsePart _response(String name, String ref, String output) {
  return ToolResponsePart(
    toolResponse: ToolResponse(name: name, ref: ref, output: output),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自定义 loop：执行工具后继续下一轮并返回最终文本', () async {
    final agent = AgentService();
    final seenToolMessages = <Message>[];
    var step = 0;

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      step++;
      if (step == 1) {
        // 模拟模型一次返回两个工具请求
        final request = Message(
          role: Role.user,
          content: [TextPart(text: '查一下')],
        );
        return _modelResponse(
          [
            _request('searchApp', {'keyword': 'termux'}, 'r1'),
            _request('getAppInfo', {'appId': 'a', 'channel': 'github'}, 'r2'),
          ],
          requestMessages: [request],
        );
      }
      // 第二步：模型看到工具结果后给出最终回答
      seenToolMessages.addAll(messages.where((m) => m.role == Role.tool));
      return _modelResponse(
        [TextPart(text: 'done')],
        requestMessages: messages,
      );
    };

    agent.debugExecuteToolsOverride = (requests) async {
      return [
        for (final request in requests)
          _response(
            request.toolRequest.name,
            request.toolRequest.ref ?? '',
            'ok:${request.toolRequest.name}',
          ),
      ];
    };

    final trace = AgentTurnTrace(
      turnId: 't',
      provider: 'test',
      model: 'm',
      toolsEnabled: true,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 2,
    );
    final result = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: '查一下')]),
      ],
      toolNames: const ['searchApp', 'getAppInfo'],
      trace: trace,
    );

    expect(result, isNotNull);
    expect(result!.text, 'done');
    expect(trace.modelSteps, 2);
    expect(trace.toolRequests, 2);
    expect(trace.toolResponses, 2);
    // 第二步模型确实收到了 tool 消息（两个 response）
    expect(seenToolMessages, hasLength(1));
    expect(seenToolMessages.single.content.length, 2);
  });

  test('达到最大步数后强制模型不再调用工具并总结', () async {
    final agent = AgentService();
    var calls = 0;
    var forcedCallSawNoTools = false;

    agent.debugGenerateStepOverride = (messages, toolNames, trace) async {
      calls++;
      if (toolNames.isEmpty) {
        forcedCallSawNoTools = true;
        return _modelResponse(
          [TextPart(text: 'summary')],
          requestMessages: messages,
        );
      }
      return _modelResponse(
        [_request('searchApp', {'keyword': 'x'}, 'r$calls')],
        requestMessages: messages,
      );
    };
    agent.debugExecuteToolsOverride = (requests) async => [
          for (final request in requests)
            _response(
              request.toolRequest.name,
              request.toolRequest.ref ?? '',
              'ok',
            ),
        ];

    final trace = AgentTurnTrace(
      turnId: 't2',
      provider: 'test',
      model: 'm',
      toolsEnabled: true,
      promptChars: 0,
      messageCount: 1,
      toolsOffered: 1,
    );
    final result = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: 'loop')]),
      ],
      toolNames: const ['searchApp'],
      trace: trace,
    );

    expect(result!.text, 'summary');
    expect(forcedCallSawNoTools, isTrue);
    expect(calls, 11, reason: '10 步 + 强制总结 1 次');
    expect(trace.modelSteps, 11);
  });

  test('_messageChars 统计文本/工具结果', () {
    final agent = AgentService();
    final messages = [
      Message(role: Role.system, content: [TextPart(text: 'abc')]),
      Message(role: Role.user, content: [TextPart(text: 'hello')]),
      Message(role: Role.tool, content: [
        ToolResponsePart(
          toolResponse: ToolResponse(name: 'x', ref: 'r', output: '12345'),
        ),
      ]),
    ];
    expect(agent.debugMessageChars(messages), 13);
  });
}
