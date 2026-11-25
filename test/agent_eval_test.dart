/// Agent 评测集（P2-3）
///
/// 目标：用**确定性回放**覆盖真实任务形态，给后续 prompt/工具/loop 改动提供回归基线。
///
/// 每个 case 描述：
/// - 用户输入（同时用于工具检索）
/// - 模型脚本（每步工具请求 / 最终文本）
/// - 期望工具序列、最终文本、工具失败数、步数上限
///
/// 不调用真实模型：通过 AgentService 的 debug seam 回放模型步与工具结果，
/// 因此可在 CI 稳定运行。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_selector.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/agent/agent_trace.dart';
import 'package:gstore/core/agent/agent_trace_store.dart';

// ---------------------------------------------------------------------------
// Eval 定义
// ---------------------------------------------------------------------------

class _ToolCall {
  const _ToolCall(this.name, [this.args = const {}]);
  final String name;
  final Map<String, dynamic> args;
}

class _Step {
  const _Step.tools(List<_ToolCall> calls) : tools = calls, text = null;
  const _Step.text(this.text) : tools = const [];

  final List<_ToolCall> tools;
  final String? text;
}

class _Case {
  const _Case({
    required this.id,
    required this.prompt,
    required this.steps,
    required this.expectedTools,
    this.expectedText = '',
    this.outputs = const {},
    this.expectedErrors = 0,
    this.maxSteps = 10,
  });

  final String id;
  final String prompt;
  final List<_Step> steps;
  final List<String> expectedTools;
  final String expectedText;
  final Map<String, String> outputs;
  final int expectedErrors;
  final int maxSteps;
}

GenerateResult<dynamic> _modelResponse(
  List<Part> content,
  List<Message> requestMessages,
) {
  return GenerateResult<dynamic>(
    ModelResponse(
      message: Message(role: Role.model, content: content),
      finishReason: FinishReason.stop,
    ),
    request: ModelRequest(messages: requestMessages),
  );
}

ToolRequestPart _request(String name, Map<String, dynamic> args, String ref) {
  return ToolRequestPart(
    toolRequest: ToolRequest(name: name, input: args, ref: ref),
  );
}

ToolResponsePart _response(String name, String ref, String output) {
  return ToolResponsePart(
    toolResponse: ToolResponse(name: name, ref: ref, output: output),
  );
}

// ---------------------------------------------------------------------------
// 30 个黄金任务
// ---------------------------------------------------------------------------

