import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
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
    return RefreshAllResult(count: _profiles.length, attempted: _profiles.length);
  }

  @override
  Stream<ProxyEvent> get events => _events.stream;

  Future<void> dispose() => _events.close();
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
  await tester.tap(find.byTooltip('导入订阅'));
  await tester.pumpAndSettle();
  expect(find.text('导入订阅'), findsWidgets);
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
            expire:
                DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
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
    expect(find.text('节点 42'), findsOneWidget);
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

    expect(find.text('删除订阅'), findsOneWidget);
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

    expect(find.text('还没有订阅'), findsOneWidget);
    expect(find.text('导入订阅'), findsWidgets);
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
          clipboardReader: () async => 'ss://YWVzLTI1Ni1nY206cGFzc0AxaDIuMy40Ojg4ODg',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('导入订阅'));
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
}
