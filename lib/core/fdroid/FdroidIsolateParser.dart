import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

/// Isolate 解析消息
class FdroidParseMessage {
  final Uint8List jsonData;
  final String repoUrl;
  final int startIndex;
  final int endIndex;

  FdroidParseMessage({
    required this.jsonData,
    required this.repoUrl,
    required this.startIndex,
    required this.endIndex,
  });
}

/// 完整JSON解析消息（用于解析整个文件）
class FdroidFullParseMessage {
  final Uint8List jsonData;
  final String repoUrl;
  final int batchSize; // 每批处理的应用数量

  FdroidFullParseMessage({
    required this.jsonData,
    required this.repoUrl,
    this.batchSize = 50,
  });
}

/// 完整解析结果（包含所有批次的应用）
class FdroidFullParseResult {
  final List<List<FdroidApp>> allBatches;
  final int totalApps;
  final int indexVersion;

  FdroidFullParseResult({
    required this.allBatches,
    required this.totalApps,
    required this.indexVersion,
  });
}

/// Isolate 中的完整解析函数
/// 在独立线程中解析整个 JSON 文件，返回分批的应用列表
/// 这样可以避免主线程执行任何 JSON 解析操作
FdroidFullParseResult parseFullJsonInIsolate(FdroidFullParseMessage message) {
  final jsonStr = utf8.decode(message.jsonData);
  final rootJson = jsonDecode(jsonStr) as Map<String, dynamic>;

  final appsMap = rootJson['apps'] as Map<String, dynamic>?;
  if (appsMap == null) {
    return FdroidFullParseResult(
      allBatches: [],
      totalApps: 0,
      indexVersion: 2,
    );
  }

  final packageNames = appsMap.keys.toList();
  final totalApps = packageNames.length;
  final batchSize = message.batchSize;

  final allBatches = <List<FdroidApp>>[];

  // 分批解析所有应用
  for (int i = 0; i < totalApps; i += batchSize) {
    final end = (i + batchSize < totalApps) ? i + batchSize : totalApps;
    final batch = packageNames.sublist(i, end);

    final apps = <FdroidApp>[];

    for (final packageName in batch) {
      final appData = appsMap[packageName];
      if (appData is Map) {
        try {
          final app = FdroidApp.fromIndexV2(
            packageName,
            Map<String, dynamic>.from(appData),
          );
          apps.add(app);
        } catch (e) {
          // 忽略错误
        }
      }
    }

    allBatches.add(apps);
  }

  final indexVersion = rootJson['index']?['version'] ??
      rootJson['repo']?['version'] ??
      2;

  return FdroidFullParseResult(
    allBatches: allBatches,
    totalApps: totalApps,
    indexVersion: indexVersion,
  );
}

/// Isolate 中的批量解析函数
/// 在独立线程中解析 JSON，避免阻塞主线程
FdroidParseResult parseBatchInIsolate(FdroidParseMessage message) {
  final jsonStr = utf8.decode(message.jsonData);
  final rootJson = jsonDecode(jsonStr) as Map<String, dynamic>;

  final apps = <FdroidApp>[];
  final packages = <FdroidPackage>[];

  final appsMap = rootJson['apps'] as Map<String, dynamic>?;
  if (appsMap != null) {
    final keys = appsMap.keys.toList();
    final batchKeys = keys.sublist(
      message.startIndex,
      message.endIndex.clamp(0, keys.length),
    );

    for (final packageName in batchKeys) {
      final appData = appsMap[packageName];
      if (appData is Map) {
        try {
          // 创建应用
          final app = FdroidApp.fromIndexV2(
            packageName,
            Map<String, dynamic>.from(appData),
          );
          apps.add(app);

          // 创建包信息
          final packagesList = appData['packages'];
          if (packagesList is List) {
            for (final pkgData in packagesList) {
              if (pkgData is Map) {
                final apkName = pkgData['apkName'] as String?;
                if (apkName != null) {
                  try {
                    packages.add(
                      FdroidPackage.fromIndexV2(
                        packageName,
                        apkName,
                        Map<String, dynamic>.from(pkgData),
                      ),
                    );
                  } catch (e) {
                    // 忽略单个包的错误
                  }
                }
              }
            }
          }
        } catch (e) {
          // 忽略单个应用的错误
        }
      }
    }
  }

  final indexVersion = rootJson['index']?['version'] ??
      rootJson['repo']?['version'] ??
      2;

  return FdroidParseResult(
    apps: apps,
    packages: packages,
    indexVersion: indexVersion,
  );
}

/// Isolate 中的解析结果
class FdroidParseResult {
  final List<FdroidApp> apps;
  final List<FdroidPackage> packages;
  final int indexVersion;

  FdroidParseResult({
    required this.apps,
    required this.packages,
    required this.indexVersion,
  });
}
