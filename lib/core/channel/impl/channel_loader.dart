import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:path_provider/path_provider.dart';

/// 渠道包加载器：扫描渠道包目录 → 解析 zip 包 → 创建 [JsChannel] → 注册到 [ChannelManager]。
///
/// ## 渠道包规范（zip）
/// ```
/// channels/<key>.zip
/// ├── entry.js    （必须：发现页脚本，main 分发器：getAllApps/searchApps/getAppInfo 等）
/// ├── detail.js   （可选：详情页脚本，main 分发器：getAppDetail/versionOptions/switchVersion/buildHistory/detailMenu 等）
/// └── meta.json   （可选：{ "name": "...", "description": "...", "icon": "..." }）
/// ```
/// channelKey = `'js_' + zip 文件名（无 .zip）`，如 `vivo.zip` → `js_vivo`；
/// `js_` 前缀规避与内置渠道 code 冲突。**单文件 .js 不再支持**（旧格式不兼容，
/// 不再扫描 `channels/*.js`，请改用 zip 渠道包）。
///
/// ## 渠道包来源
/// - **用户渠道目录**：`getApplicationDocumentsDirectory()/channels/*.zip`
///   （可注入 `directory` 覆盖，测试用）；目录不存在/为空不报错
/// - **内置示例模板**：`assets/channels/example.js`（经 [loadAssetScript] 读取，
///   仅文档/测试参考——单 .js 文件不再兼容导入（导入入口走 .zip 渠道包），
///   请按上方规范打包为 zip 后经 [importZip] 导入；**不随 loadAndRegister 注册**）
///
/// > **Android 目录说明**：`getApplicationDocumentsDirectory()` 是应用私有目录，
/// > 用户手动放入公共 Documents 的文件**读不到**。Android 用户请走
/// > [importZip] 应用内导入；iOS/桌面用户仍可手动放 zip 包到该目录。
///
/// ## 错误处理
/// 单个渠道包失败（非 zip / 缺 entry.js / 路径穿越 / JS 语法错误 / 初始化失败）
/// → 跳过 + 日志，不阻塞其他渠道包。
///
/// ## 幂等
/// 重复调用不重复注册：
/// - 同名 key 已存在且包内容相同（entry.js/detail.js/meta.json 均未变）→ 跳过
/// - 同名 key 已存在但内容变化 → 注销旧渠道后重新注册（更新）
///
/// 返回值 = 本次调用**新注册**的渠道列表（幂等跳过的不包含在内）。
class ChannelLoader {
  final Dio? _dio;
  final ChannelAddedAppDao? _appDao;

  /// 渠道包目录（默认 `文档目录/channels`）；注入可跳过 path_provider
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

