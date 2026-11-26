import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_prompt.dart';

void main() {
  test('AgentPrompt 默认 profile 为 compact', () {
    expect(AgentPrompt.profile, AgentPromptProfile.compact);
  });

  group('AgentPrompt 语言切换', () {
    tearDown(() {
      // 每个用例后恢复默认英文/紧凑，避免污染其他测试
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
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
    tearDown(() {
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
    });

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

    test('工具清单为分组目录且提示按需读取协议', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('loadProtocol'));
      expect(prompt, contains('=== AVAILABLE TOOLS ==='));
    });

    test('技能目录由 Genkit Middleware 注入，不在基础提示词中重复', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, isNot(contains('SKILL KNOWLEDGE BASE')));
      expect(prompt, isNot(contains('App Recommendation')));
    });

    test('包含敏感操作清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('SENSITIVE OPERATIONS'));
      // 清单由协议注册表的敏感动作生成（installedApps 的 uninstall 等）
      expect(prompt, contains('uninstall'));
      expect(prompt, contains('installedApps'));
    });

    test('完整 profile 包含完整错误处理指引', () {
      AgentPrompt.useFull();
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('ERROR HANDLING GUIDANCE'));
      expect(prompt, contains('WebDAV not configured'));
    });
  });

  group('AgentPrompt.build 中文版', () {
    setUp(() => AgentPrompt.useChinese());
    tearDown(() {
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
    });

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

    test('技能目录由 Genkit Middleware 注入，不在基础提示词中重复', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, isNot(contains('技能知识库')));
      expect(prompt, isNot(contains('推荐应用')));
      expect(prompt, isNot(contains('网盘中的备份列表')));
    });

    test('包含敏感操作清单', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('敏感操作清单'));
      expect(prompt, contains('卸载应用'));
    });

    test('完整 profile 包含完整错误处理指引', () {
      AgentPrompt.useFull();
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('错误处理指引'));
      expect(prompt, contains('WebDAV 未配置'));
    });
  });

  group('文件工作区提示', () {
    tearDown(() {
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
    });

    test('包含文件工具时提示审批规则', () {
      AgentPrompt.useChinese();
      final prompt = AgentPrompt.build(
        'platform',
        toolNames: const ['fileList', 'fileWrite'],
      );
      expect(prompt, contains('文件工作区'));
      expect(prompt, contains('fileApprove'));
      expect(prompt, contains('512KB'));
    });

    test('不含文件工具时不注入文件规则', () {
      AgentPrompt.useChinese();
      final prompt = AgentPrompt.build(
        'platform',
        toolNames: const ['searchApp', 'downloadApp'],
      );
      expect(prompt, isNot(contains('文件工作区：')));
      expect(prompt, isNot(contains('fileApprove')));
    });
  });

  group('showConfigControl 提示与示例', () {
    tearDown(() {
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
    });

    test('compact 中英提示词均含工具名与示例短语', () {
      AgentPrompt.useCompact();

      AgentPrompt.useChinese();
      final compactZh = AgentPrompt.build('platform');
      expect(compactZh, contains('showConfigControl'));
      expect(compactZh, contains('分段下载开关状态'));
      expect(compactZh, contains('必须'));

      AgentPrompt.useEnglish();
      final compactEn = AgentPrompt.build('platform');
      expect(compactEn, contains('showConfigControl'));
      expect(compactEn, contains('segmented download status'));
      expect(compactEn, contains('MUST'));
    });

    test('full 中英提示词均含工具名与示例短语', () {
      AgentPrompt.useFull();

      AgentPrompt.useChinese();
      final fullZh = AgentPrompt.build('platform');
      expect(fullZh, contains('showConfigControl'));
      expect(fullZh, contains('分段下载开关状态'));

      AgentPrompt.useEnglish();
      final fullEn = AgentPrompt.build('platform');
      expect(fullEn, contains('showConfigControl'));
      expect(fullEn, contains('segmented download status'));
    });
  });

  group('提示词 profile', () {
    tearDown(() {
      AgentPrompt.useEnglish();
      AgentPrompt.useCompact();
    });

    test('useCompact 构建更短的提示词（zh/en 均至少短 1000 字符）', () {
      AgentPrompt.useChinese();

      AgentPrompt.useCompact();
      final compactZh = AgentPrompt.build('platform');
      expect(compactZh, contains('searchApp'));
      expect(compactZh, contains('downloadApp'));
      expect(compactZh, contains('loadProtocol'));

      AgentPrompt.useFull();
      final fullZh = AgentPrompt.build('platform');
      expect(fullZh.length - compactZh.length, greaterThanOrEqualTo(1000));

      AgentPrompt.useEnglish();

      AgentPrompt.useCompact();
      final compactEn = AgentPrompt.build('platform');
      expect(compactEn, contains('searchApp'));
      expect(compactEn, contains('downloadApp'));
      expect(compactEn, contains('loadProtocol'));

      AgentPrompt.useFull();
      final fullEn = AgentPrompt.build('platform');
      expect(fullEn.length - compactEn.length, greaterThanOrEqualTo(1000));
    });

    test('useFull 保留完整工具目录（一行简介标记与简介文本）', () {
      AgentPrompt.useFull();

      AgentPrompt.useChinese();
      final zh = AgentPrompt.build('platform');
      expect(zh, contains('  • '));
      expect(zh, contains('搜索'));

      AgentPrompt.useEnglish();
      final en = AgentPrompt.build('platform');
      expect(en, contains('  • '));
      // brief 为中文原文，英文提示词中同样注入
      expect(en, contains('跨渠道搜索应用'));
    });

    test('compact 错误处理指引为概括版（含 WebDAV）', () {
      AgentPrompt.useCompact();

      AgentPrompt.useChinese();
      final zh = AgentPrompt.build('platform');
      expect(zh, contains('错误处理'));
      expect(zh, contains('WebDAV'));

      AgentPrompt.useEnglish();
      final en = AgentPrompt.build('platform');
      expect(en, contains('ERROR HANDLING'));
      expect(en, contains('WebDAV'));
    });

    test('full 错误处理指引保留旧的具体措辞', () {
      AgentPrompt.useFull();

      AgentPrompt.useChinese();
      final zh = AgentPrompt.build('platform');
      expect(zh, contains('WebDAV 未配置'));

      AgentPrompt.useEnglish();
      final en = AgentPrompt.build('platform');
      expect(en, contains('WebDAV not configured'));
    });
  });
}

void _toolSubsetPromptTests() {
  group('工具子集提示词（P1）', () {
    test('只渲染传入的工具与对应敏感清单', () {
      final prompt = AgentPrompt.build(
        'platform',
        toolNames: const ['searchApp', 'confirmAction'],
      );
      expect(prompt, contains('searchApp'));
      expect(prompt, contains('confirmAction'));
      expect(prompt, isNot(contains('backup')));
      expect(prompt, isNot(contains('缓存管理')));
    });

    test('null = 全量工具目录', () {
      final prompt = AgentPrompt.build('platform');
      expect(prompt, contains('searchApp'));
      expect(prompt, contains('backup'));
      expect(prompt, contains('缓存管理'));
    });
  });
}
