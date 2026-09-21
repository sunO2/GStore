// 模块管理页「原生插件」列表改为「清单成员 ∪ 本地已安装」，不再硬编码。
//
// 覆盖：清单顺序 + 仅本地按字典序、去重、元数据缺失回退、清单不可用降级、
// 双空空状态、`llm` 在未声明且未安装时消失。
// 全部用例经 `RustModuleLoader.debugConfigure` 注入 manifestOverride / supportDir /
// probeOverride，零 FFI、零网络、无真实清单。
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/page/module_manage/logic.dart';
import 'package:gstore/page/module_manage/state.dart';
import 'package:gstore/page/module_manage/view.dart';
import 'package:path/path.dart' as p;

/// 单模块单 ABI 的 v2 清单（测试注入，零网络）。
Map<String, dynamic> _manifest(List<String> names) => {
      'version': 2,
      'modules': {
        for (final name in names)
          name: {
            'version': '1.0.0',
            'abi': {
              'x86_64': {
                'asset': 'libgstore_mod_${name}_1.0.0-x86_64.so',
                'sha256': '0'.padRight(64, '0'),
                'size': 1,
              },
            },
          },
      },
    };

/// 清单来源永远返回 null（模拟网络/缓存/随包兜底全部不可用）。
class _NullManifestSource implements ModuleManifestSource {
  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = RustModuleLoader.instance;
  final tempDirs = <Directory>[];

