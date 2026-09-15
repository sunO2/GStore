import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_skills.dart';
import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/agent/tools/builtin_tools.dart';

void main() {
  group('AgentToolCatalog 注册表', () {
    test('内置工具协议唯一且完整（20 个可插拔 + 1 个元能力）', () {
      final all = AgentToolCatalog.all;
      expect(all.length, 21);
      final names = all.map((s) => s.name).toList();
      expect(names.toSet().length, names.length, reason: '工具名必须唯一');
      expect(all.where((s) => s.meta).map((s) => s.name), ['loadProtocol']);
    });

    test('每个工具都有分组/标签/简介/协议', () {
      for (final s in AgentToolCatalog.all) {
        expect(s.name.trim(), isNotEmpty);
        expect(s.group.trim(), isNotEmpty);
        expect(s.label.trim(), isNotEmpty);
        expect(s.brief.trim(), isNotEmpty);
        expect(s.protocol.trim(), isNotEmpty);
      }
    });

    test('BuiltinAgentTools 由注册表派生且不含元能力工具', () {
      final tools = BuiltinAgentTools.all;
      expect(tools.length, 20);
      expect(tools.any((t) => t.toolName == 'loadProtocol'), false);
      for (final t in tools) {
        final spec = AgentToolCatalog.byName(t.toolName)!;
        expect(t.toolDescription, spec.brief);
        expect(t.toolParams, spec.params);
        expect(t.moduleName, 'agent_tool_${t.toolName}');
      }
    });

    test('分组按声明顺序且覆盖全部工具', () {
      final groups = AgentToolCatalog.groups;
      expect(groups, isNotEmpty);
      // 每个工具都必须落在某个分组里
      var counted = 0;
      for (final g in groups) {
        counted += AgentToolCatalog.groupOf(g).length;
      }
      expect(counted, AgentToolCatalog.enabled.length);
      // 声明顺序：发现与信息在获取与安装之前
      expect(groups.indexOf(AgentToolGroup.discover),
          lessThan(groups.indexOf(AgentToolGroup.acquire)));
    });

    test('briefDirectory 常驻目录含分组与工具名', () {
      final dir = AgentToolCatalog.briefDirectory();
      for (final s in AgentToolCatalog.enabled) {
        expect(dir, contains(s.name));
      }
      expect(dir, contains(AgentToolGroup.meta));
      // 简介是"一行"，不应包含协议正文
      expect(dir, isNot(contains('【协议】')));
    });

    test('敏感操作清单由敏感动作派生', () {
      final lines = AgentToolCatalog.sensitiveLines.join('\n');
      expect(lines, contains('installedApps'));
      expect(lines, contains('uninstall'));
      expect(lines, contains('卸载应用'));
      expect(lines, contains('backup'));
      expect(lines, contains('恢复备份'));
      // 一律敏感的工具（cacheManage）
      expect(lines, contains('cacheManage'));
    });

    test('isSensitiveCall 按 action 精确判定', () {
      final backup = AgentToolCatalog.byName('backup')!;
      expect(backup.isSensitiveCall({'action': 'import'}), true);
      expect(backup.isSensitiveCall({'action': 'export'}), false);

      final cache = AgentToolCatalog.byName('cacheManage')!;
      expect(cache.isSensitiveCall({}), true, reason: 'alwaysSensitive 一律需确认');

      final search = AgentToolCatalog.byName('searchApp')!;
      expect(search.isSensitiveCall({'keyword': 'x'}), false);
    });

    test('protocolFor 返回完整协议（含参数与协议段）', () {
      final text = AgentToolCatalog.protocolFor('downloadApp');
      expect(text, isNotNull);
      expect(text, contains('【参数】'));
      expect(text, contains('appId'));
      expect(text, contains('【协议】'));
      // 未知工具返回 null
      expect(AgentToolCatalog.protocolFor('nope'), isNull);
    });

    test('运行时注册可覆盖同名工具（自动收集）', () {
      const spec = AgentToolSpec(
        name: 'searchApp',
        group: AgentToolGroup.discover,
        label: '搜索(测试)',
        brief: '覆盖后的简介',
        protocol: '覆盖后的协议',
      );
      AgentToolCatalog.register(spec);
      expect(AgentToolCatalog.byName('searchApp')!.label, '搜索(测试)');
      expect(AgentToolCatalog.all.length, 21, reason: '覆盖不应新增条目');
    });
  });

  group('技能目录按需加载', () {
    test('renderBriefs 只含名称与触发场景，不含工作流正文', () {
      final briefs = AgentSkills.renderBriefs(language: PromptLanguage.zh);
      expect(briefs, contains('推荐应用'));
      expect(briefs, isNot(contains('Workflow')));
      // 完整工作流的步骤不应出现在目录中
      expect(briefs, isNot(contains('从用户描述中提取核心需求')));
    });

    test('protocolFor 可取回完整工作流（中/英文名均可）', () {
      final zh = AgentSkills.protocolFor('推荐应用', language: PromptLanguage.zh);
      expect(zh, isNotNull);
      expect(zh, contains('从用户描述中提取核心需求'));

      final en = AgentSkills.protocolFor('App Recommendation');
      expect(en, isNotNull);
      expect(en, contains('Extract the core need'));
    });

    test('未知技能返回 null', () {
      expect(AgentSkills.protocolFor('不存在的技能'), isNull);
    });
  });

  group('AgentToolParam 类型', () {
    test('downloadApp 的 installAfterDownload 为 bool 类型', () {
      final spec = AgentToolCatalog.byName('downloadApp')!;
      final p = spec.params.firstWhere((e) => e.name == 'installAfterDownload');
      expect(p.type, 'bool');
    });
  });
}
