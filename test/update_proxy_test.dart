import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const proxyKey = 'config_proxy_url';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 重置 ConfigStore，避免单例缓存旧 prefs 实例导致跨用例污染
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize();
    ConfigRegistry.registerAll(ConfigService.instance);
  });

  tearDown(() {
    resetProxyForTest();
  });

  group('updateProxy B 轨（ConfigService 迁移）', () {
    test('未设置 → loadProxyFromConfig 后 getProxy() == defaultProxy', () async {
      await loadProxyFromConfig();
      expect(getProxy(), defaultProxy);
    });

    test('显式空串 → load 后 getProxy() == ""', () async {
      SharedPreferences.setMockInitialValues({proxyKey: ''});
      await loadProxyFromConfig();
      expect(getProxy(), '');
    });

    test('updateProxy 写入后立即生效并持久化', () async {
      await loadProxyFromConfig();
      await updateProxy('https://x.example.com/');
      expect(getProxy(), 'https://x.example.com/');
      expect(
        await ConfigService.instance.get(ConfigKeys.proxyUrl),
        'https://x.example.com/',
      );
    });

    test('watch 联动：ConfigService.set 后 getProxy() 即时反映', () async {
      await loadProxyFromConfig();
      expect(getProxy(), defaultProxy);

      await ConfigService.instance
          .set(ConfigKeys.proxyUrl, 'https://x.example.com/');
      await pumpEventQueue();

      expect(getProxy(), 'https://x.example.com/');
    });

    test('updateProxy(null) → getProxy() == defaultProxy 且持久化清除', () async {
      await loadProxyFromConfig();
      await updateProxy('https://x.example.com/');
      await updateProxy(null);
      expect(getProxy(), defaultProxy);
      expect(await ConfigService.instance.get(ConfigKeys.proxyUrl), isNull);
    });

    test('预置值 → load 后 getProxy() 返回该值', () async {
      SharedPreferences.setMockInitialValues(
        {proxyKey: 'https://x.example.com/'},
      );
      await loadProxyFromConfig();
      expect(getProxy(), 'https://x.example.com/');
    });
  });
}
