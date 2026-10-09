import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_profiles_facade.dart';
import 'package:gstore/page/proxy/proxy_profiles_page.dart';

/// `profile.export_clash` 返回的生成配置样例：必须同时含节点与规则，
/// 用于验证「导出含节点/规则」的接线（页面只透传模块返回的文档）。
const String _exportConfig = '''
mode: rule
proxies:
  - name: 香港 01
    type: ss
    server: 1.2.3.4
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - 香港 01
rules:
  - DOMAIN-SUFFIX,example.com,PROXY
  - MATCH,DIRECT
''';

/// 假订阅门面：内存列表 + 记录编辑 / 导出 / 排程 / 批量刷新调用。
class _FakeProfilesFacade implements ProxyProfilesFacade {
  _FakeProfilesFacade({List<ProfileSummary>? profiles})
      : _profiles = <ProfileSummary>[...?profiles];

  final List<ProfileSummary> _profiles;
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  int updateCount = 0;
  Map<String, dynamic>? lastUpdatePayload;
  int exportCount = 0;
  String? lastExportId;
  int setScheduleCount = 0;
  String? lastScheduleId;
  int? lastScheduleInterval;
  int refreshAllCount = 0;
  bool? lastForceAll;

  /// `profile.refresh_all` 的返回；默认全部成功、无跳过。
  RefreshAllResult refreshAllResult = const RefreshAllResult();

  @override
  Future<ProfileList> profileList() async =>
      ProfileList(count: _profiles.length, profiles: List.of(_profiles));

  @override
  Future<ImportedProfile> profileImportUrl({
    required String url,
    String? name,
    String? userAgent,
  }) async =>
      const ImportedProfile(name: 'x', format: 'clash');

  @override
  Future<ImportedProfile> profileImportText({
    required String text,
    String? name,
    String? contentType,
  }) async =>
      const ImportedProfile(name: 'x', format: 'clash');

  @override
  Future<ImportedProfile> profileImportLink({
    required String link,
    String? name,
  }) async =>
      const ImportedProfile(name: 'x', format: 'clash');

  @override
  Future<StoredProfile> profileCreate(ProfileCreateRequest request) async =>
      StoredProfile(id: 'new', profile: request.profile);

  @override
  Future<ProfileDeleteResult> profileDelete(String id) async {
    _profiles.removeWhere((profile) => profile.id == id);
    return ProfileDeleteResult(ok: true, id: id, deleted: true);
  }

  @override
  Future<RefreshResult> profileRefresh(String id, {bool force = false}) async =>
      RefreshResult(profileId: id, state: 'done');

  @override
  Future<RefreshAllResult> profileRefreshAll({
    bool force = false,
    int? limit,
  }) async {
    refreshAllCount++;
    lastForceAll = force;
    return refreshAllResult;
  }

  @override
  Future<void> applyProfile(String profileId) async {}

  @override
  Stream<ProxyEvent> get events => _events.stream;

  // ---- Todo 24 新增门面方法 ----

  @override
  Future<StoredProfile> profileUpdate(Map<String, dynamic> payload) async {
    updateCount++;
    lastUpdatePayload = payload;
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
  Future<GeneratedConfig> profileExportClash(ProfileExportRequest request) async {
    exportCount++;
    lastExportId = request.id;
    return const GeneratedConfig(
      config: _exportConfig,
      profileId: 'p1',
      profileName: '我的订阅',
      counts: ProxyConfigCounts(proxies: 1, groups: 1, rules: 2),
    );
  }

  @override
  Future<StoredProfile> profileSetSchedule(String id, int intervalMs) async {
    setScheduleCount++;
    lastScheduleId = id;
    lastScheduleInterval = intervalMs;
    final index = _profiles.indexWhere((profile) => profile.id == id);
    if (index >= 0) {
      final old = _profiles[index];
      _profiles[index] = ProfileSummary(
        id: old.id,
        name: old.name,
        format: old.format,
        nodeCount: old.nodeCount,
        groupCount: old.groupCount,
        createdAtMs: old.createdAtMs,
        updatedAtMs: old.updatedAtMs,
        revision: old.revision,
        sourceOrigin: old.sourceOrigin,
        sourceUrl: old.sourceUrl,
        userinfo: old.userinfo,
        refresh: ProfileRefreshState(
          state: old.refresh?.state ?? ProxyRefreshState.done,
          intervalMs: intervalMs == 0 ? null : intervalMs,
          lastUpdatedAtMs: old.refresh?.lastUpdatedAtMs,
        ),
      );
    }
    return StoredProfile(
      id: id,
      profile: const ImportedProfile(name: '', format: 'clash'),
    );
  }

  Future<void> dispose() => _events.close();
}

/// 记录导出的另存接缝：保存文件名与字节，返回可控落地路径。
class _RecordingSave {
  final List<String> fileNames = <String>[];
  final List<Uint8List> bytes = <Uint8List>[];
  String? nextPath = '/tmp/gstore_export.yaml';

