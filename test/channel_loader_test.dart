import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';

/// `ChannelPackage.decode` 解析契约（与车道无关）。
///
/// 旧的 Dart `JsChannel` 装载器测试已随纯 Rust 清理删除：`ChannelLoader` 现在
/// 只把 zip 渠道包交给 Rust `ScriptApi`（`ScriptChannelService`），不再构建/注册
/// Dart 渠道。Rust 车道的装载/导入由 `channel_flag_gating_test`、
/// `js_channel_import_rust_lane_test`、`script_channel_production_test`、
/// `rust_script_lane_ui_test` 覆盖。
/// 合法脚本 A：实现 getAllApps/searchApps/getAppInfo，应用名含 'A'
const String _scriptA = '''
const CHANNEL_META = { name: 'A 渠道', description: 'A 描述' };

const apps = [
  { appId: 'com.a.one', name: 'App A One', icon: 'icon://a1', des: 'A 第一个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    case 'searchApps':
      return { ok: true, data: apps };
    case 'getAppInfo':
      return { ok: true, data: apps[0] };
    default:
      return null;
  }
}
''';

/// 详情页脚本（detail.js 内容）
const String _detailScript = '''
async function main(method, params) {
  switch (method) {
    case 'getAppDetail':
      return { ok: true, data: { appId: 'com.a.one', name: 'App A One' } };
    case 'versionOptions':
      return { ok: true, data: { envs: ['prod'] } };
    default:
      return null;
  }
}
''';

/// 渠道包 meta.json 内容
const String _metaJson =
    '{"name": "zip 渠道", "description": "zip 描述", "icon": "icon://zip"}';

/// 构造内存 zip 渠道包字节（archive ZipEncoder）
Uint8List buildZip({
  String? entry,
  String? detail,
  String? meta,
  List<String> extraFiles = const [],
}) {
  final archive = Archive();
  if (entry != null) archive.addFile(ArchiveFile.string('entry.js', entry));
  if (detail != null) archive.addFile(ArchiveFile.string('detail.js', detail));
  if (meta != null) archive.addFile(ArchiveFile.string('meta.json', meta));
  for (final name in extraFiles) {
    archive.addFile(ArchiveFile.string(name, 'content'));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 损坏/非 zip 字节
Uint8List corruptZip() => Uint8List.fromList(List<int>.filled(64, 7));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelPackage.decode', () {
    test('① 合法 zip（entry.js 必须）→ 解析出 entryScript', () {
      final pkg = ChannelPackage.decode(buildZip(entry: _scriptA));
      expect(pkg, isNotNull);
      expect(pkg!.entryScript, contains('getAllApps'));
      expect(pkg.detailScript, isNull);
      expect(pkg.meta, isNull);
    });

    test('② 含 detail.js/meta.json → 全部解析正确', () {
      final pkg = ChannelPackage.decode(
          buildZip(entry: _scriptA, detail: _detailScript, meta: _metaJson));
      expect(pkg, isNotNull);
      expect(pkg!.entryScript, contains('getAllApps'));
      expect(pkg.detailScript, contains('getAppDetail'));
      expect(pkg.meta,
          {'name': 'zip 渠道', 'description': 'zip 描述', 'icon': 'icon://zip'});
    });

    test('③ 缺 entry.js → null（包无效）', () {
      expect(ChannelPackage.decode(buildZip(detail: _detailScript)), isNull);
      expect(ChannelPackage.decode(buildZip(meta: _metaJson)), isNull);
    });

    test('④ 非 zip/损坏字节 → null', () {
      expect(ChannelPackage.decode(corruptZip()), isNull);
      expect(ChannelPackage.decode(Uint8List(0)), isNull);
    });

    test('⑤ 路径穿越防护：含 ../ 或嵌套目录条目 → 整包拒绝 null', () {
      expect(
          ChannelPackage.decode(
              buildZip(entry: _scriptA, extraFiles: ['../evil.js'])),
          isNull);
      expect(
          ChannelPackage.decode(
              buildZip(entry: _scriptA, extraFiles: ['sub/entry.js'])),
          isNull);
      expect(
          ChannelPackage.decode(
              buildZip(entry: _scriptA, extraFiles: ['a\\b.js'])),
          isNull);
    });

    test('⑥ meta.json 非 JSON 对象/损坏 → 忽略 meta，包仍有效', () {
      final pkg =
          ChannelPackage.decode(buildZip(entry: _scriptA, meta: 'not-json{'));
      expect(pkg, isNotNull);
      expect(pkg!.meta, isNull);
      expect(pkg.entryScript, isNotEmpty);
    });
  });
}
