/// S3: the home read model must come from `rust.LibraryApi.page`.
///
/// `AddedAppsFacade.getAggregatedAppsPage` no longer lists rows and joins each
/// one through `ChannelManager.getAppInfoByCode`; it asks the Rust
/// `AggregationService` for one page. This test installs a fake
/// `rust.LibraryApi` (via the shared `RustChannelFacade` backend) and asserts:
///
/// * the page entries are returned,
/// * `total` is the raw `added_apps` row count (not the page length),
/// * each entry's `metadataState` is surfaced on `AggregatedAppInfo`, and
/// * no per-row `ChannelManager.getAppInfoByCode` (ChannelApi.getAppInfo) call
///   happens.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

import 'support/library_api_seam.dart';

rust.ChannelAppInfo _app(String appId, String name, String icon) =>
    rust.ChannelAppInfo(
      appId: appId,
      name: name,
      user: '',
      repositories: '',
      icon: icon,
      des: 'desc',
      category: const <String>['tool'],
      labels: const <rust.ChannelLabel>[],
    );

rust.LibraryEntry _entry({
  required String channel,
  required String appId,
  required int addTime,
  required String name,
  required String metadataState,
}) =>
    rust.LibraryEntry(
      added: rust.AddedAppEntry(
        id: addTime,
        channelId: channel,
        appId: appId,
        addTime: addTime,
        sortOrder: 0,
        isEnabled: true,
      ),
      app: _app(appId, name, '$appId.png'),
      channelCode: channel,
      channelKind: channel,
      isFromCache: metadataState == 'unresolved',
      metadataState: metadataState,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
  });

  test('getAggregatedAppsPage returns LibraryApi.page entries and total',
      () async {
    final library = FakeLibraryApi()
      ..pageEntries = [
        _entry(
          channel: 'fdroid',
          appId: 'com.new',
          addTime: 20,
          name: 'New App',
          metadataState: 'resolved',
        ),
        _entry(
          channel: 'js_probe',
          appId: 'com.js',
          addTime: 10,
          name: 'JS App',
          metadataState: 'from_channel_store',
        ),
      ]
      // Raw membership count is larger than the page: total must not be the
      // page length.
      ..pageTotalOverride = 5;
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    AddedAppsFacade.backendOverride = null;

    final (apps, total) = await AddedAppsFacade.instance
        .getAggregatedAppsPage(offset: 0, limit: 1);

    expect(library.pageRequests, const [(0, 1)],
        reason: 'the facade must ask LibraryApi for exactly this page');
    expect(total, 5, reason: 'total is the raw added_apps row count');
    expect(apps, hasLength(1), reason: 'limit 1 returns one entry');
    expect(apps.single.addedAppInfo.channelId, 'fdroid');
    expect(apps.single.addedAppInfo.appId, 'com.new');
    expect(apps.single.appInfo.name, 'New App');
    expect(apps.single.appInfo.icon, 'com.new.png');
    expect(apps.single.metadataState, 'resolved');
    expect(channels.getAppInfoCalls, isEmpty,
        reason: 'the home read must not join through getAppInfoByCode');
  });

  test('getAggregatedAppsPage surfaces from_channel_store / unresolved states',
      () async {
    final library = FakeLibraryApi()
      ..pageEntries = [
        _entry(
          channel: 'js_probe',
          appId: 'com.js',
          addTime: 2,
          name: 'JS App',
          metadataState: 'from_channel_store',
        ),
        _entry(
          channel: 'ghost',
          appId: 'com.ghost',
          addTime: 1,
          name: 'com.ghost',
          metadataState: 'unresolved',
        ),
      ];
    final channels = FakeChannelApiBackend(library);
    RustChannelFacade.installBackend(channels);
    AddedAppsFacade.backendOverride = null;

    final (apps, total) = await AddedAppsFacade.instance
        .getAggregatedAppsPage(offset: 0, limit: 10);

    expect(total, 2);
    expect(apps.map((a) => a.metadataState),
        ['from_channel_store', 'unresolved']);
    expect(apps.last.isFromCache, isTrue,
        reason: 'unresolved rows still render the placeholder');
    expect(channels.getAppInfoCalls, isEmpty);
  });
}
