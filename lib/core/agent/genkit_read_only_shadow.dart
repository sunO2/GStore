// ignore_for_file: experimental_member_use

/// Experimental, read-only Genkit custom-agent runtime.
///
/// This is intentionally isolated from [AgentService]:
/// - never exposed to the production chat path;
/// - only registers read-only tools;
/// - has no session persistence or write tools;
/// - can be enabled behind a compile-time flag while evaluating migration.
library;

import 'package:genkit/genkit.dart';
import 'package:genkit/experimental.dart';
import 'package:genkit_middleware/genkit_middleware.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:schemantic/schemantic.dart';

/// Compile-time feature flag. Disabled unless explicitly provided:
///
/// `--dart-define=GSTORE_GENKIT_READ_ONLY_SHADOW=true`
const bool genkitReadOnlyShadowEnabled = bool.fromEnvironment(
  'GSTORE_GENKIT_READ_ONLY_SHADOW',
);

/// Tools allowed in Phase 2. Keep this list deliberately small.
const Set<String> genkitReadOnlyShadowTools = {
  'searchApp',
  'getAppInfo',
};

/// Mirrors the production loop's headroom while staying below its hard cap.
const int _maxReadOnlySteps = 8;

/// Final result of one shadow-agent turn.
class ShadowAgentResult {
  const ShadowAgentResult({
    required this.engine,
    required this.text,
    required this.reasoning,
    required this.toolRequests,
    required this.duration,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.error,
  });

  final String engine;
  final String text;
  final String reasoning;
  final int toolRequests;
  final Duration duration;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final Object? error;

  bool get isSuccess => error == null;
}

/// A [defineCustomAgent] wrapper that only exposes read-only GStore tools.
///
/// The caller owns the [Genkit] instance and must:
/// - register the same model plugin used by the real AgentService;
/// - register `SkillsPlugin()` if [skillDirectory] is supplied;
/// - pass a fresh executor callback (normally `AgentService.runTool`).
class GenkitReadOnlyShadowRuntime {
  GenkitReadOnlyShadowRuntime._({
    required this.ai,
    required this.model,
    required this.systemPrompt,
    required this.executeTool,
    required this.allowedTools,
    this.skillDirectory,
  });

  final Genkit ai;
  final ModelRef<dynamic> model;
  final String systemPrompt;
  final Future<String> Function(String name, Map<String, dynamic> args)
      executeTool;
  final Set<String> allowedTools;
  final String? skillDirectory;

  int _toolRequestsThisRun = 0;
  int? _inputTokens;
  int? _outputTokens;
  int? _totalTokens;

  late final Agent<dynamic> _agent = ai.defineCustomAgent<dynamic>(
    name: 'gstoreReadOnlyShadow',
    description: 'Read-only GStore assistant shadow agent.',
    fn: (sess, options) async {
      Message? finalMessage;

      await sess.run((input, ctx) async {
        final result = await ai.generate<dynamic, void>(
          model: model,
          system: systemPrompt,
          messages: sess.getMessages(),
          toolNames: allowedTools.toList(growable: false),
          maxTurns: _maxReadOnlySteps,
          use: [
            if (skillDirectory != null) skills(skillPaths: [skillDirectory!]),
          ],
        );

        _accumulateUsage(result);
        finalMessage = result.message;
        if (finalMessage == null) {
          throw StateError(
            'defineCustomAgent 未返回最终消息'
            '（finishReason=${result.finishReason.value}）',
          );
        }
        sess.addMessages([finalMessage!]);
        return null;
      });

      return AgentResult(
        message: finalMessage ??
            Message(
              role: Role.model,
              content: [TextPart(text: '（Shadow Agent 未返回内容）')],
            ),
      );
    },
  );

  /// Builds a runtime and registers only [allowedTools] on a dedicated Genkit
  /// instance.
  static GenkitReadOnlyShadowRuntime create({
    required Genkit ai,
    required ModelRef<dynamic> model,
    required String systemPrompt,
    required Future<String> Function(String name, Map<String, dynamic> args)
        executeTool,
    String? skillDirectory,
    Set<String> allowedTools = genkitReadOnlyShadowTools,
  }) {
    final runtime = GenkitReadOnlyShadowRuntime._(
      ai: ai,
      model: model,
      systemPrompt: systemPrompt,
      executeTool: executeTool,
      allowedTools: allowedTools,
      skillDirectory: skillDirectory,
    );
    runtime._registerTools();
    return runtime;
  }

