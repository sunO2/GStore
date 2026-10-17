import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeApkBrowseListing, decodeApkExportedEntry;
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_browser_service.dart';
import 'package:gstore/page/apk_browser/directory_view.dart';
import 'package:gstore/page/apk_browser/preview.dart';
import 'package:gstore/page/apk_browser/view.dart';

const _listingJson = {
  'container': 'assets/plugins/pack.zip',
  'dir': 'res/raw',
  'parent_dir': 'res',
  'can_go_up': true,
  'total_files': 42,
  'container_size': 2048,
  'truncated': false,
  'entries': [
    {
      'path': 'res/raw/inner.txt',
      'name': 'inner.txt',
      'is_dir': false,
      'size': 13,
      'compressed_size': 13,
      'crc32': 4275878552,
      'stored': true,
      'kind': 'text',
      'browsable': false,
    },
    {
      'path': 'res/raw',
      'name': 'raw',
      'is_dir': true,
      'size': 13,
      'compressed_size': 0,
      'crc32': 0,
      'stored': false,
      'kind': 'dir',
      'browsable': false,
    },
  ],
};

void main() {
  group('浏览契约解码', () {
    test('decodeApkBrowseListing 还原容器/目录/条目', () {
      final listing = decodeApkBrowseListing(_listingJson)!;
      expect(listing.container, 'assets/plugins/pack.zip');
      expect(listing.dir, 'res/raw');
      expect(listing.parentDir, 'res');
      expect(listing.canGoUp, isTrue);
      expect(listing.totalFiles, 42);
      expect(listing.containerSize, 2048);
      expect(listing.truncated, isFalse);
      expect(listing.entries.length, 2);

      final file = listing.entries[0];
      expect(file.name, 'inner.txt');
      expect(file.isDir, isFalse);
      expect(file.size, 13);
      expect(file.crc32, 4275878552);
      expect(file.stored, isTrue);
      expect(file.kind, 'text');
      expect(file.browsable, isFalse);
      // 新元数据字段：旧响应缺 key → schema 默认（null / false / ''）
      expect(file.modified, isNull);
      expect(file.created, isNull);
      expect(file.accessed, isNull);
      expect(file.unixMode, isNull);
      expect(file.encrypted, isFalse);
      expect(file.compression, '');

      final dir = listing.entries[1];
      expect(dir.isDir, isTrue);
      expect(dir.kind, 'dir');
    });

    test('displayName 取容器链末段', () {
      final listing = decodeApkBrowseListing(_listingJson)!;
      expect(listing.displayName, 'pack.zip');
      final root = decodeApkBrowseListing({..._listingJson, 'container': ''})!;
      expect(root.displayName, 'APK');
    });

    test('非 Map 输入返回 null（模块异常时不炸）', () {
      expect(decodeApkBrowseListing('oops'), isNull);
    });

    test('decodeApkBrowseListing 解码条目元数据（时间/权限/加密/压缩）', () {
      final listing = decodeApkBrowseListing({
        ..._listingJson,
        'entries': [
          {
            'path': 'res/raw/inner.txt',
            'name': 'inner.txt',
            'is_dir': false,
            'size': 100,
            'compressed_size': 38,
            'crc32': 0,
            'stored': false,
            'kind': 'text',
            'browsable': false,
            'modified': '2026-01-02 03:04:05',
            'created': '2026-01-01 00:00:00',
            'accessed': '2026-01-03 00:00:00',
            'unix_mode': 420, // 0o644
            'encrypted': true,
            'compression': 'deflate',
          },
        ],
      })!;
      final e = listing.entries.single;
      expect(e.modified, '2026-01-02 03:04:05');
      expect(e.created, '2026-01-01 00:00:00');
      expect(e.accessed, '2026-01-03 00:00:00');
      expect(e.unixMode, 420);
      expect(e.encrypted, isTrue);
      expect(e.compression, 'deflate');
    });

    test('decodeApkExportedEntry 还原落地信息', () {
      final e = decodeApkExportedEntry({
        'path': 'assets/notes.txt',
        'size': 13,
        'crc32': 123,
        'out_path': '/tmp/x/notes.txt',
      })!;
      expect(e.path, 'assets/notes.txt');
      expect(e.size, 13);
      expect(e.crc32, 123);
      expect(e.outPath, '/tmp/x/notes.txt');
      expect(decodeApkExportedEntry(3), isNull);
    });
  });

  group('条目类型标签与 hexdump', () {
    test('kind → 中文标签', () {
      expect(apkEntryKindLabel('dir', isDir: true), '目录');
      expect(apkEntryKindLabel('zip'), 'ZIP 压缩包');
      expect(apkEntryKindLabel('image'), '图片');
      expect(apkEntryKindLabel('json'), 'JSON');
      expect(apkEntryKindLabel('font'), '字体');
      expect(apkEntryKindLabel('cert'), '证书');
      expect(apkEntryKindLabel('video'), '视频');
      expect(apkEntryKindLabel('unknown-kind'), '二进制');
    });

    test('hexDump 每行 16 字节并给出偏移与 ASCII', () {
      final bytes = Uint8List.fromList(
        List.generate(20, (i) => i),
      );
      final dump = hexDump(bytes);
      final lines = dump.trimRight().split('\n');
      expect(lines.length, 2, reason: '20 字节应为 2 行');
      expect(lines[0].startsWith('00000000'), isTrue);
      expect(lines[0].contains('0a 0b'), isTrue);
      expect(lines[1].startsWith('00000010'), isTrue);
      // 不可打印字节渲染为 '.'
      expect(lines[0].trimRight().endsWith('................'), isTrue);
    });

    test('hexDump 支持 limit 截断', () {
      final bytes = Uint8List.fromList(List.generate(64, (i) => 65));
      final dump = hexDump(bytes, limit: 16);
      expect(dump.trimRight().split('\n').length, 1);
    });
  });

  group('Agent 工具协议', () {
    test('apkBrowser 已注册且参数完整', () {
      final spec = AgentToolCatalog.byName('apkBrowser');
      expect(spec, isNotNull);
      expect(spec!.group, AgentToolGroup.snapshot);
      expect(spec.label, isNotEmpty);
      expect(spec.protocol, contains('chain'));
      final names = spec.params.map((p) => p.name).toList();
      expect(names, containsAll(['action', 'packageName', 'dir', 'chain', 'path']));
      expect(spec.params.firstWhere((p) => p.name == 'action').required, isTrue);
      expect(spec.sensitiveActions, isEmpty, reason: '只读工具不应有敏感动作');
    });
  });

  group('ApkBrowserPage', () {
    testWidgets('分析模块不可用时给出明确提示而不是空白', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ApkBrowserPage(
            apkPath: '/no/such/base.apk',
            appLabel: 'Demo',
            packageName: 'com.demo',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('APK 文件浏览'), findsOneWidget);
      // 头部始终展示应用与目标路径（即使列目录失败）
      expect(find.textContaining('/no/such/base.apk'), findsOneWidget);
      // 模块不可用 → 明确提示（测试环境无 Rust 模块）
      expect(find.textContaining('分析模块未就绪'), findsOneWidget);
    });
  });

  group('ApkBrowserPage 导航模型（目录栈 / 返回语义 / zip 另开页）', () {
    // ==================== 假数据 ====================

    ApkBrowsableEntry dirEntry(String path) => ApkBrowsableEntry(
          path: path,
          name: path.split('/').last,
          isDir: true,
          size: 0,
          compressedSize: 0,
          crc32: 0,
          stored: false,
          kind: 'dir',
          browsable: false,
        );

    ApkBrowsableEntry fileEntry(String path, String kind) => ApkBrowsableEntry(
          path: path,
          name: path.split('/').last,
          isDir: false,
          size: 10,
          compressedSize: 8,
          crc32: 7,
          stored: false,
          kind: kind,
          browsable: false,
        );

    ApkBrowsableEntry zipEntry(String path) => ApkBrowsableEntry(
          path: path,
          name: path.split('/').last,
          isDir: false,
          size: 99,
          compressedSize: 99,
          crc32: 11,
          stored: true,
          kind: 'zip',
          browsable: true,
        );

    ApkBrowseListing listing(
      String container,
      String dir, {
      List<ApkBrowsableEntry> entries = const [],
    }) =>
        ApkBrowseListing(
          container: container,
          dir: dir,
          parentDir: dir.contains('/') ? dir.substring(0, dir.lastIndexOf('/')) : '',
          canGoUp: dir.isNotEmpty,
          entries: entries,
          totalFiles: entries.length,
          containerSize: 1024,
          truncated: false,
        );

    /// APK 根 → assets → assets/models；assets 下有 pack.zip
    Future<ApkBrowseListing?> fakeLoader({
      required String apkPath,
      required String containerChain,
      required String dir,
    }) async {
      if (containerChain.isEmpty) {
        return switch (dir) {
          '' => listing('', '', entries: [dirEntry('assets')]),
          'assets' => listing('', 'assets', entries: [
              dirEntry('assets/models'),
              fileEntry('assets/config.json', 'json'),
              zipEntry('assets/pack.zip'),
            ]),
          'assets/models' => listing('', 'assets/models',
              entries: [fileEntry('assets/models/a.tflite', 'binary')]),
          _ => listing('', dir),
        };
      }
      // 进入压缩包后的新容器
      return listing(containerChain, dir,
          entries: [fileEntry('inner.txt', 'text')]);
    }

    Future<void> pumpBrowser(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ApkBrowserPage(
                        apkPath: '/tmp/base.apk',
                        appLabel: 'Demo',
                        listingLoader: fakeLoader,
                      ),
                    ),
                  ),
                  child: const Text('打开浏览器'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开浏览器'));
      await tester.pumpAndSettle();
    }

    /// 目录层数 = 栈内目录组件个数。
    ///
    /// 注意 `skipOffstage: false`：非当前层被 IndexedStack 标记为 offstage，
    /// 但仍保活在树上——这正是"返回上一层状态还在"的实现基础。
    int depth(WidgetTester tester) => tester
        .widgetList(find.byType(ApkDirectoryView, skipOffstage: false))
        .length;

    /// 模拟系统/手势返回
    Future<void> systemBack(WidgetTester tester) async {
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      await nav.maybePop();
      await tester.pumpAndSettle();
    }

    testWidgets('进入目录压栈；手势返回回上一层；标题栏返回直接退出本页', (tester) async {
      await pumpBrowser(tester);
      expect(depth(tester), 1);
      expect(find.text('APK 文件浏览'), findsOneWidget);

      // 进入 assets → 栈内两层
      await tester.tap(find.text('assets'));
      await tester.pumpAndSettle();
      expect(depth(tester), 2);

      // 手势返回：只回退一层，仍在本页
      await systemBack(tester);
      expect(depth(tester), 1);
      expect(find.text('APK 文件浏览'), findsOneWidget);

      // 再进一层，然后点标题栏返回按钮 → 直接退出本页
      await tester.tap(find.text('assets'));
      await tester.pumpAndSettle();
      expect(depth(tester), 2);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ApkBrowserPage), findsNothing);
      expect(find.text('打开浏览器'), findsOneWidget);
    });

    testWidgets('打开压缩包是新开页面，不重置当前页', (tester) async {
      await pumpBrowser(tester);
      await tester.tap(find.text('assets'));
      await tester.pumpAndSettle();
      expect(depth(tester), 2);

      await tester.tap(find.text('pack.zip'));
      await tester.pumpAndSettle();

      // 新开一个浏览器页（叠加），标题为压缩包名
      // 注意 skipOffstage:false —— 被上层不透明路由盖住的页面仍是 offstage
      expect(find.byType(ApkBrowserPage, skipOffstage: false), findsNWidgets(2));
      expect(find.text('pack.zip'), findsWidgets);
      // 新页展示的是包内条目，而不是把原页重置过去
      expect(find.text('inner.txt'), findsOneWidget);

      // 新页返回 → 回到原页（目录层栈仍是 2 层）
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.byType(ApkBrowserPage, skipOffstage: false), findsOneWidget);
      expect(depth(tester), 2);
      expect(find.text('config.json'), findsOneWidget);
    });

    testWidgets('返回上一层保留该层状态（搜索词与过滤结果）', (tester) async {
      await pumpBrowser(tester);
      await tester.tap(find.text('assets'));
      await tester.pumpAndSettle();
      expect(depth(tester), 2);

      // 在 assets 层输入搜索词：只剩 models，pack.zip 被过滤掉
      await tester.enterText(find.byType(TextField).last, 'mo');
      await tester.pumpAndSettle();
      expect(find.text('models'), findsOneWidget);
      expect(find.text('pack.zip'), findsNothing);

      // 进入子目录，再手势返回
      await tester.tap(find.text('models'));
      await tester.pumpAndSettle();
      expect(depth(tester), 3);
      await systemBack(tester);
      expect(depth(tester), 2);

      // 状态仍在：搜索词保留、过滤仍生效（若状态丢失会重新列成全量列表）
      expect(find.text('mo'), findsOneWidget);
      expect(find.text('models'), findsOneWidget);
      expect(find.text('pack.zip'), findsNothing);
    });

    testWidgets('加载中与加载后搜索栏位置一致（统计行常驻占位，不闪）', (tester) async {
      final completer = Completer<ApkBrowseListing?>();
      Future<ApkBrowseListing?> pendingLoader({
        required String apkPath,
        required String containerChain,
        required String dir,
      }) =>
          completer.future;

      await tester.pumpWidget(
        MaterialApp(
          home: ApkBrowserPage(
            apkPath: '/tmp/base.apk',
            appLabel: 'Demo',
            listingLoader: pendingLoader,
          ),
        ),
      );
      await tester.pump();

      // 加载中：统计行已占位（否则加载完成时这行冒出来会把搜索栏顶下去）
      expect(find.textContaining('正在读取目录'), findsOneWidget);
      final beforeTop = tester.getTopLeft(find.byType(TextField)).dy;

      completer.complete(listing('', '', entries: [dirEntry('assets')]));
      await tester.pumpAndSettle();

      expect(find.textContaining('条目 1'), findsOneWidget);
      final afterTop = tester.getTopLeft(find.byType(TextField)).dy;
      expect(afterTop, beforeTop, reason: '统计行出现不应导致搜索栏位移');
    });

    testWidgets('列表上滑时头部卡片折叠收起，回顶后恢复', (tester) async {
      // 足够长的列表，保证可以滚动
      ApkBrowseListing longListing() => listing(
            '',
            '',
            entries: [
              for (var i = 0; i < 60; i++)
                fileEntry('assets/file_${i.toString().padLeft(2, '0')}.txt', 'text'),
            ],
          );

      Future<ApkBrowseListing?> longLoader({
        required String apkPath,
        required String containerChain,
        required String dir,
      }) async =>
          longListing();

      await tester.pumpWidget(
        MaterialApp(
          home: ApkBrowserPage(
            apkPath: '/tmp/base.apk',
            appLabel: 'Demo',
            listingLoader: longLoader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 初始状态：头部卡片可见（展示 APK 路径），列表在顶部
      expect(find.textContaining('/tmp/base.apk'), findsOneWidget);

      // 向上拖动列表 → 头部卡片折叠隐藏
      await tester.drag(
        find.byKey(const Key('apk_browser_entries')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('/tmp/base.apk'), findsNothing,
          reason: '列表上滑后头部卡片应折叠收起');

      // 向下拖回顶部 → 头部卡片恢复
      await tester.drag(
        find.byKey(const Key('apk_browser_entries')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('/tmp/base.apk'), findsOneWidget,
          reason: '回到顶部后头部卡片应重新展开');
    });
  });

  group('ApkEntryPreviewPage 文件详情卡（新增条目元数据）', () {
    // 经注入 listingLoader 提供带元数据的条目，点开预览页断言「文件详情」卡。
    // 模块不可用 → 预览正文降级，但元信息卡仍必渲染（正是本组要断言的）。
    ApkBrowsableEntry metaEntry({
      String path = 'res/raw/inner.bin',
      String? modified,
      String? created,
      String? accessed,
      int? unixMode,
      bool encrypted = false,
      String compression = '',
      int size = 100,
      int compressedSize = 38,
      bool stored = false,
    }) =>
        ApkBrowsableEntry(
          path: path,
          name: path.split('/').last,
          isDir: false,
          size: size,
          compressedSize: compressedSize,
          crc32: 0,
          stored: stored,
          kind: 'binary',
          browsable: false,
          modified: modified,
          created: created,
          accessed: accessed,
          unixMode: unixMode,
          encrypted: encrypted,
          compression: compression,
        );

    ApkListingLoader loader(List<ApkBrowsableEntry> entries) =>
        ({
          required String apkPath,
          required String containerChain,
          required String dir,
        }) async =>
            ApkBrowseListing(
              container: '',
              dir: '',
              parentDir: '',
              canGoUp: false,
              entries: entries,
              totalFiles: entries.length,
              containerSize: 0,
              truncated: false,
            );

    /// 经注入的 [loader]（= listingLoader）取条目，再泵入预览页。
    ///
    /// 预览正文的默认导出器会等待不可用的 Rust 模块（测试环境无模块 → 永不 settle），
    /// 故注入返回 null 的准备器让正文走降级分支；「文件详情」卡仍按条目元数据渲染。
    Future<void> openPreview(
      WidgetTester tester,
      List<ApkBrowsableEntry> entries,
    ) async {
      final listing = await loader(entries)(
        apkPath: '/tmp/base.apk',
        containerChain: '',
        dir: '',
      );
      final entry = listing!.entries.single;
      await tester.pumpWidget(
        MaterialApp(
          home: ApkEntryPreviewPage(
            apkPath: '/tmp/base.apk',
            entry: entry,
            preparer: ({
              required String apkPath,
              required ApkBrowsableEntry entry,
              required String containerChain,
              String? password,
            }) async =>
                null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('带元数据条目 → 显示 修改时间/创建时间/访问时间/权限/加密/压缩率', (tester) async {
      await openPreview(
        tester,
        [
          metaEntry(
            modified: '2026-01-02 03:04:05',
            created: '2026-01-01 00:00:00',
            accessed: '2026-01-03 00:00:00',
            unixMode: 420, // 0o644
            encrypted: true,
            compression: 'deflate',
          ),
        ],
      );

      expect(find.text('修改时间'), findsOneWidget);
      expect(find.text('2026-01-02 03:04:05'), findsOneWidget);
      expect(find.text('创建时间'), findsOneWidget);
      expect(find.text('访问时间'), findsOneWidget);
      expect(find.text('权限'), findsOneWidget);
      expect(find.text('0o644 · rw-r--r--'), findsOneWidget);
      expect(find.text('加密'), findsOneWidget);
      expect(find.text('是'), findsOneWidget);
      expect(find.text('存放方式'), findsOneWidget);
      expect(find.text('DEFLATE'), findsOneWidget);
      expect(find.text('压缩率'), findsOneWidget);
      expect(find.text('节省 62%'), findsOneWidget);
    });

    testWidgets('created/accessed 为 null → 不渲染 创建时间/访问时间 行', (tester) async {
      await openPreview(
        tester,
        [
          metaEntry(
            modified: '2026-01-02 03:04:05',
            encrypted: false,
            compression: '',
            stored: true,
          ),
        ],
      );

      expect(find.text('修改时间'), findsOneWidget);
      expect(find.text('2026-01-02 03:04:05'), findsOneWidget);
      expect(find.text('创建时间'), findsNothing);
      expect(find.text('访问时间'), findsNothing);
      // 旧模块缺省压缩 → 回落 STORED；无加密 → 否
      expect(find.text('STORED（未压缩）'), findsOneWidget);
      expect(find.text('否'), findsOneWidget);
    });
  });
}
