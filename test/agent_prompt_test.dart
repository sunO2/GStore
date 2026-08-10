import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_prompt.dart';
import 'package:gstore/core/agent/agent_skills.dart';

void main() {
  group('AgentPrompt 语言切换', () {
    tearDown(() {
      // 每个用例后恢复默认英文，避免污染其他测试
      AgentPrompt.useEnglish();
    });

    test('默认使用英文', () {
      expect(AgentPrompt.language, PromptLanguage.en);
    });

    test('useEnglish / useChinese 切换', () {
      AgentPrompt.useChinese();
      expect(AgentPrompt.language, PromptLanguage.zh);
      AgentPrompt.useEnglish();
      expect(AgentPrompt.language, PromptLanguage.en);
    });
  });

  group('AgentPrompt.build 英文版', () {
    setUp(() => AgentPrompt.useEnglish());
    tearDown(() => AgentPrompt.useEnglish());

    test('包含平台描述注入', () {
      final prompt = AgentPrompt.build('当前设备 CPU 架构: arm64-v8a（Android ABI）');
      expect(prompt, contains('arm64-v8a'));
    });

    test('包含工具清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('searchApp'));
      expect(prompt, contains('downloadApp'));
      expect(prompt, contains('installApp'));
      expect(prompt, contains('confirmAction'));
      expect(prompt, contains('webdavSync'));
    });

    test('包含英文技能知识库', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('SKILL KNOWLEDGE BASE'));
      expect(prompt, contains('App Recommendation'));
    });

    test('包含敏感操作清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('SENSITIVE OPERATIONS'));
      expect(prompt, contains('Uninstall an app'));
    });

    test('包含错误处理指引', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('ERROR HANDLING GUIDANCE'));
      expect(prompt, contains('WebDAV not configured'));
    });
  });

  group('AgentPrompt.build 中文版', () {
    setUp(() => AgentPrompt.useChinese());
    tearDown(() => AgentPrompt.useEnglish());

    test('包含平台描述注入', () {
      final prompt = AgentPrompt.build('当前设备 CPU 架构: x86_64（Linux）');
      expect(prompt, contains('x86_64'));
    });

    test('包含工具清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('searchApp'));
      expect(prompt, contains('confirmAction'));
      expect(prompt, contains('webdavSync'));
    });

    test('包含中文技能知识库', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('技能知识库'));
      expect(prompt, contains('推荐应用'));
      expect(prompt, contains('WebDAV 云备份'));
    });

    test('包含敏感操作清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('敏感操作清单'));
      expect(prompt, contains('卸载应用'));
    });

    test('包含错误处理指引', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('错误处理指引'));
      expect(prompt, contains('WebDAV 未配置'));
    });
  });
}