final _cases = <_Case>[
  _Case(
    id: 'search_basic',
    prompt: '帮我找一个终端工具',
    steps: [
      _Step.tools([_ToolCall('searchApp', {'keyword': 'terminal'})]),
      _Step.text('找到 Termux，要不要下载？'),
    ],
    expectedTools: ['searchApp'],
    expectedText: 'Termux',
  ),
  _Case(
    id: 'search_compare_sources',
    prompt: '推荐开源的下载器，比较一下来源',
    steps: [
      _Step.tools([
        _ToolCall('searchApp', {'keyword': 'download manager'}),
        _ToolCall('getAppInfo', {'appId': 'gopeed', 'channel': 'github'}),
      ]),
      _Step.text('推荐 Gopeed（GitHub，开源）'),
    ],
    expectedTools: ['searchApp', 'getAppInfo'],
    expectedText: 'Gopeed',
  ),
  _Case(
    id: 'search_no_result',
    prompt: '找一个不存在的应用 zzznotexist',
    steps: [
      _Step.tools([_ToolCall('searchApp', {'keyword': 'zzznotexist'})]),
      _Step.text('没有找到，建议换个关键词'),
    ],
    outputs: {'searchApp': '执行失败: 无结果'},
    expectedTools: ['searchApp'],
    expectedErrors: 1,
    expectedText: '换个关键词',
  ),
  _Case(
    id: 'app_info',
    prompt: '看看 Termux 的详情',
    steps: [
      _Step.tools([
        _ToolCall('getAppInfo', {'appId': 'termux', 'channel': 'fdroid'}),
      ]),
      _Step.text('Termux 是一个终端模拟器'),
    ],
    expectedTools: ['getAppInfo'],
    expectedText: 'Termux',
  ),
  _Case(
    id: 'download_and_install',
    prompt: '下载 Termux 并安装',
    steps: [
      _Step.tools([
        _ToolCall('downloadApp', {
          'appId': 'termux',
          'channel': 'fdroid',
          'name': 'Termux',
          'version': '0.118',
        }),
      ]),
      _Step.tools([_ToolCall('installApp', {'savePath': '/tmp/termux.apk'})]),
      _Step.text('已下载并安装 Termux'),
    ],
    expectedTools: ['downloadApp', 'installApp'],
    expectedText: 'Termux',
  ),
  _Case(
    id: 'download_fail_then_search',
    prompt: '下载 Termux，失败的话换个来源',
    steps: [
      _Step.tools([
        _ToolCall('downloadApp', {'appId': 'termux', 'channel': 'fdroid'}),
      ]),
      _Step.tools([_ToolCall('searchApp', {'keyword': 'termux'})]),
      _Step.text('原来源失败，已改从 GitHub 查找'),
    ],
    outputs: {'downloadApp': '执行失败: 下载地址失效'},
    expectedTools: ['downloadApp', 'searchApp'],
    expectedErrors: 1,
    expectedText: 'GitHub',
  ),
  _Case(
    id: 'update_check',
    prompt: '检查我的应用有没有更新',
    steps: [
      _Step.tools([_ToolCall('updateApps')]),
      _Step.text('发现 2 个可更新应用'),
    ],
    expectedTools: ['updateApps'],
    expectedText: '2 个',
  ),
  _Case(
    id: 'update_all',
    prompt: '把能更新的应用都更新一下',
    steps: [
      _Step.tools([_ToolCall('updateApps')]),
      _Step.text('已开始更新全部可更新应用'),
    ],
    expectedTools: ['updateApps'],
    expectedText: '全部',
  ),
  _Case(
    id: 'installed_list',
    prompt: '我装了什么应用',
    steps: [
      _Step.tools([_ToolCall('installedApps', {'action': 'list'})]),
      _Step.text('你安装了 17 个应用'),
    ],
    expectedTools: ['installedApps'],
    expectedText: '17',
  ),
  _Case(
    id: 'uninstall_with_confirm',
    prompt: '卸载 com.example.app',
    steps: [
      _Step.tools([
        _ToolCall('confirmAction', {
          'question': '确认卸载 com.example.app？',
          'options': ['确认', '取消'],
        }),
      ]),
      _Step.tools([
        _ToolCall('installedApps', {
          'action': 'uninstall',
          'packageName': 'com.example.app',
        }),
      ]),
      _Step.text('已卸载'),
    ],
    expectedTools: ['confirmAction', 'installedApps'],
    expectedText: '已卸载',
  ),
  _Case(
    id: 'backup_export',
    prompt: '备份我的数据',
    steps: [
      _Step.tools([_ToolCall('backup', {'action': 'export'})]),
      _Step.text('备份已导出'),
    ],
    expectedTools: ['backup'],
    expectedText: '备份',
  ),
  _Case(
    id: 'backup_restore_confirm',
    prompt: '从备份恢复数据',
    steps: [
      _Step.tools([
        _ToolCall('confirmAction', {'question': '恢复会覆盖现有数据，确认？'}),
      ]),
      _Step.tools([
        _ToolCall('backup', {'action': 'import', 'filePath': '/tmp/b.tar.gz'}),
      ]),
      _Step.text('已恢复'),
    ],
    expectedTools: ['confirmAction', 'backup'],
    expectedText: '恢复',
  ),
  _Case(
    id: 'webdav_status',
    prompt: '查看 WebDAV 云备份状态',
    steps: [
      _Step.tools([_ToolCall('webdavSync', {'action': 'status'})]),
      _Step.text('WebDAV 已配置'),
    ],
    expectedTools: ['webdavSync'],
    expectedText: 'WebDAV',
  ),
  _Case(
    id: 'config_list',
    prompt: '看看下载相关的配置',
    steps: [
      _Step.tools([_ToolCall('configManager', {'action': 'list'})]),
      _Step.text('下载配置包括并发数、重试次数'),
    ],
    expectedTools: ['configManager'],
    expectedText: '并发',
  ),
  _Case(
    id: 'config_set',
    prompt: '修改下载配置，把最大并发调到 5',
    steps: [
      _Step.tools([
        _ToolCall('configManager', {
          'action': 'set',
          'key': 'download.max_concurrent',
          'value': 5,
        }),
      ]),
      _Step.text('已把最大并发改为 5'),
    ],
    expectedTools: ['configManager'],
    expectedText: '5',
  ),
  _Case(
    id: 'theme_dark',
    prompt: '把主题改成深色模式',
    steps: [
      _Step.tools([
        _ToolCall('themeControl', {'action': 'set', 'mode': 'dark'}),
      ]),
      _Step.text('已切换深色主题'),
    ],
    expectedTools: ['themeControl'],
    expectedText: '深色',
  ),
  _Case(
    id: 'cache_clean',
    prompt: '清理缓存和下载文件',
    steps: [
      _Step.tools([_ToolCall('cacheManage')]),
      _Step.text('已清理所选缓存'),
    ],
    expectedTools: ['cacheManage'],
    expectedText: '清理',
  ),
  _Case(
    id: 'snapshot_compare',
    prompt: '对比 Termux 两个版本的差异',
    steps: [
      _Step.tools([
        _ToolCall('snapshotCompare', {'packageName': 'com.termux'}),
      ]),
      _Step.text('两个版本主要差异在原生库'),
    ],
    expectedTools: ['snapshotCompare'],
    expectedText: '差异',
  ),
  _Case(
    id: 'apk_browse',
    prompt: '浏览 Termux 的 APK 文件',
    steps: [
      _Step.tools([
        _ToolCall('apkBrowser', {'action': 'browse', 'packageName': 'com.termux'}),
      ]),
      _Step.text('APK 根目录包含 lib、assets 等'),
    ],
    expectedTools: ['apkBrowser'],
    expectedText: 'APK',
  ),
  _Case(
    id: 'remember_preference',
    prompt: '记住我偏好使用 F-Droid 渠道',
    steps: [
      _Step.tools([
        _ToolCall('remember', {'text': '用户偏好使用 F-Droid 渠道'}),
      ]),
      _Step.text('已记住你的渠道偏好'),
    ],
    expectedTools: ['remember'],
    expectedText: '已记住',
  ),
  _Case(
    id: 'forget_preference',
    prompt: '忘掉我之前说的 F-Droid 偏好',
    steps: [
      _Step.tools([_ToolCall('forget', {'text': 'F-Droid'})]),
      _Step.text('已删除该记忆'),
    ],
    expectedTools: ['forget'],
    expectedText: '删除',
  ),
  _Case(
    id: 'fdroid_search',
    prompt: '在 F-Droid 搜索阅读器',
    steps: [
      _Step.tools([
        _ToolCall('fdroidRepo', {'action': 'search', 'keyword': 'reader'}),
      ]),
      _Step.text('F-Droid 找到 3 个阅读器'),
    ],
    expectedTools: ['fdroidRepo'],
    expectedText: 'F-Droid',
  ),
  _Case(
    id: 'script_channel',
    prompt: '用脚本渠道 js_pingan 执行 getConfig',
    steps: [
      _Step.tools([
        _ToolCall('runJsChannel', {
          'channel': 'js_pingan',
          'method': 'getConfig',
        }),
      ]),
      _Step.text('脚本渠道配置已读取'),
    ],
    expectedTools: ['runJsChannel'],
    expectedText: '配置',
  ),
  _Case(
    id: 'confirm_choice',
    prompt: '帮我从两个方案里选一个',
    steps: [
      _Step.tools([
        _ToolCall('confirmAction', {
          'question': '选择哪个方案？',
          'options': ['方案 A', '方案 B'],
        }),
      ]),
      _Step.text('已按你的选择执行'),
    ],
    expectedTools: ['confirmAction'],
    expectedText: '选择',
  ),
  _Case(
    id: 'parallel_readonly',
    prompt: '同时查 Termux 的搜索和详情',
    steps: [
      _Step.tools([
        _ToolCall('searchApp', {'keyword': 'termux'}),
        _ToolCall('getAppInfo', {'appId': 'termux', 'channel': 'fdroid'}),
      ]),
      _Step.text('搜索和详情都已返回'),
    ],
    expectedTools: ['searchApp', 'getAppInfo'],
    expectedText: '都已返回',
  ),
  _Case(
    id: 'failure_recovery',
    prompt: '查一下 Termux 详情，失败就搜索',
    steps: [
      _Step.tools([
        _ToolCall('getAppInfo', {'appId': 'termux', 'channel': 'fdroid'}),
      ]),
      _Step.tools([_ToolCall('searchApp', {'keyword': 'termux'})]),
      _Step.text('详情失败，已改用搜索'),
    ],
    outputs: {'getAppInfo': '执行失败: 渠道超时'},
    expectedTools: ['getAppInfo', 'searchApp'],
    expectedErrors: 1,
    expectedText: '搜索',
  ),
  _Case(
    id: 'max_steps_forced_summary',
    prompt: '一直重试直到成功',
    steps: [
      for (var i = 0; i < 10; i++)
        _Step.tools([_ToolCall('searchApp', {'keyword': 'retry$i'})]),
      _Step.text('达到最大步数，先总结当前结果'),
    ],
    expectedTools: List<String>.filled(10, 'searchApp'),
    expectedText: '总结',
    maxSteps: 11,
  ),
  _Case(
    id: 'selection_update',
    prompt: '检查更新',
    steps: [
      _Step.tools([_ToolCall('updateApps')]),
      _Step.text('检查完成'),
    ],
    expectedTools: ['updateApps'],
    expectedText: '检查',
  ),
  _Case(
    id: 'selection_backup',
    prompt: '备份数据',
    steps: [
      _Step.tools([_ToolCall('backup', {'action': 'export'})]),
      _Step.text('备份完成'),
    ],
    expectedTools: ['backup'],
    expectedText: '备份',
  ),
  _Case(
    id: 'selection_theme',
    prompt: '深色主题',
    steps: [
      _Step.tools([_ToolCall('themeControl', {'action': 'set', 'mode': 'dark'})]),
      _Step.text('已设置'),
    ],
    expectedTools: ['themeControl'],
    expectedText: '设置',
  ),
  _Case(
    id: 'web_search_release',
    prompt: '帮我联网查一下 Termux 最新版本和更新日志',
    steps: [
      _Step.tools([
        _ToolCall('webSearch', {'query': 'Termux 最新版本 更新日志'}),
      ]),
      _Step.text('Termux 最新版本是 0.118.3'),
    ],
    expectedTools: ['webSearch'],
    expectedText: '0.118.3',
  ),
  _Case(
    id: 'web_fetch_license',
    prompt: '抓取这个仓库的许可证原文 https://github.com/termux/termux-app',
    steps: [
      _Step.tools([
        _ToolCall('webFetch', {'url': 'https://github.com/termux/termux-app'}),
      ]),
      _Step.text('许可证是 GPLv3'),
    ],
    expectedTools: ['webFetch'],
    expectedText: 'GPLv3',
  ),
  _Case(
    id: 'web_search_then_fetch',
    prompt: '搜索 Termux 安装失败怎么修，然后打开排名第一的页面看细节',
    steps: [
      _Step.tools([
        _ToolCall('webSearch', {'query': 'Termux 安装失败 修复'}),
      ]),
      _Step.tools([
        _ToolCall('webFetch', {
          'url': 'https://github.com/termux/termux-app/issues/1',
        }),
      ]),
      _Step.text('按页面说明处理'),
    ],
    expectedTools: ['webSearch', 'webFetch'],
    expectedText: '页面',
  ),
];

