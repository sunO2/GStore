import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';

NativeLibraryRule _rule(String name, String label, {bool regex = false}) =>
    NativeLibraryRule(
      name: name,
      label: label,
      type: 0,
      isRegexRule: regex,
    );

/// 生成包含指定条目的假 APK（zip）
Future<String> _buildFakeApk(List<String> entries) async {
  final dir = await Directory.systemTemp.createTemp('gstore_apk_test');
  final path = '${dir.path}/fake.apk';
  final archive = Archive();
  for (final name in entries) {
    archive.addFile(ArchiveFile(name, 4, [1, 2, 3, 4]));
  }
  final bytes = ZipEncoder().encode(archive)!;
  await File(path).writeAsBytes(bytes);
  return path;
}

void main() {
  group('matchNativeSoNames', () {
    test('精确规则命中', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libxguardian.so'},
        rules: [_rule('libxguardian.so', '信鸽推送')],
      );
      expect(hits, hasLength(1));
      expect(hits.first.soFileName, 'libxguardian.so');
      expect(hits.first.ruleName, 'libxguardian.so');
      expect(hits.first.label, '信鸽推送');
      expect(hits.first.isRegex, isFalse);
    });

    test('精确规则未命中返回空', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libunrelated.so'},
        rules: [_rule('libxguardian.so', '信鸽推送')],
      );
      expect(hits, isEmpty);
    });

    test('正则规则命中（整串匹配）', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libAMapSDK_MAP_v6.9.0.so'},
        rules: [_rule(r'libAMapSDK_MAP_v(.*)\.so', '高德地图 SDK', regex: true)],
      );
      expect(hits, hasLength(1));
      expect(hits.first.label, '高德地图 SDK');
      expect(hits.first.isRegex, isTrue);
    });

    test('正则规则要求整串匹配（前后缀不命中）', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libAMapSDK_MAP_v1.so.part'},
        rules: [_rule(r'libAMapSDK_MAP_v(.*)\.so', '高德地图 SDK', regex: true)],
      );
      expect(hits, isEmpty);
    });

    test('同一 .so 可同时命中精确与正则，去重后保留', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libjcore1.2.3.so'},
        rules: [
          _rule(r'libjcore(.*)\.so', '极光推送', regex: true),
          _rule(r'libjcore(.*)\.so', '极光推送', regex: true),
        ],
      );
      expect(hits, hasLength(1));
      expect(hits.first.label, '极光推送');
    });

    test('结果按 label 排序', () {
      final hits = ApkLibraryAnalyzer.matchNativeSoNames(
        {'libz.so', 'liba.so'},
        rules: [
          _rule('libz.so', 'Z 库'),
          _rule('liba.so', 'A 库'),
        ],
      );
      expect(hits.map((h) => h.label).toList(), ['A 库', 'Z 库']);
    });
  });

  group('analyzeNativeLibraries', () {
    tearDown(() {
      ApkLibraryAnalyzer.instance.debugSetRules(null);
    });

    test('枚举 lib/<abi>/*.so 并命中注入规则', () async {
      ApkLibraryAnalyzer.instance.debugSetRules([
        _rule('libfakeguard.so', '假守卫'),
      ]);
      final apk = await _buildFakeApk([
        'lib/arm64-v8a/libfakeguard.so',
        'lib/armeabi-v7a/libfakeguard.so',
        'lib/arm64-v8a/libunknown.so',
        'assets/not_a_lib.so', // 非 lib/ 前缀，不应枚举
        'META-INF/MANIFEST.MF',
      ]);
      final hits = await ApkLibraryAnalyzer.instance.analyzeNativeLibraries(apk);
      expect(hits, hasLength(1));
      expect(hits.first.label, '假守卫');
      expect(hits.first.soFileName, 'libfakeguard.so');
    });

    test('正则规则命中假 APK', () async {
      ApkLibraryAnalyzer.instance.debugSetRules([
        _rule(r'libamap_v(.*)\.so', '地图 SDK', regex: true),
      ]);
      final apk = await _buildFakeApk(['lib/x86_64/libamap_v8.1.0.so']);
      final hits = await ApkLibraryAnalyzer.instance.analyzeNativeLibraries(apk);
      expect(hits, hasLength(1));
      expect(hits.first.label, '地图 SDK');
    });

    test('同一路径重复分析命中缓存', () async {
      ApkLibraryAnalyzer.instance.debugSetRules([
        _rule('libfakeguard.so', '假守卫'),
      ]);
      final apk = await _buildFakeApk(['lib/arm64-v8a/libfakeguard.so']);
      final first = await ApkLibraryAnalyzer.instance.analyzeNativeLibraries(apk);
      final second = await ApkLibraryAnalyzer.instance.analyzeNativeLibraries(apk);
      expect(identical(first, second), isTrue);
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      ApkLibraryAnalyzer.instance.debugSetRules([
        _rule('libfakeguard.so', '假守卫'),
      ]);
      final hits =
          await ApkLibraryAnalyzer.instance.analyzeNativeLibraries('/no/such/file.apk');
      expect(hits, isEmpty);
    });

    test('非 zip 文件 → 空列表且不抛异常', () async {
      ApkLibraryAnalyzer.instance.debugSetRules([
        _rule('libfakeguard.so', '假守卫'),
      ]);
      final dir = await Directory.systemTemp.createTemp('gstore_apk_test');
      final path = '${dir.path}/notzip.apk';
      await File(path).writeAsString('not a zip file at all');
      final hits = await ApkLibraryAnalyzer.instance.analyzeNativeLibraries(path);
      expect(hits, isEmpty);
    });
  });
}
