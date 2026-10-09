/// 「请求调试」URL 查询编解码（plan todo 1）测试。
///
/// 覆盖验收标准（`request-debug-ui-ux.md` todo 1）：
/// - `parseUrlQuery` 手动扫描、绝不 `Uri.parse`、绝不抛异常；`+` 字面量；
///   百分号解码（含空格）；顺序 / 重复名 / 空值 / 无值键保留。
/// - `rebuildUrl` 手动拼装；`{{var}}` 原样、仅编码 `&` `=` `#` 与空格；
///   query 永远在 `#fragment` 之前。
/// - `mergeParams` 按名分组、覆盖组顶替原位置、新名按 override 顺序追加。
/// - `buildUri` 合并后重建成 [Uri]（query 在 fragment 前）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/query_codec.dart';
import 'package:gstore/core/request_debug/request_debug.dart' as barrel;

/// 把参数列表压成 `name=value:enabled` 便于比较（DebugQueryParam 未定义 ==）。
List<String> dump(List<DebugQueryParam> params) => [
      for (final p in params) '${p.name}=${p.value}:${p.enabled}',
    ];

DebugQueryParam q(String name, [String value = '', bool enabled = true]) =>
    DebugQueryParam(name: name, value: value, enabled: enabled);

void main() {
  group('parseUrlQuery', () {
    test('empty input yields empty result', () {
      final r = parseUrlQuery('');
      expect(r.base, '');
      expect(r.params, isEmpty);
      expect(r.fragment, isNull);
    });

    test('space-containing and malformed URLs never throw', () {
      expect(() => parseUrlQuery('ht tp://x'), returnsNormally);
      expect(() => parseUrlQuery('http://[::1'), returnsNormally);
      final r = parseUrlQuery('ht tp://x');
      expect(r.base, 'ht tp://x');
      expect(r.params, isEmpty);
      expect(r.fragment, isNull);
    });

    test('absolute URL keeps path and parses one param', () {
      final r = parseUrlQuery('api.example.com/x?a=1');
      expect(r.base, 'api.example.com/x');
      expect(dump(r.params), ['a=1:true']);
      expect(r.fragment, isNull);
    });

    test('relative path parses query', () {
      final r = parseUrlQuery('/rel?a=1');
      expect(r.base, '/rel');
      expect(dump(r.params), ['a=1:true']);
    });

    test('fragment is split off first; query inside fragment is ignored', () {
      final r = parseUrlQuery('p#frag?a=1');
      expect(r.base, 'p');
      expect(r.params, isEmpty);
      expect(r.fragment, 'frag?a=1');
    });

    test('repeated names produce separate ordered rows', () {
      final r = parseUrlQuery('?a=1&a=2');
      expect(dump(r.params), ['a=1:true', 'a=2:true']);
      expect(r.base, '');
    });

    test('empty value is kept, valueless key is kept', () {
      final r = parseUrlQuery('?a=&b');
      expect(dump(r.params), ['a=:true', 'b=:true']);
    });

    test('lone valueless key is kept', () {
      final r = parseUrlQuery('?flag');
      expect(dump(r.params), ['flag=:true']);
    });

    test('semicolon is a separator too', () {
      final r = parseUrlQuery('?a=1;b=2');
      expect(dump(r.params), ['a=1:true', 'b=2:true']);
    });

    test('placeholder value is kept literally (no decoding/corruption)', () {
      final r = parseUrlQuery('?a={{host}}');
      expect(dump(r.params), ['a={{host}}:true']);
    });

    test('placeholder prefix base is separated from query', () {
      final r = parseUrlQuery('{{host}}/p?a=1');
      expect(r.base, '{{host}}/p');
      expect(dump(r.params), ['a=1:true']);
      expect(r.fragment, isNull);
    });

    test('normalization: plus stays literal', () {
      final r = parseUrlQuery('?a=1+2');
      expect(r.params[0].value, '1+2');
      expect(rebuildUrl(r.base, r.fragment, r.params), '?a=1+2');
    });

    test('normalization: percent-encoded space decodes to space and re-encodes',
        () {
      final r = parseUrlQuery('?a=%20');
      expect(r.params[0].value, ' ');
      expect(rebuildUrl(r.base, r.fragment, r.params), '?a=%20');
    });

    test('malformed percent-encoding falls back without throwing', () {
      final r = parseUrlQuery('?a=%ZZ');
      expect(r.base, '?a=%ZZ');
      expect(r.params, isEmpty);
      expect(r.fragment, isNull);
    });

    test('parsed rows are enabled by default', () {
      final r = parseUrlQuery('?a=1');
      expect(r.params.single.enabled, isTrue);
    });
  });

  group('rebuildUrl', () {
    test('placeholder is emitted raw (no %7B)', () {
      final out = rebuildUrl('{{host}}/p', null, [q('a', '{{host}}')]);
      expect(out, '{{host}}/p?a={{host}}');
      expect(out.contains('%7B'), isFalse);
    });

    test('plus is kept literal', () {
      expect(rebuildUrl('', null, [q('a', '1+2')]), '?a=1+2');
    });

    test('space encodes to %20', () {
      expect(rebuildUrl('', null, [q('a', 'x y')]), '?a=x%20y');
    });

    test('reserved characters &, =, # are percent-encoded', () {
      expect(rebuildUrl('', null, [q('a', 'x&y=z#w')]), '?a=x%26y%3Dz%23w');
      expect(rebuildUrl('', null, [q('a&b', 'v')]), '?a%26b=v');
    });

    test('literal percent encodes to %25 (round-trip safe)', () {
      expect(rebuildUrl('', null, [q('a', '100%')]), '?a=100%25');
      expect(rebuildUrl('', null, [q('a', '50%off')]), '?a=50%25off');
    });

    test('literal percent round-trips through parse + rebuild', () {
      final r = parseUrlQuery('?a=100%25&b=50%25off');
      expect(r.params[0].value, '100%');
      expect(r.params[1].value, '50%off');
      expect(rebuildUrl(r.base, r.fragment, r.params), '?a=100%25&b=50%25off');
    });

    test('order and repeated names are preserved', () {
      expect(
        rebuildUrl('', null, [q('a', '1'), q('b', '2'), q('a', '3')]),
        '?a=1&b=2&a=3',
      );
    });

    test('valueless key is emitted without =', () {
      expect(rebuildUrl('', null, [q('flag')]), '?flag');
      expect(rebuildUrl('', null, [q('a', ''), q('b', '')]), '?a&b');
    });

    test('query is placed before fragment', () {
      expect(rebuildUrl('http://x/p', 'f', [q('a', '2')]),
          'http://x/p?a=2#f');
    });

    test('no query means no ? and fragment still appended', () {
      expect(rebuildUrl('http://x/p', 'f', const []), 'http://x/p#f');
      expect(rebuildUrl('http://x/p', null, const []), 'http://x/p');
    });
  });

  group('mergeParams', () {
    test('override replaces base value group', () {
      expect(dump(mergeParams([q('a', '1')], [q('a', '2')])), ['a=2:true']);
    });

    test('override group replaces whole base group at base position', () {
      expect(
        dump(mergeParams([q('a', '1')], [q('a', '2'), q('a', '3')])),
        ['a=2:true', 'a=3:true'],
      );
      expect(
        dump(mergeParams([q('a', '1'), q('a', '2')], [q('a', '9')])),
        ['a=9:true'],
      );
    });

    test('base names absent from overrides keep value and position', () {
      expect(
        dump(mergeParams([q('a', '1')], [q('b', '2')])),
        ['a=1:true', 'b=2:true'],
      );
      expect(
        dump(mergeParams([q('a', '1'), q('x', '5')], [q('x', '9')])),
        ['a=1:true', 'x=9:true'],
      );
    });

    test('new override groups are appended in override order', () {
      expect(
        dump(mergeParams(
          [q('a', '1')],
          [q('b', '2'), q('c', '3')],
        )),
        ['a=1:true', 'b=2:true', 'c=3:true'],
      );
    });

    test('empty overrides keep base; empty base takes overrides', () {
      expect(dump(mergeParams([q('a', '1')], const [])), ['a=1:true']);
      expect(dump(mergeParams(const [], [q('a', '1')])), ['a=1:true']);
    });
  });

  group('buildUri', () {
    test('override replaces duplicate base keys', () {
      final uri = buildUri('http://x/?a=1&a=2', [q('a', '3')]);
      expect(uri.queryParametersAll['a'], ['3']);
    });

    test('query is built before the fragment', () {
      expect(buildUri('http://x/p#f', [q('a', '2')]).toString(),
          'http://x/p?a=2#f');
    });

    test('disabled and empty-name params are ignored', () {
      final uri = buildUri('http://x/p', [
        q('a', '1', false),
        q('', '2'),
        q('b', '3'),
      ]);
      expect(uri.queryParametersAll.containsKey('a'), isFalse);
      expect(uri.queryParametersAll['b'], ['3']);
    });

    test('placeholder URL does not throw (braces get percent-encoded)', () {
      expect(() => buildUri('{{host}}/p?a=1', const []), returnsNormally);
    });
  });

  group('barrel export', () {
    test('request_debug.dart re-exports the codec API', () {
      // 编译期即验证：barrel 里能取到同名符号。
      expect(barrel.parseUrlQuery('?a=1').params.single.name, 'a');
    });
  });
}
