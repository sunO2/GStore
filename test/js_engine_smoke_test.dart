import 'package:flutter_test/flutter_test.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// QuickJS 引擎 smoke 测试：
/// 验证 quickjs_engine 在测试环境可加载原生库，且核心 API 可用：
/// 1. evaluate('1+1') → stringResult == '2'
/// 2. onMessage 双向：JS sendMessage → Dart 回调收到
/// 3. JS 调用 Dart 注册函数并拿到返回值
void main() {
  group('quickjs_engine smoke', () {
    test('evaluate 1+1 返回 2', () {
      final js = getJavascriptRuntime(xhr: false);
      final result = js.evaluate('1 + 1');
      expect(result.stringResult, '2');
      expect(result.isError, isFalse);
      js.dispose();
    });

    test('onMessage 双向：JS sendMessage → Dart 回调收到', () {
      final js = getJavascriptRuntime(xhr: false);
      dynamic received;
      js.onMessage('test', (dynamic args) {
        received = args;
        return 'pong';
      });

      final result = js.evaluate("sendMessage('test', JSON.stringify('hi'))");
      expect(result.isError, isFalse);
      expect(received, 'hi');
      js.dispose();
    });

    test('JS 调用 Dart 注册函数并拿到返回值', () {
      final js = getJavascriptRuntime(xhr: false);
      js.onMessage('add', (dynamic args) {
        final map = args as Map;
        return (map['a'] as num) + (map['b'] as num);
      });

      final result = js.evaluate(
        "sendMessage('add', JSON.stringify({a: 1, b: 2}))",
      );
      expect(result.isError, isFalse);
      expect(result.stringResult, '3');
      js.dispose();
    });

    test('JS 抛错返回 isError 不崩应用', () {
      final js = getJavascriptRuntime(xhr: false);
      final result = js.evaluate('throw new Error("boom")');
      expect(result.isError, isTrue);
      expect(result.stringResult, contains('boom'));
      js.dispose();
    });
  });
}