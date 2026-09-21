// Task 16：模块管理页内部下载进度与错误呈现（不进用户下载管线）。
//
// 全部用例经 `RustModuleLoader.debugConfigure` 注入 probe / 带进度下载覆盖，
// 不触发真实 FFI、path_provider 或网络；并断言
// `DownloadNotificationService.debugCallCount` 恒为 0，证明模块内部下载
// 绝不复用用户下载通知管线。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/page/module_manage/view.dart';

/// 单模块单 ABI 的 v2 清单（测试注入，零网络）：仅声明 qr。
///
/// 插件成员由清单/本地并集决定（不再硬编码），故需显式注入才能看到 qr 行。
Map<String, dynamic> _manifestQr() => {
      'version': 2,
      'modules': {
        'qr': {
          'version': '1.0.0',
          'abi': {
            'x86_64': {
              'asset': 'libgstore_mod_qr_1.0.0-x86_64.so',
              'sha256': '0'.padRight(64, '0'),
              'size': 1,
            },
          },
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;

  setUp(() async {
    await ModuleManager.instance.clear();
    DownloadNotificationService.debugResetCallCount();
  });

  tearDown(() {
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
  });

  /// 铺满整页的大视口（17 个业务/系统条目之后才是原生插件区）。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 测试宿主 MaterialApp（挂载 appNavigatorKey / scaffoldMessengerKey）。
  Widget host(Widget home) => MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: home,
      );

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(child: host(const ModuleManagePage())),
    );
    await tester.pumpAndSettle();
  }

  RustModuleStatus none(String name) =>
      RustModuleStatus(name: name, exists: false, source: 'none');

  /// qr 可解析远端版本 → 「下载」按钮可用。
  RustModuleStatus remoteQr() => const RustModuleStatus(
        name: 'qr',
        exists: true,
        source: 'remote',
        remoteVersion: '1.0.0',
      );

  Finder qrDownload() => find.widgetWithText(FilledButton, '下载').first;

  // ---------------------------------------------------------------------------
  // 进度：注入 0 → 0.5 → 1.0，UI 逐级更新。
  // ---------------------------------------------------------------------------

  testWidgets('注入进度 0 → 0.5 → 1.0 逐级更新进度条与百分比',
      (tester) async {
    useTallViewport(tester);

    final gate05 = Completer<void>();
    final gate10 = Completer<void>();
    final gateDone = Completer<void>();

    loader.debugConfigure(
      installedNamesOverride: () async => const [],
      manifestOverride: _manifestQr(),
      probeOverride: (name) async =>
          name == 'qr' ? remoteQr() : none(name),
      downloadProgressOverride: (name, onProgress) async {
        onProgress?.call(0.0);
        await gate05.future;
        onProgress?.call(0.5);
        await gate10.future;
        onProgress?.call(1.0);
        await gateDone.future;
        return true;
      },
    );

    await pumpPage(tester);

    // 触发下载（busy 期间用 pump，不能用 pumpAndSettle：AppLoading 持续动画）。
    await tester.tap(qrDownload());
    await tester.pump();

    // 0%
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('下载中 0%'), findsOneWidget);

    // 0.5 → 50%
    gate05.complete();
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    expect(find.textContaining('下载中 50%'), findsOneWidget);

    // 1.0 → 100%
    gate10.complete();
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1.0,
    );
    expect(find.textContaining('下载中 100%'), findsOneWidget);

    // 结束：进度清除、busy 释放、成功 Snackbar。
    gateDone.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: '下载结束后必须清除进度，避免 stale state');
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('模块 qr 下载完成，重启应用后生效'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 内部下载全程绝不经用户通知管线。
    expect(DownloadNotificationService.debugCallCount, 0);
  });

  // ---------------------------------------------------------------------------
  // 错误：页面可见 + 统一 Snackbar，且通知服务调用计数为 0。
  // ---------------------------------------------------------------------------

  testWidgets('注入失败 → 页面/ Snackbar 可见错误，通知服务调用计数为 0',
      (tester) async {
    useTallViewport(tester);

    loader.debugConfigure(
      installedNamesOverride: () async => const [],
      manifestOverride: _manifestQr(),
      probeOverride: (name) async =>
          name == 'qr' ? remoteQr() : none(name),
      downloadProgressOverride: (name, onProgress) async {
        onProgress?.call(0.4);
        return false;
      },
    );

    await pumpPage(tester);
    await tester.tap(qrDownload());
    await tester.pumpAndSettle();

    // 统一 Snackbar（AppDialogs.showError）+ 页面内联错误行均展示。
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('下载未完成'), findsWidgets);
    // 进度已清除。
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // 无 busy 残留（AppLoading 已移除）。
    expect(find.byType(AppLoading), findsNothing);

    // 关键对抗断言：绝不进入用户下载通知管线。
    expect(
      DownloadNotificationService.debugCallCount,
      0,
      reason: '模块内部下载不得调用 DownloadNotificationService',
    );
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 成功：统一 Snackbar（AppDialogs.showSuccess）。
  // ---------------------------------------------------------------------------

  testWidgets('注入成功 → 经 AppDialogs 展示统一成功 Snackbar', (tester) async {
    useTallViewport(tester);

    loader.debugConfigure(
      installedNamesOverride: () async => const [],
      manifestOverride: _manifestQr(),
      probeOverride: (name) async =>
          name == 'qr' ? remoteQr() : none(name),
      downloadProgressOverride: (name, onProgress) async {
        onProgress?.call(1.0);
        return true;
      },
    );

    await pumpPage(tester);
    await tester.tap(qrDownload());
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('模块 qr 下载完成，重启应用后生效'),
      ),
      findsOneWidget,
    );
    expect(DownloadNotificationService.debugCallCount, 0);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // busy：使用 AppLoading（非裸 CircularProgressIndicator）。
  // ---------------------------------------------------------------------------

  testWidgets('busy 状态使用 AppLoading 且禁止重复触发', (tester) async {
    useTallViewport(tester);

    final hold = Completer<bool>();
    loader.debugConfigure(
      installedNamesOverride: () async => const [],
      manifestOverride: _manifestQr(),
      probeOverride: (name) async =>
          name == 'qr' ? remoteQr() : none(name),
      downloadProgressOverride: (name, onProgress) => hold.future,
    );
    await pumpPage(tester);

    // 清单仅声明 qr → 初始 1 个「下载」按钮（qr 可用）。
    expect(find.widgetWithText(FilledButton, '下载'), findsNWidgets(1));

    await tester.tap(qrDownload());
    await tester.pump();

    // busy：AppLoading 呈现；qr 行下载按钮被取代（防连击）；回退按钮禁用。
    expect(find.byType(AppLoading), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '下载'), findsNWidgets(0),
        reason: 'busy 的 qr 行不再渲染下载按钮');
    final rollback = find.widgetWithText(OutlinedButton, '回退到内置').first;
    expect(tester.widget<OutlinedButton>(rollback).onPressed, isNull);

    // 释放，避免遗留 pending timer / animation。
    hold.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(AppLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
