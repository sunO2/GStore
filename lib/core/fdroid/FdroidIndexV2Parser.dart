import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/fdroid/FdroidRepoDatabase.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/fdroid/FdroidIsolateParser.dart';
import 'package:gstore/core/fdroid/FdroidTempDatabase.dart';
import 'package:gstore/core/fdroid/ConditionalHttpClient.dart';
import 'package:path/path.dart' as path;

// 导入新的完整解析函数
import 'package:gstore/core/fdroid/FdroidIsolateParser.dart' show
    FdroidFullParseMessage,
    FdroidFullParseResult,
    parseFullJsonInIsolate;

/// F-Droid Index-V2 解析器
/// 支持增量更新和流式解析
class FdroidIndexV2Parser {
  final Dio _dio;
  final FdroidRepoDatabase database;
  late final ConditionalHttpClient _conditionalHttpClient;

  FdroidIndexV2Parser({
    required Dio dio,
    required this.database,
  }) : _dio = dio {
    _conditionalHttpClient = ConditionalHttpClient(_dio);
  }

  /// 解析入口文件（entry.json 或 entry.jar）
  /// 获取可用的索引版本信息
  Future<Map<String, dynamic>?> parseEntryFile(String repoUrl) async {
    try {
      // 先尝试 JSON 格式
      final entryJsonUrl = '$repoUrl/entry.json';
      try {
        final response = await _dio.get(entryJsonUrl);
        if (response.statusCode == 200) {
          return response.data as Map<String, dynamic>?;
        }
      } catch (e) {
        debugPrint('FdroidIndexV2: entry.json 不可用，尝试 entry.jar - $e');
      }

      // 如果 JSON 失败，忽略 JAR 格式（签名验证复杂）
      // 直接尝试最新的 index-v2
      return null;
    } catch (e) {
      debugPrint('FdroidIndexV2: 解析入口文件失败 - $e');
      return null;
    }
  }

  /// 获取当前可用的索引版本列表
  Future<List<int>> getAvailableVersions(String repoUrl) async {
    final entryData = await parseEntryFile(repoUrl);
    if (entryData == null) {
      // 如果没有 entry.json，直接尝试猜测版本
      debugPrint('FdroidIndexV2: 没有 entry.json，使用默认版本 [2, 1]');
      return [2, 1];
    }

    final index = entryData!['index'] as Map<String, dynamic>? ?? {};
    final versions = <int>[];

    // 解析版本列表
    index.forEach((key, value) {
      if (key.startsWith('index-v') && value is Map) {
        final versionStr = key.replaceAll('index-v', '').replaceAll('.json', '');
        final version = int.tryParse(versionStr);
        if (version != null) {
          versions.add(version);
        }
      }
    });

    versions.sort();

    // 如果没有找到任何版本，使用默认版本
    if (versions.isEmpty) {
      debugPrint('FdroidIndexV2: entry.json 中没有找到版本信息，使用默认版本 [2]');
      return [2];
    }

    debugPrint('FdroidIndexV2: 可用版本 $versions');
    return versions;
  }

