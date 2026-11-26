import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_workspace_service.dart';
import 'package:gstore/core/agent/workspace/saf_workspace_fs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gstore/saf_workspace');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'pickDirectory':
          return {'uri': 'content://tree/demo', 'name': 'Demo'};
        case 'resolve':
          return {
            'relative': call.arguments['path'],
            'exists': true,
            'type': 'file',
          };
        case 'stat':
          return {
            'relative': call.arguments['path'],
            'type': 'file',
            'bytes': 5,
            'modifiedAt': 1,
          };
        case 'list':
          return [
            {'path': 'a.txt', 'type': 'file', 'bytes': 5, 'modifiedAt': 1},
          ];
        case 'read':
          return {
            'path': call.arguments['path'],
            'bytes': Uint8List.fromList([104, 105]),
            'size': 2,
            'truncated': false,
          };
        case 'readBytes':
          return Uint8List.fromList([104, 105]);
        case 'stats':
          return {'files': 1, 'bytes': 2};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('SAF 包装：选择目录、读取、写入、列表', () async {
    final picked = await SafWorkspaceFs.pickDirectory();
    expect(picked?.uri, 'content://tree/demo');
    expect(picked?.name, 'Demo');

    final fs = SafWorkspaceFs('content://tree/demo');
    expect(fs.isExternal, isTrue);
    expect(fs.enforceWorkspaceQuota, isFalse);
    expect(await SafWorkspaceFs.hasPermission(fs.treeUri), isTrue);

    final read = await fs.read('a.txt');
    expect(read.text, 'hi');
    expect(read.bytes, 2);
    expect((await fs.list('')).single.path, 'a.txt');
    expect((await fs.stats()).files, 1);

    await fs.writeBytes('a.txt', [65, 66]);
    final write = calls.lastWhere((c) => c.method == 'writeBytes');
    expect(write.arguments['path'], 'a.txt');
    expect((write.arguments['bytes'] as Uint8List), [65, 66]);

    // 除 pickDirectory 外，每次 SAF 调用都必须带 tree URI，
    // 否则 Android DocumentsContract 会报 Invalid URI。
    for (final call in calls.where((c) => c.method != 'pickDirectory')) {
      expect(
        (call.arguments as Map)['uri'],
        'content://tree/demo',
        reason: '${call.method} 缺少 uri',
      );
    }
  });

  test('AgentWorkspaceInfo 支持 SAF 类型往返', () {
    final info = AgentWorkspaceInfo.fromJson({
      'id': 'saf-1',
      'name': '外部',
      'createdAt': 1,
      'updatedAt': 2,
      'type': 'saf',
      'uri': 'content://tree/demo',
    });
    expect(info.isExternal, isTrue);
    expect(info.uri, 'content://tree/demo');
    final restored = AgentWorkspaceInfo.fromJson(info.toJson());
    expect(restored.type, AgentWorkspaceType.saf);
    expect(restored.uri, 'content://tree/demo');
  });
}
