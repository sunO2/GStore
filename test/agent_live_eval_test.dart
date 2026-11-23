/// 真实模型工具选择评测（可选，默认跳过）
///
/// 目的：用设备/本地已配置的 OpenAI 兼容端点跑一批真实请求，观察模型
/// 在**同一套工具 schema + 工具检索**下是否选中期望工具，并记录耗时/token。
///
/// 运行：
/// ```bash
/// GSTORE_LIVE_EVAL_BASE_URL=http://192.168.0.31:3000/v1 \
/// GSTORE_LIVE_EVAL_MODEL=hy4-flash-free \
/// GSTORE_LIVE_EVAL_API_KEY=<token> \
/// flutter test test/agent_live_eval_test.dart
/// ```
///
/// 未设置 BASE_URL/MODEL 时整组 skip，不会影响普通 CI。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:gstore/core/agent/agent_tool_selector.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:schemantic/schemantic.dart' show SchemanticType;

class _LiveCase {
  const _LiveCase(this.prompt, this.expected);
  final String prompt;
  final String expected;
}

const _liveCases = <_LiveCase>[
  _LiveCase('帮我找一个终端工具', 'searchApp'),
  _LiveCase('检查应用更新', 'updateApps'),
  _LiveCase('备份我的数据', 'backup'),
  _LiveCase('把主题改成深色', 'themeControl'),
  _LiveCase('清理缓存', 'cacheManage'),
  _LiveCase('我装了什么应用', 'installedApps'),
  _LiveCase('记住我偏好 F-Droid', 'remember'),
  _LiveCase('对比 Termux 两个版本的差异', 'snapshotCompare'),
  _LiveCase('下载 Termux', 'downloadApp'),
  _LiveCase('在 F-Droid 搜索阅读器', 'fdroidRepo'),
];

SchemanticType<Map<String, dynamic>> _inputSchema(
  Map<String, Object?> jsonSchema,
) {
  return SchemanticType.from<Map<String, dynamic>>(
    jsonSchema: jsonSchema,
    parse: (json) => Map<String, dynamic>.from(json as Map),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final baseUrl = Platform.environment['GSTORE_LIVE_EVAL_BASE_URL']?.trim();
  final model = Platform.environment['GSTORE_LIVE_EVAL_MODEL']?.trim();
  final apiKey =
      Platform.environment['GSTORE_LIVE_EVAL_API_KEY']?.trim() ?? 'x';
  final enabled = (baseUrl?.isNotEmpty ?? false) &&
      (model?.isNotEmpty ?? false);

  group('真实模型工具选择（live）', () {
    late Genkit ai;
    late ModelRef<dynamic> modelRef;

    setUpAll(() {
      if (!enabled) return;
      ai = Genkit(
        plugins: [
          openAI(name: 'live', apiKey: apiKey, baseUrl: baseUrl),
        ],
        promptDir: null,
      );
      for (final spec in AgentToolCatalog.enabled) {
        ai.defineTool<Map<String, dynamic>, String>(
          name: spec.name,
          description: spec.brief,
          inputSchema: _inputSchema(spec.inputJsonSchema),
          fn: (input, _) async => ToolResult.response('ok:${spec.name}'),
        );
      }
      modelRef = openAI.model(model!, namespace: 'live');
    });

    for (final liveCase in _liveCases) {
      test('live/${liveCase.expected}', () async {
        final selection = AgentToolSelector.select(
          userText: liveCase.prompt,
          all: AgentToolCatalog.enabled,
        );
        final stopwatch = Stopwatch()..start();
        final result = await ai.generate(
          model: modelRef,
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: liveCase.prompt)],
            ),
          ],
          toolNames: selection.names,
          maxTurns: 1,
          returnToolRequests: true,
        );
        stopwatch.stop();

        final requests = result.message?.content
                .map((part) => part.toolRequestPart)
                .nonNulls
                .map((part) => part.toolRequest.name)
                .toList() ??
            const <String>[];

        // 输出一行可读报告（flutter test 默认只显示失败/print）
        // ignore: avoid_print
        print('LIVE ${liveCase.prompt} → tools=$requests '
            'expected=${liveCase.expected} '
            'latency=${stopwatch.elapsedMilliseconds}ms '
            'tokens=${result.usage?.totalTokens ?? '?'}');

        expect(result.finishReason, isNot(FinishReason.failed));
        expect(
          requests,
          contains(liveCase.expected),
          reason: '模型未选中期望工具；可用工具：${selection.names}',
        );
      }, skip: enabled ? false : '未配置 GSTORE_LIVE_EVAL_BASE_URL/MODEL');
    }
  });

  test('live eval 配置说明', () {
    // 让跳过原因在输出里可见
    if (!enabled) {
      // ignore: avoid_print
      print('Skip live eval: set GSTORE_LIVE_EVAL_BASE_URL / '
          'GSTORE_LIVE_EVAL_MODEL / GSTORE_LIVE_EVAL_API_KEY');
    }
  });
}
