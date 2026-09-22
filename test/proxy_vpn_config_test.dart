// F2 回归测试：内置 VPN 的 VpnService 配置必须只含合法 CIDR。
//
// 缺陷背景：`ProxyVpnService.kt` 的默认地址曾为非法 IPv6 字面量
// `fd00:1:fd00:1:fd00:1:fd00:1:fd00:1`（10 个 hextet，超过 8），而 Dart 侧
// `toVpnConfigJson()` 从不发送 `addresses`，于是 Kotlin 总是回退到该非法默认值，
// `Builder.addAddress(..., 128)` 抛 IllegalArgumentException → `start_failed`
// → 内核收到 `PROXY_TUN_FD_INVALID` → VPN 永不连通。
//
// 本测试锁定：`toVpnConfigJson()` 必须显式携带合法 `addresses` / `routes`，
// 用 `InternetAddress.tryParse` + 前缀长度校验逐条验证。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

/// F2 缺陷中的非法字面量（10 个 hextet）。
const String _invalidIpv6Literal = 'fd00:1:fd00:1:fd00:1:fd00:1:fd00:1';

/// 断言 CIDR 由合法 IP 字面量 + 合法前缀长度组成（IPv4 0..32 / IPv6 0..128）。
void _expectValidCidr(String cidr) {
  final slash = cidr.indexOf('/');
  expect(slash, greaterThan(0), reason: '缺少前缀长度: $cidr');
  final ip = InternetAddress.tryParse(cidr.substring(0, slash));
  expect(ip, isNotNull, reason: '非法 IP 字面量: $cidr');
  final prefix = int.tryParse(cidr.substring(slash + 1));
  expect(prefix, isNotNull, reason: '非法前缀长度: $cidr');
  final maxBits = ip!.type == InternetAddressType.IPv6 ? 128 : 32;
  expect(prefix, inInclusiveRange(0, maxBits), reason: '前缀越界: $cidr');
}

/// 断言生成的 VpnService 配置 JSON 含非空且逐条合法的 addresses / routes。
///
/// 同时断言隧道内 DNS：`dns == kProxyVpnDnsServers`（非空、逐条合法 IP），
/// 使系统明文 UDP:53 确定性进入 Rust 模块的 fake-IP 劫持。
Map<String, dynamic> _expectValidVpnConfig(String json) {
  final payload = jsonDecode(json) as Map<String, dynamic>;
  final addresses = (payload['addresses'] as List).cast<String>();
  final routes = (payload['routes'] as List).cast<String>();
  expect(addresses, isNotEmpty, reason: 'addresses 不得为空');
  expect(routes, isNotEmpty, reason: 'routes 不得为空');
  for (final cidr in addresses) {
    _expectValidCidr(cidr);
  }
  for (final cidr in routes) {
    _expectValidCidr(cidr);
  }
  final dns = (payload['dns'] as List).cast<String>();
  expect(dns, isNotEmpty, reason: 'dns 不得为空');
  expect(jsonDecode(json)['dns'], kProxyVpnDnsServers);
  for (final entry in dns) {
    expect(InternetAddress.tryParse(entry), isNotNull, reason: '非法 DNS: $entry');
  }
  return payload;
}

class _ThrowingStore implements ProxySettingsStore {
  @override
  Future<ProxySettingsConfig> read() async => throw StateError('store boom');

  @override
  Future<void> write(ProxySettingsConfig config) async {}
}

void main() {
  group('toVpnConfigJson 只产生合法 CIDR', () {
    test('空配置（默认）携带合法 addresses/routes', () {
      final payload = _expectValidVpnConfig(
        const ProxySettingsConfig().toVpnConfigJson(),
      );
      expect(payload['addresses'], kProxyVpnAddresses);
      expect(payload['routes'], kProxyVpnRoutes);
      expect(payload['mode'], ProxySplitTunnelMode.full.wire);
      expect(jsonDecode(const ProxySettingsConfig().toVpnConfigJson())['dns'],
          <String>['10.10.0.1']);
      expect(payload.containsKey('allowedApps'), isFalse);
      expect(payload.containsKey('disallowedApps'), isFalse);
    });

    test('allow 模式（已配置应用）仍携带合法 addresses/routes', () {
      final payload = _expectValidVpnConfig(
        const ProxySettingsConfig(
          splitMode: ProxySplitTunnelMode.allow,
          selectedApps: {'com.banana', 'com.apple'},
        ).toVpnConfigJson(),
      );
      expect(payload['allowedApps'], <String>['com.apple', 'com.banana']);
      expect(jsonDecode(const ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.allow,
        selectedApps: {'com.banana', 'com.apple'},
      ).toVpnConfigJson())['dns'], <String>['10.10.0.1']);
    });

    test('disallow 模式（已配置应用）仍携带合法 addresses/routes', () {
      final payload = _expectValidVpnConfig(
        const ProxySettingsConfig(
          splitMode: ProxySplitTunnelMode.disallow,
          selectedApps: {kGStorePackageName, 'com.apple'},
        ).toVpnConfigJson(),
      );
      expect(payload['disallowedApps'], <String>['com.apple']);
      expect(payload['disallowedApps'], isNot(contains(kGStorePackageName)));
    });

    test('addresses/routes 同时覆盖 IPv4 与 IPv6', () {
      final payload = _expectValidVpnConfig(
        const ProxySettingsConfig().toVpnConfigJson(),
      );
      bool hasFamily(List<String> cidrs, InternetAddressType type) => cidrs.any(
            (c) => InternetAddress.tryParse(c.split('/').first)?.type == type,
          );
      expect(hasFamily((payload['addresses'] as List).cast<String>(),
          InternetAddressType.IPv4), isTrue);
      expect(hasFamily((payload['addresses'] as List).cast<String>(),
          InternetAddressType.IPv6), isTrue);
      expect(hasFamily((payload['routes'] as List).cast<String>(),
          InternetAddressType.IPv4), isTrue);
      expect(hasFamily((payload['routes'] as List).cast<String>(),
          InternetAddressType.IPv6), isTrue);
    });

    test('回归：F2 非法 IPv6 字面量被解析器拒绝，修复后默认合法', () {
      expect(InternetAddress.tryParse(_invalidIpv6Literal), isNull);
      expect(InternetAddress.tryParse('fd00::1'), isNotNull);
      expect(kProxyVpnAddresses, contains('fd00::1/128'));
      expect(kProxyVpnAddresses, isNot(contains(_invalidIpv6Literal)));
    });

    test('dns 隧道内地址不落在 fake-IP 池 / 不等于 TUN 自身地址', () {
      expect(kProxyVpnDnsServers, <String>['10.10.0.1']);
      for (final dns in kProxyVpnDnsServers) {
        final ip = InternetAddress.tryParse(dns);
        expect(ip, isNotNull, reason: '非法 DNS: $dns');
        // 不得等于 TUN 自身地址（发往自身地址的包不进 TUN）。
        expect(kProxyVpnAddresses.map((c) => c.split('/').first),
            isNot(contains(dns)));
        // 不得落在 fake-IP 池 198.18.0.0/16。
        final octets = dns.split('.').map(int.parse).toList();
        final inFakeIp =
            octets[0] == 198 && octets[1] == 18;
        expect(inFakeIp, isFalse, reason: 'DNS 不得在 fake-IP 池: $dns');
      }
    });

    test('读配置失败回退 {}（Kotlin 默认已合法，不再触发 F2）', () async {
      final json = await loadProxyVpnConfigJson(store: _ThrowingStore());
      expect(json, '{}');
    });
  });
}
