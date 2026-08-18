import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';

/// 内存版 ChannelAddedAppDao（测试用，模拟渠道数据库）
class _FakeAppDao implements ChannelAddedAppDao {
  final List<ChannelAddedApp> _apps = [];

  @override
  Future<void> insertApp(ChannelAddedApp app) async {
    _apps.removeWhere(
        (a) => a.channelCode == app.channelCode && a.appId == app.appId);
    _apps.add(app);
  }

  @override
  Future<void> insertApps(List<ChannelAddedApp> apps) async {
    for (final app in apps) {
      await insertApp(app);
    }
  }

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).toList();

  @override
  Future<ChannelAddedApp?> getApp(String appId, String channelCode) async {
    for (final a in _apps) {
      if (a.appId == appId && a.channelCode == channelCode) return a;
    }
    return null;
  }

  @override
  Future<void> removeApp(String appId, String channelCode) async {
    _apps.removeWhere((a) => a.appId == appId && a.channelCode == channelCode);
  }

  @override
  Future<int?> getCountByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).length;

  @override
  Future<void> clearChannel(String channelCode) async {
    _apps.removeWhere((a) => a.channelCode == channelCode);
  }

  @override
  Future<List<ChannelAddedApp>> getAllApps() async => List.of(_apps);

  @override
  Future<int?> getTotalCount() async => _apps.length;
}

/// 固定响应 Dio adapter（测试用，模拟网络层）
class _FakeDioAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'echo': options.path}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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

/// 合法脚本 B：与 A 同名渠道下的"更新版"，应用名含 'B'
const String _scriptB = '''
const CHANNEL_META = { name: 'B 渠道' };

const apps = [
  { appId: 'com.b.one', name: 'App B One', icon: 'icon://b1', des: 'B 第一个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    case 'searchApps':
      return { ok: true, data: apps };
    default:
      return null;
  }
}
''';

/// 语法错误脚本：QuickJS 加载即失败
const String _brokenScript = '''
const broken = ;
function main(method, params) {
  return { ok: true, data: [1, 2] };
''';