  Directory makeSupport(List<String> installed) {
    final root = Directory.systemTemp.createTempSync('gstore_mm_manifest_test_');
    tempDirs.add(root);
    final modules = Directory(p.join(root.path, 'gstore_modules'))
      ..createSync(recursive: true);
    for (final name in installed) {
      Directory(p.join(modules.path, name)).createSync(recursive: true);
    }
    return root;
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

  RustModuleStatus none(String name) =>
      RustModuleStatus(name: name, exists: false, source: 'none');

  Future<List<RustPluginInfo>> runController({
    List<String> installed = const [],
    Map<String, dynamic>? manifest,
    ModuleManifestSource? source,
  }) async {
    loader.debugConfigure(
      // 注入枚举接缝：避免真实目录 IO 在 fake-async 下无法完成。
      installedNamesOverride: () async => installed,
      manifestOverride: manifest,
      manifestSource: source,
      probeOverride: (name) async => none(name),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(rustPluginsProvider);
    await container.read(rustPluginsProvider.notifier).refresh();
    final state = container.read(rustPluginsProvider);
    expect(state.loading, isFalse, reason: '刷新结束必须解除 loading');
    return state.plugins;
  }

  // ---------------------------------------------------------------------------
  // 纯函数：成员/顺序/去重/元数据回退。
  // ---------------------------------------------------------------------------

  group('resolveRustPlugins 成员 / 顺序 / 元数据', () {
    test('清单 {qr,repo} + 已安装 {qr,legacy} ⇒ qr, repo, legacy 且 llm 缺席', () {
      final list = resolveRustPlugins(
        manifestNames: const ['qr', 'repo'],
        installedNames: const ['qr', 'legacy'],
      );
      expect(list.map((e) => e.name).toList(), ['qr', 'repo', 'legacy'],
          reason: '清单顺序优先，其后为仅本地已安装（字典序）');
      expect(list.any((e) => e.name == 'llm'), isFalse,
          reason: '未声明且未安装的 llm 必须消失');
      expect(list.firstWhere((e) => e.name == 'qr').title, '二维码解码');
    });

    test('清单中未收录元数据的模块仍展示，标题回退为原始模块名', () {
      final list = resolveRustPlugins(
        manifestNames: const ['brand_new'],
        installedNames: const [],
      );
      expect(list.map((e) => e.name).toList(), ['brand_new']);
      expect(list.single.title, 'brand_new');
      expect(list.single.description, rustPluginUnknownDescription);
    });

    test('名称同时在清单与已安装时只出现一次（去重）', () {
      final list = resolveRustPlugins(
        manifestNames: const ['qr', 'repo'],
        installedNames: const ['repo', 'qr'],
      );
      expect(list.map((e) => e.name).toList(), ['qr', 'repo']);
    });

    test('仅本地已安装模块按字典序升序追加在清单之后', () {
      final list = resolveRustPlugins(
        manifestNames: const ['qr'],
        installedNames: const ['zeta', 'alpha', 'qr'],
      );
      expect(list.map((e) => e.name).toList(), ['qr', 'alpha', 'zeta']);
    });
  });

  // ---------------------------------------------------------------------------
  // 控制器：清单经 RustModuleLoader（生产即 ModuleManifestClient 链路）读取。
  // ---------------------------------------------------------------------------

  group('RustPluginsController 成员解析', () {
    test('manifest {qr,repo} + installed {qr,legacy} ⇒ 列表与状态同序且 llm 缺席',
        () async {
      final plugins = await runController(
        installed: const ['qr', 'legacy'],
        manifest: _manifest(['qr', 'repo']),
      );
      expect(plugins.map((e) => e.name).toList(), ['qr', 'repo', 'legacy']);
      expect(plugins.any((e) => e.name == 'llm'), isFalse);
    });

    test('清单不可用（来源返回 null）⇒ 仅本地已安装，页面不崩', () async {
      final plugins = await runController(
        installed: const ['legacy', 'qr'],
        source: _NullManifestSource(),
      );
      expect(plugins.map((e) => e.name).toList(), ['legacy', 'qr'],
          reason: '仅本地已安装，按字典序');
    });

    test('清单与本地均为空 ⇒ 空列表（页面走空状态）', () async {
      final plugins = await runController(
        manifest: _manifest(const []),
      );
      expect(plugins, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // RustModuleLoader.installedModuleNames：真实目录枚举（plain test，真实 IO）。
  // ---------------------------------------------------------------------------

  group('installedModuleNames 目录枚举', () {
    test('枚举 <support>/gstore_modules/* 目录名并跳过 _cache、按字典序', () async {
      final root = makeSupport(const ['zeta', 'qr']);
      Directory(p.join(root.path, 'gstore_modules', '_cache'))
          .createSync(recursive: true);
      // 非目录文件不应被当作模块。
      File(p.join(root.path, 'gstore_modules', 'stray.txt'))
          .writeAsStringSync('x');

      loader.debugConfigure(supportDir: root.path);
      final names = await loader.installedModuleNames();
      expect(names, ['qr', 'zeta']);
    });

    test('目录不存在 → 返回空列表，绝不抛异常', () async {
      final root = Directory.systemTemp.createTempSync('gstore_mm_none_');
      tempDirs.add(root);
      loader.debugConfigure(supportDir: root.path);
      expect(await loader.installedModuleNames(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Widget：空状态与降级展示。
  // ---------------------------------------------------------------------------

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget home) => MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: home,
      );

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(child: host(const ModuleManagePage())));
    await tester.pumpAndSettle();
  }

  testWidgets('清单与本地均无模块 → 原生插件空状态（不卡死）', (tester) async {
    useTallViewport(tester);
    loader.debugConfigure(
      installedNamesOverride: () async => const [],
      manifestOverride: _manifest(const []),
      probeOverride: (name) async => none(name),
    );

    await pumpPage(tester);

    expect(find.text('暂无原生插件'), findsOneWidget);
    expect(find.text('读取中…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清单不可用 → 仅展示本地已安装模块，标题回退为原始模块名', (tester) async {
    useTallViewport(tester);
    loader.debugConfigure(
      installedNamesOverride: () async => const ['legacy'],
      manifestSource: _NullManifestSource(),
      probeOverride: (name) async => none(name),
    );

    await pumpPage(tester);

    // 展示文案为 '${title} · ${name}'；未收录元数据 → title 回退为模块名。
    expect(find.text('legacy · legacy'), findsOneWidget);
    expect(find.text('暂无原生插件'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
