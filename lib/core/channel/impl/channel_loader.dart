import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:path_provider/path_provider.dart';

/// 脚本渠道加载器：扫描渠道脚本目录 → 创建 [JsChannel] → 注册到 [ChannelManager]。
///
/// ## 脚本来源
/// - **用户渠道目录**：`getApplicationDocumentsDirectory()/channels/*.js`
///   （可注入 `directory` 覆盖，测试用）；目录不存在/为空不报错
/// - **内置示例模板**：`assets/channels/example.js`（经 [loadAssetScript] 读取，
///   仅模板供用户复制导入，**不随 loadAndRegister 注册**）
///
/// ## channelKey 规范
/// `key = 'js_' + 文件名（无扩展名）`，如 `vivo.js` → `js_vivo`；
/// `js_` 前缀规避与内置渠道 code 冲突。文件名必须是合法标识符
/// （`^[a-zA-Z_][a-zA-Z0-9_]*$`），非法文件名跳过。
///
/// ## 错误处理
/// 单个脚本失败（文件读取失败 / JS 语法错误 / 初始化失败）→ 跳过 + 日志，
/// 不阻塞其他脚本。
///
/// ## 幂等
/// 重复调用不重复注册：
/// - 同名 key 已存在且脚本内容相同 → 跳过
/// - 同名 key 已存在但内容变化 → 注销旧渠道后重新注册（更新）
///
/// 返回值 = 本次调用**新注册**的渠道列表（幂等跳过的不包含在内）。
class ChannelLoader {
  final Dio? _dio;
  final ChannelAddedAppDao? _appDao;

  /// 渠道脚本目录（默认 `文档目录/channels`）；注入可跳过 path_provider
  final Directory? _directoryOverride;

  ChannelLoader({
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Directory? directory,
  })  : _dio = dio,
        _appDao = appDao,
        _directoryOverride = directory;

  /// 读取内置 assets 中的脚本（示例模板；供导入入口/测试使用）。
  static Future<String> loadAssetScript(String assetPath) {
    return rootBundle.loadString(assetPath);
  }

  /// 扫描脚本目录 → 校验（initialize）→ 注册 → 返回新注册的渠道列表。
  ///
  /// 目录不存在或为空 → 返回空列表（不报错）；
  /// 单个脚本加载/校验失败 → 跳过并日志，不阻塞其他。
  Future<List<JsChannel>> loadAndRegister() async {
    final directory = await _resolveDirectory();
    if (directory == null) return const [];

    if (!directory.existsSync()) {
      appLog.info('ChannelLoader: 渠道脚本目录不存在，跳过: ${directory.path}');
      return const [];
    }

    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.js'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      appLog.info('ChannelLoader: 渠道脚本目录为空: ${directory.path}');
      return const [];
    }

    final registered = <JsChannel>[];
    final manager = ChannelManager.instance;

    for (final file in files) {
      final fileName = file.uri.pathSegments.last;
      final key = _channelKeyFromFileName(fileName);
      if (key == null) {
        appLog.warning('ChannelLoader: 跳过非法文件名（非合法标识符）: $fileName');
        continue;
      }

      try {
        final script = await file.readAsString();
        if (script.trim().isEmpty) {
          appLog.warning('ChannelLoader: 跳过空脚本: $fileName');
          continue;
        }

        // 幂等：同名 key 已注册
        final existing = manager.getChannelByKey(key);
        if (existing is JsChannel) {
          if (existing.scriptSource == script) {
            appLog.info('ChannelLoader: 渠道 $key 已存在且未变更，跳过');
            continue;
          }
          appLog.info('ChannelLoader: 渠道 $key 脚本已变更，更新注册');
          manager.unregisterChannelByKey(key);
        }

        final channel = JsChannel(
          channelKey: key,
          script: script,
          dio: _dio,
          appDao: _appDao,
        );

        // 校验：加载引擎 + 执行脚本，失败即跳过（语法错误/初始化失败）
        try {
          await channel.initialize();
        } catch (e) {
          appLog.error('ChannelLoader: 脚本 $fileName 加载/初始化失败，跳过: $e');
          await channel.dispose();
          continue;
        }

        manager.registerChannel(channel);
        registered.add(channel);
        appLog.info('ChannelLoader: 脚本渠道 $key 注册成功');
      } catch (e) {
        appLog.error('ChannelLoader: 脚本 $fileName 处理失败，跳过: $e');
      }
    }

    return registered;
  }

  /// 文件名 → channelKey（'js_' + 去扩展名）；非法标识符返回 null
  static String? _channelKeyFromFileName(String fileName) {
    final name = fileName.endsWith('.js')
        ? fileName.substring(0, fileName.length - 3)
        : fileName;
    if (name.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) return null;
    return 'js_$name';
  }

  Future<Directory?> _resolveDirectory() async {
    final override = _directoryOverride;
    if (override != null) return override;
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/channels');
    } catch (e) {
      appLog.error('ChannelLoader: 无法解析用户渠道目录: $e');
      rethrow;
    }
  }
}
