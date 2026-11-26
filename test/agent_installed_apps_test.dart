import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

/// 回归：installedApps.list 必须把全量已安装应用交给模型。
///
/// 之前两处会截断：
/// 1. 工具实现里 take(30)/take(20)；
/// 2. 回灌模型的工具结果统一 6000 字符上限。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('installed_apps');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('installedApps list 返回全部应用（不截断前 30 条）', () async {
    final apps = List.generate(
      60,
      (i) => {
        'name': 'App ${i.toString().padLeft(2, '0')}',
        'package_name': 'com.example.app$i',
      },
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInstalledApps') return apps;
      return null;
    });

    final svc = AgentService();
    addTearDown(svc.dispose);
    final action =
        svc.buildActions().firstWhere((a) => a.name == 'installedApps');
    final result = await action.handler({'action': 'list'});
    final text = (result.data as Map)['result'] as String;

    expect(text, contains('已安装应用共 60 个（完整列表）'));
    expect(text, contains('App 00'));
    expect(text, contains('App 59'));
    // 60 条都在：条数 = 标题行 + 60 行
    expect(text.split('\n').length, 61);
  });

  test('installedApps 的 keyword 过滤也返回全部匹配项', () async {
    final apps = [
      for (var i = 0; i < 40; i++)
        {
          'name': 'Tool $i',
          'package_name': 'com.example.tool$i',
        },
      {'name': 'Other', 'package_name': 'com.example.other'},
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInstalledApps') return apps;
      return null;
    });

    final svc = AgentService();
    addTearDown(svc.dispose);
    final action =
        svc.buildActions().firstWhere((a) => a.name == 'installedApps');
    final result = await action.handler({'action': 'list', 'keyword': 'tool'});
    final text = (result.data as Map)['result'] as String;

    expect(text, contains('找到 40 个包含"tool"的应用（完整列表）'));
    expect(text, contains('Tool 39'));
    expect(text, isNot(contains('Other')));
  });

  test('installedApps 回灌模型不按 6000 字符截断，其他工具仍截断', () {
    final svc = AgentService();
    addTearDown(svc.dispose);

    // 协议声明 maxResultChars = 0 → 不截断
    expect(AgentToolCatalog.byName('installedApps')?.maxResultChars, 0);

    final long = 'x' * 9000;
    expect(svc.debugTruncateToolResult(long, toolName: 'installedApps'), long);

    final clipped = svc.debugTruncateToolResult(long, toolName: 'searchApp');
    expect(clipped.length, lessThan(long.length));
    expect(clipped, contains('结果过长已截断'));
  });
}
