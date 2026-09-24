import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/env_resolver.dart';

void main() {
  group('resolveEnv', () {
    test('substitutes a single variable', () {
      final r = resolveEnv('https://api.test/users', {'base': 'unused'});
      expect(r.text, 'https://api.test/users');
      expect(r.missing, isEmpty);

      final r2 = resolveEnv('https://{{host}}/users', {'host': 'api.test'});
      expect(r2.text, 'https://api.test/users');
      expect(r2.missing, isEmpty);
    });

    test('substitutes multiple variables in one text', () {
      final r = resolveEnv(
        '{{scheme}}://{{host}}:{{port}}/{{path}}',
        {
          'scheme': 'https',
          'host': 'api.test',
          'port': '8443',
          'path': 'v1/items',
        },
      );
      expect(r.text, 'https://api.test:8443/v1/items');
      expect(r.missing, isEmpty);
    });

    test('repeated variable occurrences all resolve', () {
      final r = resolveEnv('{{a}}-{{a}}-{{a}}', {'a': 'x'});
      expect(r.text, 'x-x-x');
      expect(r.missing, isEmpty);
    });

    test('missing variable is kept verbatim and marked', () {
      final r = resolveEnv(
        '{{scheme}}://{{missingHost}}/{{missingPath}}',
        {'scheme': 'https'},
      );
      expect(r.text, 'https://{{missingHost}}/{{missingPath}}');
      expect(r.missing, unorderedEquals(<String>['missingHost', 'missingPath']));
    });

    test('missing only: whole placeholder preserved exactly', () {
      final r = resolveEnv('a {{token}} b', <String, String>{});
      expect(r.text, 'a {{token}} b');
      expect(r.missing, unorderedEquals(<String>['token']));
    });

    test('mixed defined and undefined preserves only undefined', () {
      final r = resolveEnv(
        '/{{base}}/{{id}}?q={{q}}',
        {'base': 'v2', 'q': 'ok'},
      );
      expect(r.text, '/v2/{{id}}?q=ok');
      expect(r.missing, unorderedEquals(<String>['id']));
    });

    test('empty value substitutes to empty string, not missing', () {
      final r = resolveEnv('[{{v}}]', {'v': ''});
      expect(r.text, '[]');
      expect(r.missing, isEmpty);
    });

    test('no recursive substitution into substituted values', () {
      // `a` resolves to a string that itself contains a placeholder; the inner
      // placeholder must NOT be expanded, nor reported as missing.
      final r = resolveEnv(
        '{{a}}',
        {'a': '{{b}}', 'b': 'inner'},
      );
      expect(r.text, '{{b}}');
      expect(r.missing, isEmpty);
    });

    test('nested-looking braces are not recursively resolved', () {
      final r = resolveEnv(
        '{{outer}}',
        {'outer': '{{inner}}', 'inner': 'deep'},
      );
      expect(r.text, '{{inner}}');
      expect(r.missing, isEmpty);
    });

    test('special characters in values are inserted literally', () {
      final r = resolveEnv(
        '{{dollar}}{{braces}}{{unicode}}{{newline}}',
        {
          'dollar': r'$1 and $& and \n',
          'braces': '{ } {{ }}',
          'unicode': '你好 🌍 café',
          'newline': 'a\nb\tc',
        },
      );
      expect(r.text, r'$1 and $& and \n{ } {{ }}你好 🌍 caféa' '\n' 'b\tc');
      expect(r.missing, isEmpty);
    });

    test('special characters in the surrounding text are untouched', () {
      const input = r'pre$&{x} {{v}} post$1}';
      final r = resolveEnv(input, {'v': 'V'});
      expect(r.text, r'pre$&{x} V post$1}');
      expect(r.missing, isEmpty);
    });

    test('unicode variable names resolve', () {
      final r = resolveEnv('{{主机}}/{{路径}}', {'主机': '例子.测试', '路径': '数据'});
      expect(r.text, '例子.测试/数据');
      expect(r.missing, isEmpty);
    });

    test('whitespace inside placeholder is trimmed for lookup', () {
      final r = resolveEnv('{{ name }}', {'name': 'value'});
      expect(r.text, 'value');
      expect(r.missing, isEmpty);
    });

    test('unmatched braces are left untouched', () {
      final r = resolveEnv('a {{ b }} {{c} {d}} e', <String, String>{});
      // `{{ b }}` is a valid placeholder -> missing "b"; lone/short braces stay.
      expect(r.text, 'a {{ b }} {{c} {d}} e');
      expect(r.missing, unorderedEquals(<String>['b']));
    });

    test('input without placeholders returns identical text', () {
      const input = r'plain text with $ and {single} braces';
      final r = resolveEnv(input, {'unused': 'x'});
      expect(r.text, input);
      expect(r.missing, isEmpty);
    });

    test('empty input returns empty', () {
      final r = resolveEnv('', {'a': 'b'});
      expect(r.text, '');
      expect(r.missing, isEmpty);
    });

    test('does not mutate the vars map', () {
      final vars = <String, String>{'a': '{{b}}', 'b': 'inner'};
      resolveEnv('{{a}} {{missing}}', vars);
      expect(vars, equals(<String, String>{'a': '{{b}}', 'b': 'inner'}));
    });

    test('reports duplicate missing variable only once', () {
      final r = resolveEnv('{{x}}{{x}}{{x}}', <String, String>{});
      expect(r.text, '{{x}}{{x}}{{x}}');
      expect(r.missing.length, 1);
      expect(r.missing, contains('x'));
    });
  });
}
