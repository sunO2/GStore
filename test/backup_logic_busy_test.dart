import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/webdav/webdav_service.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:gstore/page/backup/widgets/backup_progress_sheet.dart';

/// BackupLogic 同步检查测试
///
/// 验证：WebDAV 任务进行中（预置 busy）时，
/// uploadToWebDav / downloadFromWebDav 开头同步拦截：
/// - 弹出警告提示
/// - 不打开进度面板（BackupProgressSheet 不出现）
/// - 不置位 isUploadingWebDav / isImporting
void main() {
  final manager = WebDavTaskManager.instance;

  setUp(() {
    // taskBusy 经注册表取实现：绑定后 busy 拦截才生效；
    // 服务也需绑定——模块未启用短路在 busy 检查之前
    ModuleManager.instance.bind<IWebDavTaskManager>(manager);
    ModuleManager.instance.bind<IWebDavService>(WebDavService.instance);
  });

  tearDown(() {
    manager.finish(WebDavTaskType.upload);
    manager.finish(WebDavTaskType.download);
  });

  testWidgets('uploadToWebDav：任务进行中 → 提示且不弹面板', (tester) async {
    expect(manager.tryStart(WebDavTaskType.upload), isTrue);

    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));

    final logic = BackupLogic();
    await logic.uploadToWebDav(tester.element(find.byType(Scaffold)));
    await tester.pump();

    expect(find.byType(BackupProgressSheet), findsNothing);
    expect(logic.state.isUploadingWebDav.value, isFalse);
    expect(find.text('备份/恢复任务进行中，请稍候'), findsOneWidget);
  });

  testWidgets('downloadFromWebDav：任务进行中 → 提示且不弹面板', (tester) async {
    expect(manager.tryStart(WebDavTaskType.download), isTrue);

    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));

    final logic = BackupLogic();
    await logic.downloadFromWebDav(tester.element(find.byType(Scaffold)));
    await tester.pump();

    expect(find.byType(BackupProgressSheet), findsNothing);
    expect(logic.state.isImporting.value, isFalse);
    expect(find.text('备份/恢复任务进行中，请稍候'), findsOneWidget);
  });
}
