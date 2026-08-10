import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/builtin_tools.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 自定义可插拔工具模块
class EchoTool extends AgentToolModule {
  @override
  String get toolName => 'echoTool';

  @override
  String get toolDescription => '回显输入文本';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'text', description: '要回显的文本', required: true),
      ];

  @override
  Future<String> execute(AgentToolContext context, Map<String, dynamic> params) async {
    if (context.cancelled) return '已取消';
    return 'echo: ${params['text']}';
  }
}

/// 依赖委托的模块化工具
class DelegateTool extends AgentToolModule {
  @override
  String get toolName => 'delegateTool';

  @override
  String get toolDescription => '委托到执行器';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'keyword', description: '关键词', required: true),
      ];
}

void main() {
  group('AgentToolModule 元数据', () {
    test('内置 15 个工具注册完整', () {
      final tools = BuiltinAgentTools.all;
      expect(tools.length, 15);
      final names = tools.map((t) => t.toolName).toSet();
      expect(names, containsAll([
        'searchApp',
        'downloadApp',
        'installApp',
        'manageApp',
        'channelApp',
        'getAppInfo',
        'updateApps',
        'backup',
        'manageDownload',
        'themeControl',
        'fdroidRepo',
        'configManager',
        'webdavSync',
        'installedApps',
        'confirmAction',
      ]));
    });

    test('工具名唯一', () {
      final names = BuiltinAgentTools.all.map((t) => t.toolName).toList();
      expect(names.toSet().length, names.length);
    });

    test('每个工具都有名称/描述/模块名', () {
      for (final tool in BuiltinAgentTools.all) {
        expect(tool.toolName, isNotEmpty);
        expect(tool.toolDescription, isNotEmpty);
        expect(tool.moduleName, 'agent_tool_${tool.toolName}');
        expect(tool.enabled, true);
      }
    });

    test('关键工具参数定义完整', () {
      final search = BuiltinAgentTools.all.firstWhere((t) => t.toolName == 'searchApp');
      expect(search.toolParams, hasLength(1));
      expect(search.toolParams.first.name, 'keyword');
      expect(search.toolParams.first.required, true);

      final confirm = BuiltinAgentTools.all.firstWhere((t) => t.toolName == 'confirmAction');
      expect(confirm.toolParams.any((p) => p.name == 'question'), true);
      expect(confirm.toolParams.any((p) => p.name == 'options'), true);
    });
  });

  group('AgentToolModule 执行', () {
    test('模块化工具独立 execute（不依赖委托）', () async {
      final tool = EchoTool();
      final context = AgentToolContext();
      final result = await tool.execute(context, {'text': 'hello'});
      expect(result, 'echo: hello');
    });

    test('委托执行（executeDelegate）', () async {
      final tool = DelegateTool();
      final calls = <String>[];
      final context = AgentToolContext(
        executeDelegate: (name, params) async {
          calls.add('$name:${params['keyword']}');
          return 'delegated-result';
        },
      );
      final result = await tool.execute(context, {'keyword': 'termux'});
      expect(result, 'delegated-result');
      expect(calls, ['delegateTool:termux']);
    });

    test('无执行器时返回提示', () async {
      final tool = DelegateTool();
      final context = AgentToolContext();
      final result = await tool.execute(context, {'keyword': 'x'});
      expect(result, contains('未注册执行器'));
    });

    test('停止请求检查', () async {
      final tool = EchoTool();
      final context = AgentToolContext(stopRequested: () => true);
      final result = await tool.execute(context, {'text': 'x'});
      expect(result, '已取消');
    });
  });

  group('AgentToolModule 上下线', () {
    test('模块可注册到 ModuleManager（上线）', () async {
      final manager = ModuleManager.instance;
      await manager.clear();
      await manager.registerModule(EchoTool());
      expect(manager.hasModule('agent_tool_echoTool'), true);
      expect(manager.getModule('agent_tool_echoTool'), isA<EchoTool>());
      await manager.clear();
    });

    test('模块下线后从注册表移除', () async {
      final manager = ModuleManager.instance;
      await manager.clear();
      await manager.registerModule(EchoTool());
      await manager.unregisterModule('agent_tool_echoTool');
      expect(manager.hasModule('agent_tool_echoTool'), false);
      await manager.clear();
    });
  });
}
