/// Post-wave06 bug fix (tag leg, detail): the DETAIL tag panel must read its
/// current tags and write the edited tags through the core `AddedAppsFacade`,
/// not the legacy `AppAggregatorManager` (whose `setTags` fails closed with
/// `LegacyWriteBlocked(catalog)` once the core owns `catalog`).
///
/// This lives in its OWN file (its own test isolate): `CoreFlags` keeps a
/// process-wide serialized future bound to the zone that created it, and this is
/// a `testWidgets` (FakeAsync) case. If a real-zone `test(...)` ran first in the
/// same isolate, this case's `CoreFlags.refresh()` would chain onto a future from
/// the dead zone and hang. As the sole CoreFlags user here, everything shares
/// this test's FakeAsync zone (same pattern as
/// `discovery_settags_via_facade_test.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/detail/logic.dart';

import 'support/added_apps_read_seams.dart';
import 'support/discovery_facade_seams.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
  });

  testWidgets(
      '(detail) flag on: the tag read + write route through the facade core '
      'backend and never throw', (tester) async {
    final core = FakeAddedApps('core')
      ..tagsByApp['github:owner/repo'] = ['工具'];
    AddedAppsFacade.backendOverride = core;

    ChannelManager.instance.registerChannel(
        FakeEnumChannel(ChannelType.github, const [sampleApp]));

    await setCatalogFlag(catalog: true);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));

    final logic = DetailLogic();
    addTearDown(logic.shutdown);
    logic.setRouteExtra(const AppDetailRequest(
      appId: 'owner/repo',
      name: '测试应用',
      packageName: 'com.example.app',
      channel: ChannelType.github,
    ));
    await logic.start();

    final ctx = appNavigatorKey.currentContext!;
    final future = logic.showMoreActions(ctx);
    await tester.pumpAndSettle();

    // READ: current tags came from the facade (core backend).
    expect(core.tagsCalls, contains(('github', 'owner/repo')),
        reason: 'the tag read must go through the facade core backend');

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    await future;

    // WRITE: routed to the facade core backend and never threw.
    expect(core.setTagsCalls, hasLength(1),
        reason: 'the tag write must go through the facade core backend');
    expect(core.setTagsCalls.single.$1, 'github');
    expect(core.setTagsCalls.single.$2, 'owner/repo');
    expect(core.setTagsCalls.single.$3, const ['工具']);
    expect(core.notifyCalls, greaterThan(0),
        reason: 'a tag change must announce via notifyAppsChanged()');
  });
}
