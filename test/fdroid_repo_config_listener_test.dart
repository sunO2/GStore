import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';

/// FdroidRepoManager 配置驱动状态同步测试（P1）
///
/// 验证外部写入 `fdroid.sources` / `fdroid.last_source_id` 时，管理器通过
/// `ConfigService.onChange` 监听自动刷新内存源列表与当前源，且不触发网络加载。
/// 本测试不调用 initialize()，避免依赖 Rust / path_provider。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: <ConfigStorage>[
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
    await ConfigService.instance.ensureReady();
  });

  tearDown(() async {
    await ConfigService.instance.resetForTest();
    ConfigStore.instance.resetForTest();
  });

  Future<void> waitDebounce() async {
    // 监听器防抖 50ms，留足余量等待异步应用完成。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  group('FdroidRepoManager 外部配置监听', () {
    test('fdroid.sources 变化刷新内存源列表', () async {
      final manager = FdroidRepoManager()..debugSkipCorePush = true;
      addTearDown(manager.dispose);
      manager.debugStartConfigWatcher();

      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'official',
            'name': '官方源',
            'repoUrl': 'https://f-droid.org/repo',
            'enabled': true,
          },
        ],
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();

      expect(manager.sources, hasLength(1));
      expect(manager.sources.first.id, 'official');

      // 第二批：替换旧源（tuna 禁用但仍存在）
      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'tuna',
            'name': '清华镜像',
            'repoUrl': 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
            'enabled': false,
          },
        ],
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();

      expect(manager.sources, hasLength(1));
      expect(manager.sources.first.id, 'tuna');
      expect(manager.sources.any((s) => s.id == 'official'), isFalse);
    });

    test('fdroid.last_source_id 变化切换当前源（不触发网络加载）', () async {
      final manager = FdroidRepoManager()..debugSkipCorePush = true;
      addTearDown(manager.dispose);
      manager.debugStartConfigWatcher();

      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'official',
            'name': '官方源',
            'repoUrl': 'https://f-droid.org/repo',
            'enabled': true,
          },
          <String, Object?>{
            'id': 'tuna',
            'name': '清华镜像',
            'repoUrl': 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
            'enabled': true,
          },
        ],
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();

      // 源列表变化时默认选中第一个启用源
      expect(manager.currentSource?.id, 'official');

      await ConfigService.instance.set(
        ConfigKeys.lastSourceId,
        'tuna',
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();

      expect(manager.currentSource?.id, 'tuna');
      // 外部配置只切身份，不进入加载状态（不会触发 loadRepository）
      expect(manager.isLoading, isFalse);
    });

    test('dispose 后不再响应配置变化', () async {
      final manager = FdroidRepoManager()..debugSkipCorePush = true;
      manager.debugStartConfigWatcher();

      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'official',
            'name': '官方源',
            'repoUrl': 'https://f-droid.org/repo',
            'enabled': true,
          },
        ],
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();
      expect(manager.sources, hasLength(1));

      manager.dispose();

      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'tuna',
            'name': '清华镜像',
            'repoUrl': 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo',
            'enabled': true,
          },
        ],
        source: ConfigChangeSource.internal,
      );
      await waitDebounce();

      // 监听已取消：内存列表保持 dispose 前的状态
      expect(manager.sources, hasLength(1));
      expect(manager.sources.first.id, 'official');
    });
  });
}
