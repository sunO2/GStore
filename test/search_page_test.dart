import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/page/search/providers.dart';
import 'package:gstore/page/search/view.dart';

/// 只读 flags 后端：保持镜像 all-false（catalog off → 门面走 legacy backend）。
class _FakeFlagsBackend implements CoreFlagsBackend {
  CoreFlagsSnapshot snapshot = CoreFlagsSnapshot.disabled;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
}

/// 手写 Fake 目录后端（与项目既有测试风格一致：避免 mockito 对带方法体的
/// concrete 方法无法 stub / any 泛型推断问题）。
class _FakeCatalog implements CatalogBackend {
  /// 关键词 → 搜索结果
  final Map<String, List<AppSummary>> searchResults = {};

  /// 分类 id → 分类结果
  final Map<String, List<AppSummary>> categoryResults = {};

  /// search/byCategory 实际调用计数
  int searchCallCount = 0;
  int categoryCallCount = 0;

  /// 记录最近一次关键词
  String? lastKeyword;

  @override
  Future<List<AppSummary>> search(String keyword) async {
    searchCallCount++;
    lastKeyword = keyword;
    // 模拟真实 search：返回空或预设结果
    return searchResults[keyword] ?? const [];
  }

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async {
    categoryCallCount++;
    return categoryResults[categoryId] ?? const [];
  }

  // ---- 以下抽象成员测试未用到，抛 UnsupportedError ----
  @override
  Future<List<AppSummary>> list() => throw UnsupportedError('not used');

  @override
  Future<CatalogPageData> listPage(
          {required int offset, required int limit}) =>
      throw UnsupportedError('not used');

  @override
  Future<AppSummary?> getApp(String appId) => throw UnsupportedError('not used');

  @override
  Future<List<AppCategory>> categories() =>
      throw UnsupportedError('not used');

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) =>
      throw UnsupportedError('not used');

  @override
  Future<CatalogRefreshOutcome> refresh(String url) =>
      throw UnsupportedError('not used');
}

/// 注入 fake 目录后端后创建 ProviderContainer。
///
/// [CatalogFacade] 只走 core 后端；此处注入 fake 作为 core 后端。
ProviderContainer _container(_FakeCatalog backend) {
  final container = ProviderContainer(
    overrides: [
      catalogFacadeProvider.overrideWithValue(
        CatalogFacade(frb: backend),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

AppSummary _app(String id, String name) {
  return AppSummary(
    appId: id,
    name: name,
    user: 'sunO2',
    repositories: 'GStore-Repositorys',
    icon: 'https://example.com/$id.png',
    des: '描述 $name',
    category: const ['工具'],
  );
}

void main() {
  setUp(() {
    CoreFlags.resetQueueForTest();
    CoreFlags.installBackend(_FakeFlagsBackend());
  });

  tearDown(() {
    CoreFlags.resetBackend();
  });

  group('SearchNotifier', () {
    test('空输入立即清空结果', () async {
      final backend = _FakeCatalog()
        ..searchResults['abc'] = [_app('a1', 'ABC')];
      final container = _container(backend);
      final notifier = container.read(searchProvider.notifier);

      // 先注入一批结果
      notifier.onInputChanged('abc');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(container.read(searchProvider), isNotEmpty);

      // 切空 → 立即清空（无需等防抖）
      notifier.onInputChanged('');
      expect(container.read(searchProvider), isEmpty);
    });

    test('非空输入防抖 200ms 后展示搜索结果', () async {
      final backend = _FakeCatalog()
        ..searchResults['微信'] = [_app('wx', '微信')];
      final container = _container(backend);
      final notifier = container.read(searchProvider.notifier);

      notifier.onInputChanged('微信');
      // 防抖期内不应查询
      expect(container.read(searchProvider), isEmpty);
      expect(backend.searchCallCount, 0);

      // 防抖到期后查询并更新
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final results = container.read(searchProvider);
      expect(results, hasLength(1));
      expect(results.first.name, '微信');
      expect(backend.searchCallCount, 1);
      expect(backend.lastKeyword, '微信');
    });

    test('防抖期间连续输入只查询最后一次', () async {
      final backend = _FakeCatalog();
      final container = _container(backend);
      final notifier = container.read(searchProvider.notifier);

      notifier.onInputChanged('微');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      notifier.onInputChanged('微信');
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(backend.searchCallCount, 1);
      expect(backend.lastKeyword, '微信'); // '微' 的查询被防抖取消
    });

    test('loadCategory 加载分类应用', () async {
      final backend = _FakeCatalog()
        ..categoryResults['game'] = [_app('g1', '游戏应用')];
      final container = _container(backend);
      final notifier = container.read(searchProvider.notifier);

      await notifier.loadCategory(AppCategory('game', '游戏', ''));
      final results = container.read(searchProvider);
      expect(results, hasLength(1));
      expect(results.first.name, '游戏应用');
      expect(backend.categoryCallCount, 1);
    });
  });

  group('SearchPage widget', () {
    testWidgets('无参数进入：显示搜索框，输入后展示结果列表', (tester) async {
      // 队列在 FakeAsync zone 内重建：否则 CoreFlags.refresh() 的 await 链
      // 会挂在 setUp 的真实 zone 上，tester.pump 永远 flush 不到。
      CoreFlags.resetQueueForTest();
      final backend = _FakeCatalog()
        ..searchResults['apk'] = [_app('a1', 'APK 应用')];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogFacadeProvider.overrideWithValue(
              CatalogFacade(frb: backend),
            ),
          ],
          child: const MaterialApp(home: SearchPage()),
        ),
      );

      // 搜索入口：输入框存在
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('搜索应用'), findsOneWidget);

      // 输入关键词 → 防抖后出结果
      await tester.enterText(find.byType(TextField), 'apk');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('APK 应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
