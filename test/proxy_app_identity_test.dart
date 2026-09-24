// ProxyAppIdentityResolver 单元测试：惰性加载、映射、幂等、优雅降级。
//
// 全部密闭式：注入假 loader / iconSaver，不触碰原生 MethodChannel。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/proxy/proxy_app_identity.dart';
import 'package:installed_apps/app_info.dart';

void main() {
  AppInfo app(String packageName, String name, {Uint8List? icon}) => AppInfo(
        name: name,
        icon: icon,
        packageName: packageName,
        versionName: '1.0.0',
        versionCode: 1,
        builtWith: BuiltWith.native_or_others,
        installedTimestamp: 0,
      );

  test('ensureLoaded 映射包名为 (label, iconPath) 且幂等', () async {
    var loadCalls = 0;
    final resolver = ProxyAppIdentityResolver(
      isAndroid: true,
      loader: () async {
        loadCalls++;
        return <AppInfo>[
          app(
            'com.example.app',
            'Example App',
            icon: Uint8List.fromList(<int>[1, 2, 3]),
          ),
          app('org.blank', ''),
        ];
      },
      iconSaver: (packageName, bytes) async => '/tmp/$packageName.png',
    );

    expect(resolver.isLoaded, isFalse);
    await resolver.ensureLoaded();
    await resolver.ensureLoaded();
    expect(loadCalls, 1, reason: '只加载一次');
    expect(resolver.isLoaded, isTrue);

    final example = resolver.lookup('com.example.app');
    expect(example?.label, 'Example App');
    expect(example?.iconPath, '/tmp/com.example.app.png');

    // 插件缺名 → 回落包名。
    expect(resolver.lookup('org.blank')?.label, 'org.blank');
    // 未安装 / 未知包名 → null。
    expect(resolver.lookup('com.unknown'), isNull);
  });

  test('图标保存失败降级：label 保留、iconPath 为 null', () async {
    final resolver = ProxyAppIdentityResolver(
      isAndroid: true,
      loader: () async => <AppInfo>[app('com.example.app', 'Example App')],
      iconSaver: (packageName, bytes) async => null,
    );
    await resolver.ensureLoaded();
    expect(resolver.lookup('com.example.app')?.label, 'Example App');
    expect(resolver.lookup('com.example.app')?.iconPath, isNull);
  });

  test('loader 抛错永不外抛：降级为空缓存', () async {
    final resolver = ProxyAppIdentityResolver(
      isAndroid: true,
      loader: () async => throw StateError('plugin 不可用'),
      iconSaver: (packageName, bytes) async => null,
    );
    await expectLater(resolver.ensureLoaded(), completes);
    expect(resolver.isLoaded, isTrue);
    expect(resolver.lookup('com.example.app'), isNull);
  });

  test('非 Android：不调用 loader，lookup 为 null', () async {
    var loadCalls = 0;
    final resolver = ProxyAppIdentityResolver(
      isAndroid: false,
      loader: () async {
        loadCalls++;
        return const <AppInfo>[];
      },
      iconSaver: (packageName, bytes) async => null,
    );
    await resolver.ensureLoaded();
    expect(loadCalls, 0);
    expect(resolver.isLoaded, isTrue);
    expect(resolver.lookup('com.example.app'), isNull);
  });
}
