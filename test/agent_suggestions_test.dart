import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_suggestions.dart';

void main() {
  group('AgentSuggestions.extract', () {
    test('结构化「建议：A|B|C」优先，转成祈使句', () {
      final text = 'Termux 最新版是 0.119.0-beta.2。\n'
          '建议：帮我下载 Termux|查看 Termux 详情|不用了';
      final list = AgentSuggestions.extract(text);
      expect(list.map((s) => s.sendText),
          ['帮我下载 Termux', '查看 Termux 详情', '不用了']);
      expect(list.map((s) => s.label).first, '帮我下载 Termux');
    });

    test('结构化行带 markdown/编号/全角分隔符也能解析', () {
      final text = '已查到许可证是 GPLv3。\n'
          '**建议：** 1. 抓取仓库 README ｜ 2. 对比同类应用';
      final list = AgentSuggestions.extract(text);
      expect(list.map((s) => s.sendText), ['抓取仓库 README', '对比同类应用']);
    });

    test('最多 3 条且去重', () {
      final text = '建议：A|B|C|D|A';
      final list = AgentSuggestions.extract(text);
      expect(list, hasLength(3));
      expect(list.map((s) => s.sendText), ['A', 'B', 'C']);
    });

    test('末尾祈使型列表项可点击', () {
      final text = '已安装 17 个应用。\n'
          '- 需要 Android 7.0\n'
          '- 帮我检查应用更新\n'
          '- 查看已安装列表';
      final list = AgentSuggestions.extract(text);
      expect(list.map((s) => s.sendText), ['帮我检查应用更新', '查看已安装列表']);
    });

    test('提议型问句归一化为祈使句', () {
      final text = '需要我在 GStore 里帮你搜索并下载 Termux 吗？';
      final list = AgentSuggestions.extract(text);
      expect(list, hasLength(1));
      expect(list.first.sendText, '在 GStore 里搜索并下载 Termux');
    });

    test('普通陈述/事实列表不产生建议', () {
      expect(AgentSuggestions.extract('已安装 17 个应用，全部正常。'), isEmpty);
      expect(
        AgentSuggestions.extract('- 需要 Android 7.0\n- 支持四种架构'),
        isEmpty,
      );
      expect(AgentSuggestions.extract(''), isEmpty);
    });

    test('渲染时去掉末尾建议行，正文其余内容保留', () {
      const text = '版本是 0.119.0。\n'
          '建议：帮我下载 Termux|查看 Termux 详情\n';
      expect(
        AgentSuggestions.stripStructuredLine(text),
        '版本是 0.119.0。',
      );
      // 没有建议行 → 原样返回
      expect(
        AgentSuggestions.stripStructuredLine('普通回答'),
        '普通回答',
      );
      // 中间的建议行不删（只处理末尾）
      expect(
        AgentSuggestions.stripStructuredLine('建议：A|B\n后续说明'),
        '建议：A|B\n后续说明',
      );
    });

    test('过长文案截断为标签，发送文本保持完整', () {
      final long = '帮我对比一下这个应用和另外一个同类下载器的差异并推荐一个更好的替代品';
      final list = AgentSuggestions.extract('建议：$long|不用了');
      expect(list.first.label.length, lessThanOrEqualTo(29));
      expect(list.first.label, endsWith('…'));
      expect(list.first.sendText, long);
    });
  });
}
