import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';

/// WebDavTaskManager 单测
///
/// 验证：
/// - tryStart 首次返回 true 并置位对应状态
/// - 同类型重复 tryStart 返回 false（防重复）
/// - 类型独立：upload 进行中 download 仍可开始
/// - finish 复位对应状态（互不影响）
/// - isBusy 反映任一任务进行中
void main() {
  final manager = WebDavTaskManager.instance;

  tearDown(() {
    // 复位单例状态，避免用例间串扰
    manager.finish(WebDavTaskType.upload);
    manager.finish(WebDavTaskType.download);
  });

  group('WebDavTaskManager', () {
    test('tryStart 首次返回 true 并置位 isUploading', () {
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      expect(manager.isUploading, isTrue);
      expect(manager.isBusy, isTrue);
    });

    test('同类型重复 tryStart 返回 false（防重复）', () {
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      expect(manager.tryStart(WebDavTaskType.upload), isFalse);
      expect(manager.isUploading, isTrue);
    });

    test('类型独立：upload 进行中 download 仍可开始', () {
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      expect(manager.tryStart(WebDavTaskType.download), isTrue);
      expect(manager.isUploading, isTrue);
      expect(manager.isDownloading, isTrue);
      expect(manager.isBusy, isTrue);
    });

    test('upload 进行中重复 upload 被拒（同类型互斥）', () {
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      expect(manager.tryStart(WebDavTaskType.upload), isFalse);
    });

    test('finish 复位对应状态，互不影响', () {
      manager.tryStart(WebDavTaskType.upload);
      manager.tryStart(WebDavTaskType.download);
      manager.finish(WebDavTaskType.upload);
      expect(manager.isUploading, isFalse);
      expect(manager.isDownloading, isTrue);
      expect(manager.isBusy, isTrue);
      manager.finish(WebDavTaskType.download);
      expect(manager.isBusy, isFalse);
    });

    test('finish 后任务可重新开始', () {
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      manager.finish(WebDavTaskType.upload);
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      manager.finish(WebDavTaskType.upload);
    });
  });
}