  Future<String?> call({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) async {
    fileNames.add(fileName);
    this.bytes.add(bytes);
    return nextPath;
  }
}

ProfileSummary _summary({
  String id = 'p1',
  String name = '订阅',
  int nodes = 42,
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
    refresh: refresh,
  );
}

/// 测试宿主：挂载全局 navigatorKey（弹层）与 scaffoldMessengerKey（Snackbar）。
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

/// 打开某卡片的「更多」菜单并选择 [label]。
Future<void> _openProfileMenu(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('重命名：编辑名称后调用 profile.update 并刷新列表', (tester) async {
    final facade = _FakeProfilesFacade(
      profiles: [_summary(id: 'p1', name: '旧名称')],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();
    expect(find.text('旧名称'), findsOneWidget);

    await _openProfileMenu(tester, '重命名');
    await tester.enterText(find.byType(TextField), '新名称');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await _tick(tester);
    await _tick(tester);

    expect(facade.updateCount, 1);
    expect(facade.lastUpdatePayload?['id'], 'p1');
    expect(facade.lastUpdatePayload?['name'], '新名称');
    expect(find.text('新名称'), findsOneWidget);
    expect(find.text('旧名称'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出：Clash 配置含节点与规则并另存', (tester) async {
    final save = _RecordingSave();
    final facade = _FakeProfilesFacade(
      profiles: [_summary(id: 'p1', name: '我的订阅')],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(
      _host(ProxyProfilesPage(facade: facade, saveFile: save.call)),
    );
    await tester.pumpAndSettle();

    await _openProfileMenu(tester, '导出 Clash');
    await _tick(tester);
    await _tick(tester);

    expect(facade.exportCount, 1);
    expect(facade.lastExportId, 'p1');
    expect(save.bytes, hasLength(1));
    final text = utf8.decode(save.bytes.single);
    expect(text, contains('香港 01'));
    expect(text, contains('DOMAIN-SUFFIX,example.com,PROXY'));
    expect(text, contains('MATCH,DIRECT'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('排程：设置 6 小时间隔后回读一致', (tester) async {
    final facade = _FakeProfilesFacade(
      profiles: [_summary(id: 'p1', name: '订阅A')],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅手动更新'), findsOneWidget);

    await _openProfileMenu(tester, '自动更新间隔');
    await tester.tap(find.text('每 6 小时'));
    await _tick(tester);
    await _tick(tester);

    expect(facade.setScheduleCount, 1);
    expect(facade.lastScheduleId, 'p1');
    expect(facade.lastScheduleInterval, 6 * 60 * 60 * 1000);
    expect(find.textContaining('自动更新 6 小时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部更新：展示 skipped 原因并可强制更新', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [
      _summary(id: 'p1', name: '不可刷新源', origin: 'text', url: null),
      _summary(id: 'p2', name: '退避中'),
    ]);
    facade.refreshAllResult = const RefreshAllResult(
      skipped: <RefreshSkipped>[
        RefreshSkipped(profileId: 'p1', reason: 'not_refreshable'),
        RefreshSkipped(profileId: 'p2', reason: 'backoff'),
      ],
    );
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('全部更新'));
    await _tick(tester);
    await _tick(tester);

    expect(find.textContaining('来源不可刷新'), findsOneWidget);
    expect(find.textContaining('失败退避中'), findsOneWidget);
    expect(find.text('不可刷新源'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, '强制更新'));
    await _tick(tester);
    await _tick(tester);

    expect(facade.lastForceAll, isTrue);
    expect(facade.refreshAllCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不可刷新来源：不显示单个刷新按钮', (tester) async {
    final facade = _FakeProfilesFacade(profiles: [
      _summary(id: 'p1', name: '文本订阅', origin: 'text', url: null),
      _summary(id: 'p2', name: 'URL 订阅'),
    ]);
    addTearDown(facade.dispose);

    await tester.pumpWidget(_host(ProxyProfilesPage(facade: facade)));
    await tester.pumpAndSettle();

    // 只有 URL 来源的卡片有刷新按钮。
    expect(find.byTooltip('更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
