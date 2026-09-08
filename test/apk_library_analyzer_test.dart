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

/// DEX 规则（type=5）合成器
NativeLibraryRule _dexRule(String name, String label, {bool regex = false}) =>
    NativeLibraryRule(
      name: name,
      label: label,
      type: 5,
      isRegexRule: regex,
    );

/// 组件规则（type=1/2/3/4）合成器
NativeLibraryRule _componentRule(
  String name,
  String label, {
  int type = 2,
  bool regex = false,
}) =>
    NativeLibraryRule(
      name: name,
      label: label,
      type: type,
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

  group('dexScanPatterns', () {
    test('非正则包名规则 → 点边界前缀模式', () {
      final patterns = ApkLibraryAnalyzer.dexScanPatterns([
        _dexRule('androidx.lifecycle', 'AndroidX Lifecycle'),
        _dexRule('com.tencent.smtt', '腾讯 X5'),
      ]);
      expect(patterns, [
        'androidx.lifecycle.*',
        'com.tencent.smtt.*',
      ]);
    });

    test('正则规则 → 提取字面量前缀', () {
      final patterns = ApkLibraryAnalyzer.dexScanPatterns([
        _dexRule(r'kotlin\.(.*)', 'Kotlin', regex: true),
        _dexRule(r'io\.flutter\.(.*)', 'Flutter Engine', regex: true),
        _dexRule(r'kotlin\.coroutines\.(.*)', 'Kotlin Coroutines', regex: true),
      ]);
      expect(patterns, ['io.flutter.*', 'kotlin.*', 'kotlin.coroutines.*']);
    });

    test('已以 * 结尾的规则名保持原样，结果去重排序', () {
      final patterns = ApkLibraryAnalyzer.dexScanPatterns([
        _dexRule('com.z.b*', 'Z'),
        _dexRule('com.z.b*', 'Z 重复'),
        _dexRule('androidx.appcompat', 'AppCompat'),
      ]);
      expect(patterns, ['androidx.appcompat.*', 'com.z.b*']);
    });
  });

  group('matchDexClassNames', () {
    test('包名命名空间规则命中（点边界前缀）', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {'androidx.lifecycle.LiveData', 'androidx.lifecycle.ViewModel'},
        rules: [_dexRule('androidx.lifecycle', 'AndroidX Lifecycle')],
      );
      expect(hits, hasLength(1));
      expect(hits.first.label, 'AndroidX Lifecycle');
      expect(hits.first.ruleName, 'androidx.lifecycle');
      expect(hits.first.matchedClassName, 'androidx.lifecycle.LiveData');
      expect(hits.first.isRegex, isFalse);
    });

    test('点边界：包名下无点不命中（防止前缀粘连）', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {'androidx.lifecycleExtra', 'androidx.lifecyclex.Oops'},
        rules: [_dexRule('androidx.lifecycle', 'AndroidX Lifecycle')],
      );
      expect(hits, isEmpty);
    });

    test('* 规则：去掉 * 前缀匹配', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {'com.foo.Bar', 'com.foobar.Baz'},
        rules: [_dexRule('com.foo.*', 'Foobar 库')],
      );
      expect(hits, hasLength(1));
      expect(hits.first.matchedClassName, 'com.foo.Bar');
    });

    test('正则规则：整串匹配（子串不命中）', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {
          'kotlin.jvm.functions.Function1',
          'kotlinx.coroutines.CoroutineScope', // kotlin\. 要求 kotlin 后紧跟 '.'
          'my.app.KotlinHelper',
        },
        rules: [_dexRule(r'kotlin\.(.*)', 'Kotlin', regex: true)],
      );
      expect(hits, hasLength(1));
      expect(hits.first.isRegex, isTrue);
      expect(hits.first.matchedClassName, 'kotlin.jvm.functions.Function1');
    });

    test('同一类名命中多条规则，按规则名去重', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {'androidx.core.view.ViewCompat'},
        rules: [
          _dexRule('androidx.core', 'AndroidX Core'),
          _dexRule('androidx.core.view', 'AndroidX Core View'),
          _dexRule(r'androidx\.(.*)', 'AndroidX 全部', regex: true),
        ],
      );
      expect(hits, hasLength(3));
      expect(
        hits.map((h) => h.ruleName).toSet(),
        {'androidx.core', 'androidx.core.view', r'androidx\.(.*)'},
      );
    });

    test('结果按 label 排序', () {
      final hits = ApkLibraryAnalyzer.matchDexClassNames(
        {'z.pkg.ZClass', 'a.pkg.AClass'},
        rules: [
          _dexRule('z.pkg', 'Z 库'),
          _dexRule('a.pkg', 'A 库'),
        ],
      );
      expect(hits.map((h) => h.label).toList(), ['A 库', 'Z 库']);
    });
  });

  group('analyzeDexLibraries', () {
    tearDown(() {
      ApkLibraryAnalyzer.instance.debugSetDexRules(null);
    });

    test('无法调用 Rust 时优雅降级为空列表（不抛异常）', () async {
      ApkLibraryAnalyzer.instance.debugSetDexRules([
        _dexRule('androidx.lifecycle', 'AndroidX Lifecycle'),
      ]);
      final apk = await _buildFakeApk(['classes.dex', 'AndroidManifest.xml']);
      // 测试环境无 Rust 原生库（libfdroid_repo.so 为 Android ABI），
      // RustLib.init 失败 → analyzeDexLibraries 捕获并返回空列表。
      final hits = await ApkLibraryAnalyzer.instance.analyzeDexLibraries(apk);
      expect(hits, isEmpty);
      final hits2 = await ApkLibraryAnalyzer.instance.analyzeDexLibraries(apk);
      expect(identical(hits, hits2), isTrue); // 缓存已写入（空结果同样缓存）
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      ApkLibraryAnalyzer.instance.debugSetDexRules([
        _dexRule('androidx.lifecycle', 'AndroidX Lifecycle'),
      ]);
      final hits = await ApkLibraryAnalyzer.instance
          .analyzeDexLibraries('/no/such/file.apk');
      expect(hits, isEmpty);
    });

    test('无 DEX 规则 → 直接空列表，不触发 Rust', () async {
      final hits = await ApkLibraryAnalyzer.instance
          .analyzeDexLibraries('/no/such/file.apk');
      expect(hits, isEmpty);
    });
  });

  group('matchComponentNames', () {
    test('精确规则命中（同类型）', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {2: {'com.tencent.midas.wx.APMidasWXPayActivity'}},
        rules: [
          _componentRule('com.tencent.midas.wx.APMidasWXPayActivity', '米大师'),
        ],
      );
      expect(hits, hasLength(1));
      expect(hits.first.componentName, 'com.tencent.midas.wx.APMidasWXPayActivity');
      expect(hits.first.componentType, 2);
      expect(hits.first.label, '米大师');
      expect(hits.first.isRegex, isFalse);
    });

    test('类型过滤：不同类型不互配', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {1: {'com.xiaomi.mipush.sdk.MessageHandleService'}},
        rules: [
          // 同名但 type=2（ACTIVITY）的规则，不应命中 type=1（SERVICE）组件
          _componentRule('com.xiaomi.mipush.sdk.MessageHandleService', 'MiPush', type: 2),
        ],
      );
      expect(hits, isEmpty);
    });

    test('正则规则整串匹配（同类型）', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {1: {'com.bytedance.sdk.openadsdk.core.X'}},
        rules: [
          _componentRule(r'com\.bytedance\.sdk\.openadsdk\.(.*)', 'Pangle SDK', type: 1, regex: true),
        ],
      );
      expect(hits, hasLength(1));
      expect(hits.first.label, 'Pangle SDK');
      expect(hits.first.isRegex, isTrue);
    });

    test('正则规则要求整串匹配（子串不命中）', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {1: {'com.bytedance.other.app.Y'}},
        rules: [
          _componentRule(r'com\.bytedance\.sdk\.(.*)', 'Pangle SDK', type: 1, regex: true),
        ],
      );
      expect(hits, isEmpty);
    });

    test('按（类型,规则名）去重：同名同类型去重，跨类型保留', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {
          1: {'com.example.Comp'},
          2: {'com.example.Comp'},
        },
        rules: [
          _componentRule('com.example.Comp', '库A', type: 1),
          _componentRule('com.example.Comp', '库A重复', type: 1),
          _componentRule('com.example.Comp', '库A活动', type: 2),
        ],
      );
      // 同（类型,规则名）合并为一条；跨类型（SERVICE/ACTIVITY）各保留一条
      expect(hits, hasLength(2));
      expect(
        hits.map((h) => '${h.componentType}:${h.ruleName}').toSet(),
        {'1:com.example.Comp', '2:com.example.Comp'},
      );
    });

    test('结果按 label 排序', () {
      final hits = ApkLibraryAnalyzer.matchComponentNames(
        {
          1: {'com.z.ServiceZ'},
          2: {'com.a.ActivityA'},
        },
        rules: [
          _componentRule('com.z.ServiceZ', 'Z 库', type: 1),
          _componentRule('com.a.ActivityA', 'A 库', type: 2),
        ],
      );
      expect(hits.map((h) => h.label).toList(), ['A 库', 'Z 库']);
    });
  });

  group('listNativeAbis', () {
    test('枚举 lib/<abi> 目录并按常见优先级排序', () async {
      final apk = await _buildFakeApk([
        'lib/armeabi-v7a/libx.so',
        'lib/x86_64/liby.so',
        'lib/arm64-v8a/libz.so',
        'lib/arm64-v8a/libw.so',
        'assets/nope/x.so',
      ]);
      final abis = await ApkLibraryAnalyzer.instance.listNativeAbis(apk);
      expect(abis, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
    });

    test('无原生库 → 空列表', () async {
      final apk = await _buildFakeApk(['classes.dex', 'AndroidManifest.xml']);
      final abis = await ApkLibraryAnalyzer.instance.listNativeAbis(apk);
      expect(abis, isEmpty);
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      final abis =
          await ApkLibraryAnalyzer.instance.listNativeAbis('/no/such/file.apk');
      expect(abis, isEmpty);
    });
  });

  group('analyzeNativeLibsFull', () {
    tearDown(() {
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null);
    });

    test('注入 2 个 ABI（2/1 个 so），验证分组与大小透传', () async {
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs([
        const NativeAbiLibs(abi: 'arm64-v8a', soFiles: [
          NativeSoFile(name: 'libc.so', size: 1048576),
          NativeSoFile(name: 'liba.so', size: 524288),
        ]),
        const NativeAbiLibs(abi: 'x86', soFiles: [
          NativeSoFile(name: 'libd.so', size: 4096),
        ]),
      ]);
      final libs =
          await ApkLibraryAnalyzer.instance.analyzeNativeLibsFull('/fake/apk.apk');
      expect(libs, hasLength(2));
      expect(libs[0].abi, 'arm64-v8a');
      expect(libs[0].soFiles.map((f) => f.name).toList(), ['libc.so', 'liba.so']);
      expect(libs[0].soFiles.map((f) => f.size).toList(), [1048576, 524288]);
      expect(libs[1].abi, 'x86');
      expect(libs[1].soFiles.map((f) => f.name).toList(), ['libd.so']);
      expect(libs[1].soFiles.map((f) => f.size).toList(), [4096]);
    });

    test('注入后传 null 恢复真实扫描路径', () async {
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs([
        const NativeAbiLibs(abi: 'arm64-v8a', soFiles: [
          NativeSoFile(name: 'libfake.so', size: 42),
        ]),
      ]);
      final injected =
          await ApkLibraryAnalyzer.instance.analyzeNativeLibsFull('/fake/apk.apk');
      expect(injected, hasLength(1));
      expect(injected.first.soFiles.map((f) => f.name).toList(), ['libfake.so']);
      expect(injected.first.soFiles.map((f) => f.size).toList(), [42]);

      // 恢复真实路径后走真实 zip 解压扫描
      ApkLibraryAnalyzer.instance.debugSetFullNativeLibs(null);
      final apk = await _buildFakeApk([
        'lib/armeabi-v7a/libx.so',
        'lib/x86_64/liby.so',
        'lib/arm64-v8a/libz.so',
        'lib/arm64-v8a/liba.so',
        'assets/nope/x.so',
      ]);
      final libs = await ApkLibraryAnalyzer.instance.analyzeNativeLibsFull(apk);
      expect(libs, hasLength(3));
      expect(libs[0].abi, 'arm64-v8a');
      // 组内按文件名字母序：liba.so 在 libz.so 前
      expect(libs[0].soFiles.map((f) => f.name).toList(), ['liba.so', 'libz.so']);
      // 每个 .so 条目按 4 字节内容写入 → 解压后大小即 4 B
      expect(libs[0].soFiles.map((f) => f.size).toList(), [4, 4]);
      expect(libs[1].abi, 'armeabi-v7a');
      expect(libs[1].soFiles.map((f) => f.name).toList(), ['libx.so']);
      expect(libs[1].soFiles.map((f) => f.size).toList(), [4]);
      expect(libs[2].abi, 'x86_64');
      expect(libs[2].soFiles.map((f) => f.name).toList(), ['liby.so']);
      expect(libs[2].soFiles.map((f) => f.size).toList(), [4]);
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      final libs =
          await ApkLibraryAnalyzer.instance.analyzeNativeLibsFull('/no/such/file.apk');
      expect(libs, isEmpty);
    });
  });

  group('analyzeDexFilesFull', () {
    tearDown(() {
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull(null);
    });

    test('注入 2 个 DEX 文件，验证名字与大小透传', () async {
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull([
        const DexFile(name: 'classes.dex', size: 1048576),
        const DexFile(name: 'classes2.dex', size: 524288),
      ]);
      final files = await ApkLibraryAnalyzer.instance.analyzeDexFilesFull('/fake/apk.apk');
      expect(files, hasLength(2));
      expect(files[0].name, 'classes.dex');
      expect(files[0].size, 1048576);
      expect(files[1].name, 'classes2.dex');
      expect(files[1].size, 524288);
    });

    test('注入后传 null 恢复真实扫描路径', () async {
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull([
        const DexFile(name: 'classes.dex', size: 42),
      ]);
      final injected =
          await ApkLibraryAnalyzer.instance.analyzeDexFilesFull('/fake/apk.apk');
      expect(injected, hasLength(1));
      expect(injected.first.name, 'classes.dex');
      expect(injected.first.size, 42);

      // 恢复真实路径后走真实 zip 解压扫描
      ApkLibraryAnalyzer.instance.debugSetDexFilesFull(null);
      final apk = await _buildFakeApk([
        'classes.dex',
        'classes2.dex',
        'assets/classes3.dex', // 非根目录分包也应枚举
        'classes.dex.bak', // 非精确 classes*.dex 名，不应枚举
        'AndroidManifest.xml',
        'lib/arm64-v8a/libx.so',
      ]);
      final files = await ApkLibraryAnalyzer.instance.analyzeDexFilesFull(apk);
      expect(files, hasLength(3));
      expect(files.map((f) => f.name).toList(), ['classes.dex', 'classes2.dex', 'classes3.dex']);
      // 每个 DEX 条目按 4 字节内容写入 → 解压后大小即 4 B
      expect(files.map((f) => f.size).toList(), [4, 4, 4]);
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      final files =
          await ApkLibraryAnalyzer.instance.analyzeDexFilesFull('/no/such/file.apk');
      expect(files, isEmpty);
    });
  });

  group('analyzeComponents', () {
    tearDown(() {
      ApkLibraryAnalyzer.instance.debugSetComponentRules(null);
    });

    test('无法调用 Rust 时优雅降级为空列表（不抛异常）', () async {
      ApkLibraryAnalyzer.instance.debugSetComponentRules([
        _componentRule('com.xiaomi.mipush.sdk.MessageHandleService', 'MiPush', type: 1),
      ]);
      final apk = await _buildFakeApk(['classes.dex', 'AndroidManifest.xml']);
      // 测试环境无 Rust 原生库（libfdroid_repo.so 为 Android ABI），
      // RustLib.init 失败 → analyzeComponents 捕获并返回空列表。
      final hits = await ApkLibraryAnalyzer.instance.analyzeComponents(apk);
      expect(hits, isEmpty);
      final hits2 = await ApkLibraryAnalyzer.instance.analyzeComponents(apk);
      expect(identical(hits, hits2), isTrue); // 缓存已写入（空结果同样缓存）
    });

    test('文件不存在 → 空列表且不抛异常', () async {
      ApkLibraryAnalyzer.instance.debugSetComponentRules([
        _componentRule('com.xiaomi.mipush.sdk.MessageHandleService', 'MiPush', type: 1),
      ]);
      final hits = await ApkLibraryAnalyzer.instance
          .analyzeComponents('/no/such/file.apk');
      expect(hits, isEmpty);
    });

    test('无组件规则 → 直接空列表，不触发 Rust', () async {
      final hits = await ApkLibraryAnalyzer.instance
          .analyzeComponents('/no/such/file.apk');
      expect(hits, isEmpty);
    });
  });
}
