import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/request_debug_tool.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

void main() {
  late Directory tmp;
  late RequestDebugStore store;
  late RequestDebugToolService tool;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gstore_reqdbg_tool_');
    store = RequestDebugStore(directoryProvider: () async => tmp);
    await store.load();
    tool = RequestDebugToolService(
      facade: DefaultRequestDebugFacade(
        store: store,
        sender: DebugSender(),
      ),
    );
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('save 自动建集合、保存 headers/query/body 并落盘', () async {
    final result = await tool.handle({
      'action': 'save',
      'name': '查询用户',
      'collection': '项目 A',
      'method': 'post',
      'url': 'https://api.example.com/users',
      'headers': {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer secret',
      },
      'query': {'page': 1, 'size': 20},
      'body': {'q': 'termux'},
      'bodyKind': 'json',
    });

    expect(result, contains('已保存接口'));
    expect(result, contains('项目 A'));
    expect(store.collections, hasLength(1));
    final collection = store.collections.single;
    expect(collection.name, '项目 A');
    final request = collection.requests.single;
    expect(request.method, 'POST');
    expect(request.name, '查询用户');
    expect(request.url, 'https://api.example.com/users');
    expect(request.headers.map((h) => h.name), contains('Authorization'));
    expect(request.query.map((q) => q.name), containsAll(['page', 'size']));
    expect(request.body, contains('termux'));
    expect(
      File('${tmp.path}/${RequestDebugStore.fileName}').existsSync(),
      isTrue,
    );
  });

  test('list/get 默认脱敏，get 可显式显示凭证', () async {
    await tool.handle({
      'action': 'save',
      'name': '用户',
      'url': 'https://api.example.com/users',
      'headers': {'Authorization': 'Bearer secret'},
    });
    final id = store.collections.single.requests.single.id;

    final list = await tool.handle({'action': 'list'});
    expect(list, contains('AI 收藏'));
    expect(list, contains('用户'));
    expect(list, contains('https://api.example.com/users'));

    final get = await tool.handle({'action': 'get', 'requestId': id});
    expect(get, contains('Authorization: ***'));
    expect(get, isNot(contains('Bearer secret')));

    final withSecrets = await tool.handle({
      'action': 'get',
      'requestId': id,
      'includeSecrets': true,
    });
    expect(withSecrets, contains('Bearer secret'));
  });

  test('未提供 name 时保存为空，列表回退 URL；可设置和清空名称', () async {
    final saved = await tool.handle({
      'action': 'save',
      'url': 'https://api.example.com/orders',
    });
    expect(saved, contains('https://api.example.com/orders'));
    final request = store.collections.single.requests.single;
    expect(request.name, isEmpty);
    expect(request.displayName, 'https://api.example.com/orders');

    expect(
      await tool.handle({'action': 'list'}),
      contains('https://api.example.com/orders'),
    );

    final named = await tool.handle({
      'action': 'save',
      'requestId': request.id,
      'name': '查询订单',
    });
    expect(named, contains('查询订单'));
    expect(store.requestById(request.id)!.name, '查询订单');

    await tool.handle({
      'action': 'save',
      'requestId': request.id,
      'name': '',
    });
    expect(store.requestById(request.id)!.name, isEmpty);
  });

  test('save 带 requestId 更新同一条记录，delete 删除并落盘', () async {
    await tool.handle({
      'action': 'save',
      'name': '旧名称',
      'method': 'POST',
      'url': 'https://api.example.com/v1',
      'headers': {'X-Keep': '1'},
      'body': '{"a":1}',
    });
    final id = store.collections.single.requests.single.id;

    final updated = await tool.handle({
      'action': 'save',
      'requestId': id,
      'name': '新名称',
      'method': 'GET',
    });
    expect(updated, contains('已保存接口'));
    expect(store.collections.single.requests, hasLength(1));
    final request = store.requestById(id)!;
    expect(request.name, '新名称');
    expect(request.method, 'GET');
    expect(request.url, 'https://api.example.com/v1');
    expect(request.headers.single.name, 'X-Keep');
    expect(request.body, '{"a":1}');

    final deleted = await tool.handle({'action': 'delete', 'requestId': id});
    expect(deleted, contains('已删除接口'));
    expect(store.requestById(id), isNull);
  });
}
