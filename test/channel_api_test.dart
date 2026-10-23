import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

class _RecordingBackend implements ChannelApiBackend {
  final List<String> calls = <String>[];

  static const entry = rust.ChannelEntry(
    key: 'github',
    kind: 'github',
    name: 'GitHubAPI',
    description: 'GitHub API',
    enabled: true,
    priority: 2,
    supportOffline: false,
  );

  static const app = rust.ChannelAppInfo(
    appId: 'owner/repo',
    packageName: 'com.example.app',
    name: 'Example',
    user: 'owner',
    repositories: 'repo',
    icon: 'icon.png',
    des: 'description',
    category: <String>['Tools'],
  );

  static const detail = rust.ChannelAppDetailInfo(
    appId: 'owner/repo',
    name: 'Example',
    icon: 'icon.png',
    description: 'description',
    version: '1.0',
    channel: 'github',
    sections: <String>['downloads'],
    downloads: <rust.ChannelAppDownloadInfo>[],
    extraJson: '{}',
  );

  static const pack = rust.ChannelPackInfo(
    key: 'js_alpha',
    packHash: 'hash',
    installedAt: 1,
    dir: '/tmp/js_alpha/hash',
  );

  static const category = rust.ChannelCategoryInfo(
    id: 'Tools',
    description: '工具',
    icon: 'tool.png',
  );

  static const config = rust.ChannelConfigInfo(version: '1.0', proxy: null);

  @override
  Future<List<rust.ChannelEntry>> list() async {
    calls.add('list');
    return <rust.ChannelEntry>[entry];
  }

  @override
  Future<rust.ChannelEntry> get({required String key}) async {
    calls.add('get:$key');
    if (key == 'missing') {
      throw const ChannelApiException(
        'not_found',
        'channel not registered: missing',
      );
    }
    return entry;
  }

  @override
  Future<rust.ChannelEntry> register(
      {required rust.ChannelRegistration registration}) async {
    calls.add('register:${registration.key}');
    return entry;
  }

  @override
  Future<void> unregister({required String key}) async {
    calls.add('unregister:$key');
  }

  @override
  Future<rust.ChannelEntry> enable({required String key}) async {
    calls.add('enable:$key');
    return entry;
  }

  @override
  Future<rust.ChannelEntry> disable({required String key}) async {
    calls.add('disable:$key');
    return entry;
  }

  @override
  Future<rust.ChannelPackInfo> importPack({required String path}) async {
    calls.add('importPack:$path');
    return pack;
  }

  @override
  Future<BigInt> exportPack({required String key, required String path}) async {
    calls.add('exportPack:$key:$path');
    return BigInt.from(7);
  }

  @override
  Future<bool> removePack({required String key}) async {
    calls.add('removePack:$key');
    return true;
  }

  @override
  Future<String?> envGet({required String key, required String name}) async {
    calls.add('envGet:$key:$name');
    return 'value';
  }

  @override
  Future<void> envSet({
    required String key,
    required String name,
    required String value,
  }) async {
    calls.add('envSet:$key:$name:$value');
  }

  @override
  Future<bool> envRemove({required String key, required String name}) async {
    calls.add('envRemove:$key:$name');
    return true;
  }

  @override
  Future<bool> refresh({required String key}) async {
    calls.add('refresh:$key');
    return true;
  }

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) async {
    calls.add('search:$key:$keyword:$forceRefresh');
    return <rust.ChannelAppInfo>[app];
  }

  @override
  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add('getAppInfo:$key:$appId:$forceRefresh');
    if (appId == 'missing') {
      throw const ChannelApiException(
        'not_found',
        'app not found: missing',
      );
    }
    return app;
  }

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add('getAppDetail:$key:$appId:$forceRefresh');
    return detail;
  }

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    calls.add('addApp:$key:${app.appId}');
  }

  @override
  Future<void> removeApp({required String key, required String appId}) async {
    calls.add('removeApp:$key:$appId');
  }

  @override
  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  }) async {
    calls.add('searchByCategory:$key:$categoryId:$forceRefresh');
    return <rust.ChannelAppInfo>[app];
  }

  @override
  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) async {
    calls.add('getAllCategories:$key:$forceRefresh');
    return <rust.ChannelCategoryInfo>[category];
  }

  @override
  Future<String> canonicalAppId({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    calls.add('canonicalAppId:$key:${app.appId}');
    return 'com.example.app';
  }

  @override
  Future<rust.ChannelConfigInfo?> getConfig({
    required String key,
    required bool forceRefresh,
  }) async {
    calls.add('getConfig:$key:$forceRefresh');
    return config;
  }
}

