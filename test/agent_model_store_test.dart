import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AgentModel', () {
    test('Google 默认模型与 BaseURL', () {
      final model = AgentModel(id: '1', provider: AgentLlmProvider.google);
      expect(model.defaultModel, 'gemini-2.0-flash');
      expect(model.defaultBaseUrl, '');
    });

    test('OpenAI 默认模型与 BaseURL', () {
      final model = AgentModel(id: '1', provider: AgentLlmProvider.openai);
      expect(model.defaultModel, 'gpt-4o-mini');
      expect(model.defaultBaseUrl, 'https://api.openai.com/v1');
    });

    test('effectiveModel：未设置时用默认', () {
      final model = AgentModel(id: '1', provider: AgentLlmProvider.openai);
      expect(model.effectiveModel, 'gpt-4o-mini');
      expect(model.effectiveBaseUrl, 'https://api.openai.com/v1');
    });

    test('effectiveModel：已设置时使用自定义值', () {
      final model = AgentModel(
        id: '1',
        provider: AgentLlmProvider.openai,
        model: 'gpt-4o',
        baseUrl: 'https://proxy.example.com/v1',
      );
      expect(model.effectiveModel, 'gpt-4o');
      expect(model.effectiveBaseUrl, 'https://proxy.example.com/v1');
    });

    test('displayName：优先自定义名称', () {
      final model = AgentModel(
        id: '1',
        provider: AgentLlmProvider.google,
        name: '我的模型',
        model: 'gemini-2.5-pro',
      );
      expect(model.displayName, '我的模型');
    });

    test('displayName：无名称时用模型名', () {
      final model = AgentModel(
        id: '1',
        provider: AgentLlmProvider.google,
        model: 'gemini-2.5-pro',
      );
      expect(model.displayName, 'gemini-2.5-pro');
    });

    test('displayName：都无时用默认模型名', () {
      final model = AgentModel(id: '1', provider: AgentLlmProvider.google);
      expect(model.displayName, 'gemini-2.0-flash');
    });

    test('isConfigured', () {
      final empty = AgentModel(id: '1', provider: AgentLlmProvider.google);
      expect(empty.isConfigured, false);
      final full = AgentModel(
        id: '1',
        provider: AgentLlmProvider.google,
        apiKey: 'sk-xxx',
      );
      expect(full.isConfigured, true);
    });

    test('toJson / fromJson 往返', () {
      final model = AgentModel(
        id: 'abc',
        name: '模型A',
        provider: AgentLlmProvider.openai,
        apiKey: 'sk-123',
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
      );
      final json = model.toJson();
      expect(json['id'], 'abc');
      expect(json['provider'], 'openai');
      expect(json['apiKey'], 'sk-123');

      final restored = AgentModel.fromJson(json);
      expect(restored.id, 'abc');
      expect(restored.name, '模型A');
      expect(restored.provider, AgentLlmProvider.openai);
      expect(restored.apiKey, 'sk-123');
      expect(restored.model, 'gpt-4o-mini');
      expect(restored.baseUrl, 'https://api.example.com/v1');
    });

    test('fromJson：缺省字段与未知 provider 回退', () {
      final restored = AgentModel.fromJson({'id': 'x'});
      expect(restored.id, 'x');
      expect(restored.name, '');
      expect(restored.provider, AgentLlmProvider.google);
      expect(restored.apiKey, '');
      expect(restored.model, '');
      expect(restored.baseUrl, '');
    });

    test('generateModelId 生成时间戳格式', () {
      final id = generateModelId();
      expect(id, isNotEmpty);
      expect(int.tryParse(id), isNotNull);
    });
  });

  group('AgentModelStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // 重置 ConfigStore，避免单例缓存旧 prefs 实例导致跨用例污染
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize();
      ConfigRegistry.registerAll(ConfigService.instance);
    });

    test('load 空存储返回空列表', () async {
      final store = await AgentModelStore.load();
      expect(store.models, isEmpty);
      expect(store.selected, isNull);
    });

    test('add 后自动选中并可 reload', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(
        id: 'm1',
        name: '模型1',
        provider: AgentLlmProvider.google,
        apiKey: 'k1',
      ));
      expect(store.models.length, 1);
      expect(store.selectedId, 'm1');

      final reloaded = await AgentModelStore.load();
      expect(reloaded.models.length, 1);
      expect(reloaded.models.first.name, '模型1');
      expect(reloaded.selectedId, 'm1');
    });

    test('update 修改模型字段', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      final updated = AgentModel(
        id: 'm1',
        name: '改名',
        provider: AgentLlmProvider.google,
        apiKey: 'k2',
      );
      await store.update(updated);
      final reloaded = await AgentModelStore.load();
      expect(reloaded.models.first.name, '改名');
      expect(reloaded.models.first.apiKey, 'k2');
    });

    test('select 切换选中模型', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      await store.add(AgentModel(id: 'm2', provider: AgentLlmProvider.openai));
      await store.select('m2');
      expect(store.selectedId, 'm2');
      expect(store.selected!.provider, AgentLlmProvider.openai);
    });

    test('remove 删除模型并回退选中', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      await store.add(AgentModel(id: 'm2', provider: AgentLlmProvider.openai));
      await store.select('m2');
      await store.remove('m2');
      expect(store.models.length, 1);
      expect(store.selectedId, 'm1');
      final reloaded = await AgentModelStore.load();
      expect(reloaded.models.length, 1);
    });

    test('clearAll 清空模型', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      await store.clearAll();
      expect(store.models, isEmpty);
      expect(store.selectedId, isNull);
      final reloaded = await AgentModelStore.load();
      expect(reloaded.models, isEmpty);
    });

    test('损坏的存储数据安全回退', () async {
      SharedPreferences.setMockInitialValues({'agent_models': 'not-json'});
      final store = await AgentModelStore.load();
      expect(store.models, isEmpty);
      expect(store.selected, isNull);
    });

    test('add 同 id 两次：去重更新，不产生重复', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(
        id: 'm1',
        name: 'v1',
        provider: AgentLlmProvider.google,
      ));
      await store.add(AgentModel(
        id: 'm1',
        name: 'v2',
        provider: AgentLlmProvider.google,
        apiKey: 'k2',
      ));
      expect(store.models.length, 1);
      expect(store.models.single.name, 'v2');
      expect(store.models.single.apiKey, 'k2');
      final reloaded = await AgentModelStore.load();
      expect(reloaded.models.length, 1);
      expect(reloaded.models.single.name, 'v2');
    });

    test('add 不同 id：各自保留', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      await store.add(AgentModel(id: 'm2', provider: AgentLlmProvider.openai));
      expect(store.models.length, 2);
      expect(store.models.map((m) => m.id).toSet(), {'m1', 'm2'});
    });

    test('add 同 id：保持原列表位置更新', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      await store.add(AgentModel(id: 'm2', provider: AgentLlmProvider.openai));
      await store.add(AgentModel(
        id: 'm1',
        name: 'v2',
        provider: AgentLlmProvider.google,
      ));
      expect(store.models.length, 2);
      expect(store.models[0].id, 'm1');
      expect(store.models[0].name, 'v2');
      expect(store.models[1].id, 'm2');
    });

    test('恢复场景：add 已存在的 id 用备份值更新，新 id 追加，重复恢复不产生重复', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(
        id: 'A',
        name: '旧值',
        provider: AgentLlmProvider.google,
      ));
      // 模拟 backup_service 恢复循环：对每个备份项调用 add(select: false)
      await store.add(AgentModel(
        id: 'A',
        name: '备份值',
        provider: AgentLlmProvider.google,
        apiKey: 'kA',
      ), select: false);
      await store.add(AgentModel(
        id: 'B',
        name: '新模型',
        provider: AgentLlmProvider.openai,
      ), select: false);
      expect(store.models.length, 2);
      expect(store.models.map((m) => m.id).toSet(), {'A', 'B'});
      final a = store.models.firstWhere((m) => m.id == 'A');
      expect(a.name, '备份值');
      expect(a.apiKey, 'kA');
      // 同一备份恢复多次：id 依然唯一
      await store.add(AgentModel(
        id: 'A',
        name: '备份值',
        provider: AgentLlmProvider.google,
        apiKey: 'kA',
      ), select: false);
      await store.add(AgentModel(
        id: 'B',
        name: '新模型',
        provider: AgentLlmProvider.openai,
      ), select: false);
      expect(store.models.length, 2);
    });

    test('add select:false：已有选中不变', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google));
      expect(store.selectedId, 'm1');
      await store.add(AgentModel(id: 'm2', provider: AgentLlmProvider.openai),
          select: false);
      expect(store.selectedId, 'm1');
    });

    test('add select:false：无选中时自动选中第一个', () async {
      final store = await AgentModelStore.load();
      await store.add(AgentModel(id: 'm1', provider: AgentLlmProvider.google),
          select: false);
      expect(store.selectedId, 'm1');
    });
  });
}
