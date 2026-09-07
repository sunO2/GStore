import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gstore/core/core.dart';

/// 原生库规则（LibChecker rules.db 中 type=0 / NATIVE 行）
class NativeLibraryRule {
  /// 规则名：isRegexRule=0 时为精确 .so 文件名，isRegexRule=1 时为正则表达式
  final String name;

  /// 展示名（如「高德地图 SDK」）
  final String label;

  /// 规则类型（LibChecker LibType，NATIVE=0）
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

/// 一次原生库命中（一个 .so 名匹配到一条规则）
class NativeLibraryHit {
  /// 实际匹配到的 .so 文件名（如 libamapv0676.so）
  final String soFileName;

  /// 命中的规则名
  final String ruleName;

  /// 展示名
  final String label;

  /// 是否由正则规则命中
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

/// APK 内嵌第三方库（.so）检测
///
/// 方案 A（纯 Dart）：解压 APK 枚举 lib/<abi>/*.so 文件名，
/// 与 LibChecker 规则库（assets/lcrules/rules_native.json，type=0）匹配。
/// 仅做文件名校验，不解析 ELF；DEX/更多规则类型由方案 B 覆盖。
class ApkLibraryAnalyzer {
  ApkLibraryAnalyzer._();

  static final ApkLibraryAnalyzer instance = ApkLibraryAnalyzer._();

  /// 规则资源路径
  static const String assetPath = 'assets/lcrules/rules_native.json';

  /// APK 路径 → 命中结果缓存（同路径重复分析直接返回）
  final Map<String, List<NativeLibraryHit>> _cache = {};

  /// 已加载规则（懒加载缓存；测试注入覆盖）
  List<NativeLibraryRule>? _rules;

  /// 测试用：注入合成规则，跳过真实资产读取。
  /// 传 null 恢复默认资产加载。
  @visibleForTesting
  void debugSetRules(List<NativeLibraryRule>? rules) {
    _rules = rules;
    _cache.clear();
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
      final hits = await compute(
        _analyzeInIsolate,
        (apkPath: apkPath, rulesJson: rulesJson),
      );
      _cache[apkPath] = hits;
      appLog.info('ApkLibraryAnalyzer: $apkPath 命中 ${hits.length} 条规则');
      return hits;
    } catch (e) {
      appLog.error('ApkLibraryAnalyzer: 分析 APK 失败 - $e');
      return const [];
    }
  }

  /// 纯函数：so 文件名集合 × 规则列表 → 命中列表（可单元测试）。
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
}

/// compute isolate 入参
typedef _AnalyzeRequest = ({String apkPath, String rulesJson});

/// isolate 内执行：读取 APK 字节 → 解压枚举 lib/*/*.so → 匹配规则
List<NativeLibraryHit> _analyzeInIsolate(_AnalyzeRequest request) {
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

  return ApkLibraryAnalyzer.matchNativeSoNames(soNames, rules: rules);
}
