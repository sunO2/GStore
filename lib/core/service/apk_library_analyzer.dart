import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';

/// 规则记录（LibChecker rules.db 行；NATIVE/DEX 规则 JSON 结构一致）。
/// 生成自 rules_native.json（type=0）或 rules_dex.json（type=5）。
class NativeLibraryRule {
  /// 规则名：isRegexRule=0 时为精确 .so 文件名 / DEX 点分包名；
  /// isRegexRule=1 时为正则表达式（Kotlin Pattern.matches 语义，整串匹配）
  final String name;

  /// 展示名（如「高德地图 SDK」）
  final String label;

  /// 规则类型（LibChecker LibType，NATIVE=0 / DEX=5）
  final int type;

  /// 是否为正则规则
  final bool isRegexRule;

  NativeLibraryRule({
    required this.name,
    required this.label,
    required this.type,
    required this.isRegexRule,
  });

  factory NativeLibraryRule.fromJson(Map<String, dynamic> json) {
    return NativeLibraryRule(
      name: (json['name'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      type: (json['type'] as int?) ?? 0,
      isRegexRule: (json['isRegexRule'] as int? ?? 0) == 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'type': type,
        'isRegexRule': isRegexRule ? 1 : 0,
      };
}

/// 库命中统一接口（native / dex 共用，供 UI 合并展示）
abstract class LibraryHit {
  /// 展示名（如「高德地图 SDK」「AndroidX Lifecycle」）
  String get label;

  /// 是否由正则规则命中
  bool get isRegex;
}

/// 一次原生库命中（一个 .so 名匹配到一条规则）
class NativeLibraryHit implements LibraryHit {
  /// 实际匹配到的 .so 文件名（如 libamapv0676.so）
  final String soFileName;

  /// 命中的规则名
  final String ruleName;

  /// 展示名
  @override
  final String label;

  /// 是否由正则规则命中
  @override
  final bool isRegex;

  const NativeLibraryHit({
    required this.soFileName,
    required this.ruleName,
    required this.label,
    required this.isRegex,
  });

  @override
  bool operator ==(Object other) =>
      other is NativeLibraryHit &&
      other.soFileName == soFileName &&
      other.ruleName == ruleName;

  @override
  int get hashCode => Object.hash(soFileName, ruleName);

  @override
  String toString() => 'NativeLibraryHit($soFileName -> $label)';
}

/// 一次 DEX 类名命中（一个类名匹配到一条 type=5 DEX 规则）
class DexLibraryHit implements LibraryHit {
  /// 实际匹配到的点分类名（如 androidx.lifecycle.LiveData）
  final String matchedClassName;

  /// 命中的规则名（点分包名，如 androidx.lifecycle）
  final String ruleName;

  /// 展示名
  @override
  final String label;

  /// 是否由正则规则命中
  @override
  final bool isRegex;

  const DexLibraryHit({
    required this.matchedClassName,
    required this.ruleName,
    required this.label,
    required this.isRegex,
  });

  @override
  bool operator ==(Object other) =>
      other is DexLibraryHit &&
      other.matchedClassName == matchedClassName &&
      other.ruleName == ruleName;

  @override
  int get hashCode => Object.hash(matchedClassName, ruleName);

  @override
  String toString() => 'DexLibraryHit($matchedClassName -> $label)';
}

/// 一次组件命中（一个组件完整类名匹配到一条 type=1/2/3/4 组件规则）
class ComponentLibraryHit implements LibraryHit {
  /// 实际匹配到的组件完整类名（如 com.xiaomi.mipush.sdk.MessageHandleService）
  final String componentName;

  /// 组件类型（LibChecker LibType：SERVICE=1 / ACTIVITY=2 / RECEIVER=3 / PROVIDER=4）
  final int componentType;

  /// 命中的规则名（规则 name 列：精确类名或正则表达式）
  final String ruleName;

  /// 展示名
  @override
  final String label;

  /// 是否由正则规则命中
  @override
  final bool isRegex;

  const ComponentLibraryHit({
    required this.componentName,
    required this.componentType,
    required this.ruleName,
    required this.label,
    required this.isRegex,
  });

  @override
  bool operator ==(Object other) =>
      other is ComponentLibraryHit &&
      other.componentType == componentType &&
      other.componentName == componentName &&
      other.ruleName == ruleName;

  @override
  int get hashCode => Object.hash(componentType, componentName, ruleName);

  @override
  String toString() => 'ComponentLibraryHit(type=$componentType, $componentName -> $label)';
}

/// 单一原生库 .so 文件：文件名 + zip 解压后字节数（LibChecker 风格展示）
class NativeSoFile {
  const NativeSoFile({required this.name, required this.size});

  /// .so 文件名（如 libcrypto.so）
  final String name;

  /// zip 解压后字节数（uncompressed size）
  final int size;
}

/// ===== LibChecker 特殊原生库伴随验证（requiresNativeLibValidation）=====
///
/// 某些 .so 文件名**过于通用**（或代表框架/加固壳），仅凭文件名命中规则会误报：
/// 例如任何应用都可能有 `libapp.so`，但只有真正 Flutter 应用才附带 `io.flutter.FlutterInjector`。
/// LibChecker 对以下 4 组特殊 .so 做二次验证（对齐 `RulesRepository` 的
/// NATIVE_SET_* / CLASS_PATTERNS_* / hasCompanionNativeLibValidation）：

/// 360 加固壳 .so（需配套 com.qihoo.util.* / com.tianyu.util.* 类佐证）
const Set<String> _nativeSetQihoo = {
  'libjiagu.so',
  'libjiagu_a64.so',
  'libjiagu_x86.so',
  'libjiagu_x64.so',
};

/// SecNeo 加固壳 .so（需配套 com.secneo.apkwrapper.* 类佐证）
const Set<String> _nativeSetSecneo = {
  'libDexHelper.so',
  'libDexHelper-x86.so',
  'libdexjni.so',
};

/// Flutter 引擎 .so（有 libflutter.so 伴生则直接通过；否则需 io.flutter.FlutterInjector）
const Set<String> _nativeSetFlutter = {'libapp.so'};

/// Unity 引擎 .so（**必须**有 libunity.so 伴生才命中，否则排除）
const Set<String> _nativeSetUnity = {'libmain.so'};

/// 上述 4 组特殊 .so 的并集（凡命中此集合的规则都需要伴随验证）
const Set<String> _nativeAllSpecial = {
  ..._nativeSetQihoo,
  ..._nativeSetSecneo,
  ..._nativeSetFlutter,
  ..._nativeSetUnity,
};

/// 360 加固类佐证 pattern（以 * 结尾 = 前缀匹配，对齐 Rust scanDexClasses 语义）
const List<String> _classPatternsQihoo = ['com.qihoo.util.*', 'com.tianyu.util.*'];

/// SecNeo 加固类佐证 pattern
const List<String> _classPatternsSecneo = ['com.secneo.apkwrapper.*'];

/// Flutter 类佐证 pattern
const List<String> _classPatternsFlutter = ['io.flutter.FlutterInjector'];

/// 一个 ABI 下的全部原生库 .so 文件（LibChecker 风格展示）
class NativeAbiLibs {
  const NativeAbiLibs({required this.abi, required this.soFiles});

  /// ABI 目录名（如 arm64-v8a）
  final String abi;

  /// 该 ABI 下的 .so 文件（按文件名字母序排序；含解压后字节数）
  final List<NativeSoFile> soFiles;
}

/// 单个 DEX 文件：文件名 + zip 解压后字节数（LibChecker 风格展示）
class DexFile {
  const DexFile({required this.name, required this.size});

  /// DEX 文件名（如 classes.dex / classes2.dex）
  final String name;

  /// zip 解压后字节数（uncompressed size）
  final int size;
}

/// 一次构建版本检测结果（Kotlin / Gradle / Java；空串表示未知/未检测到）
class BuildVersionInfo {
  const BuildVersionInfo({
    this.kotlinVersion = '',
    this.gradleVersion = '',
    this.javaVersion = '',
  });

  /// Kotlin 版本（如 '2.0.20'；kotlin_module 降级推断时为 '2.0.x' 形式）
  final String kotlinVersion;

  /// Gradle 版本（如 '8.7'）
  final String gradleVersion;

  /// Java 编译目标版本（如 '17'）
  final String javaVersion;

  @override
  bool operator ==(Object other) =>
      other is BuildVersionInfo &&
      other.kotlinVersion == kotlinVersion &&
      other.gradleVersion == gradleVersion &&
      other.javaVersion == javaVersion;

  @override
  int get hashCode => Object.hash(kotlinVersion, gradleVersion, javaVersion);

  @override
  String toString() =>
      'BuildVersionInfo(kotlin=$kotlinVersion, gradle=$gradleVersion, java=$javaVersion)';
}

/// APK 内嵌第三方库检测
///
/// - 方案 A（纯 Dart）：解压 APK 枚举 lib/<abi>/*.so 文件名，
///   与 LibChecker 规则库（assets/lcrules/rules_native.json，type=0）匹配。
/// - 方案 B（Rust FFI）：扫描 classes*.dex 类名，与 LibChecker DEX 规则库
///   （assets/lcrules/rules_dex.json，type=5）匹配；Rust 不可用时优雅降级为空。
/// - 方案 C（Rust FFI）：解析 AndroidManifest.xml 组件名，与 LibChecker 组件
///   规则库（assets/lcrules/rules_component.json，type=1/2/3/4）匹配；
///   同时提供 listNativeAbis 供「详细信息」展示 ABI。
class ApkLibraryAnalyzer {
  ApkLibraryAnalyzer._();

  static final ApkLibraryAnalyzer instance = ApkLibraryAnalyzer._();

  /// 原生库规则资源路径
  static const String assetPath = 'assets/lcrules/rules_native.json';

  /// DEX 类名规则资源路径
  static const String dexAssetPath = 'assets/lcrules/rules_dex.json';

  /// 组件规则资源路径（type=1 SERVICE / 2 ACTIVITY / 3 RECEIVER / 4 PROVIDER）
  static const String componentAssetPath = 'assets/lcrules/rules_component.json';

  /// APK 路径 → 原生库命中结果缓存（同路径重复分析直接返回）
  final Map<String, List<NativeLibraryHit>> _cache = {};

  /// APK 路径 → DEX 命中结果缓存
  final Map<String, List<DexLibraryHit>> _dexCache = {};

  /// APK 路径 → 组件命中结果缓存
  final Map<String, List<ComponentLibraryHit>> _componentCache = {};

  /// APK 路径 → ABI 列表缓存
  final Map<String, List<String>> _abiCache = {};

  /// APK 路径 → 全量原生库（按 ABI 分组）缓存
  final Map<String, List<NativeAbiLibs>> _fullCache = {};

  /// APK 路径 → 全量 DEX 文件列表缓存
  final Map<String, List<DexFile>> _dexFullCache = {};

  /// APK 路径 → 构建版本检测结果缓存
  final Map<String, BuildVersionInfo> _buildVersionCache = {};

  /// 测试用：注入的合成 ABI 列表（非 null 时跳过真实扫描）
  List<String>? _debugAbis;

  /// 测试用：注入的合成全量原生库（非 null 时跳过真实扫描）
  List<NativeAbiLibs>? _debugFullNativeLibs;

  /// 测试用：注入的合成全量 DEX 文件列表（非 null 时跳过真实扫描）
  List<DexFile>? _debugDexFull;

  /// 测试用：注入的合成构建版本结果（非 null 时跳过真实检测）
  BuildVersionInfo? _debugBuildVersions;

  /// 已加载原生库规则（懒加载缓存；测试注入覆盖）
  List<NativeLibraryRule>? _rules;

  /// 已加载 DEX 规则
  List<NativeLibraryRule>? _dexRules;

  /// 已加载组件规则
  List<NativeLibraryRule>? _componentRules;

  /// 测试用：注入合成原生库规则，跳过真实资产读取。
  /// 传 null 恢复默认资产加载。
  @visibleForTesting
  void debugSetRules(List<NativeLibraryRule>? rules) {
    _rules = rules;
    _cache.clear();
  }

  /// 测试用：注入合成 DEX 规则。
  @visibleForTesting
  void debugSetDexRules(List<NativeLibraryRule>? rules) {
    _dexRules = rules;
    _dexCache.clear();
  }

  /// 测试用：注入合成组件规则。
  @visibleForTesting
  void debugSetComponentRules(List<NativeLibraryRule>? rules) {
    _componentRules = rules;
    _componentCache.clear();
  }

  /// 测试用：注入合成 ABI 列表，跳过 isolate 解压扫描。
  /// 传 null 恢复真实扫描。
  @visibleForTesting
  void debugSetAbis(List<String>? abis) {
    _debugAbis = abis;
    _abiCache.clear();
  }

  /// 测试用：注入合成全量原生库列表，跳过 isolate 解压扫描。
  /// 传 null 恢复真实扫描。
  @visibleForTesting
  void debugSetFullNativeLibs(List<NativeAbiLibs>? libs) {
    _debugFullNativeLibs = libs;
    _fullCache.clear();
  }

  /// 测试用：注入合成全量 DEX 文件列表，跳过 isolate 解压扫描。
  /// 传 null 恢复真实扫描。
  @visibleForTesting
  void debugSetDexFilesFull(List<DexFile>? files) {
    _debugDexFull = files;
    _dexFullCache.clear();
  }

  /// 测试用：注入合成构建版本结果，跳过 isolate 解压检测。
  /// 传 null 恢复真实检测。
  @visibleForTesting
  void debugSetBuildVersions(BuildVersionInfo? info) {
    _debugBuildVersions = info;
    _buildVersionCache.clear();
  }

  /// 加载规则（首次从资产读取并缓存）
  Future<List<NativeLibraryRule>> _loadRules() async {
    var rules = _rules;
    if (rules != null) return rules;
    try {
      final raw = await rootBundle.loadString(assetPath);
      final list = jsonDecode(raw) as List<dynamic>;
      rules = list
          .map((e) => NativeLibraryRule.fromJson(e as Map<String, dynamic>))
          .toList();
      _rules = rules;
      appLog.info('ApkLibraryAnalyzer: 已加载原生库规则 ${rules.length} 条');
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 加载规则失败 - $e');
      rules = const [];
    }
    return rules;
  }

  /// 加载 DEX 类名规则（首次从资产读取并缓存）
  Future<List<NativeLibraryRule>> _loadDexRules() async {
    var rules = _dexRules;
    if (rules != null) return rules;
    try {
      final raw = await rootBundle.loadString(dexAssetPath);
      final list = jsonDecode(raw) as List<dynamic>;
      rules = list
          .map((e) => NativeLibraryRule.fromJson(e as Map<String, dynamic>))
          .toList();
      _dexRules = rules;
      appLog.info('ApkLibraryAnalyzer: 已加载 DEX 规则 ${rules.length} 条');
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 加载规则失败 - $e');
      rules = const [];
    }
    return rules;
  }

  /// 加载组件规则（type=1/2/3/4，首次从资产读取并缓存）
  Future<List<NativeLibraryRule>> _loadComponentRules() async {
    var rules = _componentRules;
    if (rules != null) return rules;
    try {
      final raw = await rootBundle.loadString(componentAssetPath);
      final list = jsonDecode(raw) as List<dynamic>;
      rules = list
          .map((e) => NativeLibraryRule.fromJson(e as Map<String, dynamic>))
          .toList();
      _componentRules = rules;
      appLog.info('ApkLibraryAnalyzer: 已加载组件规则 ${rules.length} 条');
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 加载组件规则失败 - $e');
      rules = const [];
    }
    return rules;
  }

  /// 分析 APK 内嵌的第三方原生库。
  ///
  /// 优雅失败：文件缺失/非 zip/规则缺失 → 返回空列表，绝不抛给调用方。
  /// 已分析过的路径直接返回缓存。
  Future<List<NativeLibraryHit>> analyzeNativeLibraries(String apkPath) async {
    final cached = _cache[apkPath];
    if (cached != null) return cached;

    final rules = await _loadRules();
    if (rules.isEmpty) return const [];

    try {
      // 规则已序列化为 JSON 字符串传入 isolate（List<Object> 可跨 isolate 传递，
      // 但避免传 1491 个对象的深拷贝；JSON 字符串更轻且稳定）
      final rulesJson = jsonEncode(rules.map((r) => r.toJson()).toList());
      final result = await compute(
        _analyzeInIsolate,
        (apkPath: apkPath, rulesJson: rulesJson),
      );
      var hits = result.hits;
      // 伴随验证：Flutter/Unity/360/SecNeo 等特殊 .so 仅凭文件名命中会误报，
      // 对齐 LibChecker 需二次验证（伴生 .so 或 DEX 类佐证，见 _validateSpecialSo）。
      hits = await _applySpecialSoValidation(
        apkPath: apkPath,
        hits: hits,
        allSoNames: result.allSoNames,
      );
      _cache[apkPath] = hits;
      appLog.info('ApkLibraryAnalyzer: $apkPath 命中 ${hits.length} 条规则');
      return hits;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 分析 APK 失败 - $e');
      return const [];
    }
  }

  /// 特殊 .so 伴随验证（对齐 LibChecker RulesRepository.checkNativeLibValidations）：
  /// 命中 [_nativeAllSpecial] 的规则必须通过验证才保留——
  /// ① Flutter(libapp.so)：有 libflutter.so 伴生 → 直接通过；否则需
  ///    io.flutter.FlutterInjector 类佐证；
  /// ② Unity(libmain.so)：有 libunity.so 伴生 → 通过；无伴生 → **排除**；
  /// ③ 360(libjiagu*)：需 com.qihoo.util.* / com.tianyu.util.* 类佐证；
  /// ④ SecNeo(libDexHelper*)：需 com.secneo.apkwrapper.* 类佐证。
  /// 需类佐证时调用 Rust scanDexClasses 检查 APK DEX（扫描失败 → 保留原命中，
  /// 避免误杀；类命中 → 通过）。
  Future<List<NativeLibraryHit>> _applySpecialSoValidation({
    required String apkPath,
    required List<NativeLibraryHit> hits,
    required List<String> allSoNames,
  }) async {
    // 无特殊 .so 命中 → 快速返回
    final specialHits =
        hits.where((h) => _nativeAllSpecial.contains(h.soFileName)).toList();
    if (specialHits.isEmpty) return hits;

    // 收集需要类佐证的模式
    final patterns = <String>{};
    for (final hit in specialHits) {
      final so = hit.soFileName;
      if (_nativeSetQihoo.contains(so)) patterns.addAll(_classPatternsQihoo);
      if (_nativeSetSecneo.contains(so)) patterns.addAll(_classPatternsSecneo);
      if (_nativeSetFlutter.contains(so)) patterns.addAll(_classPatternsFlutter);
    }

    // Rust 类扫描（失败 → 空集合，调用方据此保留原命中避免误杀）
    final foundSet = patterns.isEmpty
        ? <String>{}
        : await _scanDexClassesSafe(apkPath, patterns.toList());

    return applySpecialSoValidation(
      hits: hits,
      allSoNames: allSoNames,
      foundClasses: foundSet,
    );
  }

  /// 特殊 .so 验证决策（纯函数，可单测）：返回过滤后的命中列表。
  ///
  /// 对齐 LibChecker requiresNativeLibValidation 语义：
  /// - 非特殊 .so → 保留
  /// - Flutter/Unity：有伴生库（libflutter/libunity）→ 保留
  /// - Unity 无伴生 → 拒绝
  /// - 360/SecNeo/Flutter 无伴生：类佐证命中任一 pattern → 保留，否则拒绝
  @visibleForTesting
  static List<NativeLibraryHit> applySpecialSoValidation({
    required List<NativeLibraryHit> hits,
    required List<String> allSoNames,
    required Set<String> foundClasses,
  }) {
    return [
      for (final hit in hits)
        if (!_specialSoRejected(
          hit.soFileName,
          allSoNames,
          foundClasses,
        ))
          hit,
    ];
  }

  /// 调用 Rust scanDexClasses 扫描类佐证（失败返回空集合，调用方据此保留原命中）
  Future<Set<String>> _scanDexClassesSafe(String apkPath, List<String> patterns) async {
    try {
      final found = await FdroidRustRepoManager.scanDexClasses(apkPath, patterns);
      return found.toSet();
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 特殊 so 类佐证扫描失败（保留命中） - $e');
      return const {};
    }
  }

  /// 判断某特殊 so 命中是否被拒绝（对齐 LibChecker hasCompanionNativeLibValidation）：
  /// - 非特殊 so → 不拒绝
  /// - Flutter(libapp.so)：有 libflutter.so 伴生 → 不拒绝；否则需 io.flutter.FlutterInjector
  /// - Unity(libmain.so)：有 libunity.so 伴生 → 不拒绝；无伴生 → **拒绝**
  /// - 360(libjiagu*) / SecNeo(libDexHelper*)：需对应类佐证，类命中 → 不拒绝
  static bool _specialSoRejected(
    String so,
    List<String> allSoNames,
    Set<String> foundClasses,
  ) {
    if (!_nativeAllSpecial.contains(so)) return false;
    if (_nativeSetFlutter.contains(so)) {
      // Flutter：libflutter.so 伴生（LibChecker hasCompanionNativeLibValidation）
      if (allSoNames.contains('libflutter.so')) return false;
      // 或 io.flutter.FlutterInjector 类佐证
      return !_patternMatchesAny(foundClasses, _classPatternsFlutter.first);
    }
    if (_nativeSetUnity.contains(so)) {
      // Unity：libunity.so 伴生才通过；无伴生恒拒绝（无类佐证可依）
      return !allSoNames.contains('libunity.so');
    }
    if (_nativeSetQihoo.contains(so)) {
      return !_patternsHitAny(foundClasses, _classPatternsQihoo);
    }
    if (_nativeSetSecneo.contains(so)) {
      return !_patternsHitAny(foundClasses, _classPatternsSecneo);
    }
    return false;
  }

  /// 任一 pattern 命中任一类名（前缀 `*` 语义 + 精确）
  static bool _patternsHitAny(Set<String> classNames, List<String> patterns) =>
      patterns.any((p) => _patternMatchesAny(classNames, p));

  /// pattern（`pkg.*` 前缀语义，对齐 Rust scanDexClasses）是否命中任一已扫类名
  static bool _patternMatchesAny(Set<String> classNames, String pattern) {
    if (pattern.endsWith('*')) {
      final prefix = pattern.substring(0, pattern.length - 1);
      return classNames.any((c) => c.startsWith(prefix));
    }
    return classNames.contains(pattern);
  }

  /// 分析多个 APK 源（base + split APK）的第三方原生库命中并合并去重。
  ///
  /// split APK 分发时 SDK 库可能位于 split_config.*.apk，单独读 base 会漏；
  /// 对每个源调用 [analyzeNativeLibraries] 后按（soFileName, ruleName）去重。
  Future<List<NativeLibraryHit>> analyzeNativeLibrariesFromDirs(
      List<String> apkPaths) async {
    final seen = <String>{};
    final hits = <NativeLibraryHit>[];
    for (final path in apkPaths) {
      final pathHits = await analyzeNativeLibraries(path);
      for (final hit in pathHits) {
        final key = '${hit.soFileName}|${hit.ruleName}';
        if (seen.add(key)) hits.add(hit);
      }
    }
    return hits;
  }
  ///
  /// 匹配策略（对齐 LibChecker RulesRepository.getRulesWithRegex）：
  /// - isRegexRule=0：精确匹配规则名（.so 文件名）
  /// - isRegexRule=1：规则名为正则，整串匹配（Kotlin Pattern.matches 语义）
  /// - 同一 .so 可能命中多条规则；按规则名去重后按 label 排序
  @visibleForTesting
  static List<NativeLibraryHit> matchNativeSoNames(
    Set<String> soNames, {
    required List<NativeLibraryRule> rules,
  }) {
    // 精确规则索引
    final exactRules = <String, NativeLibraryRule>{
      for (final r in rules)
        if (!r.isRegexRule && r.name.isNotEmpty) r.name: r,
    };
    // 正则规则（编译一次，整串匹配）
    final regexRules = <(RegExp, NativeLibraryRule)>[
      for (final r in rules)
        if (r.isRegexRule && r.name.isNotEmpty)
          (RegExp('^(?:${r.name})\$'), r),
    ];

    final hitsByRule = <String, NativeLibraryHit>{};
    for (final soName in soNames) {
      // 先精确
      final exact = exactRules[soName];
      if (exact != null) {
        hitsByRule.putIfAbsent(
          exact.name,
          () => NativeLibraryHit(
            soFileName: soName,
            ruleName: exact.name,
            label: exact.label,
            isRegex: false,
          ),
        );
      }
      // 再正则
      for (final (regex, rule) in regexRules) {
        if (regex.hasMatch(soName)) {
          hitsByRule.putIfAbsent(
            rule.name,
            () => NativeLibraryHit(
              soFileName: soName,
              ruleName: rule.name,
              label: rule.label,
              isRegex: true,
            ),
          );
        }
      }
    }

    final hits = hitsByRule.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return hits;
  }

  /// 分析 APK 内嵌 DEX 类命中（方案 B，Rust FFI 扫描）。
  ///
  /// 流程：加载 DEX 规则 → 推导 Rust 扫描模式 → 调用
  /// FdroidRustRepoManager.scanDexClasses 拿到命中的点分类名 → 映射回规则命中。
  /// 优雅失败：Rust 库缺失/解析失败/路径不存在 → 返回空列表，DEX 检测仅作增强。
  /// 已分析过的路径直接返回缓存。
  Future<List<DexLibraryHit>> analyzeDexLibraries(String apkPath) async {
    final cached = _dexCache[apkPath];
    if (cached != null) return cached;

    final rules = await _loadDexRules();
    if (rules.isEmpty) return const [];

    final patterns = dexScanPatterns(rules);
    if (patterns.isEmpty) return const [];

    try {
      final matched =
          await FdroidRustRepoManager.scanDexClasses(apkPath, patterns);
      final hits = matchDexClassNames(matched.toSet(), rules: rules);
      _dexCache[apkPath] = hits;
      appLog.info('ApkLibraryAnalyzer: $apkPath DEX 命中 ${hits.length} 条规则');
      return hits;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: DEX 分析失败（降级为空） - $e');
      return const [];
    }
  }

  /// 由 DEX 规则推导 Rust 扫描模式（LibChecker matchesClassPattern 语义）。
  ///
  /// - 正则规则（如 `kotlin\.(.*)`）：提取字面部名前缀 → `kotlin.*`
  /// - 非正则规则（点分包名，如 `androidx.lifecycle`）：
  ///   - 规则名已以 `*` 结尾 → 原样（`pkg.*`）
  ///   - 否则补 `.*` → `androidx.lifecycle.*`（点边界前缀）
  /// 去重后按字母序返回。
  @visibleForTesting
  static List<String> dexScanPatterns(List<NativeLibraryRule> rules) {
    final patterns = <String>{};
    for (final rule in rules) {
      if (rule.name.isEmpty) continue;
      if (rule.isRegexRule) {
        final prefix = _regexLiteralPrefix(rule.name);
        if (prefix != null) patterns.add('$prefix*');
      } else if (rule.name.endsWith('*')) {
        patterns.add(rule.name);
      } else {
        patterns.add('${rule.name}.*');
      }
    }
    return patterns.toList()..sort();
  }

  /// 纯函数：点分类名集合 × DEX 规则列表 → 命中列表（可单元测试）。
  ///
  /// 匹配策略（对齐 LibChecker DEX 规则 + matchesClassPattern）：
  /// - isRegexRule=1：规则名为正则，整串匹配（Kotlin Pattern.matches 语义）
  /// - 规则名以 `*` 结尾：前缀匹配（去掉 `*`）
  /// - 其余（点分包名）：整串相等或处于 `{name}.` 命名空间（点边界前缀）
  /// 同一类名可能命中多条规则；按规则名去重后按 label 排序。
  @visibleForTesting
  static List<DexLibraryHit> matchDexClassNames(
    Set<String> classNames, {
    required List<NativeLibraryRule> rules,
  }) {
    final regexRules = <(RegExp, NativeLibraryRule)>[
      for (final r in rules)
        if (r.isRegexRule && r.name.isNotEmpty)
          (RegExp('^(?:${r.name})\$'), r),
    ];
    final prefixRules = <(String, NativeLibraryRule)>[
      for (final r in rules)
        if (!r.isRegexRule && r.name.endsWith('*') && r.name.isNotEmpty)
          (r.name.substring(0, r.name.length - 1), r),
    ];
    final namespaceRules = <(String, NativeLibraryRule)>[
      for (final r in rules)
        if (!r.isRegexRule && !r.name.endsWith('*') && r.name.isNotEmpty)
          ('${r.name}.', r),
    ];

    final hitsByRule = <String, DexLibraryHit>{};
    for (final className in classNames) {
      for (final (regex, rule) in regexRules) {
        if (regex.hasMatch(className)) _putDexHit(hitsByRule, rule, className);
      }
      for (final (prefix, rule) in prefixRules) {
        if (className.startsWith(prefix)) {
          _putDexHit(hitsByRule, rule, className);
        }
      }
      for (final (namespace, rule) in namespaceRules) {
        if (className == rule.name || className.startsWith(namespace)) {
          _putDexHit(hitsByRule, rule, className);
        }
      }
    }

    final hits = hitsByRule.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return hits;
  }

  static void _putDexHit(
    Map<String, DexLibraryHit> hitsByRule,
    NativeLibraryRule rule,
    String className,
  ) {
    hitsByRule.putIfAbsent(
      rule.name,
      () => DexLibraryHit(
        matchedClassName: className,
        ruleName: rule.name,
        label: rule.label,
        isRegex: rule.isRegexRule,
      ),
    );
  }

  /// 分析 APK 的 Manifest 组件命中（方案 C，Rust FFI 解析 AXML）。
  ///
  /// 流程：加载组件规则 → FdroidRustRepoManager.parseComponents 拿到四类组件名
  /// → matchComponentNames 映射命中。优雅失败：Rust 库缺失/解析失败/路径不存在
  /// → 返回空列表，组件检测仅作增强。已分析过的路径直接返回缓存。
  Future<List<ComponentLibraryHit>> analyzeComponents(String apkPath) async {
    final cached = _componentCache[apkPath];
    if (cached != null) return cached;

    final rules = await _loadComponentRules();
    if (rules.isEmpty) return const [];

    try {
      final components = await FdroidRustRepoManager.parseComponents(apkPath);
      final namesByType = <int, Set<String>>{
        1: components.services.toSet(),
        2: components.activities.toSet(),
        3: components.receivers.toSet(),
        4: components.providers.toSet(),
      };
      final hits = matchComponentNames(namesByType, rules: rules);
      _componentCache[apkPath] = hits;
      appLog.info('ApkLibraryAnalyzer: $apkPath 组件命中 ${hits.length} 条规则');
      return hits;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 组件分析失败（降级为空） - $e');
      return const [];
    }
  }

  /// 纯函数：组件类型→类名集合 × 组件规则列表 → 命中列表（可单元测试）。
  ///
  /// 匹配策略（对齐 LibChecker RuleStore.findRule(name, type, useRegex=true)）：
  /// - 先精确：name == rule.name（所有规则均入精确索引，含正则规则）
  /// - 未命中再对 isRegexRule=1 规则整串匹配（Kotlin Pattern.matches 语义）
  /// - 规则按组件类型（type 字段）过滤，不同类型互不匹配
  /// 同一组件名可命中多条规则；按（类型, 规则名）去重后按 label 排序。
  @visibleForTesting
  static List<ComponentLibraryHit> matchComponentNames(
    Map<int, Set<String>> namesByType, {
    required List<NativeLibraryRule> rules,
  }) {
    final rulesByType = <int, List<NativeLibraryRule>>{};
    for (final rule in rules) {
      rulesByType.putIfAbsent(rule.type, () => []).add(rule);
    }

    final hitsByRule = <String, ComponentLibraryHit>{};
    for (final entry in namesByType.entries) {
      final type = entry.key;
      final typeRules = rulesByType[type];
      if (typeRules == null || typeRules.isEmpty) continue;

      final exactRules = <String, NativeLibraryRule>{
        for (final r in typeRules)
          if (r.name.isNotEmpty) r.name: r,
      };
      final regexRules = <(RegExp, NativeLibraryRule)>[
        for (final r in typeRules)
          if (r.isRegexRule && r.name.isNotEmpty)
            (RegExp('^(?:${r.name})\$'), r),
      ];

      for (final name in entry.value) {
        final exact = exactRules[name];
        if (exact != null) {
          _putComponentHit(hitsByRule, exact, name, type);
        }
        for (final (regex, rule) in regexRules) {
          if (regex.hasMatch(name)) {
            _putComponentHit(hitsByRule, rule, name, type);
          }
        }
      }
    }

    final hits = hitsByRule.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return hits;
  }

  static void _putComponentHit(
    Map<String, ComponentLibraryHit> hitsByRule,
    NativeLibraryRule rule,
    String componentName,
    int componentType,
  ) {
    hitsByRule.putIfAbsent(
      '$componentType:${rule.name}',
      () => ComponentLibraryHit(
        componentName: componentName,
        componentType: componentType,
        ruleName: rule.name,
        label: rule.label,
        isRegex: rule.isRegexRule,
      ),
    );
  }

  /// 枚举 APK 内 lib/<abi>/ 目录（原生库 ABI 架构），按常见优先级排序。
  ///
  /// 复用 isolate 解压扫描（与 analyzeNativeLibraries 同一套 zip 读取）；
  /// 失败 → 空列表。已分析过的路径直接返回缓存。
  Future<List<String>> listNativeAbis(String apkPath) async {
    final debug = _debugAbis;
    if (debug != null) return debug;
    final cached = _abiCache[apkPath];
    if (cached != null) return cached;

    try {
      final abis = await compute(_listAbisInIsolate, apkPath);
      _abiCache[apkPath] = abis;
      appLog.info('ApkLibraryAnalyzer: $apkPath ABI: $abis');
      return abis;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 枚举 ABI 失败 - $e');
      return const [];
    }
  }

  /// 枚举 APK 内全部原生库（lib/<abi>/*.so），按 ABI 分组（LibChecker 风格）。
  ///
  /// 与 analyzeNativeLibraries 的规则命中不同：这里返回 APK 内**每个** .so 文件
  /// （文件名 + zip 解压后字节数，见 [NativeSoFile]），按 ABI 目录分组；
  /// ABI 排序与 listNativeAbis 一致，各 ABI 内文件名按字母序。
  /// 失败 → 空列表。已分析过的路径直接返回缓存。
  Future<List<NativeAbiLibs>> analyzeNativeLibsFull(String apkPath) async {
    final debug = _debugFullNativeLibs;
    if (debug != null) return debug;
    final cached = _fullCache[apkPath];
    if (cached != null) return cached;

    try {
      final libs = await compute(_listFullNativeLibsInIsolate, apkPath);
      _fullCache[apkPath] = libs;
      appLog.info(
        'ApkLibraryAnalyzer: $apkPath 全量原生库: '
        '${libs.map((l) => '${l.abi}(${l.soFiles.length})').join(', ')}',
      );
      return libs;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 枚举全量原生库失败 - $e');
      return const [];
    }
  }

  /// 枚举多个 APK 源（base + split APK）的全部原生库并按 ABI 合并去重。
  ///
  /// split APK 分发时原生库位于 split_config.*.apk 中，单独读 base 会漏掉；
  /// 本方法对每个源调用 [analyzeNativeLibsFull] 后合并（同名同 ABI 去重）。
  /// 同时纳入 `assets/*.so`（LibChecker getApkLibEntryDir 同样匹配 assets 前缀），
  /// 归入名为 `assets` 的分组。
  Future<List<NativeAbiLibs>> analyzeNativeLibsFullFromDirs(
      List<String> apkPaths) async {
    final debug = _debugFullNativeLibs;
    final merged = <String, Map<String, NativeSoFile>>{};
    for (final path in apkPaths) {
      final libs = await analyzeNativeLibsFull(path);
      for (final group in libs) {
        merged.putIfAbsent(group.abi, () => {});
        for (final so in group.soFiles) {
          merged[group.abi]![so.name] = so;
        }
      }
      // seam 注入时跳过 assets 解压扫描：注入值即完整输出（含 assets 分组），
      // 避免 FakeAsync 测试环境里 compute isolate 永不完成。
      if (debug == null) {
        final assets = await _listAssetsSo(path);
        if (assets != null) {
          merged.putIfAbsent('assets', () => {});
          for (final so in assets) {
            merged['assets']![so.name] = so;
          }
        }
      }
    }
    return _sortedAbiGroups(merged);
  }

  /// 枚举单个 APK 内 `assets/*.so`（LibChecker 将 assets 下的 .so 单列分组）。
  /// 失败 → null（调用方忽略该源）。
  Future<List<NativeSoFile>?> _listAssetsSo(String apkPath) async {
    try {
      return await compute(_listAssetsSoInIsolate, apkPath);
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 枚举 assets .so 失败 - $e');
      return null;
    }
  }

  /// 将「ABI → 文件表」按常见 ABI 优先级排序输出（assets 分组排最后）。
  static List<NativeAbiLibs> _sortedAbiGroups(
      Map<String, Map<String, NativeSoFile>> merged) {
    const priority = [
      'arm64-v8a',
      'armeabi-v7a',
      'x86_64',
      'x86',
      'armeabi',
      'mips64',
      'mips',
    ];
    final list = <NativeAbiLibs>[
      for (final entry in merged.entries)
        NativeAbiLibs(
          abi: entry.key,
          soFiles: entry.value.values.toList()
            ..sort((a, b) => a.name.compareTo(b.name)),
        ),
    ]..sort((a, b) {
        if (a.abi == 'assets' && b.abi != 'assets') return 1;
        if (b.abi == 'assets' && a.abi != 'assets') return -1;
        final ia = priority.indexOf(a.abi);
        final ib = priority.indexOf(b.abi);
        final oa = ia < 0 ? priority.length : ia;
        final ob = ib < 0 ? priority.length : ib;
        return oa != ob ? oa.compareTo(ob) : a.abi.compareTo(b.abi);
      });
    return list;
  }
  ///
  /// 匹配 zip 内所有名称形如 `classes\d*\.dex` 的条目（忽略大小写，
  /// 含分包 classes2.dex / classes3.dex …），记录文件名与解压后字节数，
  /// 按文件名字母序返回。失败 → 空列表。已分析过的路径直接返回缓存。
  Future<List<DexFile>> analyzeDexFilesFull(String apkPath) async {
    final debug = _debugDexFull;
    if (debug != null) return debug;
    final cached = _dexFullCache[apkPath];
    if (cached != null) return cached;

    try {
      final files = await compute(_listDexFilesInIsolate, apkPath);
      _dexFullCache[apkPath] = files;
      appLog.info('ApkLibraryAnalyzer: $apkPath 全量 DEX: '
          '${files.map((f) => '${f.name}(${f.size})').join(', ')}');
      return files;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 枚举全量 DEX 失败 - $e');
      return const [];
    }
  }

  /// 检测 APK 的构建版本（Kotlin / Gradle / Java）。
  ///
  /// 主路径：解析根目录 `kotlin-tooling-metadata.json`（Kotlin Gradle Plugin
  /// 2.0+ 生成），规则对齐 LibChecker KotlinBuildMetadataDetector；
  /// kotlinVersion 未解析出时降级扫描 `META-INF/*.kotlin_module` 二进制版本推断。
  /// 任一字段未知 → 空串。优雅失败：文件缺失/非 zip/解析失败 → 全部空串，
  /// 绝不抛给调用方。已检测过的路径直接返回缓存。
  Future<BuildVersionInfo> detectBuildVersions(String apkPath) async {
    final debug = _debugBuildVersions;
    if (debug != null) return debug;
    final cached = _buildVersionCache[apkPath];
    if (cached != null) return cached;

    try {
      final info = await compute(_detectBuildVersionsInIsolate, apkPath);
      _buildVersionCache[apkPath] = info;
      appLog.info('ApkLibraryAnalyzer: $apkPath 构建信息: '
          'Kotlin=${info.kotlinVersion}, Gradle=${info.gradleVersion}, '
          'Java=${info.javaVersion}');
      return info;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 检测构建信息失败 - $e');
      return const BuildVersionInfo();
    }
  }

  /// 从正则规则名提取字面量包名前缀（如 `kotlin\.coroutines\.(.*)` → `kotlin.coroutines.`）。
  /// 规则库中 DEX 正则均形如 `pkg\d\.pkg\.(...)`；解析失败返回 null（跳过该规则）。
  static String? _regexLiteralPrefix(String regexName) {
    if (regexName.isEmpty) return null;
    final literal = regexName.split('(').first.replaceAll(r'\.', '.');
    if (literal.isEmpty) return null;
    return literal.endsWith('.') ? literal : '$literal.';
  }
}

/// compute isolate 入参
typedef _AnalyzeRequest = ({String apkPath, String rulesJson});

/// isolate 内执行：读取 APK 字节 → 解压枚举 lib/*/*.so → 匹配规则。
/// 返回 (命中列表, 全部 .so 文件名)——全部 so 名供主 isolate 做伴随验证
///（Flutter/Unity 等特殊库需判断伴生 .so 是否存在）。
({List<NativeLibraryHit> hits, List<String> allSoNames}) _analyzeInIsolate(
    _AnalyzeRequest request) {
  final rules = (jsonDecode(request.rulesJson) as List<dynamic>)
      .map((e) => NativeLibraryRule.fromJson(e as Map<String, dynamic>))
      .toList();

  final bytes = File(request.apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  // lib/<abi>/<name>.so（忽略大小写目录下的 .so 文件；不处理目录条目）
  final libEntryRegex = RegExp(r'^lib/[^/]+/[^/]+\.so$');
  final soNames = <String>{};
  for (final entry in archive) {
    if (entry.isFile && libEntryRegex.hasMatch(entry.name)) {
      soNames.add(entry.name.split('/').last);
    }
  }

  return (
    hits: ApkLibraryAnalyzer.matchNativeSoNames(soNames, rules: rules),
    allSoNames: soNames.toList()..sort(),
  );
}

/// isolate 内执行：读取 APK 字节 → 解压枚举 lib/<abi>/ 目录集合
List<String> _listAbisInIsolate(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  final libEntryRegex = RegExp(r'^lib/([^/]+)/[^/]+\.so$');
  final abis = <String>{};
  for (final entry in archive) {
    if (entry.isFile) {
      final match = libEntryRegex.firstMatch(entry.name);
      if (match != null) abis.add(match.group(1)!);
    }
  }

  // 常见 ABI 优先级排序（arm64 在前，符合主流分发习惯）
  const priority = [
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
    'x86',
    'armeabi',
    'mips64',
    'mips',
  ];
  final list = abis.toList()
    ..sort((a, b) {
      final ia = priority.indexOf(a);
      final ib = priority.indexOf(b);
      final oa = ia < 0 ? priority.length : ia;
      final ob = ib < 0 ? priority.length : ib;
      return oa != ob ? oa.compareTo(ob) : a.compareTo(b);
    });
  return list;
}

/// isolate 内执行：读取 APK 字节 → 解压枚举 assets/*.so（LibChecker 单列分组）
List<NativeSoFile> _listAssetsSoInIsolate(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  final assetsSoRegex = RegExp(r'^assets/.+\.so$');
  final soByAbi = <String, NativeSoFile>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    if (!assetsSoRegex.hasMatch(entry.name)) continue;
    final name = entry.name.split('/').last;
    soByAbi.putIfAbsent(
        name, () => NativeSoFile(name: name, size: entry.size));
  }
  final list = soByAbi.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return list;
}

/// isolate 内执行：读取 APK 字节 → 解压枚举 lib/<abi>/*.so → 按 ABI 分组
List<NativeAbiLibs> _listFullNativeLibsInIsolate(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  // lib/<abi>/<name>.so（忽略大小写目录下的 .so 文件；不处理目录条目）
  // 每个文件记录 zip 解压后字节数（entry.size），供 UI 行尾展示大小。
  final libEntryRegex = RegExp(r'^lib/([^/]+)/[^/]+\.so$');
  final soByAbi = <String, List<NativeSoFile>>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final match = libEntryRegex.firstMatch(entry.name);
    if (match == null) continue;
    soByAbi
        .putIfAbsent(match.group(1)!, () => [])
        .add(NativeSoFile(name: entry.name.split('/').last, size: entry.size));
  }

  // 常见 ABI 优先级排序（与 _listAbisInIsolate 一致）
  const priority = [
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
    'x86',
    'armeabi',
    'mips64',
    'mips',
  ];
  final list = <NativeAbiLibs>[
    for (final entry in soByAbi.entries)
      NativeAbiLibs(
        abi: entry.key,
        soFiles: entry.value..sort((a, b) => a.name.compareTo(b.name)),
      ),
  ]..sort((a, b) {
      final ia = priority.indexOf(a.abi);
      final ib = priority.indexOf(b.abi);
      final oa = ia < 0 ? priority.length : ia;
      final ob = ib < 0 ? priority.length : ib;
      return oa != ob ? oa.compareTo(ob) : a.abi.compareTo(b.abi);
    });
  return list;
}

/// isolate 内执行：读取 APK 字节 → 解压枚举 classes*.dex（zip 任意层级）
List<DexFile> _listDexFilesInIsolate(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  // classes*.dex（忽略大小写，含分包 classes2.dex …；不处理目录条目）
  // 每个文件记录 zip 解压后字节数（entry.size），供 UI 行尾展示大小。
  final dexEntryRegex = RegExp(r'^classes\d*\.dex$', caseSensitive: false);
  final files = <DexFile>[
    for (final entry in archive)
      if (entry.isFile && dexEntryRegex.hasMatch(entry.name.split('/').last))
        DexFile(name: entry.name.split('/').last, size: entry.size),
  ]..sort((a, b) => a.name.compareTo(b.name));
  return files;
}

/// kotlin-tooling-metadata.json 条目名（Kotlin Gradle Plugin 2.0+ 生成）
const String _kKotlinToolingMetadataEntry = 'kotlin-tooling-metadata.json';

/// Kotlin Android 插件名（LibChecker KOTLIN_ANDROID_PLUGIN）
const String _kKotlinAndroidPlugin =
    'org.jetbrains.kotlin.gradle.plugin.KotlinAndroidPluginWrapper';

/// Kotlin Android target 名（LibChecker KOTLIN_ANDROID_TARGET）
const String _kKotlinAndroidTarget =
    'org.jetbrains.kotlin.gradle.plugin.mpp.KotlinAndroidTarget';

/// Gradle 构建系统名（LibChecker GRADLE_BUILD_SYSTEM）
const String _kGradleBuildSystem = 'Gradle';

/// kotlin_module 元数据目录前缀（LibChecker KOTLIN_MODULE_DIRECTORY）
const String _kKotlinModuleDirectory = 'META-INF/';

/// kotlin_module 元数据文件后缀（LibChecker KOTLIN_MODULE_SUFFIX）
const String _kKotlinModuleSuffix = '.kotlin_module';

/// 版本组件数合法区间（LibChecker MIN/MAX_VERSION_COMPONENTS）
const int _kMinVersionComponents = 2;
const int _kMaxVersionComponents = 16;

/// 版本分量值合法区间（0..99，含 0）
const int _kMinVersionNumber = 0;
const int _kMaxVersionNumber = 99;

/// isolate 内执行：读取 APK 字节 → 解析 kotlin-tooling-metadata.json；
/// kotlinVersion 未解析出时降级扫描 META-INF/*.kotlin_module 二进制版本推断。
///
/// 主路径 kotlinVersion 已解析出 → 直接返回；否则保留 tooling 已解析出的
/// gradleVersion/javaVersion（对齐 LibChecker：降级结果基于 toolingMetadata 拷贝）。
/// 全部未知 → 全空串。
BuildVersionInfo _detectBuildVersionsInIsolate(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  // 主路径：kotlin-tooling-metadata.json（根目录精确条目）
  var tooling = const BuildVersionInfo();
  for (final entry in archive) {
    if (!entry.isFile || entry.name != _kKotlinToolingMetadataEntry) continue;
    final content = entry.content;
    tooling = content is List<int>
        ? _parseKotlinToolingMetadata(content)
        : const BuildVersionInfo();
    // kotlinVersion 已解析出 → 直接返回；否则降级 kotlin_module
    if (tooling.kotlinVersion.isNotEmpty) return tooling;
    break;
  }

  // 降级：META-INF/*.kotlin_module 二进制版本推断（对齐 LibChecker
  // readKotlinModuleVersions）：仅当恰好一种 distinct 版本时采用。
  final versions = <String>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name;
    if (!name.startsWith(_kKotlinModuleDirectory) ||
        !name.endsWith(_kKotlinModuleSuffix)) {
      continue;
    }
    final version = _readKotlinModuleVersion(entry);
    if (version != null) versions.add(version);
  }
  if (versions.length == 1) {
    return BuildVersionInfo(
      kotlinVersion: versions.single,
      gradleVersion: tooling.gradleVersion,
      javaVersion: tooling.javaVersion,
    );
  }
  // 无 kotlin_module 可推断 → 返回 tooling 已解析出的 gradle/java（可能全空串）
  return tooling;
}

/// 解析 kotlin-tooling-metadata.json → 构建版本（规则对齐 LibChecker
/// readToolingMetadata）：
///
/// - kotlinVersion = buildPluginVersion，仅当 buildPlugin 为
///   KotlinAndroidPluginWrapper 或存在 KotlinAndroidTarget 时采用
/// - gradleVersion = buildSystemVersion，仅当 buildSystem == Gradle
/// - javaVersion = 首个 KotlinAndroidTarget 的 extras.android.sourceCompatibility，
///   仅当其非空且全为数字字符
BuildVersionInfo _parseKotlinToolingMetadata(List<int> content) {
  try {
    final decoded = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
    final buildSystem = decoded['buildSystem'] as String? ?? '';
    final buildSystemVersion = decoded['buildSystemVersion'] as String? ?? '';
    final buildPlugin = decoded['buildPlugin'] as String? ?? '';
    final buildPluginVersion = decoded['buildPluginVersion'] as String? ?? '';

    var hasKotlinAndroidTarget = false;
    var sourceCompatibility = '';
    final projectTargets = decoded['projectTargets'];
    if (projectTargets is List) {
      for (final target in projectTargets) {
        if (target is! Map) continue;
        if (target['target'] != _kKotlinAndroidTarget) continue;
        hasKotlinAndroidTarget = true;
        final extras = target['extras'];
        if (extras is Map) {
          final android = extras['android'];
          if (android is Map) {
            final sc = android['sourceCompatibility'];
            if (sc is String) sourceCompatibility = sc;
          }
        }
        break; // 只取首个 KotlinAndroidTarget
      }
    }

    final kotlinVersion = buildPluginVersion.isNotEmpty &&
            (buildPlugin == _kKotlinAndroidPlugin || hasKotlinAndroidTarget)
        ? buildPluginVersion
        : '';
    final gradleVersion =
        buildSystem == _kGradleBuildSystem && buildSystemVersion.isNotEmpty
            ? buildSystemVersion
            : '';
    final javaVersion = sourceCompatibility.isNotEmpty &&
            _isAllDigits(sourceCompatibility)
        ? sourceCompatibility
        : '';

    return BuildVersionInfo(
      kotlinVersion: kotlinVersion,
      gradleVersion: gradleVersion,
      javaVersion: javaVersion,
    );
  } catch (e) {
    return const BuildVersionInfo();
  }
}

/// 解析 kotlin_module 二进制头 → 'major.minor.x' 版本串；非法布局返回 null。
///
/// 布局：int componentCount（4 字节大端），随后 componentCount 个 int
/// （版本分量 [major, minor, …]）。仅当 componentCount ∈ [2,16] 且每个
/// 分量 ∈ [0,99] 时接受（对齐 LibChecker MIN/MAX_VERSION_COMPONENTS）。
String? _readKotlinModuleVersion(ArchiveFile entry) {
  final content = entry.content;
  if (content is! List<int> || content.length < 4) return null;
  final bytes = content is Uint8List ? content : Uint8List.fromList(content);

  final data = ByteData.sublistView(bytes);
  final componentCount = data.getInt32(0);
  if (componentCount < _kMinVersionComponents ||
      componentCount > _kMaxVersionComponents) {
    return null;
  }
  if (bytes.length < 4 + componentCount * 4) return null;

  final components = <int>[];
  for (var i = 0; i < componentCount; i++) {
    final value = data.getInt32(4 + i * 4);
    if (value < _kMinVersionNumber || value > _kMaxVersionNumber) return null;
    components.add(value);
  }
  return '${components[0]}.${components[1]}.x';
}

/// 字符串是否全为数字字符（ASCII 0-9，非空）
bool _isAllDigits(String s) {
  if (s.isEmpty) return false;
  for (final c in s.codeUnits) {
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}
