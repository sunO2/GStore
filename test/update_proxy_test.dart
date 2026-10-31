import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 新配置栈的分组 wire key 为 network.proxy_url；SharedPreferences 存储层
  // 统一加 config_ 前缀，故预置键为 config_network.proxy_url。
  const proxyKey = 'config_network.proxy_url';

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
      final snap = await ConfigService.instance.snapshot(ConfigKeys.proxyUrl);
      expect(snap?.value, isNull, reason: '清除后快照表示「未设置」');
      expect(
        await ConfigService.instance.getRaw(ConfigKeys.proxyUrl),
        '',
        reason: '未设置时 getRaw 回落注册表默认值（空串）',
      );
    });

    test('updateProxy(null) 后再次写入仍可持久化（清除走 clear 而非 set-null）',
        () async {
      await loadProxyFromConfig();
      await updateProxy('https://old.example.com/');
      await updateProxy(null);
      expect(getProxy(), defaultProxy);

      // 清除后重新写入，必须真正落盘（回归：set(null) 被 Rust 拒绝后
      // updateProxy 仍乐观显示成功，旧值残留；这里验证后续写入可覆盖）。
      await updateProxy('https://x.example.com/');
      expect(getProxy(), 'https://x.example.com/');
      expect(
        (await ConfigService.instance.snapshot(ConfigKeys.proxyUrl))?.value,
        'https://x.example.com/',
      );
    });

    test('ConfigService.set(proxyUrl, null) 被拒绝；clear 才删除（Rust 语义）',
        () async {
      await loadProxyFromConfig();
      await updateProxy('https://x.example.com/');

      // 真实 Rust 对 String 条目拒绝 JSON null（ConfigTypeMismatch），
      // 内存 fake 也必须同样失败，否则无法区分 clear 与 set-null。
      final setNull =
          await ConfigService.instance.set(ConfigKeys.proxyUrl, null);
      expect(setNull.success, isFalse, reason: 'String 条目不接受 JSON null');
      expect(
        (await ConfigService.instance.snapshot(ConfigKeys.proxyUrl))?.value,
        'https://x.example.com/',
        reason: 'set(null) 失败后旧值必须保留',
      );

      final cleared = await ConfigService.instance.clear(ConfigKeys.proxyUrl);
      expect(cleared.success, isTrue, reason: 'clear 走 Rust remove 路径');
      expect(
        (await ConfigService.instance.snapshot(ConfigKeys.proxyUrl))?.value,
        isNull,
      );
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
