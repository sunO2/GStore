import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';
import 'package:gstore/page/proxy/proxy_profiles_facade.dart';
import 'package:gstore/page/proxy/proxy_profiles_page.dart';

/// 假订阅门面：内存列表 + 可控导入结果 / 异常，无需原生模块。
class _FakeProfilesFacade implements ProxyProfilesFacade {
  _FakeProfilesFacade({List<ProfileSummary>? profiles})
      : _profiles = <ProfileSummary>[...?profiles];

  final List<ProfileSummary> _profiles;
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  /// 设置后所有 `profile.import_*` 调用抛出该异常。
  Object? importError;

  /// `profile.import_*` 成功时返回的规范 profile。
  ImportedProfile importResult = const ImportedProfile(
    name: '新订阅',
    format: 'clash',
    nodeCount: 3,
  );

  int listCount = 0;
  int createCount = 0;
  int deleteCount = 0;
  int refreshCount = 0;
  int refreshAllCount = 0;
  String? lastDeletedId;

  /// `config.apply` 收到的 profile id 序列。
  final List<String> appliedIds = <String>[];

  /// 设置后 `applyProfile` 抛出该异常（模拟引擎未运行等）。
  Object? applyError;

  @override
  Future<ProfileList> profileList() async {
    listCount++;
    return ProfileList(count: _profiles.length, profiles: List.of(_profiles));
  }

  @override
  Future<ImportedProfile> profileImportUrl({
    required String url,
    String? name,
    String? userAgent,
  }) async {
    _throwIfNeeded();
    return importResult;
  }

  @override
  Future<ImportedProfile> profileImportText({
    required String text,
    String? name,
    String? contentType,
  }) async {
    _throwIfNeeded();
    return importResult;
  }

  @override
  Future<ImportedProfile> profileImportLink({
    required String link,
    String? name,
  }) async {
    _throwIfNeeded();
    return importResult;
  }

  void _throwIfNeeded() {
    final error = importError;
    if (error != null) throw error;
  }

  @override
  Future<StoredProfile> profileCreate(ProfileCreateRequest request) async {
    createCount++;
    final profile = request.profile;
    _profiles.add(
      ProfileSummary(
        id: 'new-$createCount',
        name: profile.name,
        format: profile.format,
        nodeCount: profile.nodeCount,
        createdAtMs: 1000,
        updatedAtMs: 2000,
      ),
    );
    return StoredProfile(id: 'new-$createCount', profile: profile);
  }

  @override
  Future<ProfileDeleteResult> profileDelete(String id) async {
    deleteCount++;
    lastDeletedId = id;
    _profiles.removeWhere((profile) => profile.id == id);
    return ProfileDeleteResult(ok: true, id: id, deleted: true);
  }

  @override
  Future<RefreshResult> profileRefresh(String id, {bool force = false}) async {
    refreshCount++;
    return RefreshResult(profileId: id, state: 'done');
  }

  @override
  Future<RefreshAllResult> profileRefreshAll({
    bool force = false,
    int? limit,
  }) async {
    refreshAllCount++;
    return RefreshAllResult(
        count: _profiles.length, attempted: _profiles.length);
  }

  @override
  Future<StoredProfile> profileUpdate(Map<String, dynamic> payload) async {
    final id = payload['id'] as String?;
    final name = payload['name'] as String?;
    final index = _profiles.indexWhere((profile) => profile.id == id);
    if (index >= 0 && name != null) {
      final old = _profiles[index];
      _profiles[index] = ProfileSummary(
        id: old.id,
        name: name,
        format: old.format,
        nodeCount: old.nodeCount,
        groupCount: old.groupCount,
        createdAtMs: old.createdAtMs,
        updatedAtMs: old.updatedAtMs,
        revision: old.revision + 1,
        sourceOrigin: old.sourceOrigin,
        sourceUrl: old.sourceUrl,
        userinfo: old.userinfo,
        refresh: old.refresh,
      );
    }
    return StoredProfile(
      id: id ?? '',
      profile: const ImportedProfile(name: '', format: 'clash'),
    );
  }

  @override
  Future<GeneratedConfig> profileExportClash(ProfileExportRequest request) async =>
      const GeneratedConfig(config: 'mode: rule\n', profileId: 'p1');

  @override
  Future<StoredProfile> profileSetSchedule(String id, int intervalMs) async =>
      StoredProfile(
        id: id,
        profile: const ImportedProfile(name: '', format: 'clash'),
      );

  @override
  Future<void> applyProfile(String profileId) async {
    final error = applyError;
    if (error != null) throw error;
    appliedIds.add(profileId);
  }