void main() {
  late _RecordingBackend backend;

  setUp(() {
    backend = _RecordingBackend();
    RustChannelFacade.installBackend(backend);
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot()),
    );
  });

  tearDown(() {
    RustChannelFacade.resetBackend();
    CoreFlags.resetBackend();
  });

  test('facade delegates every method to the injected backend', () async {
    final facade = RustChannelFacade.instance;

    expect((await facade.list()).single.key, 'github');
    expect((await facade.get(key: 'github')).key, 'github');
    expect(
      (await facade.register(
        registration: const rust.ChannelRegistration(
          key: 'js_new',
          kind: 'custom',
          name: 'New',
          description: '',
          enabled: true,
          priority: 9,
          supportOffline: false,
        ),
      ))
          .key,
      'github',
    );
    await facade.unregister(key: 'js_new');
    await facade.enable(key: 'github');
    await facade.disable(key: 'github');
    expect((await facade.importPack(path: '/tmp/a.zip')).key, 'js_alpha');
    expect(
      await facade.exportPack(key: 'js_alpha', path: '/tmp/out.zip'),
      BigInt.from(7),
    );
    expect(await facade.removePack(key: 'js_alpha'), isTrue);
    expect(await facade.envGet(key: 'github', name: 'USER'), 'value');
    await facade.envSet(key: 'github', name: 'USER', value: 'alice');
    expect(await facade.envRemove(key: 'github', name: 'USER'), isTrue);
    expect(await facade.refresh(key: 'github'), isTrue);
    expect(
      (await facade.search(
        key: 'github',
        keyword: 'hello',
        forceRefresh: true,
      ))
          .single
          .appId,
      'owner/repo',
    );
    expect(
      (await facade.getAppInfo(
        key: 'github',
        appId: 'owner/repo',
        forceRefresh: false,
      ))
          .name,
      'Example',
    );
    expect(
      (await facade.getAppDetail(
        key: 'github',
        appId: 'owner/repo',
        forceRefresh: false,
      ))
          .version,
      '1.0',
    );
    await facade.addApp(key: 'github', app: _RecordingBackend.app);
    await facade.removeApp(key: 'github', appId: 'owner/repo');
    expect(
      (await facade.searchByCategory(
        key: 'github',
        categoryId: 'Tools',
        forceRefresh: false,
      ))
          .single
          .appId,
      'owner/repo',
    );
    expect(
      (await facade.getAllCategories(key: 'github', forceRefresh: false))
          .single
          .id,
      'Tools',
    );
    expect(
      await facade.canonicalAppId(key: 'github', app: _RecordingBackend.app),
      'com.example.app',
    );
    expect(
      (await facade.getConfig(key: 'github', forceRefresh: false))?.version,
      '1.0',
    );

    expect(backend.calls, <String>[
      'list',
      'get:github',
      'register:js_new',
      'unregister:js_new',
      'enable:github',
      'disable:github',
      'importPack:/tmp/a.zip',
      'exportPack:js_alpha:/tmp/out.zip',
      'removePack:js_alpha',
      'envGet:github:USER',
      'envSet:github:USER:alice',
      'envRemove:github:USER',
      'refresh:github',
      'search:github:hello:true',
      'getAppInfo:github:owner/repo:false',
      'getAppDetail:github:owner/repo:false',
      'addApp:github:owner/repo',
      'removeApp:github:owner/repo',
      'searchByCategory:github:Tools:false',
      'getAllCategories:github:false',
      'canonicalAppId:github:owner/repo',
      'getConfig:github:false',
    ]);
  });

  test('flag off keeps ChannelManager on the old Dart path', () async {
    await CoreFlags.refresh();
    expect(CoreFlags.channels, isFalse);

    final result = await ChannelManager.instance.getAppInfo(
      'owner/repo',
      from: ChannelType.vivo,
    );

    expect(result.success, isFalse);
    expect(result.error, contains('渠道不可用或未注册'));
    expect(backend.calls, isEmpty,
        reason: 'the Rust backend must not be called while the flag is false');
  });

  test('flag on makes ChannelManager delegate to the facade', () async {
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
    expect(CoreFlags.channels, isTrue);

    final result = await ChannelManager.instance.getAppInfo(
      'owner/repo',
      from: ChannelType.github,
    );

    expect(result.success, isTrue);
    expect(result.data?.appId, 'owner/repo');
    expect(result.data?.packageName, 'com.example.app');
    expect(result.data?.category, <String>['Tools']);
    expect(backend.calls, <String>['getAppInfo:github:owner/repo:false']);
  });

  test('typed missing-channel errors surface unchanged', () async {
    final facade = RustChannelFacade.instance;
    await expectLater(
      facade.get(key: 'missing'),
      throwsA(
        isA<ChannelApiException>()
            .having((error) => error.code, 'code', 'not_found')
            .having(
              (error) => error.message,
              'message',
              contains('channel not registered: missing'),
            ),
      ),
    );

    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
    );
    await CoreFlags.refresh();
    final result = await ChannelManager.instance.getAppInfo(
      'missing',
      from: ChannelType.github,
    );
    expect(result.success, isFalse);
    expect(result.error, contains('not_found'));
    expect(result.error, contains('app not found: missing'));
  });
}
