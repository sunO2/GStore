import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';

/// 假 AssetBundle：直接从内存字符串返回清单。
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.contents);

  final String contents;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(contents)));

  @override
  Future<String> loadString(String key, {bool cache = true}) async => contents;
}

String _manifestJson({
  Object? schema = 1,
  Map<String, dynamic>? assets,
}) =>
    jsonEncode(<String, dynamic>{
      'schema': schema,
      'assets': assets ??
          <String, dynamic>{
            'country.mmdb': <String, dynamic>{
              'url':
                  'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb',
            },
            'geosite.dat': <String, dynamic>{
              'url':
                  'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat',
            },
          },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyGeoManifest.load（真实资产）', () {
    test('加载内置清单：2 个资产、https、github.com、无 sha256', () async {
      final manifest = await ProxyGeoManifest.load();

      expect(manifest.assets.length, 2);
      expect(
        manifest.assets.map((a) => a.file).toList(),
        <String>['country.mmdb', 'geosite.dat'],
      );
      for (final asset in manifest.assets) {
        expect(asset.url.startsWith('https://'), isTrue);
        expect(asset.url.contains('github.com'), isTrue);
        expect(asset.url.contains('sha256'), isFalse);
      }
    });

    test('可注入 fake AssetBundle', () async {
      final manifest = await ProxyGeoManifest.load(bundle: _FakeBundle(_manifestJson()));
      expect(manifest.assets.length, 2);
    });
  });

  group('ProxyGeoManifest.parse（校验）', () {
    test('合法清单解析成功', () {
      final manifest = ProxyGeoManifest.parse(_manifestJson());
      expect(manifest.assets.length, 2);
      expect(manifest.assets.first.file, 'country.mmdb');
    });

    test('schema 不匹配抛异常', () {
      expect(
        () => ProxyGeoManifest.parse(_manifestJson(schema: 2)),
        throwsA(isA<ProxyGeoManifestException>()),
      );
    });

    test('缺少必需资产抛异常', () {
      expect(
        () => ProxyGeoManifest.parse(_manifestJson(assets: <String, dynamic>{
          'country.mmdb': <String, dynamic>{
            'url': 'https://github.com/x/country.mmdb',
          },
        })),
        throwsA(isA<ProxyGeoManifestException>()),
      );
    });

    test('非 https URL 抛异常', () {
      expect(
        () => ProxyGeoManifest.parse(_manifestJson(assets: <String, dynamic>{
          'country.mmdb': <String, dynamic>{
            'url': 'http://github.com/x/country.mmdb',
          },
          'geosite.dat': <String, dynamic>{
            'url': 'https://github.com/x/geosite.dat',
          },
        })),
        throwsA(isA<ProxyGeoManifestException>()),
      );
    });

    test('非 github.com URL 抛异常', () {
      expect(
        () => ProxyGeoManifest.parse(_manifestJson(assets: <String, dynamic>{
          'country.mmdb': <String, dynamic>{
            'url': 'https://example.com/country.mmdb',
          },
          'geosite.dat': <String, dynamic>{
            'url': 'https://github.com/x/geosite.dat',
          },
        })),
        throwsA(isA<ProxyGeoManifestException>()),
      );
    });

    test('非法 JSON 抛异常', () {
      expect(
        () => ProxyGeoManifest.parse('not json'),
        throwsA(isA<ProxyGeoManifestException>()),
      );
    });
  });
}
