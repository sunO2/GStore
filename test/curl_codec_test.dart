import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/curl_codec.dart';
import 'package:gstore/core/request_debug/debug_models.dart';

/// cURL 导入 / 导出编解码纯函数测试（plan todo 27）。
///
/// 覆盖：GET / POST JSON / 表单 / 多 `-H` / `-b` / 转义 / 往返等价 /
/// 非法 cURL → 明确错误（绝不抛异常）。
void main() {
  group('parseCurl', () {
    test('GET：解析 --url 与多个 -H', () {
      final r = parseCurl(
        "curl --url 'https://api.example.com/items' "
        "-H 'Accept: application/json' -H 'X-Trace: abc'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      final req = r.request!;
      expect(req.method, 'GET');
      expect(req.url, 'https://api.example.com/items');
      expect(req.headers.map((h) => h.name).toList(),
          ['Accept', 'X-Trace']);
      expect(req.headers[1].value, 'abc');
      expect(req.body, isEmpty);
      expect(req.bodyKind, DebugBodyKind.none);
    });

    test('POST JSON：-X + -d 推断 JSON bodyKind', () {
      final r = parseCurl(
        "curl -X POST 'https://api.example.com/items' "
        "-H 'Content-Type: application/json' "
        "-d '{\"name\":\"a\",\"n\":1}'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      final req = r.request!;
      expect(req.method, 'POST');
      expect(req.bodyKind, DebugBodyKind.json);
      expect(req.body, '{"name":"a","n":1}');
      // 实际解析出 JSON 内容而非仅记录字符串。
      expect(req.body.contains('"name"'), isTrue);
    });

    test('POST：有 body 无 -X 时方法推断为 POST', () {
      final r = parseCurl(
        "curl 'https://api.example.com/items' "
        "-H 'Content-Type: application/json' "
        '--data-raw \'{"k":"v"}\'',
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.method, 'POST');
      expect(r.request!.bodyKind, DebugBodyKind.json);
    });

    test('表单：--data 与 content-type 推断 form_urlencoded', () {
      final r = parseCurl(
        "curl 'https://api.example.com/login' "
        "-H 'Content-Type: application/x-www-form-urlencoded' "
        "-d 'user=alice&pwd=s3cr3t'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.method, 'POST');
      expect(r.request!.bodyKind, DebugBodyKind.formUrlEncoded);
      expect(r.request!.body, 'user=alice&pwd=s3cr3t');
    });

    test('-b 解析为多个 cookie', () {
      final r = parseCurl(
        "curl 'https://x.test/' -b 'sid=abc; theme=dark'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      final cookies = r.request!.cookies;
      expect(cookies.length, 2);
      expect(cookies[0].name, 'sid');
      expect(cookies[0].value, 'abc');
      expect(cookies[1].name, 'theme');
      expect(cookies[1].value, 'dark');
    });

    test('-b 文件引用明确忽略且不产生 cookie', () {
      final r = parseCurl("curl 'https://x.test/' -b cookies.txt");
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.cookies, isEmpty);
      expect(r.ignoredOptions.any((e) => e.contains('cookie')), isTrue);
    });

    test('-F multipart 解析为 multipart body', () {
      final r = parseCurl(
        "curl 'https://x.test/upload' -F 'file=@/tmp/a.png' -F 'name=pic'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      final req = r.request!;
      expect(req.method, 'POST');
      expect(req.bodyKind, DebugBodyKind.multipart);
      expect(req.body, 'file=@/tmp/a.png\nname=pic');
    });

    test('转义：单引号 / 双引号 / 反斜杠 / 行续接', () {
      final r = parseCurl(
        "curl -X POST 'https://x.test/q' \\\n"
        '  -H "X-Note: it\'s \\"quoted\\"" \\\n'
        "  -d 'a=1&b=2'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.headers.single.value, 'it\'s "quoted"');
      expect(r.request!.body, 'a=1&b=2');
      expect(r.request!.bodyKind, DebugBodyKind.formUrlEncoded);
    });

    test('ANSI-C 美元引号与反斜杠 n 转义', () {
      final r = parseCurl(
        r"curl -X POST 'https://x.test/e' -d $'line1\nline2'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.body, 'line1\nline2');
    });

    test('不支持选项：明确记录忽略且不崩溃', () {
      final r = parseCurl(
        "curl --compressed -k -s 'https://x.test/' -A 'ua/1'",
      );
      expect(r.isSuccess, isTrue, reason: r.error);
      expect(r.request!.url, 'https://x.test/');
      // -A 映射为 User-Agent 头
      expect(
        r.request!.headers
            .firstWhere((h) => h.name.toLowerCase() == 'user-agent')
            .value,
        'ua/1',
      );
      expect(r.ignoredOptions.any((e) => e.contains('--compressed')), isTrue);
      expect(r.ignoredOptions.any((e) => e.contains('-k')), isTrue);
      expect(r.ignoredOptions.any((e) => e.contains('-s')), isTrue);
    });

    group('非法输入 → 明确错误，绝不抛', () {
      test('空串', () {
        final r = parseCurl('');
        expect(r.isSuccess, isFalse);
        expect(r.error, isNotNull);
        expect(r.request, isNull);
      });

      test('非 curl 命令', () {
        final r = parseCurl('wget https://x.test/');
        expect(r.isSuccess, isFalse);
        expect(r.error, contains('curl'));
      });

      test('未闭合引号', () {
        final r = parseCurl("curl 'https://x.test/");
        expect(r.isSuccess, isFalse);
        expect(r.error, isNotNull);
      });

      test('缺少 URL', () {
        final r = parseCurl('curl -X GET');
        expect(r.isSuccess, isFalse);
        expect(r.error, contains('URL'));
      });

      test('无效 header（无冒号）被忽略但不错误', () {
        final r = parseCurl("curl 'https://x.test/' -H 'not-a-header'");
        expect(r.isSuccess, isTrue, reason: r.error);
        expect(r.request!.headers, isEmpty);
        expect(r.ignoredOptions.any((e) => e.contains('header')), isTrue);
      });

      test('缺少 -H 的值', () {
        final r = parseCurl("curl 'https://x.test/' -H");
        expect(r.isSuccess, isTrue, reason: r.error);
        expect(r.request!.headers, isEmpty);
        expect(r.ignoredOptions.any((e) => e.contains('header')), isTrue);
      });
    });
  });

  group('toCurl', () {
    test('单引号转义：值内含单引号', () {
      final req = DebugRequest(
        id: 'r1',
        name: 'n',
        method: 'POST',
        url: 'https://x.test/',
        headers: const [DebugHeader(name: 'X-Note', value: "it's ok")],
        body: "a='b'",
        bodyKind: DebugBodyKind.text,
      );
      final out = toCurl(req);
      expect(out, contains("-H 'X-Note: it'\\''s ok'"));
      expect(out, contains("-d 'a='\\''b'\\'''"));
    });

    test('输出可被 parseCurl 再次解析（导出→导入等价）', () {
      final req = DebugRequest(
        id: 'r2',
        name: 'n',
        method: 'POST',
        url: 'https://x.test/api?a=1',
        headers: const [
          DebugHeader(name: 'Content-Type', value: 'application/json'),
          DebugHeader(name: 'X-A', value: 'b'),
        ],
        cookies: const [DebugCookie(name: 'sid', value: 'x')],
        body: '{"q":"w"}',
        bodyKind: DebugBodyKind.json,
      );
      final back = parseCurl(toCurl(req));
      expect(back.isSuccess, isTrue, reason: back.error);
      final r = back.request!;
      expect(r.method, req.method);
      expect(r.url, req.url);
      expect(r.body, req.body);
      expect(r.bodyKind, req.bodyKind);
      expect(r.headers.map((h) => '${h.name}:${h.value}').toList(),
          req.headers.map((h) => '${h.name}:${h.value}').toList());
      expect(r.cookies.map((c) => '${c.name}=${c.value}').toList(),
          req.cookies.map((c) => '${c.name}=${c.value}').toList());
    });
  });

  group('往返等价（parse → toCurl → parse）', () {
    void roundTrip(String curl) {
      final first = parseCurl(curl);
      expect(first.isSuccess, isTrue, reason: first.error);
      final second = parseCurl(toCurl(first.request!));
      expect(second.isSuccess, isTrue, reason: second.error);
      final a = first.request!;
      final b = second.request!;
      expect(b.method, a.method);
      expect(b.url, a.url);
      expect(b.body, a.body);
      expect(b.bodyKind, a.bodyKind);
      expect(
        b.headers.map((h) => '${h.name}:${h.value}').toList(),
        a.headers.map((h) => '${h.name}:${h.value}').toList(),
      );
      expect(
        b.cookies.map((c) => '${c.name}=${c.value}').toList(),
        a.cookies.map((c) => '${c.name}=${c.value}').toList(),
      );
    }

    test('GET + 多 header', () {
      roundTrip(
        "curl 'https://api.example.com/x' -H 'Accept: application/json' "
        "-H 'X-Trace: 1'",
      );
    });

    test('POST JSON', () {
      roundTrip(
        "curl -X POST 'https://api.example.com/x' "
        "-H 'Content-Type: application/json' -d '{\"a\":[1,2]}'",
      );
    });

    test('表单 + cookie', () {
      roundTrip(
        "curl 'https://api.example.com/x' "
        "-H 'Content-Type: application/x-www-form-urlencoded' "
        "-b 'sid=abc; theme=dark' -d 'u=1&p=2'",
      );
    });

    test('转义内容', () {
      roundTrip(
        "curl -X POST 'https://api.example.com/x' "
        "-H 'Content-Type: application/json' -d '{\"msg\":\"it'\\''s\"}'",
      );
    });

    test('multipart', () {
      roundTrip("curl 'https://x.test/u' -F 'file=a.txt' -F 'n=1'");
    });
  });
}