// ---------------------------------------------------------------------------
// 执行器
// ---------------------------------------------------------------------------

Future<({List<String> executed, int errors, AgentTurnTrace trace})> _run(
  _Case c,
) async {
  final selection = AgentToolSelector.select(
    userText: c.prompt,
    all: AgentToolCatalog.enabled,
  );
  for (final name in c.expectedTools) {
    expect(selection.names, contains(name),
        reason: '工具检索未选中 $name（${c.id}）');
  }

  final agent = AgentService();
  final executed = <String>[];
  var errors = 0;
  var stepIndex = 0;
  late AgentTurnTrace trace;

  agent.debugGenerateStepOverride = (messages, toolNames, t) async {
    if (stepIndex >= c.steps.length) {
      // 脚本耗尽仍被调用：返回兜底文本，便于定位
      return _modelResponse(
        [TextPart(text: '（脚本耗尽）')],
        messages,
      );
    }
    final step = c.steps[stepIndex++];
    if (step.tools.isEmpty) {
      return _modelResponse(
        [TextPart(text: step.text ?? 'done')],
        messages,
      );
    }
    for (final call in step.tools) {
      if (!toolNames.contains(call.name)) {
        throw StateError('模型调用了未下发的工具 ${call.name}（${c.id}）');
      }
    }
    return _modelResponse(
      [
        for (var i = 0; i < step.tools.length; i++)
          _request(
            step.tools[i].name,
            step.tools[i].args,
            '${c.id}-${stepIndex}-$i',
          ),
      ],
      messages,
    );
  };

  agent.debugExecuteToolsOverride = (requests) async {
    final responses = <ToolResponsePart>[];
    for (final request in requests) {
      final name = request.toolRequest.name;
      executed.add(name);
      final output = c.outputs[name] ?? 'ok:$name';
      if (output.startsWith('执行失败')) {
        errors++;
        trace.toolErrors++;
      }
      responses.add(
        _response(
          name,
          request.toolRequest.ref ?? '',
          output,
        ),
      );
    }
    return responses;
  };

  trace = AgentTurnTrace(
    turnId: c.id,
    provider: 'eval',
    model: 'scripted',
    toolsEnabled: true,
    promptChars: c.prompt.length,
    messageCount: 1,
    toolsOffered: selection.names.length,
  );

  try {
    var result = await agent.debugRunAgentLoop(
      initialMessages: [
        Message(role: Role.user, content: [TextPart(text: c.prompt)]),
      ],
      toolNames: selection.names,
      trace: trace,
    );

    // confirmAction 现在会暂停模型回合；评测脚本自动确认后继续。
    final pendingId = agent.debugPendingModelConfirmationId;
    if (result == null && pendingId != null) {
      executed.add(AgentService.confirmToolName);
      final confirmMsg = agent.messages.value.firstWhere(
        (m) => m.id == pendingId,
      );
      final choice = confirmMsg.confirmOptions?.isNotEmpty == true
          ? confirmMsg.confirmOptions!.first
          : '确认';
      agent.resolveConfirmation(pendingId, choice);
      for (var i = 0; i < 100; i++) {
        if (agent.debugPendingModelConfirmationId == null &&
            trace.finishReason != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      result = agent.debugLastModelConfirmationResponse;
    }

    expect(result, isNotNull, reason: c.id);
    expect(result!.text, contains(c.expectedText), reason: c.id);
  } finally {
    agent.dispose();
  }

  return (executed: executed, errors: errors, trace: trace);
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('评测集包含 33 个黄金任务', () {
    expect(_cases, hasLength(33));
    expect(_cases.map((c) => c.id).toSet().length, _cases.length);
  });

  for (final c in _cases) {
    test('eval/${c.id}', () async {
      final result = await _run(c);
      expect(result.executed, c.expectedTools, reason: '工具序列不符（${c.id}）');
      expect(result.errors, c.expectedErrors, reason: '工具失败数不符（${c.id}）');
      expect(result.trace.modelSteps, lessThanOrEqualTo(c.maxSteps),
          reason: '步数超限（${c.id}）');
      expect(result.trace.toolRequests, c.expectedTools.length,
          reason: '工具请求计数不符（${c.id}）');
      expect(result.trace.toolResponses, c.expectedTools.length,
          reason: '工具结果计数不符（${c.id}）');
    });
  }

  /// P3-1 评测闭环：30 例的回合记录都能落库，且聚合基线稳定。
  test('评测基线：全部用例可落库为回合记录', () async {
    var steps = 0;
    var requests = 0;
    var errors = 0;
    for (final c in _cases) {
      final result = await _run(c);
      final record = AgentTurnRecord.fromTrace(
        result.trace,
        sessionId: 'eval-baseline',
      );
      expect(record.turnId, c.id);
      expect(record.sessionId, 'eval-baseline');
      expect(record.detail, isNotNull, reason: 'detail 必须保留完整 trace');
      expect(record.parsedDetail['turnId'], c.id);
      // 工具业务失败（工具返回失败文本）不等于回合失败
      expect(record.status, 'ok', reason: '回合状态不符（${c.id}）');
      expect(record.toolRequests, c.expectedTools.length);
      expect(record.toolErrors, c.expectedErrors);
      steps += record.modelSteps;
      requests += record.toolRequests;
      errors += record.toolErrors;
    }
    final expectedRequests =
        _cases.fold<int>(0, (sum, c) => sum + c.expectedTools.length);
    final expectedErrors = _cases.fold<int>(0, (sum, c) => sum + c.expectedErrors);
    expect(requests, expectedRequests, reason: '聚合工具请求数偏离基线');
    expect(errors, expectedErrors, reason: '聚合工具失败数偏离基线');
    expect(steps, greaterThanOrEqualTo(_cases.length),
        reason: '每个用例至少一次模型步');
  });
}
