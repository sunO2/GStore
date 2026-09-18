// Task 15：模块管理页原生插件「下载 / 更新 / 回退」交互。
//
// 全部用例经 `RustModuleLoader.debugConfigure` 注入 supportDir / 清单 / probe /
// rollback / download 覆盖，不触发真实 FFI、path_provider 或网络。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/page/module_manage/view.dart';
import 'package:path/path.dart' as p;

/// 单模块单 ABI 的 v2 清单（测试注入，零网络）。
Map<String, dynamic> _manifest({
  required String module,
  required String version,
  String abi = 'x86_64',
}) =>
    {
      'version': 2,
      'modules': {
        module: {
          'version': version,
          'abi': {
            abi: {
              'asset': 'libgstore_mod_${module}_$version-$abi.so',
              'sha256': sha256.convert(utf8.encode(module)).toString(),
              'size': 1,
            },
          },
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeSupportDir() {
    final dir = Directory.systemTemp.createTempSync('gstore_module_ui_test_');
    tempDirs.add(dir);
    return dir;
  }

  Directory moduleDir(Directory supportDir, String name) =>
      Directory(p.join(supportDir.path, 'gstore_modules', name));

  /// 写入「合法 .so + 匹配 .meta」的已验证下载产物。
  File writeVerified(
    Directory dir,
    String name,
    String version,
    String bytes,
  ) {
    dir.createSync(recursive: true);
    final so = File(p.join(dir.path, 'libgstore_mod_${name}_$version.so'))
      ..writeAsBytesSync(utf8.encode(bytes));
    File('${so.path}.meta').writeAsStringSync(jsonEncode({
      'name': name,
      'version': version,
      'abi': 'x86_64',
      'sha256': sha256.convert(utf8.encode(bytes)).toString(),
      'source': 'remote',
    }));
    return so;
  }

  /// 隔离标记：把 [fileName] / [version] 记入下载目录的 `quarantine.json`。
  void writeQuarantine(Directory dir, String fileName, String version) {
    File(p.join(dir.path, 'quarantine.json')).writeAsStringSync(jsonEncode({
      version: {
        'version': version,
        'file': fileName,
        'reason': 'mount_failed',
      },
    }));
  }

  setUp(() async {
    await ModuleManager.instance.clear();
  });

  tearDown(() {
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
    for (final dir in tempDirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    tempDirs.clear();
  });

  // ---------------------------------------------------------------------------
  // 真实探测（无 FFI/网络）：probe 与解析顺序一致且隔离感知。
  // ---------------------------------------------------------------------------

  group('probe 解析一致性 / 隔离感知', () {
    test('隔离的下载产物 → 不可用，绝不回落为「可远程」', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'qr');
      writeVerified(dir, 'qr', '1.0.0', 'QUARANTINED');
      writeQuarantine(dir, 'libgstore_mod_qr_1.0.0.so', '1.0.0');

      loader.debugConfigure(
        supportDir: supportDir.path,
        // 远端可解析也必须被隔离态拦截，不得展示为可下载来源。
        manifestOverride: _manifest(module: 'qr', version: '2.0.0'),
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr', withRemote: true);
      expect(status.exists, isFalse);
      expect(status.source, 'none');
      expect(status.quarantined, isTrue);
      expect(status.hasDownloaded, isTrue);
      expect(status.remoteVersion, isNull,
          reason: '隔离态不得被展示为可用的远程下载');
    });

    test('无效下载产物（缺 .meta）→ 不可用，不回落为「可远程」', () async {
      final supportDir = makeSupportDir();
      final dir = moduleDir(supportDir, 'qr')..createSync(recursive: true);
      File(p.join(dir.path, 'libgstore_mod_qr_1.0.0.so'))
          .writeAsBytesSync(utf8.encode('NO_META'));

      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(module: 'qr', version: '2.0.0'),
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr', withRemote: true);
      expect(status.exists, isFalse);
      expect(status.source, 'none');
      expect(status.remoteVersion, isNull);
    });

    test('有效下载 + 更高远端 → downloaded 且 updateAvailable', () async {
      final supportDir = makeSupportDir();
      writeVerified(moduleDir(supportDir, 'qr'), 'qr', '1.0.0', 'LOCAL_V1');

      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(module: 'qr', version: '2.0.0'),
        builtinManifestOverride: const {},
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr', withRemote: true);
      expect(status.source, 'downloaded');
      expect(status.exists, isTrue);
      expect(status.version, '1.0.0');
      expect(status.remoteVersion, '2.0.0');
      expect(status.updateAvailable, isTrue);
    });

    test('内置随包 → builtin，且远端版本可解析', () async {
      final supportDir = makeSupportDir();
      loader.debugConfigure(
        supportDir: supportDir.path,
        manifestOverride: _manifest(module: 'qr', version: '0.2.0'),
        builtinManifestOverride: {
          'qr': {'version': '0.1.0'},
        },
        isLoadedOverride: (_) async => false,
      );

      final status = await loader.probe('qr', withRemote: true);
      expect(status.source, 'builtin');
      expect(status.exists, isTrue);
      expect(status.version, '0.1.0');
      expect(status.remoteVersion, '0.2.0');
      expect(status.updateAvailable, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Widget：注入 loader 接缝，验证 UI 渲染与交互。
  // ---------------------------------------------------------------------------

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

  group('原生插件行操作', () {
    testWidgets('插件行渲染「下载」与「回退到内置」按钮', (tester) async {
      useTallViewport(tester);
      loader.debugConfigure(
        probeOverride: (name) async => name == 'qr'
            ? const RustModuleStatus(
                name: 'qr',
                exists: true,
                source: 'remote',
                remoteVersion: '1.0.0',
              )
            : none(name),
      );

      await pumpPage(tester);

      // 下载按钮 + 回退按钮均渲染。
      expect(find.text('下载'), findsWidgets);
      expect(find.text('回退到内置'), findsWidgets);

      // qr 有可解析远端版本 → 下载按钮可用。
      final qrDownload = find.widgetWithText(FilledButton, '下载').first;
      expect(tester.widget<FilledButton>(qrDownload).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已下载有效产物 + 远端更高版本 → 显示「更新」且可用', (tester) async {
      useTallViewport(tester);
      loader.debugConfigure(
        probeOverride: (name) async => name == 'qr'
            ? const RustModuleStatus(
                name: 'qr',
                exists: true,
                source: 'downloaded',
                version: '1.0.0',
                remoteVersion: '2.0.0',
                updateAvailable: true,
                hasDownloaded: true,
              )
            : none(name),
      );

      await pumpPage(tester);

      expect(find.textContaining('本地 1.0.0'), findsOneWidget);
      expect(find.textContaining('远端 2.0.0'), findsOneWidget);

      final update = find.widgetWithText(FilledButton, '更新');
      expect(update, findsOneWidget);
      expect(tester.widget<FilledButton>(update).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('隔离模块渲染为不可用：按钮禁用 + 隔离说明', (tester) async {
      useTallViewport(tester);
      loader.debugConfigure(
        probeOverride: (name) async => name == 'qr'
            ? const RustModuleStatus(
                name: 'qr',
                exists: false,
                source: 'none',
                hasDownloaded: true,
                quarantined: true,
              )
            : none(name),
      );

      await pumpPage(tester);

      // 隔离说明（quarantine-aware，不当作可用下载）。
      expect(find.textContaining('已被隔离'), findsOneWidget);

      // qr 的下载按钮禁用；回退按钮仍可用于恢复。
      final qrDownload = find.widgetWithText(FilledButton, '下载').first;
      expect(tester.widget<FilledButton>(qrDownload).onPressed, isNull);
      final qrRollback = find.widgetWithText(OutlinedButton, '回退到内置').first;
      expect(tester.widget<OutlinedButton>(qrRollback).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('回退交互', () {
    testWidgets('点击回退经统一底部弹层确认 → 调用注入 rollback 并刷新状态',
        (tester) async {
      useTallViewport(tester);
      var rolledBack = false;
      var rollbackCalls = 0;

      RustModuleStatus statusOf(String name) {
        if (name != 'qr') return none(name);
        if (rolledBack) {
          return const RustModuleStatus(
            name: 'qr',
            exists: true,
            source: 'builtin',
            version: '1.0.0',
          );
        }
        return const RustModuleStatus(
          name: 'qr',
          exists: false,
          source: 'none',
          hasDownloaded: true,
          quarantined: true,
        );
      }

      loader.debugConfigure(
        probeOverride: (name) async => statusOf(name),
        rollbackOverride: (name) async {
          rollbackCalls++;
          if (name == 'qr') rolledBack = true;
          return true;
        },
      );

      await pumpPage(tester);

      // 初始：qr 被隔离、回退可用。
      expect(find.textContaining('已被隔离'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '回退到内置').first);
      await tester.pumpAndSettle();

      // 危险操作确认走统一底部弹层（AppSheetScaffold），非裸 AlertDialog。
      expect(find.byType(AppSheetScaffold), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('回退'), findsOneWidget);

      await tester.tap(find.text('回退'));
      await tester.pumpAndSettle();

      // 注入回退被真实调用一次，且状态刷新为内置可用。
      expect(rollbackCalls, 1, reason: '确认后必须真实调用注入的回退');
      expect(find.textContaining('产物: 内置'), findsOneWidget,
          reason: '回退后必须刷新为内置可用状态');
      expect(find.textContaining('已被隔离'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消危险确认 → 不调用 rollback', (tester) async {
      useTallViewport(tester);
      var rollbackCalls = 0;

      loader.debugConfigure(
        probeOverride: (name) async => name == 'qr'
            ? const RustModuleStatus(
                name: 'qr',
                exists: false,
                source: 'none',
                hasDownloaded: true,
                quarantined: true,
              )
            : none(name),
        rollbackOverride: (_) async {
          rollbackCalls++;
          return true;
        },
      );

      await pumpPage(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '回退到内置').first);
      await tester.pumpAndSettle();

      expect(find.byType(AppSheetScaffold), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(rollbackCalls, 0, reason: '取消后不得调用回退');
      expect(tester.takeException(), isNull);
    });
  });
}
