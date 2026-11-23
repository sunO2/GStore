import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_memory_store.dart';
import 'package:gstore/core/agent/agent_prompt.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AgentMemoryStore', () {
    test('新增/去重/渲染/删除', () async {
      final store = await AgentMemoryStore.load();
      await store.add('  用户偏好使用 F-Droid 渠道  ');
      await store.add('用户偏好使用 F-Droid 渠道');
      await store.add('安装包保存到 /sdcard/Download');

      expect(store.all.length, 2);
      final fdroid =
          store.all.firstWhere((m) => m.text.contains('F-Droid'));
      expect(fdroid.hits, 2, reason: '同文本应累加命中而不是新增');
      final rendered = store.renderForPrompt();
      expect(rendered, contains('F-Droid'));
      expect(rendered, startsWith('- '));

      final removed = await store.remove('F-Droid');
      expect(removed, 1);
      expect(store.all.length, 1);
    });

    test('重新 load 能恢复（持久化）', () async {
      final first = await AgentMemoryStore.load();
      await first.add('用户习惯用深色主题');
      final second = await AgentMemoryStore.load();
      expect(second.all.single.text, '用户习惯用深色主题');
    });

    test('按查询相关性召回，未知查询回退最近记忆', () async {
      final store = await AgentMemoryStore.load();
      await store.add('用户偏好使用 F-Droid 渠道');
      await store.add('用户喜欢深色主题');
      await store.add('下载保存到 /sdcard/Download');

      expect(store.recall(query: '渠道偏好').first.text, contains('F-Droid'));
      expect(store.recall(query: '主题').first.text, contains('深色'));
      expect(store.recall(query: '下载路径').first.text, contains('Download'));
      expect(store.renderForPrompt(query: '主题'), contains('深色'));

      // 完全无关：仍返回最近记忆（不返回空，避免模型完全没上下文）
      final fallback = store.recall(query: 'zzznotexist');
      expect(fallback, hasLength(3));
    });

    test('空内容拒绝，超长截断', () async {
      final store = await AgentMemoryStore.load();
      expect(() => store.add('   '), throwsArgumentError);
      await store.add('a' * 800);
      expect(store.all.single.text.length, AgentMemoryStore.maxTextLength);
    });
  });

  group('长期记忆接入', () {
    test('提示词包含记忆区；空记忆不占位', () {
      AgentPrompt.useChinese();
      addTearDown(AgentPrompt.useEnglish);
      final withMemory = AgentPrompt.build(
        'platform',
        memories: '- 用户偏好 F-Droid',
      );
      expect(withMemory, contains('用户长期记忆'));
      expect(withMemory, contains('用户偏好 F-Droid'));

      final without = AgentPrompt.build('platform');
      expect(without, isNot(contains('用户长期记忆')));
    });

    test('remember / forget 工具可执行', () async {
      final agent = AgentService();
      final remember = await agent.runTool('remember', {'text': '用户偏好 F-Droid'});
      expect(remember, contains('已记住'));
      final forget = await agent.runTool('forget', {'text': 'F-Droid'});
      expect(forget, contains('已删除 1 条'));
    });
  });
}
