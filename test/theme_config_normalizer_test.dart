import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/theme/theme_config_normalizer.dart';

void main() {
  const expectedBlue = Color(0xFF1976D2);

  group('ThemeConfigNormalizer.parse', () {
    test('接受 FF1976D2 并自动开启自定义颜色', () {
      final config = ThemeConfigNormalizer.parse(
        <String, dynamic>{'primaryColor': 'FF1976D2'},
      );

      expect(config, isNotNull);
      expect(config!.useCustomColors, isTrue);
      expect(config.primaryColor, expectedBlue);
    });

    test('接受 #1976D2', () {
      final config = ThemeConfigNormalizer.parse(
        <String, dynamic>{'primaryColor': '#1976D2'},
      );

      expect(config!.primaryColor, expectedBlue);
      expect(config.useCustomColors, isTrue);
    });

    test('接受 0xFF1976D2', () {
      final config = ThemeConfigNormalizer.parse(
        <String, dynamic>{'primaryColor': '0xFF1976D2'},
      );

      expect(config!.primaryColor, expectedBlue);
    });

    test('接受 6 位 1976D2 并补全 FF alpha', () {
      final config = ThemeConfigNormalizer.parse(
        <String, dynamic>{'primaryColor': '1976D2'},
      );

      expect(config!.primaryColor, expectedBlue);
    });

    test('接受 JSON 字符串形式', () {
      final config = ThemeConfigNormalizer.parse(
        '{"primaryColor":"FF1976D2"}',
      );

      expect(config!.primaryColor, expectedBlue);
      expect(config.useCustomColors, isTrue);
    });

    test('接受双重编码 JSON 字符串', () {
      final doubleEncoded = jsonEncode(
        jsonEncode(<String, dynamic>{'primaryColor': 'FF1976D2'}),
      );

      final config = ThemeConfigNormalizer.parse(doubleEncoded);

      expect(config!.primaryColor, expectedBlue);
    });
  });

  group('ThemeConfigNormalizer.parse 非法输入', () {
    test('非法枚举索引返回 null', () {
      expect(
        ThemeConfigNormalizer.parse(<String, dynamic>{'fontStyle': 99}),
        isNull,
      );
    });

    test('非 JSON 字符串返回 null', () {
      expect(ThemeConfigNormalizer.parse('not-json'), isNull);
    });

    test('List 返回 null', () {
      expect(ThemeConfigNormalizer.parse(<Object?>[]), isNull);
    });

    test('空字符串返回 null', () {
      expect(ThemeConfigNormalizer.parse(''), isNull);
    });
  });

  group('ThemeConfigNormalizer.normalizeJson', () {
    test('显式 useCustomColors:false 保持不变', () {
      final normalized = ThemeConfigNormalizer.normalizeJson(
        <String, dynamic>{
          'useCustomColors': false,
          'primaryColor': '#1976D2',
        },
      );

      expect(normalized['useCustomColors'], isFalse);
    });

    test('所有颜色统一输出 8 位 ARGB 十六进制且不修改入参', () {
      final input = <String, dynamic>{
        'seedColor': '#1976D2',
        'primaryColor': '0xFF1976D2',
        'secondaryColor': '1976D2',
        'tertiaryColor': 0xFF1976D2,
      };

      final normalized = ThemeConfigNormalizer.normalizeJson(input);

      expect(normalized['seedColor'], 'FF1976D2');
      expect(normalized['primaryColor'], 'FF1976D2');
      expect(normalized['secondaryColor'], 'FF1976D2');
      expect(normalized['tertiaryColor'], 'FF1976D2');
      expect(normalized['useCustomColors'], isTrue);

      // 入参不被修改。
      expect(input['seedColor'], '#1976D2');
      expect(input['primaryColor'], '0xFF1976D2');
      expect(input['secondaryColor'], '1976D2');
      expect(input.containsKey('useCustomColors'), isFalse);
    });
  });

  group('颜色编解码', () {
    test('toArgbHex / parseArgb 往返', () {
      for (final argb in <int>[0xFF1976D2, 0x80123456, 0xFFFFFFFF]) {
        final hex = ThemeConfigNormalizer.toArgbHex(argb);
        expect(hex, isNotNull);
        expect(ThemeConfigNormalizer.parseArgb(hex), argb);
        expect(ThemeConfigNormalizer.parseArgb('0x$hex'), argb);
        expect(ThemeConfigNormalizer.parseArgb('#$hex'), argb);
      }
    });

    test('6 位 int 视为 RRGGBB 并补全 FF alpha', () {
      expect(ThemeConfigNormalizer.parseArgb(0x1976D2), 0xFF1976D2);
      expect(ThemeConfigNormalizer.toArgbHex(0x1976D2), 'FF1976D2');
    });

    test('非法颜色返回 null', () {
      expect(ThemeConfigNormalizer.parseArgb('nope'), isNull);
      expect(ThemeConfigNormalizer.parseArgb('#12345'), isNull);
      expect(ThemeConfigNormalizer.parseArgb(-1), isNull);
      expect(ThemeConfigNormalizer.toArgbHex(null), isNull);
    });
  });
}
