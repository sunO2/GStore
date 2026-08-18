import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';

/// 渠道包 zip 结构测试（Wave 5）：验证 scripts/channels/ 下的 pingan.zip / vivo.zip
/// 符合渠道包规范——根目录 entry.js（必须）+ detail.js（可选）+ meta.json（可选），
/// 且经 ChannelPackage.decode 可正确解析出 entry/detail 脚本与 meta。
///
/// 注意：zip/脚本不入库（scripts/ 已被 .gitignore 忽略），本测试读取本地文件
/// （flutter test 以项目根为 cwd）；文件缺失时测试失败（与脚本渠道测试同约定）。
void main() {
  group('渠道包 zip 结构', () {
    test('pingan.zip：根目录 entry.js/detail.js/meta.json + decode 正确', () {
      final bytes = File('scripts/channels/pingan.zip').readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 结构：仅根目录直接文件，无子目录/路径穿越
      final names = archive.files
          .where((f) => f.isFile)
          .map((f) => f.name)
          .toList()
        ..sort();
      expect(names, ['detail.js', 'entry.js', 'meta.json']);

      final pkg = ChannelPackage.decode(bytes);
      expect(pkg, isNotNull);
      expect(pkg!.entryScript, isNotEmpty);
      expect(pkg.entryScript, contains('CHANNEL_META'));
      expect(pkg.detailScript, isNotEmpty);
      expect(pkg.detailScript, contains('getDetailMenu'));
      expect(pkg.meta, isNotNull);
      expect(pkg.meta!['name'], '平安测试商店');
      expect(pkg.meta!['description'], contains('Iris Store'));

      // 分发器方法清单：entry 仅发现页/更新路径；detail 仅详情页
      expect(pkg.entryScript, contains("case 'getAllApps'"));
      expect(pkg.entryScript, contains("case 'searchApps'"));
      expect(pkg.entryScript, contains("case 'getAppInfo'"));
      expect(pkg.entryScript, contains("case 'getAppDetail'"));
      expect(pkg.entryScript, contains("case 'checkAppUpdate'"));
      expect(pkg.entryScript, contains("case 'checkUpdate'"));
      expect(pkg.entryScript, contains("case 'doUpdate'"));
      expect(pkg.entryScript, isNot(contains("case 'versionOptions'")));
      expect(pkg.entryScript, isNot(contains("case 'detailMenu'")));

      expect(pkg.detailScript, contains("case 'getAppDetail'"));
      expect(pkg.detailScript, contains("case 'versionOptions'"));
      expect(pkg.detailScript, contains("case 'switchVersion'"));
      expect(pkg.detailScript, contains("case 'buildHistory'"));
      expect(pkg.detailScript, contains("case 'detailMenu'"));
      expect(pkg.detailScript, contains("case 'jsswitchVersion'"));
      expect(pkg.detailScript, contains("case 'jsBuildHistory'"));
      expect(pkg.detailScript, isNot(contains("case 'getAllApps'")));
      expect(pkg.detailScript, isNot(contains("case 'checkUpdate'")));
    });

    test('vivo.zip：根目录 entry.js/detail.js/meta.json + decode 正确', () {
      final bytes = File('scripts/channels/vivo.zip').readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final names = archive.files
          .where((f) => f.isFile)
          .map((f) => f.name)
          .toList()
        ..sort();
      expect(names, ['detail.js', 'entry.js', 'meta.json']);

      final pkg = ChannelPackage.decode(bytes);
      expect(pkg, isNotNull);
      expect(pkg!.entryScript, isNotEmpty);
      expect(pkg.entryScript, contains('CHANNEL_META'));
      expect(pkg.detailScript, isNotEmpty);
      expect(pkg.detailScript, contains('getDetailMenu'));
      expect(pkg.meta, isNotNull);
      expect(pkg.meta!['name'], 'vivo 应用市场');
      expect(pkg.meta!['description'], contains('vivo'));

      // 分发器方法清单：entry 仅发现页/更新路径；detail 仅详情页
      expect(pkg.entryScript, contains("case 'getAllApps'"));
      expect(pkg.entryScript, contains("case 'searchApps'"));
      expect(pkg.entryScript, contains("case 'getAppInfo'"));
      expect(pkg.entryScript, contains("case 'getAppDetail'"));
      expect(pkg.entryScript, contains("case 'checkAppUpdate'"));
      expect(pkg.entryScript, contains("case 'checkUpdate'"));
      expect(pkg.entryScript, contains("case 'doUpdate'"));
      expect(pkg.entryScript, isNot(contains("case 'detailMenu'")));

      expect(pkg.detailScript, contains("case 'getAppDetail'"));
      expect(pkg.detailScript, contains("case 'checkAppUpdate'"));
      expect(pkg.detailScript, contains("case 'detailMenu'"));
      expect(pkg.detailScript, isNot(contains("case 'getAllApps'")));
      expect(pkg.detailScript, isNot(contains("case 'searchApps'")));
    });

    test('路径穿越防护：子目录条目 → 整包拒绝（decode 返回 null）', () {
      // 构造含 sub/entry.js 的恶意包：应被 ChannelPackage.decode 拒绝
      final archive = Archive()
        ..addFile(ArchiveFile('sub/entry.js', 4, Uint8List.fromList('var x'.codeUnits)));
      final encoded = ZipEncoder().encode(archive);
      expect(encoded, isNotNull);
      expect(ChannelPackage.decode(Uint8List.fromList(encoded!)), isNull);
    });
  });
}