/// 非法文件名内容（'my-channel.zip' 含连字符，不是合法标识符，应跳过）
const String _validBody = '''
async function main(method, params) { return null; }
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
const String _metaJson = '{"name": "zip 渠道", "description": "zip 描述", "icon": "icon://zip"}';

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

  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() {
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  ChannelManager getManager() => ChannelManager.instance;

  /// 在临时目录写入 zip 渠道包文件，返回目录
  Future<Directory> writeZips(Map<String, Uint8List> files) async {
    final dir = await Directory.systemTemp.createTemp('channel_loader_test');
    for (final entry in files.entries) {
      await File('${dir.path}/${entry.key}').writeAsBytes(entry.value);
    }
    return dir;
  }

  tearDown(() async {
    // 清理本次测试注册的动态渠道（单例隔离）
    for (final channel in getManager().dynamicChannels) {
      if (channel is DynamicChannel &&
          (channel as DynamicChannel).channelKey.startsWith('js_')) {
        getManager().unregisterChannelByKey((channel as DynamicChannel).channelKey);
      }
    }
  });

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
      expect(pkg.meta, {'name': 'zip 渠道', 'description': 'zip 描述', 'icon': 'icon://zip'});
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
      expect(ChannelPackage.decode(buildZip(entry: _scriptA, extraFiles: ['../evil.js'])), isNull);
      expect(ChannelPackage.decode(buildZip(entry: _scriptA, extraFiles: ['sub/entry.js'])), isNull);
      expect(ChannelPackage.decode(buildZip(entry: _scriptA, extraFiles: ['a\\b.js'])), isNull);
    });

    test('⑥ meta.json 非 JSON 对象/损坏 → 忽略 meta，包仍有效', () {
      final pkg = ChannelPackage.decode(
          buildZip(entry: _scriptA, meta: 'not-json{'));
      expect(pkg, isNotNull);
      expect(pkg!.meta, isNull);
      expect(pkg.entryScript, isNotEmpty);
    });
  });

  group('ChannelLoader.loadAndRegister', () {
    test('① 扫描 .zip 目录 → 注册成功且 getChannelByKey 返回（渠道已初始化）', () async {
      final dir = await writeZips({
        'one.zip': buildZip(entry: _scriptA),
        'two.zip': buildZip(entry: _scriptB),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      // key = 'js_' + 文件名（无 .zip 扩展）
      expect(loaded.map((c) => c.channelKey), containsAll(['js_one', 'js_two']));

      final channel = getManager().getChannelByKey('js_one');
      expect(channel, isNotNull);
      expect(channel, isA<JsChannel>());
      // 加载时已校验初始化
      expect(channel!.isInitialized, isTrue);

      // 脚本可正常分发调用（searchApps 走脚本）
      final result = await (channel as JsChannel).searchApps('App');
      expect(result.success, isTrue);
      expect(result.data, hasLength(1));
      expect(result.data!.first.name, 'App A One');

      // 另一个文件同样注册
      expect(getManager().getChannelByKey('js_two'), isNotNull);
    });

    test('② 目录为空 → 不报错，返回空列表', () async {
      final dir = await Directory.systemTemp.createTemp('channel_loader_empty');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(loaded, isEmpty);
      expect(
          getManager()
              .dynamicChannels
              .where((c) =>
                  c is DynamicChannel &&
                  (c as DynamicChannel).channelKey.startsWith('js_')),
          isEmpty);
    });

    test('③ 缺 entry.js 的 zip → 跳过 + 日志，不阻塞其他包', () async {
      final dir = await writeZips({
        'noentry.zip': buildZip(detail: _detailScript),
        'good.zip': buildZip(entry: _scriptA),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      // 无效包未注册
      expect(getManager().getChannelByKey('js_noentry'), isNull);
      // 有效包正常注册
      expect(loaded.map((c) => c.channelKey), ['js_good']);
      expect(getManager().getChannelByKey('js_good'), isNotNull);
    });

    test('④ 损坏 zip → 跳过 + 日志，不阻塞其他包', () async {
      final dir = await writeZips({
        'bad.zip': corruptZip(),
        'good.zip': buildZip(entry: _scriptA),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(getManager().getChannelByKey('js_bad'), isNull);
      expect(loaded.map((c) => c.channelKey), ['js_good']);
    });

    test('⑤ 含 detail.js/meta.json → JsChannel 解析正确（detailScript/meta 断言）', () async {
      final dir = await writeZips({
        'full.zip':
            buildZip(entry: _scriptA, detail: _detailScript, meta: _metaJson),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      await loader.loadAndRegister();

      final channel = getManager().getChannelByKey('js_full') as JsChannel;
      expect(channel.detailScript, contains('getAppDetail'));
      expect(channel.detailScript, contains('versionOptions'));
      expect(channel.meta,
          {'name': 'zip 渠道', 'description': 'zip 描述', 'icon': 'icon://zip'});
    });

    test('⑥ 非法脚本（语法错误）→ 跳过 + 日志，不阻塞其他包', () async {
      final dir = await writeZips({
        'bad.zip': buildZip(entry: _brokenScript),
        'good.zip': buildZip(entry: _scriptA),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      // 坏包未注册
      expect(getManager().getChannelByKey('js_bad'), isNull);
      // 好包正常注册
      expect(loaded.map((c) => c.channelKey), ['js_good']);
      expect(getManager().getChannelByKey('js_good'), isNotNull);
    });

    test('⑦ 路径穿越 zip（含 ../ 条目）→ 整包拒绝，不阻塞其他包', () async {
      final dir = await writeZips({
        'evil.zip': buildZip(entry: _scriptA, extraFiles: ['../evil.js']),
        'good.zip': buildZip(entry: _scriptA),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(getManager().getChannelByKey('js_evil'), isNull);
      expect(loaded.map((c) => c.channelKey), ['js_good']);
    });

    test('⑧ 非法文件名（含连字符的 zip）→ 跳过，不阻塞其他包', () async {
      final dir = await writeZips({
        'my-channel.zip': buildZip(entry: _validBody),
        'ok.zip': buildZip(entry: _scriptA),
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(getManager().getChannelByKey('js_my-channel'), isNull);
      expect(loaded.map((c) => c.channelKey), ['js_ok']);
    });

    test('⑨ 幂等：重复调用不重复注册（包内容未变 → 跳过）', () async {
      final dir = await writeZips({'dup.zip': buildZip(entry: _scriptA)});
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final first = await loader.loadAndRegister();
      final second = await loader.loadAndRegister();

      expect(first, hasLength(1));
      // 第二次调用无新增注册
      expect(second, isEmpty);

      final count = getManager()
          .dynamicChannels
          .where((c) =>
              c is DynamicChannel &&
              (c as DynamicChannel).channelKey == 'js_dup')
          .length;
      expect(count, 1);
    });

    test('⑩ 同名 key：包内容变化 → 更新注册（不残留旧渠道）', () async {
      final dir = await writeZips({'dup.zip': buildZip(entry: _scriptA)});
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      await loader.loadAndRegister();

      final before = getManager().getChannelByKey('js_dup') as JsChannel;
      expect((await before.searchApps('App')).data!.first.name, 'App A One');

      // 覆盖包内容（模拟用户更新渠道包）后重新加载
      await File('${dir.path}/dup.zip').writeAsBytes(buildZip(entry: _scriptB));
      final updated = await loader.loadAndRegister();
      expect(updated, hasLength(1));
      expect(updated.first.channelKey, 'js_dup');

      final after = getManager().getChannelByKey('js_dup') as JsChannel;
      expect(after.isInitialized, isTrue);
      expect((await after.searchApps('App')).data!.first.name, 'App B One');

      // 更新后仍只有 1 个同 key 渠道（旧实例已注销）
      final count = getManager()
          .dynamicChannels
          .where((c) =>
              c is DynamicChannel &&
              (c as DynamicChannel).channelKey == 'js_dup')
          .length;
      expect(count, 1);
    });

    test('⑪ 集成冒烟：ChannelLoader 加载 assets/channels/example.js → JsChannel.initialize 成功', () async {
      // 内置模板（assets 声明于 pubspec，flutter test 可经 rootBundle 读取）
      final script = await ChannelLoader.loadAssetScript('assets/channels/example.js');
      expect(script, contains('main'));
      expect(script, contains('host.network'));

      final channel = JsChannel(
        channelKey: 'js_example',
        script: script,
        dio: dio,
        appDao: appDao,
      );

      // 模板脚本可被引擎加载（语法/契约有效）
      await channel.initialize();
      expect(channel.isInitialized, isTrue);

      // main 分发器可调用（searchApps 走 host.network 示例 → fake dio 返回非数组 → 空结果）
      final result = await channel.searchApps('example');
      expect(result.success, isTrue);
      expect(result.data, isEmpty);

      await channel.dispose();
    });
  });

  group('ChannelLoader.importZip', () {
    test('① 写入 .zip 文件 + 注册成功（getChannelByKey 返回、已初始化、脚本可调用）', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_ok');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final channel = await loader.importZip(
        channelKey: 'js_vivo',
        zipBytes: buildZip(entry: _scriptA),
      );

      expect(channel.channelKey, 'js_vivo');
      expect(channel.isInitialized, isTrue);

      // 已注册到 ChannelManager（key 索引）
      final registered = getManager().getChannelByKey('js_vivo');
      expect(registered, same(channel));

      // 脚本可正常分发调用
      final result = await channel.searchApps('App');
      expect(result.success, isTrue);
      expect(result.data!.first.name, 'App A One');

      // 文件已写入渠道目录（key 去 js_ 前缀 + .zip，与 loadAndRegister 扫描互逆）
      expect(File('${dir.path}/vivo.zip').existsSync(), isTrue);
    });

    test('② 含 detail.js/meta.json 的 zip 导入 → JsChannel 携带 detailScript/meta', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_full');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final channel = await loader.importZip(
        channelKey: 'js_full',
        zipBytes:
            buildZip(entry: _scriptA, detail: _detailScript, meta: _metaJson),
      );

      expect(channel.detailScript, contains('getAppDetail'));
      expect(channel.meta,
          {'name': 'zip 渠道', 'description': 'zip 描述', 'icon': 'icon://zip'});
    });

    test('③ 非法 key → 抛 ArgumentError（不写文件、不注册）', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_badkey');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);

      for (final badKey in ['my-channel', '1abc', '', 'a b']) {
        expect(
          () => loader.importZip(
              channelKey: badKey, zipBytes: buildZip(entry: _scriptA)),
          throwsArgumentError,
          reason: '非法 key: $badKey',
        );
      }

      expect(getManager().getChannelByKey('js_my-channel'), isNull);
      expect(dir.listSync(), isEmpty, reason: '非法 key 不应写入任何文件');
    });

    test('④ 无效 zip（缺 entry.js）→ 抛 ArgumentError 且不写文件、不注册', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_noentry');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);

      await expectLater(
        loader.importZip(
            channelKey: 'js_bad', zipBytes: buildZip(detail: _detailScript)),
        throwsArgumentError,
      );

      expect(getManager().getChannelByKey('js_bad'), isNull);
      expect(dir.listSync(), isEmpty,
          reason: '包校验失败不应写入任何文件');
    });

    test('⑤ 损坏 zip → 抛 ArgumentError 且不写文件、不注册', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_corrupt');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);

      await expectLater(
        loader.importZip(channelKey: 'js_bad', zipBytes: corruptZip()),
        throwsArgumentError,
      );

      expect(getManager().getChannelByKey('js_bad'), isNull);
      expect(dir.listSync(), isEmpty, reason: '包校验失败不应写入任何文件');
    });

    test('⑥ 路径穿越 zip → 抛 ArgumentError 且不写文件、不注册', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_evil');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);

      await expectLater(
        loader.importZip(
          channelKey: 'js_bad',
          zipBytes: buildZip(entry: _scriptA, extraFiles: ['../evil.js']),
        ),
        throwsArgumentError,
      );

      expect(getManager().getChannelByKey('js_bad'), isNull);
      expect(dir.listSync(), isEmpty, reason: '路径穿越包不应写入任何文件');
    });

    test('⑦ 同名覆盖：包内容变化 → 注销旧渠道 + 注册新渠道（仅 1 个同 key 实例）', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_overwrite');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final first = await loader.importZip(
          channelKey: 'js_dup', zipBytes: buildZip(entry: _scriptA));
      expect((await first.searchApps('App')).data!.first.name, 'App A One');

      // 同 key 导入不同包 → 覆盖
      final second = await loader.importZip(
          channelKey: 'js_dup', zipBytes: buildZip(entry: _scriptB));
      expect(second.channelKey, 'js_dup');
      expect(second, isNot(same(first)), reason: '覆盖后应为新实例');
      expect((await second.searchApps('App')).data!.first.name, 'App B One');

      // 旧实例已注销，仅 1 个同 key 渠道
      final count = getManager()
          .dynamicChannels
          .where((c) =>
              c is DynamicChannel &&
              (c as DynamicChannel).channelKey == 'js_dup')
          .length;
      expect(count, 1);
      expect(getManager().getChannelByKey('js_dup'), same(second));
    });

    test('⑧ entry.js 语法错误 → 抛错且文件回滚（不残留坏文件、不注册）', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_badscript');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);

      await expectLater(
        loader.importZip(
            channelKey: 'js_bad', zipBytes: buildZip(entry: _brokenScript)),
        throwsA(anything),
      );

      expect(getManager().getChannelByKey('js_bad'), isNull);
      expect(File('${dir.path}/bad.zip').existsSync(), isFalse,
          reason: '校验失败应回滚删除文件');
    });

    test('⑨ 幂等：同 key 同包重复导入 → 返回同一渠道，不重复注册', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_idem');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final first = await loader.importZip(
          channelKey: 'js_idem', zipBytes: buildZip(entry: _scriptA));
      final second = await loader.importZip(
          channelKey: 'js_idem', zipBytes: buildZip(entry: _scriptA));

      expect(second, same(first), reason: '包未变应返回现有渠道');

      final count = getManager()
          .dynamicChannels
          .where((c) =>
              c is DynamicChannel &&
              (c as DynamicChannel).channelKey == 'js_idem')
          .length;
      expect(count, 1);
    });

    test('⑩ 导入后 loadAndRegister 扫描 round-trip：不产生 js_js_ 双前缀重复渠道', () async {
      final dir = await Directory.systemTemp.createTemp('channel_import_roundtrip');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      await loader.importZip(
          channelKey: 'js_vivo', zipBytes: buildZip(entry: _scriptA));

      // 文件名为 vivo.zip（key 去 js_ 前缀）→ 扫描推导回 js_vivo
      expect(File('${dir.path}/vivo.zip').existsSync(), isTrue);

      // 再次扫描：同 key 同包 → 幂等跳过，无新增注册
      final loaded = await loader.loadAndRegister();
      expect(loaded, isEmpty);

      // 不产生 js_js_vivo 双前缀渠道
      expect(getManager().getChannelByKey('js_js_vivo'), isNull);
      expect(getManager().getChannelByKey('js_vivo'), isNotNull);
    });
  });
}
