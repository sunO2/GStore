// ignore_for_file: experimental_member_use

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/genkit_read_only_shadow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('read-only shadow agent executes searchApp and returns final text',
      () async {
    final ai = Genkit(plugins: const [], promptDir: null);
    var calls = 0;
    List<Message>? secondRequestMessages;

    final model = ai.defineModel(
      name: 'debug/shadow-model',
      fn: (request, ctx) async {
        calls++;
        if (calls == 1) {
          return ModelResponse(
            message: Message(role: Role.model, content: [
              ToolRequestPart(
                toolRequest: ToolRequest(
                  name: 'searchApp',
                  input: {'keyword': 'terminal'},
                  ref: 'shadow-r1',
                ),
              ),
            ]),
            finishReason: FinishReason.stop,
          );
        }
        secondRequestMessages = request.messages;
        return ModelResponse(
          message: Message(
            role: Role.model,
            content: [TextPart(text: '推荐 Termux')],
          ),
          finishReason: FinishReason.stop,
        );
      },
    );

    var executed = 0;
    final runtime = GenkitReadOnlyShadowRuntime.create(
      ai: ai,
      model: model,
      systemPrompt: '你是只读 Shadow Agent。',
      executeTool: (name, args) async {
        executed++;
        expect(name, 'searchApp');
        expect(args['keyword'], 'terminal');
        return '找到 Termux';
      },
    );

    final result = await runtime.run('找一个终端');

    expect(result.isSuccess, isTrue);
    expect(result.text, '推荐 Termux');
    expect(result.toolRequests, 1);
    expect(executed, 1);
    expect(calls, 2);
    expect(
      secondRequestMessages!.any((message) => message.role == Role.tool),
      isTrue,
      reason: '第二轮模型请求应包含工具结果',
    );
  });

  test('legacy loop replica executes the same read-only tool', () async {
    final ai = Genkit(plugins: const [], promptDir: null);
    var calls = 0;
    final model = ai.defineModel(
      name: 'debug/shadow-model',
      fn: (request, ctx) async {
        calls++;
        if (calls == 1) {
          return ModelResponse(
            message: Message(role: Role.model, content: [
              ToolRequestPart(
                toolRequest: ToolRequest(
                  name: 'getAppInfo',
                  input: {'appId': 'com.termux', 'channel': 'fdroid'},
                  ref: 'legacy-r1',
                ),
              ),
            ]),
            finishReason: FinishReason.stop,
          );
        }
        return ModelResponse(
          message: Message(
            role: Role.model,
            content: [TextPart(text: 'Termux 详情已获取')],
          ),
          finishReason: FinishReason.stop,
        );
      },
    );

    var executed = 0;
    final runtime = GenkitReadOnlyShadowRuntime.create(
      ai: ai,
      model: model,
      systemPrompt: '只读测试',
      executeTool: (name, args) async {
        executed++;
        expect(name, 'getAppInfo');
        return 'Termux 0.118';
      },
    );

    final result = await runtime.runLegacyLoop('看看 Termux 详情');

    expect(result.isSuccess, isTrue);
    expect(result.engine, 'legacyLoop');
    expect(result.text, 'Termux 详情已获取');
    expect(result.toolRequests, 1);
    expect(executed, 1);
    expect(calls, 2);
  });

  test('shadow allowlist excludes write tools', () {
    expect(genkitReadOnlyShadowTools, contains('searchApp'));
    expect(genkitReadOnlyShadowTools, contains('getAppInfo'));
    expect(genkitReadOnlyShadowTools, isNot(contains('downloadApp')));
    expect(genkitReadOnlyShadowTools, isNot(contains('installApp')));
    expect(genkitReadOnlyShadowTools, isNot(contains('configManager')));
  });

  test('shadow feature flag is disabled by default', () {
    expect(genkitReadOnlyShadowEnabled, isFalse);
  });
}
