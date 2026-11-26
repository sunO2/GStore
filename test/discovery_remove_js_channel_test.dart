import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';

import 'support/discovery_facade_seams.dart';
import 'support/library_api_seam.dart';

/// Regression: a `js_*` pack app added from discovery must be removable from
/// the channel. The old `removeFromChannel` returned false for every Rust-lane
/// pack ("无 remove API"), so the UI silently did nothing.
class _FakeLane extends RustScriptChannelLane {
  final List<(String, String)> removed = [];
  final List<AppSummary> saved = [];

  @override
  bool get enabled => true;

  @override
  Future<void> refresh() async {}

  @override
  rust_pack.ScriptPackInfo? packFor(String code) => code == 'js_vivo'
      ? const rust_pack.ScriptPackInfo(
          key: 'js_vivo',
          name: 'vivo 应用市场',
          description: '',
          icon: '',
          hasDetail: false,
        )
      : null;

  @override
  Future<List<AppSummary>> storedApps(String code) async =>
      List<AppSummary>.unmodifiable(saved);

  @override
  Future<void> removeApp(String code, String appId) async {
    removed.add((code, appId));
    saved.removeWhere((app) => app.appId == appId);
  }
}

class _EnabledLane extends RustScriptChannelLane {
  @override
  bool get enabled => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() {
    AddedAppsFacade.backendOverride = null;
    RustScriptChannelLane.resetForTest();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  test('lane.removeApp 走 ChannelApi.removeApp（真实实现）', () async {
    final fake = FakeChannelApiBackend(FakeLibraryApi());
    RustChannelFacade.installBackend(fake);
    addTearDown(RustChannelFacade.resetBackend);

    await _EnabledLane().removeApp('js_vivo', 'com.zhihu.android');

    expect(fake.removeAppCalls, [('js_vivo', 'com.zhihu.android')]);
  });

  test('js 渠道应用可从渠道删除，并同步清掉首页索引', () async {
    final lane = _FakeLane();
    lane.saved.add(const AppSummary(
      appId: 'com.zhihu.android',
      name: '知乎',
      user: '',
      repositories: '',
      icon: '',
      des: '',
    ));
    RustScriptChannelLane.installForTest(lane);

    final added = RecordingAddedApps('core');
    added.added['js_vivo'] = {'com.zhihu.android'};
    AddedAppsFacade.backendOverride = added;

    final notifier = DiscoveryNotifier();
    final container = ProviderContainer(overrides: [
      discoveryProvider.overrideWith(() => notifier),
    ]);
    container.read(discoveryProvider);

    final ok = await notifier.removeFromChannel(
      'js_vivo',
      'com.zhihu.android',
      showSnack: false,
    );

    expect(ok, isTrue);
    expect(lane.removed, [('js_vivo', 'com.zhihu.android')],
        reason: 'must delete the channel_apps row through the Rust lane');
    expect(added.removeCalls, contains(('js_vivo', 'com.zhihu.android')),
        reason: 'must also remove the home membership');
    expect(notifier.state.channelApps['js_vivo'] ?? const [], isEmpty);

    container.dispose();
  });
}
