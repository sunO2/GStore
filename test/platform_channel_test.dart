import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/platform/platform_channel.dart';

/// `gstore/platform` 的 Dart 侧契约测试：13 个方法逐一覆盖，
/// 外加错误信封 / 未知包 / 未实现 / 未注册 Shizuku 的降级路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformChannelClient.channelName);
  late List<MethodCall> calls;
  late PlatformChannelClient client;

  void installHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    calls = <MethodCall>[];
    client = PlatformChannelClient(channel: channel);
  });

  tearDown(() => installHandler(null));

  // pinned inventory entry（由 InventoryInspector.installedAppJson 产出）。
  const appJson = '{"package_name":"com.example.app","app_name":"示例",'
      '"version_name":"1.2.3","version_code":123,"icon":null,'
      '"is_system":false,"signature_sha256":"ab:cd:ef",'
      '"source_dir":"/data/app/base.apk","installer":"com.android.vending",'
      '"target_sdk":34,"min_sdk":24,"abis":["arm64-v8a"]}';

  Future<Object?> okHandler(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'listInstalled':
        return '[$appJson]';
      case 'getInstalled':
        return call.arguments == 'com.example.app' ? appJson : null;
      case 'getSourceDir':
        return call.arguments == 'com.example.app' ? '/data/app/base.apk' : null;
      case 'getSignatures':
        return '[{"algorithm":"SHA256withRSA","subject":"CN=GStore",'
            '"sha256":"ab:cd:ef","sha1":"01:02","kind":"current"}]';
      case 'getPermissions':
        return '["android.permission.INTERNET","android.permission.CAMERA"]';
      case 'getComponents':
        return '{"components":[{"kind":"ACTIVITY","name":"com.example.app.Main",'
            '"exported":true,"enabled":true,"process_name":null}],'
            '"permission_states":[]}';
      case 'deviceInfo':
        return '{"manufacturer":"Google","model":"Pixel","device":"pixel",'
            '"android_version":"14","sdk_int":34,"abis":["arm64-v8a"]}';
      case 'readBattery':
        return '{"present":true,"level":80,"capacityPercent":80}';
      case 'readDeviceState':
        return '{"battery":{"present":true},"display":{"width":1080}}';
      case 'readForeground':
        return '{"enabled":true,"package":"com.example.app",'
            '"activity":"Main","updatedAtMs":1}';
      case 'readFrameMetrics':
        return '{"count":3,"avgMs":8.5,"p90Ms":10.0,"p99Ms":11.0,'
            '"jankPercent":0.0,"lastMs":9.0,"refreshRate":60.0,"windowSize":120}';
      case 'exec':
        return call.arguments == 'pm list packages' ? 'package:com.example.app' : '';
      case 'available':
        return true;
      default:
        throw MissingPluginException(
          'No implementation found for method ${call.method} on channel '
          '${PlatformChannelClient.channelName}',
        );
    }
  }

  group('13 个方法（happy path）', () {
    test('listInstalled 返回加宽后的清单字段', () async {
      installHandler(okHandler);

      final apps = await client.listInstalled();

      expect(calls.single.method, 'listInstalled');
      expect(apps, hasLength(1));
      expect(apps.single.keys.toSet(), <String>{
        'package_name',
        'app_name',
        'version_name',
        'version_code',
        'icon',
        'is_system',
        'signature_sha256',
        'source_dir',
        'installer',
        'target_sdk',
        'min_sdk',
        'abis',
      });
      expect(apps.single['is_system'], isFalse);
      expect(apps.single['signature_sha256'], 'ab:cd:ef');
      expect(apps.single['abis'], <String>['arm64-v8a']);
      expect(apps.single.containsKey('system'), isFalse);
    });

    test('getInstalled 已知包返回对象，未知包返回 null', () async {
      installHandler(okHandler);

      final known = await client.getInstalled('com.example.app');
      final unknown = await client.getInstalled('com.example.missing');

      expect(known, isNotNull);
      expect(known!['package_name'], 'com.example.app');
      expect(unknown, isNull);
      expect(calls.map((c) => c.arguments), <Object?>[
        'com.example.app',
        'com.example.missing',
      ]);
    });

    test('getSourceDir 返回路径，未知包返回 null', () async {
      installHandler(okHandler);

      expect(await client.getSourceDir('com.example.app'), '/data/app/base.apk');
      expect(await client.getSourceDir('com.example.missing'), isNull);
    });

    test('getSignatures 返回签名数组', () async {
      installHandler(okHandler);

      final signatures = await client.getSignatures('com.example.app');

      expect(signatures, hasLength(1));
      expect(signatures.single['sha256'], 'ab:cd:ef');
      expect(signatures.single['kind'], 'current');
    });

    test('getPermissions 返回权限名单', () async {
      installHandler(okHandler);

      expect(await client.getPermissions('com.example.app'), <String>[
        'android.permission.INTERNET',
        'android.permission.CAMERA',
      ]);
    });

    test('getComponents 返回 snake_case 结构', () async {
      installHandler(okHandler);

      final components = await client.getComponents('com.example.app');

      expect(components.keys, containsAll(<String>['components', 'permission_states']));
      final list = components['components']! as List<Object?>;
      expect((list.single! as Map<Object?, Object?>)['kind'], 'ACTIVITY');
    });

    test('deviceInfo 返回设备键集', () async {
      installHandler(okHandler);

      final info = await client.deviceInfo();

      expect(info.keys.toSet(), <String>{
        'manufacturer',
        'model',
        'device',
        'android_version',
        'sdk_int',
        'abis',
      });
      expect(info['sdk_int'], 34);
    });

    test('readBattery 解析 JSON 对象', () async {
      installHandler(okHandler);

      expect((await client.readBattery())['capacityPercent'], 80);
    });

    test('readDeviceState 解析 JSON 对象', () async {
      installHandler(okHandler);

      final state = await client.readDeviceState();

      expect(state.keys, containsAll(<String>['battery', 'display']));
    });

    test('readForeground 解析 JSON 对象', () async {
      installHandler(okHandler);

      final foreground = await client.readForeground();

      expect(foreground['enabled'], isTrue);
      expect(foreground['package'], 'com.example.app');
    });

    test('readFrameMetrics 解析 JSON 对象', () async {
      installHandler(okHandler);

      final metrics = await client.readFrameMetrics();

      expect(metrics['count'], 3);
      expect(metrics['refreshRate'], 60.0);
    });

    test('exec 返回 shell 输出；Shizuku 不可用时返回 null', () async {
      installHandler(okHandler);

      expect(await client.exec('pm list packages'), 'package:com.example.app');

      installHandler((call) async => null);
      expect(await client.exec('pm list packages'), isNull);
    });

    test('available 透传布尔值', () async {
      installHandler(okHandler);
      expect(await client.available(), isTrue);

      installHandler((call) async => false);
      expect(await client.available(), isFalse);
    });
  });

  group('失败路径', () {
    test('未注册方法 → 原生 notImplemented → MissingPluginException', () async {
      // 原生 `result.notImplemented()` 回 null 应答，MethodChannel 映射为
      // MissingPluginException（客户端把该异常收敛为 typed 错误）。
      installHandler(
        (call) async => throw MissingPluginException(
          'No implementation found for method ${call.method}',
        ),
      );

      await expectLater(
        const MethodChannel(PlatformChannelClient.channelName)
            .invokeMethod<Object?>('noSuchMethod'),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('未知 / 未注册方法经客户端调用 → CORE_E_PLATFORM_UNIMPLEMENTED', () async {
      installHandler(
        (call) async => throw MissingPluginException(
          'No implementation found for method ${call.method}',
        ),
      );

      await expectLater(
        client.listInstalled(),
        throwsA(
          isA<PlatformChannelException>()
              .having((e) => e.code, 'code', 'CORE_E_PLATFORM_UNIMPLEMENTED'),
        ),
      );
    });

    test('listInstalled 的 typed 错误信封 → PlatformChannelException', () async {
      installHandler(
        (call) async => '{"ok":false,"code":"CORE_E_PLATFORM_DENIED",'
            '"message":"QUERY_ALL_PACKAGES denied"}',
      );

      await expectLater(
        client.listInstalled(),
        throwsA(
          isA<PlatformChannelException>()
              .having((e) => e.code, 'code', 'CORE_E_PLATFORM_DENIED')
              .having((e) => e.message, 'message', 'QUERY_ALL_PACKAGES denied'),
        ),
      );
    });

    test('非法 JSON 载荷 → CORE_E_PLATFORM_DECODE', () async {
      installHandler((call) async => 'not-json{');

      await expectLater(
        client.readBattery(),
        throwsA(
          isA<PlatformChannelException>()
              .having((e) => e.code, 'code', 'CORE_E_PLATFORM_DECODE'),
        ),
      );
    });

    test('PlatformException 归一为 typed 错误', () async {
      installHandler(
        (call) async => throw PlatformException(
          code: 'CORE_E_PLATFORM_FAILED',
          message: 'boom',
        ),
      );

      await expectLater(
        client.deviceInfo(),
        throwsA(
          isA<PlatformChannelException>()
              .having((e) => e.code, 'code', 'CORE_E_PLATFORM_FAILED'),
        ),
      );
    });
  });
}
