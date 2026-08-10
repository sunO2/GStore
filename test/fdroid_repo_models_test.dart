import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

void main() {
  group('FdroidSource', () {
    test('默认值与 toJson/fromJson 往返', () {
      final source = FdroidSource(
        id: 's1',
        name: '测试源',
        repoUrl: 'https://example.com/repo',
        priority: 3,
        mirrors: ['https://m1.example.com'],
      );
      expect(source.enabled, true);

      final json = source.toJson();
      expect(json['id'], 's1');
      expect(json['name'], '测试源');
      expect(json['repoUrl'], 'https://example.com/repo');
      expect(json['priority'], 3);
      expect(json['mirrors'], ['https://m1.example.com']);

      final restored = FdroidSource.fromJson(json);
      expect(restored.id, 's1');
      expect(restored.name, '测试源');
      expect(restored.priority, 3);
      expect(restored.mirrors, ['https://m1.example.com']);
    });

    test('fromJson 缺省字段使用默认值', () {
      final restored = FdroidSource.fromJson({
        'id': 's1',
        'name': '源',
        'repoUrl': 'https://a/repo',
      });
      expect(restored.enabled, true);
      expect(restored.priority, 0);
      expect(restored.mirrors, isEmpty);
    });

    test('官方源包含镜像', () {
      final official = FdroidSource.official;
      expect(official.id, 'official');
      expect(official.repoUrl, 'https://f-droid.org/repo');
      expect(official.mirrors, isNotEmpty);
    });

    test('清华镜像源优先级更高', () {
      final mirror = FdroidSource.tunaMirror;
      expect(mirror.id, 'tuna_mirror');
      expect(mirror.priority, lessThan(FdroidSource.official.priority));
    });

    test('toString 不含敏感字段', () {
      final source = FdroidSource(id: 's', name: 'n', repoUrl: 'https://a');
      expect(source.toString(), contains('s'));
      expect(source.toString(), contains('n'));
    });
  });

  group('FdroidApp.fromIndexV2', () {
    test('完整字段解析', () {
      final app = FdroidApp.fromIndexV2('com.example.app', {
        'name': '示例应用',
        'summary': '摘要',
        'description': '描述',
        'icon': 'icon.png',
        'license': 'GPL-3.0',
        'authorName': '作者',
        'sourceCode': 'https://github.com/a/b',
        'categories': ['工具', '开发'],
        'added': '2026-01-01T00:00:00Z',
      });
      expect(app.packageName, 'com.example.app');
      expect(app.name, '示例应用');
      expect(app.summary, '摘要');
      expect(app.description, '描述');
      expect(app.icon, 'icon.png');
      expect(app.license, 'GPL-3.0');
      expect(app.authorName, '作者');
      expect(app.sourceCode, 'https://github.com/a/b');
      expect(app.categories, ['工具', '开发']);
      expect(app.added, isNotNull);
      expect(app.metadata, isNotNull);
    });

    test('缺失字段的默认值', () {
      final app = FdroidApp.fromIndexV2('com.a', {});
      expect(app.name, 'com.a');
      expect(app.summary, '');
      expect(app.icon, 'com.a.png');
      expect(app.license, isNull);
      expect(app.categories, isNull);
      expect(app.added, isNull);
    });

    test('license 为列表时取首项', () {
      final app = FdroidApp.fromIndexV2('com.a', {'license': ['GPL-3.0', 'MIT']});
      expect(app.license, 'GPL-3.0');
    });

    test('toJson 往返', () {
      final app = FdroidApp.fromIndexV2('com.a', {
        'name': 'A',
        'summary': 'S',
        'categories': ['工具'],
        'added': '2026-01-01T00:00:00Z',
      });
      final json = app.toJson();
      expect(json['packageName'], 'com.a');
      expect(json['name'], 'A');
      expect(json['categories'], ['工具']);
      expect(json['added'], '2026-01-01T00:00:00.000Z');
    });
  });

  group('FdroidPackage', () {
    test('fromIndexV2 解析', () {
      final pkg = FdroidPackage.fromIndexV2('com.a', 'com.a_1.0.apk', {
        'versionName': '1.0',
        'versionCode': 10,
        'size': 2048,
        'hash': 'abc123',
        'hashType': 'sha256',
        'signer': 'sig',
        'nativecode': 'arm64-v8a',
      });
      expect(pkg.packageName, 'com.a');
      expect(pkg.apkName, 'com.a_1.0.apk');
      expect(pkg.versionName, '1.0');
      expect(pkg.versionCode, 10);
      expect(pkg.size, 2048);
      expect(pkg.hash, 'abc123');
      expect(pkg.hashType, 'sha256');
      expect(pkg.signer, 'sig');
      expect(pkg.nativecode, 'arm64-v8a');
    });

    test('downloadUrl 前缀斜杠', () {
      final pkg = FdroidPackage.fromIndexV2('com.a', 'com.a.apk', {});
      expect(pkg.downloadUrl, '/com.a.apk');
    });

    test('toDownloadInfo 映射字段', () {
      final pkg = FdroidPackage.fromIndexV2('com.a', 'com.a.apk', {
        'versionName': '2.0',
        'size': 1024,
        'nativecode': 'x86_64',
      });
      final info = pkg.toDownloadInfo('https://example.com/');
      expect(info.url, 'https://example.com/com.a.apk');
      expect(info.name, 'com.a.apk');
      expect(info.size, 1024);
      expect(info.version, '2.0');
      expect(info.platform, 'x86_64');
    });

    test('toMap 往返字段', () {
      final pkg = FdroidPackage.fromIndexV2('com.a', 'com.a.apk', {
        'versionName': '1.0',
        'versionCode': 1,
        'size': 1,
      });
      final map = pkg.toMap();
      expect(map['packageName'], 'com.a');
      expect(map['apkName'], 'com.a.apk');
      expect(map['versionName'], '1.0');
      expect(map['versionCode'], 1);
    });
  });

  group('FdroidVersionInfo', () {
    test('无可用版本时 hasUpdate 为 false', () {
      final info = FdroidVersionInfo(indexVersion: 10, repoUrl: 'https://a');
      expect(info.hasUpdate, false);
      expect(info.getNextVersion(), isNull);
    });

    test('当前版本已最新', () {
      final info = FdroidVersionInfo(
        indexVersion: 3,
        repoUrl: 'https://a',
        availableVersions: [1, 2, 3],
      );
      expect(info.hasUpdate, false);
    });

    test('有更新时返回下一个版本号', () {
      final info = FdroidVersionInfo(
        indexVersion: 3,
        repoUrl: 'https://a',
        availableVersions: [1, 2, 3, 4, 5],
      );
      expect(info.hasUpdate, true);
      expect(info.getNextVersion(), 4);
    });

    test('toJson / fromJson 往返', () {
      final info = FdroidVersionInfo(
        indexVersion: 3,
        repoUrl: 'https://a',
        lastCheckTime: DateTime(2026, 1, 1),
        availableVersions: [1, 2, 3, 4],
        lastModified: 'Wed, 01 Jan 2026',
        entityTag: '"abc"',
      );
      final json = info.toJson();
      expect(json['indexVersion'], 3);
      expect(json['repoUrl'], 'https://a');
      expect(json['availableVersions'], [1, 2, 3, 4]);
      expect(json['lastModified'], 'Wed, 01 Jan 2026');

      final restored = FdroidVersionInfo.fromJson(json);
      expect(restored.indexVersion, 3);
      expect(restored.repoUrl, 'https://a');
      expect(restored.availableVersions, [1, 2, 3, 4]);
      expect(restored.lastCheckTime, DateTime(2026, 1, 1));
      expect(restored.lastModified, 'Wed, 01 Jan 2026');
      expect(restored.entityTag, '"abc"');
    });
  });
}
