import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/state.dart';

import 'support/added_apps_read_seams.dart';

class _RecordingAdded extends InMemoryAddedAppsBackend {
  AppSummary? lastApp;

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {
    lastApp = appInfo;
    await super.add(channel, appId, sortOrder: sortOrder, appInfo: appInfo);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
  });

  test('gstore 详情页加入渠道并写入库关系', () async {
    final backend = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = backend;

    final state = DetailState();
    final logic = DetailLogic(state: state);
    final request = AppDetailRequest(
      appId: 'com.catalog',
      name: 'Catalog App',
      packageName: 'com.catalog',
      icon: 'icons/catalog.png',
      description: 'A catalog app',
      channel: ChannelType.gstore,
      channelCode: 'gstore',
    );
    logic.request = request;
    state.request = request;

    await logic.addToLibrary();

    expect(await backend.isAdded('gstore', 'com.catalog'), isTrue);
    expect(state.libraryAdded, isTrue);
    expect(state.libraryBusy, isFalse);
  });
  test('加入 gstore 时把 owner/repo 与包名传给渠道 metadata 写入', () async {
    final backend = _RecordingAdded();
    AddedAppsFacade.backendOverride = backend;

    final state = DetailState();
    final logic = DetailLogic(state: state);
    final request = AppDetailRequest(
      appId: 'acme/repo',
      name: 'Acme App',
      packageName: 'com.example.acme',
      channel: ChannelType.gstore,
      channelCode: 'gstore',
    );
    logic.request = request;
    state.request = request;

    await logic.addToLibrary();

    expect(backend.lastApp?.user, 'acme');
    expect(backend.lastApp?.repositories, 'repo');
    expect(backend.lastApp?.packageName, 'com.example.acme');
    expect(backend.lastApp?.extra?['packageName'], 'com.example.acme');
  });
}
