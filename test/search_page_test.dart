import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfoDao.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/page/search/providers.dart';
import 'package:gstore/page/search/view.dart';

/// 手写 Fake DAO（与项目既有测试风格一致：避免 mockito 对带方法体的
/// concrete 方法无法 stub / any 泛型推断问题）。
class _FakeDao implements AppInfoDao {
  /// 关键词 → 搜索结果（search 内部走 searchWord LIKE 兜底）
  final Map<String, List<AppInfo>> searchResults = {};

  /// 分类 id → 分类结果
  final Map<String, List<AppInfo>> categoryResults = {};

  /// search/queryCategory 实际调用计数
  int searchCallCount = 0;
  int categoryCallCount = 0;

  /// 记录最近一次关键词
  String? lastKeyword;

  @override
  Future<List<AppInfo>> search(String word) async {
    searchCallCount++;
    lastKeyword = word;
    // 模拟真实 search：返回空或预设结果
    return searchResults[word] ?? const [];
  }

  @override
  Future<List<AppInfo>> queryCategory(String word) async {
    categoryCallCount++;
    return categoryResults[word] ?? const [];
  }

  // ---- 以下抽象成员测试未用到，抛 UnsupportedError ----
  @override
  Future<List<AppInfo>> getAllApps() => throw UnsupportedError('not used');

  @override
  Future<AppInfo?> getAppInfo(String appId) =>
      throw UnsupportedError('not used');

  @override
  Future<List<AppInfo>> searchFts(String word) =>
      throw UnsupportedError('not used');

  @override
  Future<List<AppInfo>> searchWord(String word) =>
      throw UnsupportedError('not used');

  @override
  Future<List<AppInfo>> searchCategoryLike(String word) =>
      throw UnsupportedError('not used');

  @override
  Future<AppInfoConfig?> getVersion() => throw UnsupportedError('not used');

  @override
  Future<void> insertConfig(AppInfoConfig config) =>
      throw UnsupportedError('not used');

  @override
  Future<List<AppCategory>> getAllCategory() =>
      throw UnsupportedError('not used');
}

/// 手写 Fake 数据库：仅暴露 dao，其余 FloorDatabase 成员由 noSuchMethod
/// 兜底（测试未用到）。
class _FakeDb implements AppInfoDatabase {
  _FakeDb(this._dao);

  final _FakeDao _dao;

  @override
  AppInfoDao get dao => _dao;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注入 fake 数据库后创建 ProviderContainer。
ProviderContainer _container(_FakeDb db) {
  final container = ProviderContainer(
    overrides: [
      searchDatabaseProvider.overrideWithValue(db),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

AppInfo _app(String id, String name) {
  return AppInfo(
    id,
    name,
    'sunO2',
    'GStore-Repositorys',
    'https://example.com/$id.png',
    '描述 $name',
    const ['工具'],
  );
}

void main() {
  group('SearchNotifier', () {
    test('空输入立即清空结果', () async {
      final dao = _FakeDao()
        ..searchResults['abc'] = [_app('a1', 'ABC')];
      final container = _container(_FakeDb(dao));
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
      final dao = _FakeDao()
        ..searchResults['微信'] = [_app('wx', '微信')];
      final container = _container(_FakeDb(dao));
      final notifier = container.read(searchProvider.notifier);

      notifier.onInputChanged('微信');
      // 防抖期内不应查询
      expect(container.read(searchProvider), isEmpty);
      expect(dao.searchCallCount, 0);

      // 防抖到期后查询并更新
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final results = container.read(searchProvider);
      expect(results, hasLength(1));
      expect(results.first.name, '微信');
      expect(dao.searchCallCount, 1);
      expect(dao.lastKeyword, '微信');
    });

    test('防抖期间连续输入只查询最后一次', () async {
      final dao = _FakeDao();
      final container = _container(_FakeDb(dao));
      final notifier = container.read(searchProvider.notifier);

      notifier.onInputChanged('微');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      notifier.onInputChanged('微信');
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(dao.searchCallCount, 1);
      expect(dao.lastKeyword, '微信'); // '微' 的查询被防抖取消
    });

    test('loadCategory 加载分类应用', () async {
      final dao = _FakeDao()
        ..categoryResults['game'] = [_app('g1', '游戏应用')];
      final container = _container(_FakeDb(dao));
      final notifier = container.read(searchProvider.notifier);

      await notifier.loadCategory(AppCategory('game', '游戏', ''));
      final results = container.read(searchProvider);
      expect(results, hasLength(1));
      expect(results.first.name, '游戏应用');
      expect(dao.categoryCallCount, 1);
    });
  });

  group('SearchPage widget', () {
    testWidgets('无参数进入：显示搜索框，输入后展示结果列表', (tester) async {
      final dao = _FakeDao()
        ..searchResults['apk'] = [_app('a1', 'APK 应用')];
      final db = _FakeDb(dao);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchDatabaseProvider.overrideWithValue(db)],
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
