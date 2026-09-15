import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/service/app_version_service.dart';

/// IT Tools 离线包的落地与解压。
///
/// 离线包以 zip 形式随宿主资产分发（`assets/it_tools/it-tools.zip`），
/// 使用时解压到应用私有目录，再由 WebView 以 `file://` 直接加载。
///
/// 解压策略：用**应用版本号**做标记，首次进入与每次升级后各解压一次，
/// 之后直接复用，不会每次打开都重复解压 278 个文件。
class ItToolsService {
  ItToolsService._();

  /// 宿主资产中的离线包（由 it-tools 仓库的 `pnpm build:embed` 产出）
  static const String assetZipPath = 'assets/it_tools/it-tools.zip';

  /// 离线包入口文件
  static const String entryFile = 'index.html';

  /// 解压目标目录名（位于应用私有文档目录下）
  static const String _dirName = 'it_tools';

  /// 版本标记文件名，内容为解压时的应用版本号
  static const String _stampFileName = '.extracted_version';

  /// 确保离线包已解压到本地，返回解压目录。
  ///
  /// 已解压且版本一致时直接返回，不重复解压。
  static Future<Directory> ensureExtracted() async {
    final root = await _targetDir();
    final stamp = File(p.join(root.path, _stampFileName));
    final version = await AppVersionService.versionName() ?? 'unknown';

    if (await stamp.exists() && await stamp.readAsString() == version) {
      return root;
    }

    final data = await rootBundle.load(assetZipPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    // 先清空旧目录：升级后可能删过文件，增量覆盖会留下残骸
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await root.create(recursive: true);

    // 13MB / 278 个文件的落盘放后台 isolate，避免阻塞 UI
    await compute(_extractZipTo, _ExtractRequest(bytes, root.path));

    await stamp.writeAsString(version);
    debugPrint('ItToolsService: 离线包已解压到 ${root.path}（版本 $version）');
    return root;
  }

  /// 把 zip 字节解压到 [targetDir]。
  ///
  /// 公开以便单测直接调用（`compute` 需要顶层函数，见 [_extractZipTo]）。
  @visibleForTesting
  static Future<void> extractTo(Uint8List bytes, String targetDir) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final entry in archive.files) {
      if (!entry.isFile) continue;

      // zip-slip 防护：拒绝绝对路径与跳出目标目录的条目
      final normalized = p.normalize(entry.name.replaceAll('\\', '/'));
      if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
        debugPrint('ItToolsService: 跳过可疑条目 ${entry.name}');
        continue;
      }

      final target = File(p.join(targetDir, normalized));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.content as List<int>);
    }
  }

  /// 解压目标目录（不保证已存在）。
  ///
  /// 供「缓存管理」等外部方统计占用 / 清理复用，避免离线包路径散落多处。
  static Future<Directory> extractedDir() => _targetDir();

  /// 清理已解压的离线资源（连同版本标记一起删）。
  ///
  /// 清理后 [ensureExtracted] 找不到标记，下次进入页面会重新从资产解压。
  /// 返回是否真的删除了内容（目录本就不存在时为 false）。
  static Future<bool> clearExtracted() async {
    final dir = await _targetDir();
    if (!await dir.exists()) return false;
    await dir.delete(recursive: true);
    debugPrint('ItToolsService: 已清理离线资源 ${dir.path}');
    return true;
  }

  static Future<Directory> _targetDir() async {
    // 测试注入：避免依赖 path_provider 平台通道（与 CacheManageService 同套路）
    if (debugDocsDir != null) {
      return Directory(p.join(debugDocsDir!.path, _dirName));
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, _dirName));
  }

  /// 测试注入：应用文档目录替身
  @visibleForTesting
  static Directory? debugDocsDir;
}

/// isolate 解压任务入参（需可跨 isolate 传递）
class _ExtractRequest {
  const _ExtractRequest(this.bytes, this.targetDir);

  final Uint8List bytes;
  final String targetDir;
}

/// compute 要求顶层函数
Future<void> _extractZipTo(_ExtractRequest req) =>
    ItToolsService.extractTo(req.bytes, req.targetDir);