  void _registerTools() {
    for (final spec in AgentToolCatalog.enabled) {
      if (!allowedTools.contains(spec.name)) continue;
      ai.defineTool<Map<String, dynamic>, String>(
        name: spec.name,
        description: spec.brief,
        inputSchema: _inputSchema(spec.inputJsonSchema),
        fn: (input, _) async {
          _toolRequestsThisRun++;
          final output = await executeTool(spec.name, input);
          return ToolResult.response(output);
        },
      );
    }
  }

  /// Runs one isolated turn through `defineCustomAgent`.
  Future<ShadowAgentResult> run(String text) async {
    _resetMetrics();
    final stopwatch = Stopwatch()..start();
    try {
      final chat = _agent.chat();
      final response = await chat.send(text: text);
      stopwatch.stop();

      return _result(
        engine: 'defineCustomAgent',
        text: response.text,
        reasoning: response.reasoning,
        duration: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return _result(
        engine: 'defineCustomAgent',
        text: '',
        reasoning: '',
        duration: stopwatch.elapsed,
        error: error,
      );
    }
  }

  /// Runs the same read-only task through a headless replica of GStore's
  /// existing `returnToolRequests + manual execution` loop.
  ///
  /// This does not touch `AgentService` UI/session state and is only used for
  /// debug comparison.
  Future<ShadowAgentResult> runLegacyLoop(String text) async {
    _resetMetrics();
    final stopwatch = Stopwatch()..start();
    var conversation = <Message>[
      Message(role: Role.system, content: [TextPart(text: systemPrompt)]),
      Message(role: Role.user, content: [TextPart(text: text)]),
    ];

    try {
      GenerateResult<dynamic>? last;
      for (var step = 0; step < _maxReadOnlySteps; step++) {
        final result = await ai.generate<dynamic, void>(
          model: model,
          messages: conversation,
          toolNames: allowedTools.toList(growable: false),
          maxTurns: 1,
          returnToolRequests: true,
          use: [
            if (skillDirectory != null) skills(skillPaths: [skillDirectory!]),
          ],
        );
        last = result;
        _accumulateUsage(result);

        final requests = result.message?.content
                .map((part) => part.toolRequestPart)
                .nonNulls
                .toList(growable: false) ??
            const <ToolRequestPart>[];
        if (requests.isEmpty) break;

        final responses = <ToolResponsePart>[];
        for (final request in requests) {
          _toolRequestsThisRun++;
          final input = request.toolRequest.input;
          final args = input is Map
              ? input.map((key, value) => MapEntry(key.toString(), value))
              : <String, dynamic>{};
          final output = await executeTool(request.toolRequest.name, args);
          responses.add(
            ToolResponsePart(
              toolResponse: ToolResponse(
                ref: request.toolRequest.ref ?? request.toolRequest.name,
                name: request.toolRequest.name,
                output: output,
              ),
            ),
          );
        }
        conversation = [
          ...result.messages,
          Message(role: Role.tool, content: responses),
        ];
      }
      stopwatch.stop();
      final text = last?.text ?? '';

      return _result(
        engine: 'legacyLoop',
        text: text,
        reasoning: '',
        duration: stopwatch.elapsed,
        error: text.trim().isEmpty ? StateError('现有 Loop 未返回最终文本') : null,
      );
    } catch (error) {
      stopwatch.stop();
      return _result(
        engine: 'legacyLoop',
        text: '',
        reasoning: '',
        duration: stopwatch.elapsed,
        error: error,
      );
    }
  }

  void _resetMetrics() {
    _toolRequestsThisRun = 0;
    _inputTokens = null;
    _outputTokens = null;
    _totalTokens = null;
  }

  void _accumulateUsage(GenerateResult<dynamic> result) {
    final usage = result.usage;
    if (usage == null) return;
    _inputTokens = (_inputTokens ?? 0) + (usage.inputTokens ?? 0);
    _outputTokens = (_outputTokens ?? 0) + (usage.outputTokens ?? 0);
    _totalTokens = (_totalTokens ?? 0) + (usage.totalTokens ?? 0);
  }

  ShadowAgentResult _result({
    required String engine,
    required String text,
    required String reasoning,
    required Duration duration,
    Object? error,
  }) {
    return ShadowAgentResult(
      engine: engine,
      text: text,
      reasoning: reasoning,
      toolRequests: _toolRequestsThisRun,
      duration: duration,
      inputTokens: _inputTokens,
      outputTokens: _outputTokens,
      totalTokens: _totalTokens,
      error: error,
    );
  }
}

SchemanticType<Map<String, dynamic>> _inputSchema(
  Map<String, Object?> jsonSchema,
) {
  return SchemanticType.from<Map<String, dynamic>>(
    jsonSchema: jsonSchema,
    parse: (json) => Map<String, dynamic>.from(json as Map),
  );
}