  /// 扫描渠道包目录（`channels/*.zip`）→ 解析校验（initialize）→ 注册
  /// → 返回新注册的渠道列表。
  ///
  /// 目录不存在或为空 → 返回空列表（不报错）；
  /// 单个渠道包无效/加载失败 → 跳过并日志，不阻塞其他。
  Future<List<JsChannel>> loadAndRegister() async {
    final directory = await _resolveDirectory();
    if (directory == null) return const [];

    if (!directory.existsSync()) {
      appLog.info('ChannelLoader: 渠道包目录不存在，跳过: ${directory.path}');
      return const [];
    }

    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      appLog.info('ChannelLoader: 渠道包目录为空: ${directory.path}');
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
        final pkg = ChannelPackage.decode(await file.readAsBytes());
        if (pkg == null) {
          appLog.warning('ChannelLoader: 跳过无效 zip 渠道包（非 zip/缺 entry.js/路径穿越）: $fileName');
          continue;
        }
        if (pkg.entryScript.trim().isEmpty) {
          appLog.warning('ChannelLoader: 跳过空 entry.js: $fileName');
          continue;
        }

        // 幂等：同名 key 已注册
        final existing = manager.getChannelByKey(key);
        if (existing is JsChannel) {
          if (_samePackage(existing, pkg)) {
            appLog.info('ChannelLoader: 渠道 $key 已存在且包内容未变更，跳过');
            continue;
          }
          appLog.info('ChannelLoader: 渠道 $key 包内容已变更，更新注册');
          manager.unregisterChannelByKey(key);
        }

        final channel = _buildChannel(key, pkg);

        // 校验：加载引擎 + 执行脚本，失败即跳过（语法错误/初始化失败）
        try {
          await channel.initialize();
        } catch (e) {
          appLog.error('ChannelLoader: 渠道包 $fileName 加载/初始化失败，跳过: $e');
          await channel.dispose();
          continue;
        }

        manager.registerChannel(channel);
        registered.add(channel);
        appLog.info('ChannelLoader: 渠道包渠道 $key 注册成功');
      } catch (e) {
        appLog.error('ChannelLoader: 渠道包 $fileName 处理失败，跳过: $e');
      }
    }

    return registered;
  }

  /// 文件名 → channelKey（'js_' + 去 .zip 扩展）；非法标识符返回 null
  static String? _channelKeyFromFileName(String fileName) {
    final name = fileName.endsWith('.zip')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
    if (name.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) return null;
    return 'js_$name';
  }

  /// 包内容幂等比对：entry.js / detail.js / meta.json 全部一致才算未变更
  bool _samePackage(JsChannel channel, ChannelPackage pkg) {
    if (channel.scriptSource != pkg.entryScript) return false;
    if (channel.detailScript != pkg.detailScript) return false;
    return jsonEncode(channel.meta ?? const <String, dynamic>{}) ==
        jsonEncode(pkg.meta ?? const <String, dynamic>{});
  }

  /// 由解析后的渠道包构建 [JsChannel]（detailScript/meta 一并携带，Wave 2 使用）
  JsChannel _buildChannel(String key, ChannelPackage pkg) {
    return JsChannel(
      channelKey: key,
      script: pkg.entryScript,
      detailScript: pkg.detailScript,
      meta: pkg.meta,
      pkg: pkg,
      dio: _dio,
      appDao: _appDao,
    );
  }

  /// 导入 zip 渠道包（Android 应用私有目录无法读取用户手动放置的公共
  /// Documents 文件，走应用内导入）。
  ///
  /// [channelKey] 为最终渠道标识（如 `js_vivo`，与 [loadAndRegister] 的
  /// 文件名校验一致：`^[a-zA-Z_][a-zA-Z0-9_]*$`，非法抛 [ArgumentError]）。
  /// zip 包写入渠道目录（`<key 去 js_ 前缀>.zip`，目录不存在自动创建），
  /// 保证后续 [loadAndRegister] 扫描可 round-trip 还原同一 key（不产生
  /// `js_js_` 双前缀重复渠道）。
  ///
  /// 包校验（[ChannelPackage.decode]）：非 zip / 缺 entry.js / 路径穿越条目
  /// → 抛 [ArgumentError]（调用方提示）；校验通过才落盘。
  ///
  /// 幂等：同名 key 已注册且包内容未变 → 直接返回现有渠道；
  /// 内容变化 → 注销旧渠道后注册新渠道（覆盖）。
  /// 校验失败（JS 语法错误/初始化失败）→ 回滚文件 + 抛异常（调用方提示）。
  Future<JsChannel> importZip({
    required String channelKey,
    required Uint8List zipBytes,
  }) async {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(channelKey)) {
      throw ArgumentError.value(
          channelKey, 'channelKey', '非法渠道标识（需字母/下划线开头，仅含字母数字下划线）');
    }
    final pkg = ChannelPackage.decode(zipBytes);
    if (pkg == null) {
      throw ArgumentError.value(
          zipBytes, 'zipBytes', '无效的 zip 渠道包（非 zip/缺 entry.js/路径穿越）');
    }
    if (pkg.entryScript.trim().isEmpty) {
      throw ArgumentError.value(zipBytes, 'zipBytes', '渠道包 entry.js 内容为空');
    }

    final directory = await _resolveDirectory();
    if (directory == null) {
      throw StateError('无法解析渠道包目录');
    }
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    // 文件名 = key 去 'js_' 前缀（与 loadAndRegister 的 key 推导互逆，round-trip）
    final fileName = channelKey.startsWith('js_')
        ? channelKey.substring(3)
        : channelKey;
    final file = File('${directory.path}/$fileName.zip');

    // 记录旧文件内容（校验失败回滚用）
    final oldBytes = file.existsSync() ? await file.readAsBytes() : null;

    // 写文件 → 校验（initialize）→ 注册；失败回滚文件 + 抛错
    await file.writeAsBytes(zipBytes);

    final manager = ChannelManager.instance;
    final existing = manager.getChannelByKey(channelKey);
    if (existing is JsChannel && _samePackage(existing, pkg)) {
      appLog.info('ChannelLoader: 导入渠道 $channelKey 已存在且包内容未变更，跳过');
      return existing;
    }

    final channel = _buildChannel(channelKey, pkg);
    try {
      await channel.initialize();
    } catch (e) {
      await channel.dispose();
      // 回滚：恢复旧内容（无旧内容则删除）
      if (oldBytes != null) {
        await file.writeAsBytes(oldBytes);
      } else if (file.existsSync()) {
        file.deleteSync();
      }
      appLog.error('ChannelLoader: 导入渠道 $channelKey 校验失败，已回滚: $e');
      rethrow;
    }

    // 覆盖：注销旧渠道（同 key）后注册新渠道
    if (existing != null) {
      manager.unregisterChannelByKey(channelKey);
    }
    manager.registerChannel(channel);
    appLog.info('ChannelLoader: 渠道包渠道 $channelKey 导入成功');
    return channel;
  }

  /// 删除渠道包渠道：注销注册 + 删除 .zip 文件 + 清空环境变量持久化。
  ///
  /// [channelKey] 校验与 [importZip] 一致（非法抛 [ArgumentError]，
  /// 防止路径穿越删除任意文件）。
  /// 幂等：渠道未注册（仅残留文件/env）也清理文件与 env。
  /// env 清空失败不阻塞文件删除与注销（ConfigStore 未初始化等场景容错）。
  Future<void> removeChannel(String channelKey) async {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(channelKey)) {
      throw ArgumentError.value(
          channelKey, 'channelKey', '非法渠道标识（需字母/下划线开头，仅含字母数字下划线）');
    }

    // 注销（内部 dispose）；未注册则跳过
    ChannelManager.instance.unregisterChannelByKey(channelKey);

    // 清空 env 持久化（channel_env_<key> 敏感路由；未注册渠道也清理残留）
    try {
      await ConfigJsChannelEnvStore(channelKey).save(const {});
    } catch (e) {
      appLog.error('ChannelLoader: 清空渠道 $channelKey 环境变量失败（不影响删除）: $e');
    }

    // 删除渠道包文件（key 去 'js_' 前缀，与 importZip round-trip）
    final directory = await _resolveDirectory();
    if (directory == null) return;
    final fileName = channelKey.startsWith('js_')
        ? channelKey.substring(3)
        : channelKey;
    final file = File('${directory.path}/$fileName.zip');
    if (file.existsSync()) {
      file.deleteSync();
    }
    appLog.info('ChannelLoader: 渠道包渠道 $channelKey 已删除（注销 + 文件 + env）');
  }

  Future<Directory?> _resolveDirectory() async {
    final override = _directoryOverride;
    if (override != null) return override;
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/channels');
    } catch (e) {
      appLog.error('ChannelLoader: 无法解析用户渠道包目录: $e');
      rethrow;
    }
  }
}
