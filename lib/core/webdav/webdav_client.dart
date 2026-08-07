import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'webdav_config.dart';

/// WebDAV 文件信息
class WebDavFile {
  final String name;
  final String path;
  final int size;
  final DateTime modified;
  final bool isDirectory;

  WebDavFile({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
    required this.isDirectory,
  });

  /// 格式化文件大小
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// WebDAV 客户端
class WebDavClient {
  final WebDavConfig config;

  late final Dio _dio;

  WebDavClient(this.config) {
    _dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        headers: {
          'Authorization': _getAuthHeader(),
        },
        // 允许更多状态码，特别是 WebDAV 可能返回的状态码
        validateStatus: (status) {
          return status != null && status < 500;
        },
      ),
    );

    // 添加日志拦截器
    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(
          requestBody: false,
          responseBody: false,
          requestHeader: false,
          responseHeader: false,
        ),
      );
    }
  }

  /// 获取认证头
  String _getAuthHeader() {
    final credentials = '${config.username}:${config.password}';
    final encoded = base64.encode(utf8.encode(credentials));
    return 'Basic $encoded';
  }

  /// 测试连接
  Future<bool> testConnection() async {
    try {
      debugPrint('WebDavClient: 测试连接 - ${config.baseUrl}');

      // 尝试创建备份目录（如果目录已存在会返回 405 或 201）
      await ensureDirectory(config.backupPath);

      appLog.info('WebDavClient: 连接测试成功');
      return true;
    } catch (e) {
      appLog.error('WebDavClient: 连接测试失败 - $e');
      return false;
    }
  }

  /// 确保目录存在
  Future<void> ensureDirectory(String dirPath) async {
    try {
      // 规范化路径
      String normalizedPath = dirPath;
      if (!normalizedPath.startsWith('/')) {
        normalizedPath = '/$normalizedPath';
      }
      normalizedPath = normalizedPath.replaceAll('//', '/');

      debugPrint('WebDavClient: 确保目录存在 - $normalizedPath');

      // 使用 MKCOL 方法创建目录
      final response = await _dio.request(
        normalizedPath,
        options: Options(
          method: 'MKCOL',
        ),
      );

      // 检查状态码
      if (response.statusCode == 201 || response.statusCode == 405) {
        debugPrint('WebDavClient: 目录已存在或创建成功 - ${response.statusCode}');
        return;
      }

      debugPrint('WebDavClient: 目录创建结果 - ${response.statusCode}');
    } on DioException catch (e) {
      // 如果目录已存在，返回 201 Created 或 405 Method Not Allowed
      if (e.response?.statusCode == 201 || e.response?.statusCode == 405) {
        debugPrint('WebDavClient: 目录已存在 - ${e.response?.statusCode}');
        return;
      }
      appLog.error('WebDavClient: 创建目录失败 - $e');
      rethrow;
    }
  }

  /// 上传文件（支持 429 错误重试）
  Future<String> uploadFile(String remotePath, Uint8List data, {int maxRetries = 3}) async {
    int retryCount = 0;

    while (retryCount <= maxRetries) {
      try {
        debugPrint('WebDavClient: 上传文件原始路径 - $remotePath (${data.length} bytes)');
        debugPrint('WebDavClient: baseUrl - ${config.baseUrl}');
        if (retryCount > 0) {
          debugPrint('WebDavClient: 重试第 $retryCount 次');
        }

        // 规范化路径：确保以 / 开头，但不包含 //
        String normalizedPath = remotePath;
        if (!normalizedPath.startsWith('/')) {
          normalizedPath = '/$normalizedPath';
        }
        normalizedPath = normalizedPath.replaceAll('//', '/');

        debugPrint('WebDavClient: 上传文件规范化路径 - $normalizedPath');

        // 获取父目录并确保其存在
        final dirPath = p.dirname(normalizedPath);
        debugPrint('WebDavClient: 父目录路径 - $dirPath');

        if (dirPath != '/' && dirPath != '.' && dirPath.isNotEmpty) {
          try {
            await ensureDirectory(dirPath);
          } catch (e) {
            debugPrint('WebDavClient: 创建目录失败（可能已存在），继续上传 - $e');
          }
        }

        // 上传文件
        debugPrint('WebDavClient: 开始 PUT 请求到 - $normalizedPath');
        final response = await _dio.put(
          normalizedPath,
          data: Stream.fromIterable([data]),
          options: Options(
            headers: {
              'Content-Type': 'application/octet-stream',
            },
          ),
        );

        debugPrint('WebDavClient: PUT 响应状态码 - ${response.statusCode}');

        // 检查响应状态码
        if (response.statusCode != 200 &&
            response.statusCode != 201 &&
            response.statusCode != 204) {
          // HTTP 429 - Too Many Requests
          if (response.statusCode == 429 && retryCount < maxRetries) {
            retryCount++;
            final waitTime = Duration(seconds: 2 * retryCount); // 递增等待时间：2s, 4s, 6s
            debugPrint('WebDavClient: HTTP 429，等待 ${waitTime.inSeconds} 秒后重试...');
            await Future.delayed(waitTime);
            continue; // 继续重试
          }

          throw Exception('上传失败：HTTP ${response.statusCode}');
        }

        appLog.info('WebDavClient: 上传成功 - ${response.statusCode}');
        return normalizedPath;
      } on DioException catch (e) {
        // HTTP 429 - Too Many Requests
        if (e.response?.statusCode == 429 && retryCount < maxRetries) {
          retryCount++;
          final waitTime = Duration(seconds: 2 * retryCount);
          debugPrint('WebDavClient: HTTP 429（DioException），等待 ${waitTime.inSeconds} 秒后重试...');
          await Future.delayed(waitTime);
          continue;
        }

        appLog.error('WebDavClient: 上传文件失败 - $e');
        rethrow;
      } catch (e) {
        appLog.error('WebDavClient: 上传文件失败 - $e');
        rethrow;
      }
    }

    throw Exception('上传失败：超过最大重试次数 ($maxRetries 次)');
  }

  /// 下载文件
  Future<Uint8List> downloadFile(String remotePath) async {
    try {
      // 规范化路径
      String normalizedPath = remotePath;
      if (!normalizedPath.startsWith('/')) {
        normalizedPath = '/$normalizedPath';
      }
      normalizedPath = normalizedPath.replaceAll('//', '/');

      debugPrint('WebDavClient: 下载文件 - $normalizedPath');

      final response = await _dio.get(
        normalizedPath,
        options: Options(
          responseType: ResponseType.bytes,
        ),
      );

      // 检查响应状态码
      if (response.statusCode != 200) {
        throw Exception('下载失败：HTTP ${response.statusCode}');
      }

      final data = response.data as Uint8List;
      appLog.info('WebDavClient: 下载成功 - ${data.length} bytes');
      return data;
    } catch (e) {
      appLog.error('WebDavClient: 下载文件失败 - $e');
      rethrow;
    }
  }

  /// 删除文件
  Future<void> deleteFile(String remotePath) async {
    try {
      // 规范化路径
      String normalizedPath = remotePath;
      if (!normalizedPath.startsWith('/')) {
        normalizedPath = '/$normalizedPath';
      }
      normalizedPath = normalizedPath.replaceAll('//', '/');

      debugPrint('WebDavClient: 删除文件 - $normalizedPath');

      final response = await _dio.delete(
        normalizedPath,
      );

      appLog.info('WebDavClient: 删除成功 - ${response.statusCode}');
    } catch (e) {
      appLog.error('WebDavClient: 删除文件失败 - $e');
      rethrow;
    }
  }

  /// 检查文件是否存在
  Future<bool> fileExists(String remotePath) async {
    try {
      // 规范化路径
      String normalizedPath = remotePath;
      if (!normalizedPath.startsWith('/')) {
        normalizedPath = '/$normalizedPath';
      }
      normalizedPath = normalizedPath.replaceAll('//', '/');

      final response = await _dio.head(normalizedPath);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 列出目录中的文件
  /// [dirPath] 目录路径
  /// [pattern] 可选的文件名模式过滤（例如：gstore_backup_*.json.gz）
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async {
    try {
      // 规范化路径
      String normalizedPath = dirPath;
      if (!normalizedPath.startsWith('/')) {
        normalizedPath = '/$normalizedPath';
      }
      normalizedPath = normalizedPath.replaceAll('//', '/');

      debugPrint('WebDavClient: 列出目录 - $normalizedPath');
      debugPrint('WebDavClient: baseUrl - ${config.baseUrl}');

      // 使用 PROPFIND 方法列出目录内容（深度1）
      final response = await _dio.request(
        normalizedPath,
        options: Options(
          method: 'PROPFIND',
          headers: {
            'Depth': '1',
          },
        ),
      );

      if (response.statusCode != 207) {
        throw Exception('列出目录失败：HTTP ${response.statusCode}');
      }

      // 解析 XML 响应
      final files = <WebDavFile>[];
      final xmlString = response.data as String;
      debugPrint('WebDavClient: XML 响应: $xmlString');
      final xml = XmlDocument.parse(xmlString);

      // 解析 baseUrl 获取路径前缀
      final baseUrlUri = Uri.parse(config.baseUrl);
      final baseUrlPath = baseUrlUri.path; // 例如: /dav 或 /

      // WebDAV 使用 D: 命名空间，需要处理带命名空间的元素
      final responses = xml.findAllElements('response', namespace: '*');

      for (final resp in responses) {
        // 查找 href（可能在任何命名空间）
        final hrefElement = resp.findAllElements('href', namespace: '*').firstOrNull;
        if (hrefElement == null) continue;

        // 获取完整服务器路径
        var filePath = hrefElement.innerText;
        // 解码 URL
        filePath = Uri.decodeFull(filePath);

        debugPrint('WebDavClient: 原始 href: $filePath');

        // 移除 baseUrl 中的路径前缀，获取相对路径
        var relativePath = filePath;
        if (baseUrlPath.isNotEmpty && baseUrlPath != '/' && filePath.startsWith(baseUrlPath)) {
          relativePath = filePath.substring(baseUrlPath.length);
          debugPrint('WebDavClient: 移除 baseUrl 前缀: $baseUrlPath -> $relativePath');
        }

        // 跳过目录本身
        if (relativePath == normalizedPath || relativePath == '$normalizedPath/') {
          continue;
        }

        // 获取文件属性 - 在 propstat/prop 中
        final propElement = resp.findAllElements('prop', namespace: '*').firstOrNull;
        if (propElement == null) continue;

        // 获取各种属性（处理命名空间）
        final getContentLength = propElement.findAllElements('getcontentlength', namespace: '*').firstOrNull?.innerText;
        final getLastModified = propElement.findAllElements('getlastmodified', namespace: '*').firstOrNull?.innerText;
        final resourceType = propElement.findAllElements('resourcetype', namespace: '*').firstOrNull;
        final isCollection = resourceType?.findAllElements('collection', namespace: '*').isNotEmpty ?? false;

        // 解析文件名
        final name = p.basename(relativePath);

        // 应用模式过滤
        if (pattern != null && pattern.contains('*')) {
          final regex = RegExp('^${pattern.replaceAll('*', '.*')}\$');
          if (!regex.hasMatch(name)) {
            continue;
          }
        } else if (pattern != null && name != pattern) {
          continue;
        }

        files.add(WebDavFile(
          name: name,
          path: relativePath, // 使用相对路径
          size: int.tryParse(getContentLength ?? '0') ?? 0,
          modified: getLastModified != null
              ? DateTime.tryParse(getLastModified) ?? DateTime.now()
              : DateTime.now(),
          isDirectory: isCollection,
        ));

        debugPrint('WebDavClient: 找到文件 - $name (相对路径: $relativePath, ${files.last.size} bytes, ${files.last.modified})');
      }

      appLog.info('WebDavClient: 列出目录成功 - 找到 ${files.length} 个文件');
      return files;
    } catch (e) {
      appLog.error('WebDavClient: 列出目录失败 - $e');
      rethrow;
    }
  }

  /// 查找指定目录中匹配模式的最新文件
  /// [dirPath] 目录路径
  /// [pattern] 文件名模式（例如：gstore_backup_*.json.gz）
  Future<WebDavFile?> findLatestFile(String dirPath, String pattern) async {
    try {
      final files = await listFiles(dirPath, pattern: pattern);

      if (files.isEmpty) {
        debugPrint('WebDavClient: 未找到匹配文件 - $pattern');
        return null;
      }

      // 按修改时间降序排序
      files.sort((a, b) => b.modified.compareTo(a.modified));

      final latest = files.first;
      debugPrint('WebDavClient: 找到最新文件 - ${latest.name} (${latest.modified})');
      return latest;
    } catch (e) {
      appLog.error('WebDavClient: 查找最新文件失败 - $e');
      return null;
    }
  }
}
