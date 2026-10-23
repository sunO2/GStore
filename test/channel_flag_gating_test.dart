import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';

/// 可注入的 flags 后端（Rust 侧默认全 false；这里只切 `jsChannel`）。
class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

const String _script = '''
const CHANNEL_META = { name: 'gate 渠道' };
function main(method, params) { return { ok: true, data: [] }; }
''';

Uint8List _zip() {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', _script));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<Directory> _channelDir() async {
  final dir = await Directory.systemTemp.createTemp('gstore_flag_gating');
  await File('${dir.path}/gate.zip').writeAsBytes(_zip());
  return dir;
}

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  // 断言仅在 fake 生效后继续（防止误读真实 Rust 后端）。
  expect(CoreFlags.jsChannel, jsChannel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    await ChannelManager.instance.disposeAll();
  });

  test('flag=false：loader 扫描并注册 Dart JsChannel（旧路径不变）', () async {
    await _setFlag(jsChannel: false);
    final manager = ChannelManager.instance;
    expect(manager.dartScriptChannelsEnabled, isTrue);

    final dir = await _channelDir();
    addTearDown(() => dir.delete(recursive: true));

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();

    expect(loaded.map((channel) => channel.channelKey), <String>['js_gate']);
    expect(manager.getChannelByKey('js_gate'), isA<JsChannel>());
    expect(manager.dynamicChannels, isNotEmpty);
    expect(manager.getChannel(ChannelType.custom), isA<JsChannel>());
  });

  test('flag=true：loader 返回空列表且不注册；manager 拒绝 Dart JsChannel', () async {
    await _setFlag(jsChannel: true);
    final manager = ChannelManager.instance;
    expect(manager.dartScriptChannelsEnabled, isFalse);

    final dir = await _channelDir();
    addTearDown(() => dir.delete(recursive: true));

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();
    expect(loaded, isEmpty, reason: 'Rust ScriptApi 接管时不构建 Dart JsChannel');
    expect(manager.getChannelByKey('js_gate'), isNull);
    expect(manager.dynamicChannels, isEmpty);

    // 结构性门禁：即使有人绕过 loader 直接注册，也不会进入动态索引。
    final js = JsChannel(channelKey: 'js_rejected', script: _script);
    manager.registerChannel(js);
    expect(manager.getChannelByKey('js_rejected'), isNull);
    expect(manager.getChannel(ChannelType.custom), isNull);
    expect(manager.dynamicChannels, isEmpty);
  });

  test('flag 默认值 false（CoreFlags 快照默认）→ Dart 渠道启用', () {
    CoreFlags.resetBackend();
    expect(CoreFlags.jsChannel, isFalse);
    expect(ChannelManager.instance.dartScriptChannelsEnabled, isTrue);
  });
}
