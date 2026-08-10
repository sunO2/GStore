import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_skills.dart';

void main() {
  group('AgentSkill.render', () {
    test('中文渲染包含中文名称/触发条件/工作流', () {
      const skill = AgentSkill(
        name: '测试技能',
        nameEn: 'Test Skill',
        triggers: '触发场景A',
        triggersEn: 'Trigger A',
        workflow: '步骤1',
        workflowEn: 'Step 1',
      );
      final text = skill.render(PromptLanguage.zh);
      expect(text, contains('[Skill: 测试技能]'));
      expect(text, contains('Trigger: 触发场景A'));
      expect(text, contains('步骤1'));
      expect(text, isNot(contains('Test Skill')));
    });

    test('英文渲染包含英文名称/触发条件/工作流', () {
      const skill = AgentSkill(
        name: '测试技能',
        nameEn: 'Test Skill',
        triggers: '触发场景A',
        triggersEn: 'Trigger A',
        workflow: '步骤1',
        workflowEn: 'Step 1',
      );
      final text = skill.render(PromptLanguage.en);
      expect(text, contains('[Skill: Test Skill]'));
      expect(text, contains('Trigger: Trigger A'));
      expect(text, contains('Step 1'));
      expect(text, isNot(contains('测试技能')));
    });
  });

  group('AgentSkills.renderAll', () {
    test('默认渲染英文', () {
      final text = AgentSkills.renderAll();
      expect(text, contains('[Skill: App Recommendation]'));
      expect(text, isNot(contains('推荐应用')));
    });

    test('中文渲染包含全部中文技能', () {
      final text = AgentSkills.renderAll(language: PromptLanguage.zh);
      expect(text, contains('推荐应用'));
      expect(text, contains('下载安装流程'));
      expect(text, contains('应用更新检查'));
      expect(text, contains('备份与恢复'));
      expect(text, contains('已安装应用管理'));
      expect(text, contains('敏感操作与选择'));
      expect(text, contains('下载管理'));
      expect(text, contains('F-Droid 仓库'));
      expect(text, contains('WebDAV 云备份'));
      expect(text, contains('问题诊断与失败处理'));
    });

    test('英文渲染包含全部英文技能', () {
      final text = AgentSkills.renderAll(language: PromptLanguage.en);
      expect(text, contains('App Recommendation'));
      expect(text, contains('Download & Install Flow'));
      expect(text, contains('App Update Check'));
      expect(text, contains('Backup & Restore'));
      expect(text, contains('Installed Apps Management'));
      expect(text, contains('Sensitive Operations & Choices'));
      expect(text, contains('Download Management'));
      expect(text, contains('F-Droid Repository'));
      expect(text, contains('WebDAV Cloud Backup'));
      expect(text, contains('Troubleshooting & Failure Handling'));
    });

    test('全部技能默认启用', () {
      final all = AgentSkills.all;
      expect(all.every((s) => s.enabled), true);
      expect(all.length, greaterThanOrEqualTo(10));
    });

    test('所有技能均提供中英双语字段', () {
      for (final skill in AgentSkills.all) {
        expect(skill.name.trim(), isNotEmpty);
        expect(skill.nameEn.trim(), isNotEmpty);
        expect(skill.triggers.trim(), isNotEmpty);
        expect(skill.triggersEn.trim(), isNotEmpty);
        expect(skill.workflow.trim(), isNotEmpty);
        expect(skill.workflowEn.trim(), isNotEmpty);
      }
    });
  });
}
