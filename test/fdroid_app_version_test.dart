import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

/// 版本级元数据解析测试。
///
/// 索引 v2 的 `versions` 是 map(key=versionCode)，但不同仓库实现存在差异，
/// 所以解析是**宽松**的——这些用例就是"可接受形态"的活文档。
void main() {
  group('FdroidAppVersion.parseAll', () {
    test('v2 map 形态：按 versionCode 解析并按新→旧排序', () {
      const json = '''
      {
        "100": {
          "file": {"name": "app_100.apk", "size": 1048576, "sha256": "aa11"},
          "manifest": {
            "versionCode": 100, "versionName": "1.0.0",
            "usesSdk": {"minSdkVersion": 21, "targetSdkVersion": 34},
            "nativecode": ["arm64-v8a", "armeabi-v7a"]
          }
        },
        "200": {
          "file": {"name": "app_200.apk", "size": 2097152, "sha256": "bb22"},
          "manifest": {
            "versionCode": 200, "versionName": "2.0.0",
            "usesSdk": {"minSdkVersion": 23},
            "nativecode": ["arm64-v8a"]
          },
          "antiFeatures": {"Tracking": {"en-US": "tracks you"}},
          "releaseChannels": ["beta"]
        }
      }''';

      final versions = FdroidAppVersion.parseAll(json);

      expect(versions, hasLength(2));
      // 新→旧
      expect(versions.first.versionCode, 200);
      expect(versions.first.versionName, '2.0.0');
      expect(versions.first.apkName, 'app_200.apk');
      expect(versions.first.size, 2097152);
      expect(versions.first.sha256, 'bb22');
      expect(versions.first.minSdk, 23);
      expect(versions.first.nativecode, ['arm64-v8a']);
      expect(versions.first.antiFeatures, ['Tracking']);
      expect(versions.first.releaseChannels, ['beta']);

      expect(versions.last.versionCode, 100);
      expect(versions.last.targetSdk, 34);
      expect(versions.last.nativecode, ['arm64-v8a', 'armeabi-v7a']);
    });

    test('数组形态同样可解析', () {
      const json = '[{"versionCode":7,"versionName":"0.7","file":{"name":"a.apk","size":10}}]';
      final versions = FdroidAppVersion.parseAll(json);
      expect(versions, hasLength(1));
      expect(versions.single.versionCode, 7);
      expect(versions.single.apkName, 'a.apk');
    });

    test('whatsNew 为 LocalizedText 时优先取中文', () {
      const json = '{"1":{"versionCode":1,"versionName":"1","whatsNew":{"en-US":"Fixed bugs","zh-CN":"修复问题"}}}';
      final versions = FdroidAppVersion.parseAll(json);
      expect(versions.single.whatsNew, '修复问题');
    });

    test('字段缺失不抛异常，用默认值兜底', () {
      const json = '{"9":{}}';
      final versions = FdroidAppVersion.parseAll(json);
      // key 作为 versionCode 兜底
      expect(versions.single.versionCode, 9);
      expect(versions.single.apkName, '');
      expect(versions.single.size, 0);
      expect(versions.single.nativecode, isEmpty);
    });

    test('versionCode 无法确定（0）的条目被丢弃', () {
      const json = '{"abc":{"manifest":{"versionName":"x"}}}';
      expect(FdroidAppVersion.parseAll(json), isEmpty);
    });

    test('非法 JSON / 空值返回空列表而不是抛错', () {
      expect(FdroidAppVersion.parseAll('not json'), isEmpty);
      expect(FdroidAppVersion.parseAll(''), isEmpty);
      expect(FdroidAppVersion.parseAll(null), isEmpty);
    });
  });

  group('FdroidAppMeta.parse', () {
    test('抗特性取 key，截图/特色图按语言取值，名称摘要本地化', () {
      const json = '''
      {
        "antiFeatures": {"Tracking": {"en-US": "tracks"}, "Ads": {"en-US": "ads"}},
        "screenshots": {"zh-CN": ["screenshots/zh/1.png", "screenshots/zh/2.png"]},
        "featureGraphic": {"zh-CN": "graphics/feature-zh.png", "en-US": "graphics/feature-en.png"},
        "name": {"zh-CN": "示例应用", "en-US": "Sample"},
        "summary": {"zh-CN": "一个示例", "en-US": "A sample"}
      }''';
      final meta = FdroidAppMeta.parse(json);
      expect(meta.antiFeatures, containsAll(['Tracking', 'Ads']));
      expect(meta.screenshots, ['screenshots/zh/1.png', 'screenshots/zh/2.png']);
      expect(meta.featureGraphic, 'graphics/feature-zh.png');
      expect(meta.localizedName, '示例应用');
      expect(meta.localizedSummary, '一个示例');
    });

    test('缺失/非法 metadata 降级为空而不是抛错', () {
      expect(FdroidAppMeta.parse(null).antiFeatures, isEmpty);
      expect(FdroidAppMeta.parse('').screenshots, isEmpty);
      expect(FdroidAppMeta.parse('not json').featureGraphic, '');
      expect(FdroidAppMeta.parse('[1,2]').localizedName, '');
    });

    test('截图是数组形态也能解析', () {
      final meta = FdroidAppMeta.parse('{"screenshots":["a.png","b.png"]}');
      expect(meta.screenshots, ['a.png', 'b.png']);
    });
  });

  group('SDK 兼容性', () {
    const v = FdroidAppVersion(
      versionCode: 1,
      versionName: '1',
      minSdk: 26,
      nativecode: ['arm64-v8a'],
    );

    test('设备 API level 满足 minSdk → 可装', () {
      expect(v.supportsSdk(33), isTrue);
      expect(v.supportsSdk(26), isTrue);
    });

    test('设备 API level 低于 minSdk → 不可装', () {
      expect(v.supportsSdk(25), isFalse);
    });

    test('minSdk 未知或设备未知时不误判', () {
      const unknown = FdroidAppVersion(versionCode: 1, versionName: '1');
      expect(unknown.supportsSdk(19), isTrue);
      expect(v.supportsSdk(null), isTrue);
    });

    test('isCompatible 要求 ABI 与 SDK 同时满足', () {
      expect(v.isCompatible(deviceAbi: 'arm64-v8a', deviceSdk: 34), isTrue);
      expect(v.isCompatible(deviceAbi: 'x86_64', deviceSdk: 34), isFalse);
      expect(v.isCompatible(deviceAbi: 'arm64-v8a', deviceSdk: 21), isFalse);
    });
  });

  group('FdroidAppVersion.supportsAbi', () {
    const armOnly = FdroidAppVersion(
      versionCode: 1,
      versionName: '1',
      nativecode: ['arm64-v8a'],
    );
    const pure = FdroidAppVersion(versionCode: 1, versionName: '1');

    test('无原生代码 → 任何 ABI 都可装', () {
      expect(pure.supportsAbi('x86_64'), isTrue);
      expect(pure.supportsAbi(null), isTrue);
    });

    test('含当前 ABI → 可装；不含 → 不可装', () {
      expect(armOnly.supportsAbi('arm64-v8a'), isTrue);
      expect(armOnly.supportsAbi('x86_64'), isFalse);
    });

    test('设备 ABI 未知时不误判为不可装', () {
      expect(armOnly.supportsAbi(null), isTrue);
    });
  });

  test('真机形态：icon/featureGraphic 是 LocalizedFile 对象（Bitwarden 源）', () {
    final meta = FdroidAppMeta.parse(
        '{"featureGraphic":{"en-US":{"name":"/com.x8bit.bitwarden/en-US/featureGraphic_x=.png","sha256":"3f1d","size":55973}},'
        '"icon":{"en-US":{"name":"/com.x8bit.bitwarden/en-US/icon_x=.png","sha256":"a07b","size":13229}},'
        '"name":{"en-US":"Bitwarden"},"license":"GPL-3.0"}');
    // 路径必须取到 name，而不是空、也不能是 sha256/size
    expect(meta.featureGraphic, '/com.x8bit.bitwarden/en-US/featureGraphic_x=.png');
    expect(meta.localizedName, 'Bitwarden');
  });

  test('真机形态：versions 以 APK sha256 为键，版本号在 manifest 里（Bitwarden 源）', () {
    final vs = FdroidAppVersion.parseAll(
        '{"a6ca58fe9ea0":{"added":1787541127000,'
        '"file":{"name":"/bitwarden_v2026.8.0-bwpm.apk","sha256":"a6ca58fe9ea0","size":87780023},'
        '"manifest":{"nativecode":["arm64-v8a","x86_64"],"versionName":"2026.8.0","versionCode":21819,'
        '"usesSdk":{"minSdkVersion":29,"targetSdkVersion":37}}}}');
    expect(vs, hasLength(1));
    expect(vs.first.versionCode, 21819);
    expect(vs.first.versionName, '2026.8.0');
    expect(vs.first.apkName, '/bitwarden_v2026.8.0-bwpm.apk');
    expect(vs.first.minSdk, 29);
    expect(vs.first.nativecode, contains('arm64-v8a'));
  });
}
