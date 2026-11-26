import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_tool_selector.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

void main() {
  group('AgentToolSelector 词法检索', () {
    List<String> namesFor(String text, {List<String> recent = const []}) {
      return AgentToolSelector.select(
        userText: text,
        recentTexts: recent,
        all: AgentToolCatalog.enabled,
      ).names;
    }

    test('中文分词产出 bigram/trigram', () {
      final tokens = AgentToolSelector.tokenize('检查更新');
      expect(tokens, contains('检查'));
      expect(tokens, contains('更新'));
      expect(tokens, contains('检查更'));
    });

    test('检查更新：命中 updateApps，不塞入备份/主题', () {
      final names = namesFor('检查我的应用有没有更新');
      expect(names, contains('updateApps'));
      expect(names, isNot(contains('backup')));
      expect(names, isNot(contains('themeControl')));
      // 核心工具始终存在
      expect(names, containsAll(['searchApp', 'downloadApp', 'loadProtocol']));
    });

    test('备份数据：命中 backup', () {
      final names = namesFor('帮我备份一下当前数据');
      expect(names, contains('backup'));
      expect(names, isNot(contains('themeControl')));
    });

    test('主题/深色：命中 themeControl', () {
      final names = namesFor('把主题改成深色模式');
      expect(names, contains('themeControl'));
    });

    test('直接说工具名：高权重命中', () {
      final names = namesFor('调用 backup 导出');
      expect(names, contains('backup'));
    });

    test('接口调试：命中 httpRequest', () {
      final names = namesFor('帮我用 POST 请求这个接口，带上 Authorization 头');
      expect(names, contains('httpRequest'));
    });

    test('保存接口：命中 requestDebug', () {
      final names = namesFor('把这个接口保存到请求调试库');
      expect(names, contains('requestDebug'));
    });

    test('网页调试：命中 webView', () {
      final names = namesFor('用 webview 打开这个网页并抓一下接口请求');
      expect(names, contains('webView'));
    });

    test('最近对话可补足指代（低权重）', () {
      final names = namesFor('继续', recent: ['帮我备份一下当前数据']);
      expect(names, contains('backup'));
    });

    test('寒暄：只保留核心工具且不超过上限', () {
      final selection = AgentToolSelector.select(
        userText: '你好',
        all: AgentToolCatalog.enabled,
      );
      expect(selection.names.length, lessThanOrEqualTo(AgentToolSelector.maxTools));
      for (final name in AgentToolSelector.alwaysOnNames) {
        if (AgentToolCatalog.byName(name)?.enabled ?? false) {
          expect(selection.names, contains(name), reason: '核心工具 $name');
        }
      }
    });

    test('用户提到白名单配置：强制保留 showConfigControl', () {
      final names = namesFor('分段下载开关状态');
      expect(names, contains('showConfigControl'),
          reason: '工具检索裁剪不能把控件工具裁掉');
    });

    test('普通下载请求不会误加强制控件', () {
      final names = namesFor('帮我下载一个笔记应用');
      expect(names, isNot(contains('showConfigControl')));
    });

    test('无重复、保持注册表顺序、数量受限', () {
      final selection = AgentToolSelector.select(
        userText: '帮我搜索、下载、安装、更新、备份、清理缓存、看快照、执行脚本',
        all: AgentToolCatalog.enabled,
      );
      expect(selection.names.toSet().length, selection.names.length);
      expect(
          selection.names.length, lessThanOrEqualTo(AgentToolSelector.maxTools));
      final order = [
        for (final s in AgentToolCatalog.enabled)
          if (selection.names.contains(s.name)) s.name,
      ];
      expect(selection.names, order);
    });
  });
}
