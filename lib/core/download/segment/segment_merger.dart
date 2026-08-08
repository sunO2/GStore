import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

/// 段合并器
///
/// 将下载完成的多个 .part{index} 文件按索引顺序合并为完整文件：
/// 1. 流式读取每个 part 文件 → 追加写入 .temp 文件
/// 2. .temp 写入完成后 rename 为最终 savePath
/// 3. 删除所有 part 文件
///
/// 使用流式合并，避免把整个文件读入内存。
class SegmentMerger {
  /// 合并段文件为完整文件
  ///
  /// [savePath] 最终保存路径
  /// [segmentCount] 段数量（part 文件 index 为 0..segmentCount-1）
  ///
  /// 返回 true = 合并成功；false = 失败（部分 part 缺失等）
  static Future<bool> merge({
    required String savePath,
    required int segmentCount,
    int chunkSize = 64 * 1024,
  }) async {
    final target = File(savePath);
    final temp = File('${savePath}.temp');
    await target.parent.create(recursive: true);

    // 删除可能存在的旧 .temp
    if (await temp.exists()) {
      await temp.delete();
    }

    // 逐段合并
    final sink = temp.openWrite(mode: FileMode.writeOnly);
    try {
      for (var i = 0; i < segmentCount; i++) {
        final partFile = File('${savePath}.part$i');
        if (!await partFile.exists()) {
          appLog.error('SegmentMerger: 缺少段文件 ${partFile.path}');
          return false;
        }

        // 流式复制
        final partStream = partFile.openRead();
        await for (final chunk in partStream) {
          sink.add(chunk);
        }
        debugPrint('SegmentMerger: 已合并段[$i] (${partFile.lengthSync()} B)');
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      appLog.error('SegmentMerger: 合并失败 - $e');
      await sink.close();
      // 清理不完整的 .temp
      if (await temp.exists()) {
        await temp.delete();
      }
      return false;
    }

    // rename .temp → savePath
    try {
      await temp.rename(target.path);
    } catch (e) {
      appLog.error('SegmentMerger: 重命名失败 - $e');
      // 尝试复制兜底
      try {
        await temp.copy(target.path);
        await temp.delete();
      } catch (e2) {
        appLog.error('SegmentMerger: 复制兜底失败 - $e2');
        return false;
      }
    }

    // 清理 part 文件
    for (var i = 0; i < segmentCount; i++) {
      try {
        final partFile = File('${savePath}.part$i');
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } catch (e) {
        debugPrint('SegmentMerger: 清理段[$i] 失败（忽略）- $e');
      }
    }

    appLog.info('SegmentMerger: 合并完成 - $savePath');
    return true;
  }

  /// 清理孤儿 part 文件（下载被取消/中断后调用）
  static Future<void> cleanupParts(String savePath, int segmentCount) async {
    for (var i = 0; i < segmentCount; i++) {
      try {
        final partFile = File('${savePath}.part$i');
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } catch (e) {
        debugPrint('SegmentMerger: 清理段[$i] 失败（忽略）- $e');
      }
    }
  }
}
