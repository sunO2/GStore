/// 发现页渠道列表门禁：`local_db` 只是内部目录数据源，绝不能出现在发现页
/// 渠道 code（侧栏 / 加载 / 搜索选择器）；`gstore` 作为可写渠道在 flag on 时可见。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/home/tab/discovery/logic.dart';

import 'support/discovery_facade_seams.dart';
import 'support/library_api_seam.dart';

Future<void> _setFlags({required bool channels}) async {
  CoreFlags.installBackend(
    FakeFlagsBackend(CoreFlagsSnapshot(channels: channels)),
  );
  await CoreFlags.refresh();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    AddedAppsFacade.backendOverride = null;
    RustChannelFacade.resetBackend();
    await ChannelManager.instance.disposeAll();
    ModuleManager.instance.unbind<ChannelManager>();
  });

  /// 安装无需原生库的 facade 后端（gstore 走 Rust 门面）。
  void installFakeBackends() {
    RustChannelFacade.installBackend(FakeChannelApiBackend(FakeLibraryApi()));
    AddedAppsFacade.backendOverride = RecordingAddedApps('added');
  }

  ProviderContainer makeContainer(DiscoveryNotifier notifier) {
    final container = ProviderContainer(overrides: [
      discoveryProvider.overrideWith(() => notifier),
    ]);
    container.read(discoveryProvider);
    return container;
  }

  testWidgets('discovery channel codes omit local_db and keep gstore',
      (tester) async {
    late List<String> codes;
    await tester.runAsync(() async {
      await _setFlags(channels: true);
      installFakeBackends();
      // local_db 仍可注册（内部目录读取器），但发现页不得列出
      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.localDb, const []));
      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const []));

      final notifier = DiscoveryNotifier();
      final container = makeContainer(notifier);
      codes = notifier.sortedChannelCodes;
      container.dispose();
    });

    expect(codes, isNot(contains(ChannelType.localDb.code)),
        reason: 'local_db is an internal catalog source, not a discovery channel');
    expect(codes, contains(ChannelType.fdroid.code));
    expect(codes, contains(ChannelType.gstore.code),
        reason: 'gstore is a writable channel the discovery page must list');
  });

  testWidgets('_loadAllChannelApps never loads local_db', (tester) async {
    late List<String> loadedCodes;
    await tester.runAsync(() async {
      await _setFlags(channels: true);
      installFakeBackends();
      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.localDb, const []));

      final notifier = DiscoveryNotifier();
      final container = makeContainer(notifier);
      await notifier.loadData();
      loadedCodes = notifier.state.channelApps.keys.toList();
      container.dispose();
    });

    expect(loadedCodes, isNot(contains(ChannelType.localDb.code)),
        reason: 'discovery must not load the local_db channel');
    expect(loadedCodes, contains(ChannelType.gstore.code),
        reason: 'gstore must be loaded through the core facade');
  });
}