  @override
  Stream<ProxyEvent> get events => _events.stream;

  Future<void> dispose() => _events.close();
}

/// 假「当前订阅」持久化存储：内存实现，无需原生存储。
class _FakeProfileStore implements ProxyActiveProfileStore {
  String? value;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String id) async {
    value = id;
    writes++;
  }

  @override
  Future<void> clear() async {
    value = null;
    clears++;
  }
}

ProfileSummary _summary({
  String id = 'p1',
  String name = '原有订阅',
  int nodes = 42,
  SubscriptionUserinfo? userinfo,
  ProfileRefreshState? refresh,
  String? origin = 'url',
  String? url = 'https://example.com/sub',
}) {
  return ProfileSummary(
    id: id,
    name: name,
    format: 'clash',
    nodeCount: nodes,
    groupCount: 2,
    createdAtMs: 1000,
    updatedAtMs: DateTime(2026, 9, 21, 10, 30).millisecondsSinceEpoch,
    sourceOrigin: origin,
    sourceUrl: url,
    userinfo: userinfo,
    refresh: refresh,
  );
}

/// 测试宿主：挂载全局 navigatorKey（确认/提示弹层）与 scaffoldMessengerKey（Snackbar）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 固定帧推进：避免 `AppLoading`（无限动画）让 `pumpAndSettle` 超时。
Future<void> _tick(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 打开导入弹层（URL 模式）并提交指定 URL。
Future<void> _importViaUrl(WidgetTester tester, String url) async {
  await tester.tap(find.byTooltip('导入网络组'));
  await tester.pumpAndSettle();
  expect(find.text('导入网络组'), findsWidgets);
  await tester.enterText(find.byType(TextField), url);
  await tester.tap(find.widgetWithText(FilledButton, '导入'));
  await _tick(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('列表：展示名称 / 来源 / 节点数 / 流量与到期 userinfo', (tester) async {
    final facade = _FakeProfilesFacade(
      profiles: [
        _summary(
          name: '我的机场',
          nodes: 42,
          userinfo: SubscriptionUserinfo(
            upload: 1024,
            download: 2048,
            total: 1024 * 1024,
            expire: DateTime.now()
                    .add(const Duration(days: 30))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
          refresh: const ProfileRefreshState(
            state: ProxyRefreshState.done,
            intervalMs: 6 * 60 * 60 * 1000,
          ),
        ),
      ],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    expect(find.text('我的机场'), findsOneWidget);
    expect(find.text('端子 42'), findsOneWidget);
    expect(find.text('分组 2'), findsOneWidget);
    expect(find.text('已用 3.00 KB / 1.00 MB'), findsOneWidget);
    expect(find.textContaining('到期：'), findsOneWidget);
    expect(find.textContaining('自动更新 6 小时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('happy：通过内容弹层按 URL 导入 → 列表更新', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '原有订阅')]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();
    expect(find.text('原有订阅'), findsOneWidget);

    await _importViaUrl(tester, 'https://example.com/new-sub');
    // 等待成功后 `_load()` 刷新列表
    await _tick(tester);

    expect(facade.createCount, 1);
    expect(find.text('新订阅'), findsOneWidget);
    expect(find.text('原有订阅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure：无效 URL → 错误弹层，列表不变', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '原有订阅')]);
    facade.importError = const ProxyModuleException(
      code: 'PROXY_SUB_FETCH_FAILED',
      message: '订阅地址无效',
      status: 502,
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await _importViaUrl(tester, 'not-a-url');

    expect(find.text('导入失败'), findsOneWidget);
    expect(find.text('订阅地址无效'), findsOneWidget);
    expect(facade.createCount, 0);
    expect(find.text('新订阅'), findsNothing);
    expect(find.text('原有订阅'), findsOneWidget);

    // 关闭错误弹层
    await tester.tap(find.text('知道了'));
    await _tick(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除：危险确认弹层 → 确认后调用 delete 并移除', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '要删除的订阅')]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除网络组'), findsOneWidget);
    // 危险样式：确认按钮带显式 error 背景（普通确认按钮 style 为 null）
    final confirmButton =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '删除'));
    expect(confirmButton.style?.backgroundColor, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _tick(tester);

    expect(facade.deleteCount, 1);
    expect(facade.lastDeletedId, 'p1');
    expect(find.text('要删除的订阅'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除：取消确认弹层不调用 delete', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '保留订阅')]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await _tick(tester);

    expect(facade.deleteCount, 0);
    expect(find.text('保留订阅'), findsOneWidget);
  });

  testWidgets('刷新：单个刷新按钮触发 profileRefresh', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '可更新订阅')]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更新'));
    await _tick(tester);

    expect(facade.refreshCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新：全部更新触发 profileRefreshAll', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '订阅A')]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('全部更新'));
    await _tick(tester);

    expect(facade.refreshAllCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态：无订阅时展示空状态与导入入口', (tester) async {
    final facade = _FakeProfilesFacade();
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    expect(find.text('还没有网络组'), findsOneWidget);
    expect(find.text('导入网络组'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分享链接：读取剪贴板后按 link 导入', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [_summary(name: '原有')]);
    facade.importResult = const ImportedProfile(
      name: '链接订阅',
      format: 'shareLink',
      nodeCount: 1,
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(
        ProxyProfilesPage(
          facade: facade,
          clipboardReader: () async =>
              'ss://YWVzLTI1Ni1nY206cGFzc0AxaDIuMy40Ojg4ODg',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('导入网络组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取剪贴板中的分享链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await _tick(tester);
    await _tick(tester);

    expect(facade.createCount, 1);
    expect(find.text('链接订阅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择：点击订阅卡片设为当前并持久化 + 视觉「当前」标识', (tester) async {
    final store = _FakeProfileStore();
    final facade = _FakeProfilesFacade(profiles: [
      _summary(id: 'p1', name: '订阅A'),
      _summary(id: 'p2', name: '订阅B'),
    ]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, profileStore: store)),
    );
    await tester.pumpAndSettle();

    // 多订阅且无持久化值时不自动选中。
    expect(find.byKey(const Key('proxy_profile_active_p1')), findsNothing);
    expect(find.byKey(const Key('proxy_profile_active_p2')), findsNothing);

    await tester.tap(find.text('订阅B'));
    await _tick(tester);

    expect(store.value, 'p2');
    expect(store.writes, 1);
    expect(facade.appliedIds, <String>['p2']);
    final activeFinder = find.byKey(const Key('proxy_profile_active_p2'));
    expect(activeFinder, findsOneWidget);
    expect(find.byKey(const Key('proxy_profile_active_p1')), findsNothing);
    // 当前订阅仅由主题高亮表达：卡片底色为 primaryContainer。
    final activeCard = tester.widget<Card>(activeFinder);
    final activeContext = tester.element(activeFinder);
    expect(
      activeCard.color,
      Theme.of(activeContext).colorScheme.primaryContainer,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择：engine 同步失败不阻断「设为当前订阅」（best-effort）', (tester) async {
    final store = _FakeProfileStore();
    final facade = _FakeProfilesFacade(profiles: [
      _summary(id: 'p1', name: '订阅A'),
      _summary(id: 'p2', name: '订阅B'),
    ]);
    facade.applyError = const ProxyModuleException(
      code: 'PROXY_NOT_CONFIGURED',
      message: 'engine is not running',
      status: 409,
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, profileStore: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('订阅B'));
    await _tick(tester);

    expect(store.value, 'p2');
    expect(find.byKey(const Key('proxy_profile_active_p2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择：只有一个订阅时自动选中并持久化', (tester) async {
    final store = _FakeProfileStore();
    final facade = _FakeProfilesFacade(
      profiles: [_summary(id: 'only', name: '唯一订阅')],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, profileStore: store)),
    );
    await tester.pumpAndSettle();

    expect(store.value, 'only');
    expect(store.writes, greaterThanOrEqualTo(1));
    expect(find.byKey(const Key('proxy_profile_active_only')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择：持久化的选中 id 在列表中生效', (tester) async {
    final store = _FakeProfileStore()..value = 'p2';
    final facade = _FakeProfilesFacade(profiles: [
      _summary(id: 'p1', name: '订阅A'),
      _summary(id: 'p2', name: '订阅B'),
    ]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, profileStore: store)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('proxy_profile_active_p2')), findsOneWidget);
    expect(find.byKey(const Key('proxy_profile_active_p1')), findsNothing);
    // 未发生新写入（沿用既有持久化值）。
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择：持久化 id 失效且仅剩 1 个订阅时自动改选并持久化', (tester) async {
    final store = _FakeProfileStore()..value = 'gone';
    final facade = _FakeProfilesFacade(
      profiles: [_summary(id: 'fresh', name: '新订阅')],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, profileStore: store)),
    );
    await tester.pumpAndSettle();

    expect(store.value, 'fresh');
    expect(
        find.byKey(const Key('proxy_profile_active_fresh')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
