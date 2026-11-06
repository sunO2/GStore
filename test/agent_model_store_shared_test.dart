// AgentModelStore 共享单例 + 可观察性测试：
// 所有消费方（设置页 / 备份恢复 / AgentService）必须看到同一份状态。
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ConfigStore.instance;
  final service = ConfigService.instance;

  AgentModel model(String id, {String name = ''}) => AgentModel(
        id: id,
        name: name,
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-$id',
      );

  setUp(() async {
    AgentModelStore.resetForTest();
    store.resetForTest();
    await store.initialize(storages: <ConfigStorage>[MemoryConfigStorage()]);
    await service.ensureReady();
  });

  tearDown(() async {
    AgentModelStore.resetForTest();
    await service.resetForTest();
    store.resetForTest();
  });

  test('load 两次返回同一实例', () async {
    final first = await AgentModelStore.load();
    final second = await AgentModelStore.load();
    expect(identical(first, second), isTrue);
  });

  test('add 通知监听者并更新选中 ID', () async {
    final shared = await AgentModelStore.load();
    var notifications = 0;
    shared.addListener(() => notifications++);

    await shared.add(model('m1'));

    expect(notifications, greaterThan(0));
    expect(shared.selectedId, 'm1');
    expect(shared.models.single.id, 'm1');
  });

  test('外部配置写入触发共享 store 重载并通知', () async {
    final shared = await AgentModelStore.load();
    final seen = <String>[];
    shared.addListener(() {
      seen.add(shared.models.map((m) => m.id).join(','));
    });

    await service.set(
      ConfigKeys.agentModels,
      <Map<String, Object?>>[model('ext').toJson()],
      source: ConfigChangeSource.internal,
    );

    // 30ms 防抖后再 reload。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(shared.models.map((m) => m.id), contains('ext'));
    expect(seen, isNotEmpty);
  });

  test('restoreModels 按 id upsert 并选中请求的 ID', () async {
    final shared = await AgentModelStore.load();
    await shared.add(model('a', name: '旧值'));

    await shared.restoreModels(
      <AgentModel>[model('a', name: '新值'), model('b')],
      selectedId: 'b',
    );

    expect(shared.models.map((m) => m.id).toList(), <String>['a', 'b']);
    expect(shared.models.first.name, '新值');
    expect(shared.selectedId, 'b');

    final raw = await store.readValue(ConfigKeys.agentModels);
    expect(raw, isA<List>());
    expect(raw as List, hasLength(2));
    expect(await store.readString(ConfigKeys.agentSelectedModelId), 'b');
  });

  test('batch 合并通知为一次', () async {
    final shared = await AgentModelStore.load();
    var notifications = 0;
    shared.addListener(() => notifications++);

    await shared.batch(() async {
      await shared.add(model('a'));
      await shared.update(model('a', name: 'x'));
    });

    expect(notifications, 1);
    expect(shared.models.single.name, 'x');
  });
}
