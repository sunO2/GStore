/// AppConfig URL 白名单 / host 校验回归测试（Todo 9）。
///
/// 覆盖：GitHub 资产 host 通过、子域通过、欺骗性 host（点边界绕过）拒绝、
/// 协议规则、畸形输入不抛异常、`enableUrlValidation` 短路、`UrlValidator` 一致性。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/security/UrlValidator.dart';

void main() {
  late AppConfig config;
  late bool originalEnableUrlValidation;

  setUp(() {
    // AppConfig() 是进程级单例：记录并强制开启校验，tearDown 恢复。
    config = AppConfig();
    originalEnableUrlValidation = config.enableUrlValidation;
    config.enableUrlValidation = true;
  });

  tearDown(() {
    config.enableUrlValidation = originalEnableUrlValidation;
  });

  group('AppConfig.isValidUrl — 白名单 host 通过', () {
    const passUrls = <String>[
      'https://objects.githubusercontent.com/x',
      'https://release-assets.githubusercontent.com/x',
      'https://api.github.com/x',
      'https://github.com/x',
      'https://github.com/sunO2/GStore/releases/download/v1/modules.json',
      // 子域（点边界）应命中 github.com
      'https://foo.github.com/x',
      // 既有渠道 host
      'https://h5-api.appstore.vivo.com.cn/detailInfo',
      'https://f-droid.org/repo/index-v2.jar',
      'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo/x',
      // 仅 host，无 path
      'https://api.github.com',
      'https://github.com',
    ];

    for (final url in passUrls) {
      test('通过: $url', () {
        expect(config.isValidUrl(url), isTrue, reason: '应通过: $url');
      });
    }
  });

  group('AppConfig.isValidUrl — 欺骗/越界 host 拒绝（关键回归）', () {
    const rejectUrls = <String>[
      // 点边界绕过：旧实现 host.contains('github.com') 会放行
      'https://github.com.evil.com/x',
      'https://github.com.evil.com',
      // 子串后缀：旧实现 host.contains('github.com') 会放行
      'https://evilgithub.com/x',
      'https://notgithub.com/x',
      'https://xgithub.com',
      // api 后缀欺骗（点边界失效场景）
      'https://api.github.com.evil.com/x',
      // 资产域欺骗
      'https://objects.githubusercontent.com.evil.com/x',
      'https://release-assets.githubusercontent.com.evil.com/x',
      'https://evil-objects.githubusercontent.com/x',
      // 其他渠道欺骗
      'https://f-droid.org.evil.com/x',
      'https://h5-api.appstore.vivo.com.cn.evil.com/x',
      'https://mirrors.tuna.tsinghua.edu.cn.evil.com/x',
      // 完全无关域
      'https://evil.com/x',
      'https://evil.com',
    ];

    for (final url in rejectUrls) {
      test('拒绝: $url', () {
        // 显式断言 false：若匹配器过宽（contains / 前缀）此测试即失败。
        expect(config.isValidUrl(url), isFalse, reason: '必须拒绝: $url');
      });
    }
  });

  group('AppConfig.isValidUrl — 协议规则', () {
    test('不在 allowedProtocols 的 scheme 拒绝: ftp', () {
      expect(config.isValidUrl('ftp://api.github.com/x'), isFalse);
    });

    test('无 scheme 的相对路径拒绝', () {
      expect(config.isValidUrl('relative/path'), isFalse);
      expect(config.isValidUrl('/relative/path'), isFalse);
      expect(config.isValidUrl('github.com'), isFalse);
    });

    // 基线语义为 https-only：历史白名单是完整 `https://` 前缀，`url.startsWith`
    // 使任何 http URL 都无法命中。此处显式断言 http 被拒，**不得**放宽到 http。
    test('http + 白名单 host 拒绝（https-only 基线语义）', () {
      expect(config.isValidUrl('http://api.github.com/x'), isFalse);
      expect(config.isValidUrl('http://github.com/x'), isFalse);
      expect(config.isValidUrl('http://mirrors.tuna.tsinghua.edu.cn/x'), isFalse);
      expect(
        config.isValidUrl('http://h5-api.appstore.vivo.com.cn/x'),
        isFalse,
      );
      expect(
        config.isValidUrl('http://objects.githubusercontent.com/x'),
        isFalse,
      );
      expect(
        config.isValidUrl('http://release-assets.githubusercontent.com/x'),
        isFalse,
      );
    });

    test('http + 欺骗 host 拒绝（协议与 host 双重拒绝）', () {
      expect(config.isValidUrl('http://github.com.evil.com/x'), isFalse);
      expect(config.isValidUrl('http://evilgithub.com/x'), isFalse);
    });
  });

  group('AppConfig.isValidUrl — 畸形输入（不抛异常且 false）', () {
    const malformed = <String>[
      '',
      'not a url',
      '   ',
      '://',
      'https://',
      'https:///path-only',
      'javascript:alert(1)',
      'data:text/plain,hi',
    ];

    for (final input in malformed) {
      test('畸形输入安全处理: ${input.isEmpty ? '<empty>' : input}', () {
        expect(() => config.isValidUrl(input), returnsNormally);
        expect(config.isValidUrl(input), isFalse);
      });
    }

    test('unicode host 不抛异常且拒绝', () {
      const unicodeUrl = 'https://例え.github.com.evil.com/';
      expect(() => config.isValidUrl(unicodeUrl), returnsNormally);
      expect(config.isValidUrl(unicodeUrl), isFalse);
    });
  });

  group('AppConfig.isValidUrl — enableUrlValidation 短路', () {
    test('false 时任意 URL 通过（含恶意）', () {
      config.enableUrlValidation = false;
      expect(config.isValidUrl('https://evil.com/x'), isTrue);
      expect(config.isValidUrl('not a url'), isTrue);
    });

    test('恢复 true 后校验重新生效', () {
      config.enableUrlValidation = false;
      expect(config.isValidUrl('https://evil.com/x'), isTrue);

      config.enableUrlValidation = true;
      expect(config.isValidUrl('https://evil.com/x'), isFalse);
      expect(config.isValidUrl('https://github.com/x'), isTrue);
    });
  });

  group('AppConfig.isWhitelistedHost — 点边界语义', () {
    test('精确 host 与子域命中', () {
      expect(AppConfig.isWhitelistedHost('github.com'), isTrue);
      expect(AppConfig.isWhitelistedHost('foo.github.com'), isTrue);
      expect(AppConfig.isWhitelistedHost('a.b.github.com'), isTrue);
      expect(
        AppConfig.isWhitelistedHost('release-assets.githubusercontent.com'),
        isTrue,
      );
    });

    test('大小写归一化', () {
      expect(AppConfig.isWhitelistedHost('GitHub.COM'), isTrue);
      expect(AppConfig.isWhitelistedHost('API.GITHUB.COM'), isTrue);
    });

    test('无点边界/子串/空串拒绝', () {
      expect(AppConfig.isWhitelistedHost('github.com.evil.com'), isFalse);
      expect(AppConfig.isWhitelistedHost('evilgithub.com'), isFalse);
      expect(AppConfig.isWhitelistedHost('notgithub.com'), isFalse);
      expect(AppConfig.isWhitelistedHost(''), isFalse);
    });
  });

  group('UrlValidator — 与 AppConfig 白名单口径一致', () {
    late UrlValidator validator;

    setUp(() {
      validator = UrlValidator();
    });

    test('白名单 host 通过', () {
      final result = validator.validate('https://objects.githubusercontent.com/x');
      expect(result.isValid, isTrue, reason: result.errorMessage);
    });

    test('欺骗 host 拒绝', () {
      expect(validator.validate('https://github.com.evil.com/x').isValid, isFalse);
      expect(validator.validate('https://evilgithub.com/x').isValid, isFalse);
      expect(validator.validate('https://api.github.com.evil.com/x').isValid, isFalse);
    });

    test('非白名单 host 拒绝', () {
      expect(validator.validate('https://evil.com/x').isValid, isFalse);
    });

    test('http:// 白名单 host 拒绝并给出 HTTPS 提示（基线语义）', () {
      for (final url in <String>[
        'http://api.github.com/x',
        'http://github.com/x',
        'http://mirrors.tuna.tsinghua.edu.cn/x',
        'http://h5-api.appstore.vivo.com.cn/x',
      ]) {
        final result = validator.validate(url);
        expect(result.isValid, isFalse, reason: '必须拒绝: $url');
        expect(result.errorMessage, contains('HTTPS'), reason: url);
      }
    });
  });
}
