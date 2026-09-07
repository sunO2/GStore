import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:gstore/page/backup/state.dart';
import 'package:gstore/page/backup/widgets/backup_progress_sheet.dart';
import 'package:gstore/page/backup/widgets/backup_restore_sheet.dart';

/// BackupLogic WebDAV 注册表注入 + 下线降级测试
///
/// 验证（todo 9）：
/// - `ModuleManager.get<IWebDavService>()` 未绑定（模块下线）时
///   checkWebDavConfig / testWebDavConnection / uploadToWebDav /
///   downloadFromWebDav 安全降级不抛：check 置 notConfigured、
///   upload/download showWarning 且不发起上传/不弹面板
/// - 服务已绑定（bind 假实现）时功能路径不受影响（面板正常弹出）
/// - taskBusy 在 IWebDavTaskManager 未绑定时为 false 不崩
///   （走注册表 `?.isBusy ?? false`）；绑定时 busy 拦截生效
class _FakeWebDavService implements IWebDavService {
  int uploadCalls = 0;

  @override
  Future<bool> testWebDavConnection(WebDavConfig config) async => true;

  @override
  Future<List<WebDavFile>> listFiles(String dirPath, {String? pattern}) async => [];

  @override
  Future<String> uploadToWebDav({
    required WebDavConfig config,
    bool compressed = true,
    BackupOptions? options,
    List<ChannelType>? channels,
    bool includeAppConfig = false,
    BackupLogCallback? onLog,
  }) async {
    uploadCalls++;
    return '/GStore/x.tar.gz';
  }

  @override
  Future<BackupImportResult> downloadFromWebDav({
    required WebDavConfig config,
    required String remotePath,
    BackupImportMode mode = BackupImportMode.merge,
    bool restoreAppConfig = true,
    BackupLogCallback? onLog,
  }) async {
    final result = BackupImportResult();
    result.success = true;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    // 面板内 loadConfig 走 flutter_secure_storage 真实 channel：
    // 在 fake-async 测试环境下无 mock 时挂起，mock 返回 null（未配置）
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  /// 环境：AppDialogs snackbar 需要 MaterialApp + scaffoldMessengerKey
  Future<BuildContext> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));
    return tester.element(find.byType(Scaffold));
  }

  group('模块未绑定（get<IWebDavService>() == null）→ 安全降级', () {
    test('checkWebDavConfig：短路置 notConfigured，不读 secure storage 不抛', () async {
      final logic = BackupLogic();
      await logic.checkWebDavConfig();
      expect(logic.state.hasWebDavConfig, isFalse);
      expect(logic.state.webDavStatus, WebDavConnectionStatus.notConfigured);
    });

    test('testWebDavConnection：短路置 notConfigured，不抛', () async {
      final logic = BackupLogic();
      await logic.testWebDavConnection();
      expect(logic.state.webDavStatus, WebDavConnectionStatus.notConfigured);
    });

    testWidgets('uploadToWebDav：showWarning「模块未启用」且不弹面板、不置位', (tester) async {
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      // unawaited：模块下线（GREEN）时方法立即返回；旧实现（RED）会打开
      // 不可关闭的面板导致 await 挂起，故不 await 直接断言
      unawaited(logic.uploadToWebDav(context));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('WebDAV 模块未启用'), findsOneWidget);
      expect(find.byType(BackupProgressSheet), findsNothing);
      expect(logic.state.isUploadingWebDav, isFalse);
      expect(find.text('备份/恢复任务进行中，请稍候'), findsNothing);
    });

    testWidgets('downloadFromWebDav：showWarning「模块未启用」且不弹面板、不置位', (tester) async {
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      unawaited(logic.downloadFromWebDav(context));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('WebDAV 模块未启用'), findsOneWidget);
      expect(find.byType(BackupRestoreSheet), findsNothing);
      expect(logic.state.isImporting, isFalse);
    });
  });

  group('服务已绑定 → 功能路径不受影响', () {
    testWidgets('uploadToWebDav：不短路、面板正常弹出；taskBusy 未绑定时 false 不崩', (tester) async {
      ModuleManager.instance.bind<IWebDavService>(_FakeWebDavService());
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      unawaited(logic.uploadToWebDav(context));
      await tester.pump();
      await tester.pump();

      // 未走模块未启用短路，也未走 busy 拦截 → 面板弹出（config 未配置 → 面板内报错）
      expect(find.text('WebDAV 模块未启用'), findsNothing);
      expect(find.text('备份/恢复任务进行中，请稍候'), findsNothing);
      expect(find.byType(BackupProgressSheet), findsOneWidget);

      // 面板任务加载配置为 null → 错误态（未真正发起上传；onLog 与异常各渲染一次）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('未配置 WebDAV 信息'), findsWidgets);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(logic.state.isUploadingWebDav, isFalse);
    });

    testWidgets('downloadFromWebDav：不短路、恢复面板正常弹出', (tester) async {
      ModuleManager.instance.bind<IWebDavService>(_FakeWebDavService());
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      unawaited(logic.downloadFromWebDav(context));
      await tester.pump();
      await tester.pump();

      expect(find.text('WebDAV 模块未启用'), findsNothing);
      expect(find.byType(BackupRestoreSheet), findsOneWidget);

      // 关闭面板，isImporting 复位
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('关闭').first);
      await tester.pumpAndSettle();
      expect(logic.state.isImporting, isFalse);
    });
  });

  group('taskBusy 注册表化', () {
    testWidgets('IWebDavTaskManager 绑定时 busy → 拦截提示不弹面板', (tester) async {
      ModuleManager.instance.bind<IWebDavService>(_FakeWebDavService());
      ModuleManager.instance.bind<IWebDavTaskManager>(WebDavTaskManager.instance);
      final manager = WebDavTaskManager.instance;
      expect(manager.tryStart(WebDavTaskType.upload), isTrue);
      addTearDown(() => manager.finish(WebDavTaskType.upload));

      final context = await pumpApp(tester);

      final logic = BackupLogic();
      unawaited(logic.uploadToWebDav(context));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('备份/恢复任务进行中，请稍候'), findsOneWidget);
      expect(find.byType(BackupProgressSheet), findsNothing);
      expect(logic.state.isUploadingWebDav, isFalse);
    });
  });
}
