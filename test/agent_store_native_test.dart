import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Real-native smoke test for `AgentStoreApi` (SQLite + FTS5).
///
/// ```sh
/// cargo build --manifest-path rust/gstore_host/Cargo.toml
/// FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=$PWD/rust/gstore_host/target/debug/ \
///   flutter test test/agent_store_native_test.dart
/// ```
void main() {
  final nativeLibDir =
      Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
  final available = nativeLibDir != null &&
      Directory(nativeLibDir).existsSync() &&
      Directory(nativeLibDir)
          .listSync()
          .any((e) => e.path.split('/').last.startsWith('libgstore_host'));

  group('AgentStoreApi native smoke', () {
    late Directory root;
    late rust.AgentStoreApi api;

    setUpAll(() async {
      RustBridge.debugForceUnavailable = false;
      root = await Directory.systemTemp.createTemp('gstore_agent_store_');
      final dataDir = '${root.path}/data';
      await Directory(dataDir).create(recursive: true);
      await RustBridge.ensureInitialized();
      api = await rust.AgentStoreApi.init(dataDir: dataDir);
    });

    tearDownAll(() async {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('sessions + memory roundtrip through the real core DB', () async {
      final sessions = [
        {
          'id': 's1',
          'title': '测试',
          'createdAt': 100,
          'updatedAt': 200,
          'messages': [
            {'seq': 0, 'time': 100, 'isUser': true, 'text': '你好'},
            {
              'seq': 1,
              'time': 101,
              'isUser': false,
              'text': '确认？',
              'isToolResult': true,
              'toolType': 'confirm',
              'toolStatus': 'running',
              'confirmOptions': ['确认', '取消'],
              'confirmMultiSelect': true,
            },
          ],
        },
      ];
      await api.replaceSessionsJson(json: jsonEncode(sessions));
      await api.setCurrentSessionId(id: 's1');
      final loaded = jsonDecode(await api.sessionsJson()) as List;
      expect(loaded, hasLength(1));
      expect((loaded.first as Map)['title'], '测试');
      expect(((loaded.first as Map)['messages'] as List), hasLength(2));
      expect(await api.currentSessionId(), 's1');

      await api.replaceSessionsJson(json: '[]');
      expect(jsonDecode(await api.sessionsJson()), isEmpty);
    });

    test('upsertSessionJson only rewrites the target session', () async {
      await api.clearSessions();
      final other = {
        'id': 'other',
        'title': '其它会话',
        'createdAt': 1,
        'updatedAt': 2,
        'messages': [
          {'seq': 0, 'time': 1, 'isUser': true, 'text': '保留我'},
        ],
      };
      await api.upsertSessionJson(json: jsonEncode(other));
      await api.upsertSessionJson(
        json: jsonEncode({
          'id': 'target',
          'title': '目标会话',
          'createdAt': 3,
          'updatedAt': 4,
          'messages': [
            {'seq': 0, 'time': 3, 'isUser': true, 'text': '旧内容'},
            {'seq': 1, 'time': 4, 'isUser': false, 'text': '旧回复'},
          ],
        }),
      );

      // 内容变更：只替换 target 的消息，消息键按列表顺序归一化（重复 seq 不冲突）
      await api.upsertSessionJson(
        json: jsonEncode({
          'id': 'target',
          'title': '目标会话',
          'createdAt': 3,
          'updatedAt': 9,
          'messages': [
            {'seq': 0, 'time': 3, 'isUser': true, 'text': '新内容'},
            {'seq': 0, 'time': 4, 'isUser': false, 'text': '新回复'},
            {'seq': 0, 'time': 5, 'isUser': true, 'text': '追问'},
          ],
        }),
      );

      final sessions = (jsonDecode(await api.sessionsJson()) as List)
          .cast<Map<String, dynamic>>();
      expect(sessions, hasLength(2), reason: '其它会话必须保留');
      final byId = {for (final s in sessions) s['id']: s};
      expect(byId['other'], isNotNull);
      final messages = (byId['target']!['messages'] as List).cast<Map>();
      expect(messages.map((m) => m['text']), ['新内容', '新回复', '追问']);
      expect(messages.map((m) => m['seq']), [0, 1, 2]);
      expect(byId['target']!['updatedAt'], 9);

      // 删除单会话不影响另一个
      await api.deleteSession(id: 'target');
      final left = (jsonDecode(await api.sessionsJson()) as List)
          .cast<Map<String, dynamic>>();
      expect(left.map((s) => s['id']), ['other']);
    });

    test('turn traces persist, order, prune and meta roundtrip', () async {
      Map<String, dynamic> trace(String id, int at, String status) => {
            'turnId': id,
            'sessionId': 's1',
            'createdAt': at,
            'status': status,
            'provider': 'openai',
            'model': 'hy4',
            'toolsEnabled': true,
            'promptChars': 1000,
            'messageCount': 7,
            'toolsOffered': 16,
            'modelSteps': 2,
            'toolRequests': 1,
            'toolResponses': 1,
            'toolErrors': 0,
            'firstTokenMs': 1800,
            'totalMs': 4200,
            'responseChars': 21,
            'reasoningChars': 88,
            'inputTokens': 6000,
            'outputTokens': 40,
            'finishReason': 'stop',
            'detail': '{"steps":2}',
          };

      await api.clearTraces();
      await api.insertTraceJson(json: jsonEncode(trace('t1', 100, 'ok')));
      await api.insertTraceJson(json: jsonEncode(trace('t2', 200, 'error')));

      final traces = (jsonDecode(await api.tracesJson(limit: 10)) as List)
          .cast<Map<String, dynamic>>();
      expect(traces.map((t) => t['turnId']), ['t2', 't1']);
      expect(traces.first['status'], 'error');
      expect(traces.first['firstTokenMs'], 1800);
      expect(traces.first['detail'], '{"steps":2}');

      // upsert 同一 turnId 不重复
      await api.insertTraceJson(json: jsonEncode(trace('t1', 300, 'cancelled')));
      expect((jsonDecode(await api.tracesJson(limit: 10)) as List), hasLength(2));

      expect((await api.pruneTraces(keep: 1)).toInt(), 1);
      final left = (jsonDecode(await api.tracesJson(limit: 10)) as List)
          .cast<Map<String, dynamic>>();
      expect(left.map((t) => t['turnId']), ['t1']);

      // agent_meta 通用读写（滚动摘要）
      expect(await api.readMeta(key: 'session_summary:s1'), isNull);
      await api.writeMeta(key: 'session_summary:s1', value: '用户问过 F-Droid');
      expect(await api.readMeta(key: 'session_summary:s1'), '用户问过 F-Droid');
      await api.writeMeta(key: 'session_summary:s1', value: null);
      expect(await api.readMeta(key: 'session_summary:s1'), isNull);

      await api.clearTraces();
      expect(jsonDecode(await api.tracesJson(limit: 10)), isEmpty);
    });

    test('memory FTS5 trigram recall + short LIKE + remove', () async {
      await api.clearMemories();
      await api.addMemory(text: '用户偏好使用 F-Droid 渠道');
      await api.addMemory(text: '用户喜欢深色主题');
      await api.addMemory(text: '下载保存到 /sdcard/Download');

      // 3+ chars → FTS5 trigram
      final fts = jsonDecode(
        await api.searchMemoriesJson(query: 'F-Droid', limit: 10),
      ) as List;
      expect((fts.first as Map)['text'], contains('F-Droid'));

      // 2 chars → LIKE
      final like = jsonDecode(
        await api.searchMemoriesJson(query: '主题', limit: 10),
      ) as List;
      expect((like.first as Map)['text'], contains('深色'));

      final removed = await api.removeMemory(idOrText: 'F-Droid');
      expect(removed.toInt(), 1);
      final remaining = jsonDecode(await api.memoriesJson()) as List;
      expect(remaining, hasLength(2));
    });
  }, skip: available
      ? false
      : 'native host library not loadable: build rust/gstore_host and set '
          'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR');
}
