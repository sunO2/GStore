import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:path_provider/path_provider.dart';

/// Outcome of a channel-pack import on the Rust script lane.
///
/// `CoreFlags.jsChannel` is on for the shipping path: the pack is installed by
/// the Rust `ScriptApi` and no Dart channel exists. The legacy Dart `JsChannel`
/// lane (and its `LegacyChannelImport` result) was removed in the pure-Rust
/// cleanup, so this is the only import outcome.
final class ScriptLaneChannelImport {
  const ScriptLaneChannelImport(this.pack);

  final rust_pack.ScriptPackInfo pack;
}

/// `CoreFlags.channels == true` 时旧 Dart 渠道包写入路径停用的类型化错误。
///
/// Rust core 接管 `channel` 域后，Dart 不得再写 zip 再让 `registerChannel`
/// 静默拒绝；调用方按 [code] 呈现明确提示。
class ChannelImportDisabledException implements Exception {
  const ChannelImportDisabledException(this.message);

  /// 稳定机器代码。
  static const String code = 'CORE_E_CHANNEL_LEGACY_DISABLED';

  /// 人类可读细节。
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 渠道包加载器：扫描渠道包目录 → 把 zip 渠道包导入 Rust 脚本通道。
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
/// ## 车道（Wave 6 closeout 之后的唯一车道）
/// 脚本渠道包由 Rust `ScriptApi` 拥有（`CoreFlags.jsChannel == true`，生产默认）。
/// 旧 Dart `JsChannel` 车道已删除；`loadAndRegister` 把渠道目录里的 zip 经
/// `ScriptChannelService`（`ScriptApi.init/import`）导入 Rust 通道，这是生产环境的
/// 启动加载入口。`CoreFlags.jsChannel == false` 时已无任何 Dart 车道可加载。
///
/// ## 错误处理
/// 单个渠道包失败（非 zip / 缺 entry.js / 路径穿越 / 初始化失败）
/// → 跳过 + 日志，不阻塞其他渠道包。
///
/// ## 幂等
/// 重复调用不重复导入：Rust `ScriptApi.import` 按 key upsert。
///
/// 返回值 = 本次调用**新导入**的渠道包列表（幂等跳过/失败的不包含在内）。
class ChannelLoader {
  /// 渠道包目录（默认 `文档目录/channels`）；注入可跳过 path_provider
  final Directory? _directoryOverride;

  /// 门禁日志只打一次（每次 skip 都打会刷屏）。
  static bool _disabledLogged = false;

  ChannelLoader({Directory? directory}) : _directoryOverride = directory;

  /// 读取内置 assets 中的脚本（示例模板；供导入入口/测试使用）。
  static Future<String> loadAssetScript(String assetPath) {
    return rootBundle.loadString(assetPath);
  }

  /// 扫描渠道包目录（`channels/*.zip`）→ 导入 Rust 脚本通道 → 返回本次导入的包列表。
  ///
  /// 目录不存在或为空 → 返回空列表（不报错）；
  /// 单个渠道包无效/导入失败 → 跳过并日志，不阻塞其他。
  ///
  /// `CoreFlags.jsChannel == false` 时 Dart 车道已删除，无任何渠道可加载 →
  /// 返回空列表（旧 Dart `JsChannel` 构建/注册路径已随纯 Rust 清理删除）。
  Future<List<rust_pack.ScriptPackInfo>> loadAndRegister() async {
    if (!ChannelManager.instance.dartScriptChannelsEnabled) {
      if (!_disabledLogged) {
        _disabledLogged = true;
        appLog.info(
            'ChannelLoader: CoreFlags.jsChannel=true，Dart 脚本渠道由 Rust ScriptApi 接管');
      }
      final directory = await _resolveDirectory();
      if (directory == null) return const [];
      final imported =
          await ScriptChannelService.instance.syncInstalledPacks(directory);
      // Refresh the UI-facing Rust-lane cache so discovery/settings see the packs.
      await RustScriptChannelLane.instance.refresh();
      if (imported.isNotEmpty) {
        appLog.info(
            'ChannelLoader: 已向 Rust 脚本通道导入 ${imported.length} 个渠道包');
      }
      return imported;
    }

    // Dart 脚本车道已删除：flag off 时没有任何渠道可加载/注册。
    return const [];
  }

  /// 导入 zip 渠道包（Android 应用私有目录无法读取用户手动放置的公共
  /// Documents 文件，走应用内导入）。
  ///
  /// [channelKey] 为最终渠道标识（如 `js_vivo`，与 [loadAndRegister] 的
  /// 文件名校验一致：`^[a-zA-Z_][a-zA-Z0-9_]*$`，非法抛 [ArgumentError]）。
  ///
  /// **Lane**：`CoreFlags.jsChannel == true` 时 zip 只暂存到临时文件后交给
  /// Rust `ScriptApi.import`（返回 [ScriptLaneChannelImport]），临时文件在
  /// `finally` 删除，失败抛 [ScriptChannelImportException] 且不写旧渠道目录。
  /// `CoreFlags.jsChannel == false` 时 Dart 车道已删除 → 抛
  /// [ChannelImportDisabledException]（类型化拒绝，绝不静默写入）。
  Future<ScriptLaneChannelImport> importZip({
    required String channelKey,
    required Uint8List zipBytes,
  }) async {
    if (CoreFlags.jsChannel) {
      // Rust 脚本通道：不触碰 LegacyWriteGuard / 旧渠道目录，失败也不落盘。
      final pack = await ScriptChannelService.instance.importPack(
        channelKey: channelKey,
        zipBytes: zipBytes,
      );
      // Keep the UI-facing Rust-lane cache in sync (discovery/settings read it).
      await RustScriptChannelLane.instance.refresh();
      return ScriptLaneChannelImport(pack);
    }
    throw const ChannelImportDisabledException(
        'channels/jsChannel 已由 Rust core 接管，Dart 渠道包写入路径已停用');
  }

  /// 删除渠道包渠道：从 Rust 脚本通道移除（幂等）+ 清理切轨前可能残留的旧 zip 文件。
  ///
  /// [channelKey] 校验与 [importZip] 一致（非法抛 [ArgumentError]，
  /// 防止路径穿越删除任意文件）。
  /// `CoreFlags.jsChannel == false` 时 Dart 车道已删除，无包可删（no-op）。
  Future<void> removeChannel(String channelKey) async {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(channelKey)) {
      throw ArgumentError.value(
          channelKey, 'channelKey', '非法渠道标识（需字母/下划线开头，仅含字母数字下划线）');
    }
    if (!CoreFlags.jsChannel) {
      // Dart 脚本渠道已删除；旧轨无包可删。
      return;
    }
    await ScriptChannelService.instance.removePack(channelKey);
    // Keep the UI-facing Rust-lane cache in sync after a delete.
    await RustScriptChannelLane.instance.refresh();
    final directory = await _resolveDirectory();
    if (directory != null) {
      final fileName = channelKey.startsWith('js_')
          ? channelKey.substring(3)
          : channelKey;
      final file = File('${directory.path}/$fileName.zip');
      if (file.existsSync()) file.deleteSync();
    }
    appLog.info('ChannelLoader: 渠道包渠道 $channelKey 已从 Rust 脚本通道删除');
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
