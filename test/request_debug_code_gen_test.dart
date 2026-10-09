import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/code_gen.dart';
import 'package:gstore/core/request_debug/debug_models.dart';

/// 多语言代码生成纯函数测试（plan todo 19）。
///
/// 覆盖：
/// - 每种语言片段都包含 方法 / URL / 头 / 体；
/// - `{{var}}` 占位符在全部语言中**逐字保留**（绝不百分号编码 / 丢弃）；
/// - 空请求仍生成合法（非空、含方法）片段，绝不抛异常。
void main() {
  DebugRequest demoRequest() => DebugRequest(
        id: 'r-codegen',
        name: 'codegen',
        method: 'POST',
        url: 'https://{{host}}/api/items',
        query: <DebugQueryParam>[
          DebugQueryParam(name: 'q', value: '{{q}}'),
        ],
        headers: <DebugHeader>[
          const DebugHeader(name: 'Accept', value: 'application/json'),
          const DebugHeader(name: 'X-Token', value: '{{token}}'),
        ],
        body: '{"name":"{{name}}"}',
        bodyKind: DebugBodyKind.json,
      );

  group('generateCode · 非空请求含方法/URL/头/体', () {
    for (final language in CodeGenLanguage.values) {
      test('${language.label}：片段含方法 / URL / 头 / 体', () {
        final code = generateCode(demoRequest(), language);
        expect(code.trim(), isNotEmpty, reason: language.label);
        expect(code, contains('POST'), reason: '${language.label} 缺少方法');
        expect(
          code,
          contains('https://{{host}}/api/items'),
          reason: '${language.label} 缺少 URL',
        );
        expect(code, contains('Accept'), reason: '${language.label} 缺少头名');
        expect(
          code,
          contains('application/json'),
          reason: '${language.label} 缺头值',
        );
        expect(
          code,
          contains('{"name":"{{name}}"}'),
          reason: '${language.label} 缺少请求体',
        );
      });
    }
  });

  group('generateCode · {{var}} 占位符逐字保留', () {
    for (final language in CodeGenLanguage.values) {
      test('${language.label}：URL / 头 / 体 / 查询占位符均保留', () {
        final code = generateCode(demoRequest(), language);
        expect(code, contains('{{host}}'), reason: '${language.label} host');
        expect(code, contains('{{token}}'), reason: '${language.label} token');
        expect(code, contains('{{name}}'), reason: '${language.label} name');
        expect(code, contains('{{q}}'), reason: '${language.label} query');
      });
    }
  });

  group('generateCode · 空请求仍合法', () {
    final empty = DebugRequest(id: 'r-empty', name: 'empty');

    for (final language in CodeGenLanguage.values) {
      test('${language.label}：空请求生成非空片段且含默认方法', () {
        final code = generateCode(empty, language);
        expect(code.trim(), isNotEmpty, reason: language.label);
        expect(code, contains('GET'), reason: '${language.label} 缺少默认方法');
      });
    }
  });

  group('generateCode · 集合与纯度', () {
    test('generateAllCode 覆盖全部语言键', () {
      final all = generateAllCode(demoRequest());
      for (final language in CodeGenLanguage.values) {
        expect(all.containsKey(language), isTrue);
        expect(all[language]!.trim(), isNotEmpty);
      }
    });

    test('generateCode 不修改传入请求（纯函数）', () {
      final request = demoRequest();
      final before = request.toJson();
      for (final language in CodeGenLanguage.values) {
        generateCode(request, language);
      }
      expect(request.toJson(), before);
    });
  });
}
