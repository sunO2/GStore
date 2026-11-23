import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_trace.dart';

void main() {
  test('轨迹记录首 token 延迟、分片与工具计数', () {
    final started = DateTime(2026, 1, 1, 12, 0, 0);
    final trace = AgentTurnTrace(
      turnId: 'turn-1',
      provider: 'openai',
      model: 'gpt-test',
      toolsEnabled: true,
      promptChars: 1200,
      messageCount: 4,
      toolsOffered: 12,
      startedAt: started,
    );

    trace.addChunk(); // 空分片不计数
    trace.addChunk(reasoningChars: 8);
    trace.addChunk(textChars: 20, reasoningChars: 2);
    trace.toolRequests = 2;
    trace.toolResponses = 2;
    trace.toolErrors = 1;
    trace.finishReason = 'stop';
    trace.inputTokens = 300;
    trace.outputTokens = 40;
    trace.totalTokens = 340;
    trace.finishedAt = started.add(const Duration(milliseconds: 1500));

    final json = trace.toJson();
    expect(json['turnId'], 'turn-1');
    expect(json['textChunks'], 1);
    expect(json['reasoningChunks'], 2);
    expect(json['responseChars'], 20);
    expect(json['reasoningChars'], 10);
    expect(json['toolRequests'], 2);
    expect(json['toolErrors'], 1);
    expect(json['totalMs'], 1500);
    expect(json['inputTokens'], 300);
    expect(json['firstTokenMs'], isNotNull);
  });

  test('未结束时 totalMs 使用当前时间，firstTokenMs 为空', () {
    final trace = AgentTurnTrace(
      turnId: 'turn-2',
      provider: 'google',
      model: 'gemini-test',
      toolsEnabled: false,
      promptChars: 10,
      messageCount: 1,
      toolsOffered: 0,
    );
    expect(trace.firstTokenMs, isNull);
    expect(trace.totalMs, greaterThanOrEqualTo(0));
    expect(trace.toJson()['cancelled'], false);
  });
}