  /// 流式解析 index-v2 文件并写入数据库
  /// 使用 chunk 方式解析，避免一次性加载大文件到内存
  Future<int> parseIndexV2ToDatabase(
    String repoUrl, {
    int? version,
    bool forceRefresh = false,
    Function(int current, int total)? onProgress,
    int maxRetries = 3, // 最大重试次数
  }) async {
    int retryCount = 0;

    while (retryCount <= maxRetries) {
      try {
        final availableVersions = await getAvailableVersions(repoUrl);

        if (availableVersions.isEmpty) {
          throw Exception('无法获取可用的索引版本');
        }

        final indexVersion = version ?? availableVersions.last;
        final indexUrl = '$repoUrl/index-v$indexVersion.json';

        debugPrint('FdroidIndexV2: 开始解析 $indexUrl (版本: $indexVersion)${retryCount > 0 ? " (重试 $retryCount/$maxRetries)" : ""}');

        // 检查本地缓存（只在非强制刷新且第一次尝试时检查）
        if (!forceRefresh && retryCount == 0) {
          final existingVersion = await database.dao.getVersionInfo(repoUrl);
          if (existingVersion != null && existingVersion.indexVersion == indexVersion) {
            // 版本匹配，但还需要检查是否真的有应用数据
            final appCount = (await database.dao.getAppCount()) ?? 0;
            if (appCount > 0) {
              debugPrint('FdroidIndexV2: 已是最新版本 $indexVersion，且有 $appCount 个应用');
              return 0;
            } else {
              debugPrint('FdroidIndexV2: 版本匹配但无应用数据，需要重新加载');
            }
          }
        }

        // 跳过条件请求检查，直接下载（条件请求对首次加载没有意义，且会增加延迟）
        String? lastModified;
        String? entityTag;

        debugPrint('FdroidIndexV2: 跳过条件请求，直接下载');

        // 使用流式下载
        debugPrint('FdroidIndexV2: 开始下载 $indexUrl');
        final response = await _dio.get(
          indexUrl,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: Duration(minutes: 5), // 增加超时时间
          ),
        );

        if (response.statusCode != 200) {
          throw Exception('Failed to fetch index: ${response.statusCode}');
        }

        // 提取响应头（如果条件请求没有获取到）
        lastModified ??= response.headers['Last-Modified']?.first;
        entityTag ??= response.headers['ETag']?.first;

        // 获取文件实际大小
        final contentLength = response.headers['Content-Length']?.first;
        final int? expectedSize = contentLength != null ? int.tryParse(contentLength) : null;

        debugPrint('FdroidIndexV2: 下载响应成功，开始读取流');
        debugPrint('FdroidIndexV2: Last-Modified: $lastModified');
        debugPrint('FdroidIndexV2: ETag: $entityTag');
        debugPrint('FdroidIndexV2: Content-Length: $expectedSize bytes');

        // 从 ResponseBody 获取流
        final responseBody = response.data;
        final stream = responseBody.stream;
        final buffer = <int>[];

        // 分块读取和解析
        int appsInserted = 0;
        int packagesInserted = 0;
        int totalBytes = 0;

        debugPrint('FdroidIndexV2: 开始读取流数据');
        await for (final chunk in stream) {
          final chunkSize = chunk.length as int;
          totalBytes += chunkSize;
          buffer.addAll(chunk);

          // 每 1MB 输出一次进度
          if (totalBytes % (1024 * 1024) < chunkSize) {
            if (expectedSize != null) {
              // 有文件大小时，显示进度
              final progress = ((totalBytes / expectedSize) * 100).toStringAsFixed(1);
              debugPrint('FdroidIndexV2: 已接收 ${totalBytes ~/ 1024} KB / ${expectedSize ~/ 1024} KB ($progress%)');
              onProgress?.call(totalBytes, expectedSize);
            } else {
              // 没有文件大小时，只显示已接收的字节数，不调用进度回调
              // 这样可以避免UI显示错误的100%进度
              debugPrint('FdroidIndexV2: 已接收 ${totalBytes ~/ 1024} KB');
            }
          }

          // 尝试解析 JSON（每次追加后尝试）
          try {
            final jsonStr = utf8.decode(buffer);
            final jsonData = jsonDecode(jsonStr) as Map<String, dynamic>;

            debugPrint('FdroidIndexV2: JSON 解析成功，开始处理 (共 ${totalBytes ~/ 1024} KB)');

            // 先清空旧数据，释放内存
            debugPrint('FdroidIndexV2: 清空旧数据...');
            await clearDatabase();
            buffer.clear(); // 立即清空 buffer

            // 使用后台解析方法（Neo-Store 风格）
            appsInserted = await parseIndexV2WithTempDatabase(
              jsonData,
              repoUrl,
              onProgress: onProgress,
              lastModified: lastModified,
              entityTag: entityTag,
            );

            debugPrint('FdroidIndexV2: 解析完成 - $appsInserted 个应用');

            return appsInserted;
          } on FormatException catch (e) {
            // JSON 还不完整，继续读取
            continue;
          } catch (e) {
            debugPrint('FdroidIndexV2: JSON 解析异常 - $e');
            rethrow;
          }
        }

        debugPrint('FdroidIndexV2: 流结束，但未成功解析 JSON (共接收 $totalBytes 字节)');
        throw Exception('Incomplete JSON data');

      } catch (e) {
        retryCount++;

        if (retryCount <= maxRetries && _isNetworkError(e)) {
          debugPrint('FdroidIndexV2: 网络错误，准备重试 ($retryCount/$maxRetries) - $e');
          await Future.delayed(Duration(seconds: retryCount * 2)); // 指数退避
          continue;
        }

        // 如果不是网络错误或已达到最大重试次数，抛出异常
        if (retryCount > maxRetries) {
          debugPrint('FdroidIndexV2: 已达到最大重试次数，放弃重试');
        }
        rethrow;
      }
    }

    throw Exception('Unexpected error: should not reach here');
  }

  /// 判断是否为网络错误
  bool _isNetworkError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('connection') ||
        errorStr.contains('socket') ||
        errorStr.contains('timeout') ||
        errorStr.contains('network') ||
        errorStr.contains('http');
  }

  /// 增量更新（使用 JSON Merge Patch）
  Future<Map<String, int>> applyIncrementalUpdate(
    String repoUrl,
    int fromVersion,
    int toVersion,
  ) async {
    try {
      debugPrint('FdroidIndexV2: 增量更新 $fromVersion -> $toVersion');

      int appsUpdated = 0;
      int appsAdded = 0;
      int packagesAdded = 0;

      // 依次应用每个增量文件
      for (int version = fromVersion + 1; version <= toVersion; version++) {
        final patchUrl = '$repoUrl/index-v2-$version.json';

        try {
          final response = await _dio.get(patchUrl);
          if (response.statusCode != 200) {
            debugPrint('FdroidIndexV2: 跳过版本 $version - ${response.statusCode}');
            continue;
          }

          final patchData = response.data as Map<String, dynamic>?;

          if (patchData != null) {
            // 应用增量更新到数据库
            final result = await _applyPatchToDatabase(patchData, repoUrl);
            appsUpdated += result['updated'] ?? 0;
            appsAdded += result['added'] ?? 0;
            packagesAdded += result['packages'] ?? 0;

            debugPrint('FdroidIndexV2: 版本 $version 更新完成');
          }
        } catch (e) {
          debugPrint('FdroidIndexV2: 版本 $version 更新失败 - $e');
        }
      }

      // 更新版本信息
      await _updateVersionInfo(repoUrl, toVersion);

      return {
        'appsUpdated': appsUpdated,
        'appsAdded': appsAdded,
        'packagesAdded': packagesAdded,
      };
    } catch (e) {
      debugPrint('FdroidIndexV2: 增量更新失败 - $e');
      rethrow;
    }
  }

  /// 检查并应用增量更新
  Future<Map<String, dynamic>?> checkAndApplyIncrementalUpdate(
    String repoUrl, {
    bool force = false,
  }) async {
    try {
      // 获取当前版本
      final currentVersionInfo = await database.dao.getVersionInfo(repoUrl);

      // 获取可用版本列表
      final availableVersions = await getAvailableVersions(repoUrl);

      if (availableVersions.isEmpty) {
        debugPrint('FdroidIndexV2: 没有可用的版本');
        return null;
      }

      final currentVersion = currentVersionInfo?.indexVersion ?? 0;
      final latestVersion = availableVersions.last;

      if (latestVersion <= currentVersion) {
        debugPrint('FdroidIndexV2: 已是最新版本 $latestVersion');
        return {
          'hasUpdate': false,
          'currentVersion': currentVersion,
          'latestVersion': latestVersion,
        };
      }

      debugPrint('FdroidIndexV2: 发现更新 $currentVersion -> $latestVersion');

      // 应用增量更新
      final result = await applyIncrementalUpdate(
        repoUrl,
        currentVersion,
        latestVersion,
      );

      return {
        'hasUpdate': true,
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        ...result,
      };
    } catch (e) {
      debugPrint('FdroidIndexV2: 检查更新失败 - $e');
      return null;
    }
  }

  /// 将索引数据写入数据库（分批处理）
  Future<Map<String, int>> _writeIndexToDatabase(
    Map<String, dynamic> jsonData,
    String repoUrl,
  ) async {
    int appsInserted = 0;
    int packagesInserted = 0;

    final appsMap = jsonData['apps'] as Map<String, dynamic>?;

    if (appsMap != null) {
      // 分批处理，避免内存峰值
      const batchSize = 100;
      final packageNames = appsMap.keys.toList();

      debugPrint('FdroidIndexV2: 开始分批处理 ${packageNames.length} 个应用，每批 $batchSize 个');

      for (int i = 0; i < packageNames.length; i += batchSize) {
        final end = (i + batchSize < packageNames.length) ? i + batchSize : packageNames.length;
        final batch = packageNames.sublist(i, end);

        debugPrint('FdroidIndexV2: 处理批次 $i - $end');

        final apps = <FdroidApp>[];
        final packages = <FdroidPackage>[];

        for (final packageName in batch) {
          final appData = appsMap[packageName];
          if (appData is Map) {
            try {
              // 创建应用
              final app = FdroidApp.fromIndexV2(packageName, Map<String, dynamic>.from(appData));
              apps.add(app);

              // 创建包信息 - packages 是一个 List，不是 Map
              final packagesList = appData['packages'];
              if (packagesList is List) {
                for (final pkgData in packagesList) {
                  if (pkgData is Map) {
                    // 获取 APK 文件名
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
                        debugPrint('FdroidIndexV2: 解析包失败 $packageName:$apkName - $e');
                      }
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint('FdroidIndexV2: 解析应用失败 $packageName - $e');
            }
          }
        }

        // 写入当前批次
        await database.dao.upsertApps(apps);
        appsInserted += apps.length;

        await database.dao.upsertPackages(packages);
        packagesInserted += packages.length;

        debugPrint('FdroidIndexV2: 批次完成，累计 $appsInserted 个应用, $packagesInserted 个包');
      }

      // 更新版本信息
      final indexVersion = jsonData['index']?['version'] ?? jsonData['repo']?['version'] ?? 2;
      await _updateVersionInfo(repoUrl, indexVersion);
    }

    return {
      'apps': appsInserted,
      'packages': packagesInserted,
    };
  }

  /// 使用 Isolate 优化的分批处理（Neo-Store 风格）
  Future<Map<String, int>> _writeIndexToDatabaseWithIsolates(
    Map<String, dynamic> jsonData,
    String repoUrl,
    Function(int current, int total)? onProgress,
  ) async {
    int appsInserted = 0;
    int packagesInserted = 0;

    final appsMap = jsonData['apps'] as Map<String, dynamic>?;

    if (appsMap != null) {
      const batchSize = 100;
      final packageNames = appsMap.keys.toList();
      final totalApps = packageNames.length;

      debugPrint('FdroidIndexV2: [Isolate模式] 开始处理 $totalApps 个应用，每批 $batchSize 个');

      // 将 JSON 转换为字节数组，用于 isolate 间传递
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(jsonData)));

      // 分批在 isolate 中处理
      for (int i = 0; i < totalApps; i += batchSize) {
        final end = (i + batchSize < totalApps) ? i + batchSize : totalApps;

        debugPrint('FdroidIndexV2: [Isolate模式] 处理批次 $i - $end (${((end / totalApps) * 100).toStringAsFixed(1)}%)');

        // 在 isolate 中解析当前批次
        final parseMessage = FdroidParseMessage(
          jsonData: jsonBytes,
          repoUrl: repoUrl,
          startIndex: i,
          endIndex: end,
        );

        final result = await compute(
          parseBatchInIsolate,
          parseMessage,
        );

        // 写入数据库
        await database.dao.upsertApps(result.apps);
        appsInserted += result.apps.length;

        await database.dao.upsertPackages(result.packages);
        packagesInserted += result.packages.length;

        // 更新进度
        onProgress?.call(end, totalApps);

        debugPrint('FdroidIndexV2: [Isolate模式] 批次完成，累计 $appsInserted 个应用, $packagesInserted 个包');
      }

      // 更新版本信息
      final indexVersion = jsonData['index']?['version'] ?? jsonData['repo']?['version'] ?? 2;
      await _updateVersionInfo(repoUrl, indexVersion);
    }

    debugPrint('FdroidIndexV2: [Isolate模式] 处理完成 - 共 $appsInserted 个应用, $packagesInserted 个包');

    return {
      'apps': appsInserted,
      'packages': packagesInserted,
    };
  }

  /// 应用增量更新到数据库
  Future<Map<String, int>> _applyPatchToDatabase(
    Map<String, dynamic> patchData,
    String repoUrl,
  ) async {
    // JSON Merge Patch 简化实现
    // 只处理 apps 字段的更新
    final appsPatch = patchData['apps'] as Map<String, dynamic>?;

    if (appsPatch == null) {
      return {'updated': 0, 'added': 0, 'packages': 0};
    }

    int updated = 0;
    int added = 0;
    int packages = 0;

    for (final entry in appsPatch.entries) {
      final packageName = entry.key;
      final appData = entry.value;

      if (appData == null) {
        // null 表示删除
        await database.dao.deleteApp(packageName);
      } else if (appData is Map) {
        // 检查应用是否已存在
        // 这里简化处理，直接 upsert
        try {
          final app = FdroidApp.fromIndexV2(packageName, Map<String, dynamic>.from(appData));
          await database.dao.upsertApp(app);

          final exists = await database.dao.getApp(packageName);
          if (exists == null) {
            added++;
          } else {
            updated++;
          }

          // 处理包信息 - packages 是一个 List
          final packagesList = appData['packages'];
          if (packagesList is List) {
            for (final pkgData in packagesList) {
              if (pkgData is Map) {
                final apkName = pkgData['apkName'] as String?;
                if (apkName != null) {
                  try {
                    final pkg = FdroidPackage.fromIndexV2(
                      packageName,
                      apkName,
                      Map<String, dynamic>.from(pkgData),
                    );
                    await database.dao.upsertPackage(pkg);
                    packages++;
                  } catch (e) {
                    debugPrint('FdroidIndexV2: 更新包失败 $packageName:$apkName - $e');
                  }
                }
              }
            }
          }
        } catch (e) {
          debugPrint('FdroidIndexV2: 更新应用失败 $packageName - $e');
        }
      }
    }

    return {
      'updated': updated,
      'added': added,
      'packages': packages,
    };
  }

  /// 更新版本信息
  Future<void> _updateVersionInfo(
    String repoUrl,
    int indexVersion, {
    String? lastModified,
    String? entityTag,
  }) async {
    final versions = await getAvailableVersions(repoUrl);

    await database.dao.upsertVersionInfo(
      FdroidVersionInfo(
        indexVersion: indexVersion,
        lastCheckTime: DateTime.now(),
        repoUrl: repoUrl,
        availableVersions: versions,
        lastModified: lastModified,
        entityTag: entityTag,
      ),
    );
  }

  /// 清空数据库
  Future<void> clearDatabase() async {
    await database.dao.clearApps();
    await database.dao.clearPackages();
    debugPrint('FdroidIndexV2: 数据库已清空');
  }

  /// 使用后台线程完整解析JSON（避免ANR）
  /// 所有JSON解析都在Isolate中完成，主线程只负责数据库写入
  Future<int> parseIndexV2WithTempDatabase(
    Map<String, dynamic> jsonData,
    String repoUrl, {
    Function(int current, int total)? onProgress,
    String? lastModified,
    String? entityTag,
  }) async {
    try {
      debugPrint('FdroidIndexV2: [完整后台解析] 开始...');

      // 将完整的JSON数据转换为字节数组
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(jsonData)));

      debugPrint('FdroidIndexV2: [完整后台解析] JSON大小: ${(jsonBytes.length / 1024).toStringAsFixed(1)} KB');

      // 在Isolate中完整解析所有应用
      final parseMessage = FdroidFullParseMessage(
        jsonData: jsonBytes,
        repoUrl: repoUrl,
        batchSize: 50,
      );

      debugPrint('FdroidIndexV2: [完整后台解析] 启动后台解析...');
      final result = await compute(
        parseFullJsonInIsolate,
        parseMessage,
      );

      debugPrint('FdroidIndexV2: [完整后台解析] 后台解析完成，共 ${result.totalApps} 个应用，分为 ${result.allBatches.length} 个批次');

      // 现在主线程只需要写入数据库
      int appsInserted = 0;

      for (int i = 0; i < result.allBatches.length; i++) {
        final batch = result.allBatches[i];

        // 写入主数据库
        await database.dao.upsertApps(batch);
        appsInserted += batch.length;

        // 更新进度
        onProgress?.call(appsInserted, result.totalApps);

        // 每处理100个应用打印一次日志
        if (appsInserted % 100 == 0) {
          debugPrint('FdroidIndexV2: [完整后台解析] 已写入 $appsInserted/${result.totalApps} 个应用');
        }

        // 关键：每批处理后都让出控制权
        await Future.delayed(Duration(microseconds: 100));
      }

      debugPrint('FdroidIndexV2: [完整后台解析] 全部完成，共 $appsInserted 个应用');

      // 更新版本信息（包含HTTP响应头）
      await _updateVersionInfo(
        repoUrl,
        result.indexVersion,
        lastModified: lastModified,
        entityTag: entityTag,
      );

      return appsInserted;
    } catch (e) {
      debugPrint('FdroidIndexV2: [完整后台解析] 失败 - $e');
      rethrow;
    }
  }
}
