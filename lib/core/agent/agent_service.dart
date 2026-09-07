import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart'
    hide AgentState;
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_notification_service.dart';
import 'package:gstore/core/agent/agent_session_store.dart';
import 'package:gstore/core/agent/agent_skills.dart';
import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/platform_arch.dart';
import 'package:gstore/core/agent/tools/builtin_tools.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/cache_manage/cache_service.dart';
import 'package:gstore/page/cache_manage/state.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';

/// Agent 工具调用结果类型
enum AgentToolType {
  search,
  download,
  install,
  manageApp,
  appInfo,
  update,
  backup,
  manageDownload,
  theme,
  fdroid,
  webdav,
  installed,
  confirm,
  config,
}

/// 工具执行状态
enum AgentToolStatus { running, done, error }

/// Agent 会话级异步任务（下载等长任务）
///
/// 与 [AgentSession] 绑定（sessionId），完成回调只影响归属会话，
/// 防止会话切换时任务结果串扰。
class AgentAsyncTask {
  /// 任务唯一 ID
  final String id;

  /// 归属会话 ID（关键：防串扰）
  final String sessionId;

  /// 工具名（如 downloadApp）
  final String toolName;

  /// 启动时的回合 ID（绑定对话轮次）
  final String? turnId;

  /// 初始描述（如"下载 X"）
  final String detail;

  /// 是否已结束
  bool finished = false;

  /// 是否成功
  bool success = false;

  /// 终态消息（成功/失败描述）
  String message = '';

  /// 下载进度（下载工具专用，UI 进度条实时更新）
  DownloadTask? downloadStatus;

  AgentAsyncTask({
    required this.id,
    required this.sessionId,
    required this.toolName,
    this.turnId,
    required this.detail,
  });
}

/// Agent 对话消息（UI 层模型）
/// 支持流式文本更新与工具调用状态展示
class AgentMessage {
  /// 唯一 ID（用于流式更新）
  final String id;

  final bool isUser;

  /// 文本内容（可流式追加）
  String text;

  /// 工具类型
  final AgentToolType? toolType;

  /// 工具执行状态
  AgentToolStatus? toolStatus;

  /// 工具调用参数描述（如关键词/应用名）
  String? toolDetail;

  /// 下载状态（下载工具使用，用于显示进度）
  DownloadTask? downloadStatus;

  final DateTime time;

  /// 是否是工具消息
  final bool isToolResult;

  /// 消息序号（用于持久化后恢复顺序，实时按创建顺序递增）
  final int seq;

  /// 回合 ID（同一轮对话共享，用于绑定工具调用记录）
  final String? turnId;

  /// 确认工具的选项列表（多选一时使用；二选一时为 null）
  /// 仅运行时使用，不持久化（恢复历史时确认已解决，无需选项）
  List<String>? confirmOptions;

  /// 是否为多选模式（勾选多个选项后统一确认）。
  /// 仅运行时使用，不持久化（恢复历史时确认已解决）。
  bool confirmMultiSelect = false;

  /// 已勾选项集合（多选模式 UI 回传选中结果后置空）。
  List<String>? confirmSelected;

  AgentMessage({
    String? id,
    required this.isUser,
    required this.text,
    this.toolType,
    this.toolStatus,
    this.toolDetail,
    this.downloadStatus,
    this.isToolResult = false,
    DateTime? time,
    int? seq,
    this.turnId,
    this.confirmOptions,
  })  : id = id ?? _generateId(),
        time = time ?? DateTime.now(),
        seq = seq ?? _seqCounter++;

  static int _idCounter = 0;
  static String _generateId() => 'msg-${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

  /// 全局序号计数器（跨会话递增，保证顺序唯一）
  static int _seqCounter = 0;

  /// 追加流式文本
  void appendText(String t) {
    text += t;
  }
}

/// Agent 服务
/// 基于 Google Genkit 的对话式应用管理助手
/// 支持：
/// - 搜索应用（跨渠道）
/// - 下载应用
/// - 安装应用
class AgentService {
  /// 工具名称常量
  static const String searchToolName = 'searchApp';
  static const String downloadToolName = 'downloadApp';
  static const String installToolName = 'installApp';
  static const String manageAppToolName = 'manageApp';
  static const String appInfoToolName = 'getAppInfo';
  static const String updateAppsToolName = 'updateApps';
  static const String backupToolName = 'backup';
  static const String manageDownloadToolName = 'manageDownload';
  static const String themeToolName = 'themeControl';
  static const String fdroidRepoToolName = 'fdroidRepo';
  static const String webdavSyncToolName = 'webdavSync';
  static const String installedAppsToolName = 'installedApps';
  static const String channelAppToolName = 'channelApp';
  static const String configManagerToolName = 'configManager';
  static const String runJsChannelToolName = 'runJsChannel';
  static const String cacheManageToolName = 'cacheManage';

  Genkit? _ai;
  AgentModel? _model;
  AgentModelStore? _store;
  AgentSessionStore? _sessionStore;
  List<Message> _messages = [];
  bool _initialized = false;
  bool _busy = false;

  /// 是否正在生成回复（响应式：页面/通知订阅，脱离页面仍可感知）
  final ValueNotifier<bool> busy = ValueNotifier(false);

  /// 已注册的 Agent 工具模块（内置 + 模块化热插拔工具）
  final List<AgentToolModule> _agentTools = [];

  /// 工具执行上下文（委托到 AgentService 内部实现）
  late final AgentToolContext _toolContext = AgentToolContext(
    executeDelegate: (toolName, params) => _executeTool(toolName, params),
    stopRequested: () => _cancelRequested,
  );

  /// 注册 Agent 工具模块（上线；幂等去重）
  void registerAgentTools(List<AgentToolModule> tools) {
    for (final tool in tools) {
      if (_agentTools.any((t) => t.toolName == tool.toolName)) continue;
      _agentTools.add(tool);
      appLog.info('AgentService: 工具上线 - ${tool.toolName}');
    }
  }

  /// 注销 Agent 工具模块（下线）
  void unregisterAgentTools(List<String> toolNames) {
    final names = toolNames.toSet();
    _agentTools.removeWhere((t) {
      final removed = names.contains(t.toolName);
      if (removed) {
        appLog.info('AgentService: 工具下线 - ${t.toolName}');
      }
      return removed;
    });
  }

  /// 当前全部已注册工具名（模型可调用清单）
  List<String> get registeredToolNames =>
      _agentTools.map((t) => t.toolName).toList();

  /// 执行工具（模块化工具委托入口；测试可直接调用）
  Future<String> runTool(String toolName, Map<String, dynamic> params) =>
      _executeTool(toolName, params);

  /// 分发工具执行到对应实现（模块 execute 的委托目标）
  Future<String> _executeTool(String toolName, Map<String, dynamic> params) {
    switch (toolName) {
      case searchToolName:
        return _searchApps(params['keyword']?.toString() ?? '');
      case downloadToolName:
        return _downloadApp(
          params['appId']?.toString() ?? '',
          params['channel']?.toString() ?? '',
          params['url']?.toString() ?? '',
          params['name']?.toString() ?? '',
          params['version']?.toString() ?? '',
          vivoId: params['vivoId']?.toString(),
          installAfterDownload:
              params['installAfterDownload'] == true ||
              params['installAfterDownload'] == 'true',
        );
      case installToolName:
        return _installApp(params['savePath']?.toString() ?? '');
      case manageAppToolName:
        return _manageApp(
          params['action']?.toString() ?? '',
          params['appId']?.toString() ?? '',
          params['channel']?.toString() ?? '',
          params['name']?.toString() ?? '',
        );
      case channelAppToolName:
        return _manageChannelApp(
          params['action']?.toString() ?? '',
          params['appId']?.toString() ?? '',
          params['channel']?.toString() ?? '',
          params['name']?.toString() ?? '',
        );
      case appInfoToolName:
        return _getAppInfo(
          params['appId']?.toString() ?? '',
          params['channel']?.toString() ?? '',
        );
      case updateAppsToolName:
        return _checkUpdates(
          params['appId']?.toString() ?? '',
          params['channel']?.toString() ?? '',
        );
      case backupToolName:
        return _backup(
          params['action']?.toString() ?? '',
          params['filePath']?.toString() ?? '',
        );
      case manageDownloadToolName:
        return _manageDownloads(
          params['action']?.toString() ?? '',
          params['fileName']?.toString() ?? '',
        );
      case themeToolName:
        return _controlTheme(
          params['action']?.toString() ?? '',
          params['mode']?.toString() ?? '',
          params['hexColor']?.toString() ?? '',
        );
      case fdroidRepoToolName:
        return _fdroidRepo(
          params['action']?.toString() ?? '',
          params['keyword']?.toString() ?? '',
          params['force']?.toString() == 'true',
        );
      case webdavSyncToolName:
        return _webdavSync(params['action']?.toString() ?? '');
      case configManagerToolName:
        return _configManager(
          params['action']?.toString() ?? '',
          params['key']?.toString() ?? '',
          params['value'],
        );
      case installedAppsToolName:
        return _installedApps(
          params['action']?.toString() ?? '',
          params['keyword']?.toString() ?? '',
          params['packageName']?.toString() ?? '',
        );
      case confirmToolName:
        return _confirmAction(params);
      case cacheManageToolName:
        return _cacheManageAction(params);
      case runJsChannelToolName:
        return _runJsChannel(
          params['channel']?.toString() ?? '',
          params['method']?.toString() ?? '',
          params['params'],
        );
      default:
        // 尝试模块化工具自身的 execute（可扩展执行体）
        for (final tool in _agentTools) {
          if (tool.toolName == toolName) {
            return tool.execute(_toolContext, params);
          }
        }
        return Future.value('未知工具: $toolName');
    }
  }

  /// 确认工具执行（用户确认/选项选择/多选勾选）
  Future<String> _confirmAction(Map<String, dynamic> params) async {
    final question = params['question']?.toString() ?? '';
    List<String>? options;
    final optRaw = params['options'];
    if (optRaw is List) {
      options =
          optRaw.map((o) => o.toString()).where((o) => o.isNotEmpty).toList();
    } else if (optRaw is String && optRaw.trim().isNotEmpty) {
      options = optRaw
          .split(RegExp(r'[,，]'))
          .map((o) => o.trim())
          .where((o) => o.isNotEmpty)
          .toList();
    }
    if (options != null && options.isEmpty) options = null;
    // 多选模式：模型传 multiSelect=true（或 multiSelect='true'）
    final multiSelect = params['multiSelect'] == true ||
        params['multiSelect']?.toString() == 'true';
    return _requestUserConfirmation(question,
        options: options, multiSelect: multiSelect);
  }

  /// 下载文件选项前缀（与 _cacheManageAction 解析保持一致）
  static const String _dlFilePrefix = '[下载文件] ';

  /// 缓存管理工具执行（枚举 → 多选 → 清理）
  ///
  /// 一次调用完成：
  /// 1. 扫描缓存类别（网络图片/README/图标/通用/内存/临时等）与下载目录文件
  /// 2. 发起多选确认，用户勾选要清理的内容（可同时勾缓存类别与下载文件）
  /// 3. 按勾选执行清理，返回结果汇总
  Future<String> _cacheManageAction(Map<String, dynamic> params) async {
    // 工具执行前定稿流式文本（与其它工具一致）
    _commitActiveStreamText();

    final service = CacheManageService.instance;
    // 1. 枚举缓存类别与下载文件
    String categoriesText;
    final cacheNames = <String>[];
    try {
      final cats = await service.cacheCategorySizes();
      cacheNames.addAll(cats.map((c) => c.$2));
      // 过滤占用为 0 的类别（无可清理内容不展示）
      final nonEmpty = cats.where((c) => c.$3 > 0).toList();
      categoriesText = nonEmpty.isEmpty
          ? '（当前无可清理的缓存）'
          : nonEmpty.map((c) => '${c.$2}(${byteSize(c.$3)})').join('、');
    } catch (e) {
      appLog.error('AgentService: cacheManage 枚举缓存失败 - $e');
      categoriesText = '（枚举失败）';
    }

    // 下载目录文件（跳过下载残留分片）
    final files = <DownloadedFileItem>[];
    try {
      final (items, _) = await service.scanDownloads();
      files.addAll(items);
    } catch (e) {
      appLog.error('AgentService: cacheManage 枚举下载失败 - $e');
    }

    if (categoriesText == '（当前无可清理的缓存）' && files.isEmpty) {
      return '当前没有可清理的缓存或已下载文件，无需清理。';
    }

    // 2. 组装选项并多选确认
    final options = <String>[
      if (categoriesText != '（当前无可清理的缓存）') ...cacheNames,
      ...files.map((f) => '$_dlFilePrefix${f.fileName}'),
    ];
    // 控制单次选项数量（避免过长）
    if (options.length > 12) {
      return '可清理项较多（缓存 ${options.length} 项），'
          '建议打开「缓存管理」页手动选择清理。'
          '当前缓存概况：$categoriesText'
          '${files.isNotEmpty ? '；已下载文件 ${files.length} 个' : ''}。';
    }

    final question = StringBuffer('请勾选要清理的内容（可多选）：\n');
    if (categoriesText != '（当前无可清理的缓存）') {
      question.write('缓存：$categoriesText\n');
    }
    if (files.isNotEmpty) {
      question.write('已下载文件：${files.length} 个（删除后不可恢复）');
    }
    final choice = await _requestUserConfirmation(
      question.toString().trim(),
      options: options,
      multiSelect: true,
    );
    if (choice == '用户已取消' || choice == '已取消') {
      return '已取消清理';
    }
    // 返回形如 "用户已选择：A、B" → 取 "：" 后拆分
    final selectedRaw = choice.contains('：')
        ? choice.substring(choice.indexOf('：') + 1)
        : choice;
    final selected = selectedRaw
        .split('、')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (selected.isEmpty) {
      return '未选择任何清理项';
    }

    // 3. 分类执行：缓存类别名 → clearByNames；下载文件前缀 → deleteDownloads
    final cacheNamesSelected = selected
        .where((s) => !s.startsWith(_dlFilePrefix))
        .toList();
    final fileNames = selected
        .where((s) => s.startsWith(_dlFilePrefix))
        .map((s) => s.substring(_dlFilePrefix.length))
        .toList();

    final results = <String>[];
    if (cacheNamesSelected.isNotEmpty) {
      try {
        final ok = await service.clearByNames(cacheNamesSelected);
        results.add('已清理缓存 $ok 项');
      } catch (e) {
        appLog.error('AgentService: 清理缓存失败 - $e');
        results.add('缓存清理失败');
      }
    }
    if (fileNames.isNotEmpty) {
      final paths = files
          .where((f) => fileNames.contains(f.fileName))
          .map((f) => f.filePath)
          .toList();
      try {
        final ok = await service.deleteDownloads(paths);
        results.add('已删除下载文件 $ok 个');
      } catch (e) {
        appLog.error('AgentService: 删除下载文件失败 - $e');
        results.add('下载文件删除失败');
      }
    }
    return results.isEmpty ? '未执行任何清理' : results.join('；');
  }

  /// 是否请求停止当前生成（用户点击停止按钮）
  bool _cancelRequested = false;

  /// 当前正在累积文本的流式助手消息
  /// 工具调用时将其"定稿"为独立 agent 消息，实现文本被工具调用分割
  AgentMessage? _activeStreamMsg;

  /// 当前正在执行的下载任务状态（停止时取消）
  DownloadTask? _currentDownloadStatus;

  /// 当前工具下载进度订阅（taskId → subscription），终态后移除
  final Map<int, StreamSubscription<DownloadTask>> _downloadWatchSubs = {};

  /// 当前正在执行的工具消息（供下载等长任务通过 handler 回调实时更新进度卡）
  AgentMessage? _currentToolMsg;

  /// 当前正在执行的异步任务（下载等；完成回调经 onFinished 定位归属会话）
  AgentAsyncTask? _currentAsyncTask;

  /// 会话级异步任务表（key = sessionId → 该会话的任务列表）。
  ///
  /// 异步工具（下载等）启动时记录归属会话，完成时**只对归属会话生效**：
  /// - 更新归属会话的持久化工具消息（切走/重启后仍可见）
  /// - 仅当归属会话 == 当前会话且页面可见时，更新当前 UI 消息卡 + 触发 agent 续接
  /// 防止"会话 A 的任务结果串扰到会话 B"。
  final Map<String, List<AgentAsyncTask>> _sessionTasks = {};

  /// 当前活跃任务 ID → 任务（用于完成回调快速定位）
  final Map<String, AgentAsyncTask> _tasksById = {};

  /// 记录一次异步工具启动（下载等），绑定归属会话
  AgentAsyncTask _registerAsyncTask({
    required String toolName,
    required String detail,
  }) {
    final sessionId = _sessionStore?.current?.id ?? '';
    final task = AgentAsyncTask(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: sessionId,
      toolName: toolName,
      turnId: _currentTurnId,
      detail: detail,
    );
    _sessionTasks.putIfAbsent(sessionId, () => []).add(task);
    _tasksById[task.id] = task;
    return task;
  }

  /// 异步任务终态处理（**会话绑定**，防切换串扰）。
  ///
  /// 规则：
  /// 1. 更新任务记录（finished/success/message）并持久化到**归属会话**的消息列表
  ///    （切走会话/重启后切回仍可见结果）；
  /// 2. 仅当任务归属会话 == 当前会话，且 AI 页在前台时：
  ///    更新当前 UI 消息卡（running → done/error）+ 触发 agent 续接生成；
  /// 3. 否则（已切走/页面不可见）：不触碰当前对话，只落库 + 后台通知。
  void _finalizeAsyncTask({
    required AgentAsyncTask? task,
    required bool success,
    required String message,
  }) {
    final t = task;
    if (t == null) return;
    t.finished = true;
    t.success = success;
    t.message = message;

    // 持久化到归属会话（不依赖"当前会话"）
    _persistAsyncTaskToSession(t);

    // 归属会话仍是当前会话 → 更新 UI 消息卡 + 触发续接
    final currentSessionId = _sessionStore?.current?.id;
    if (t.sessionId.isNotEmpty && t.sessionId == currentSessionId) {
      // 更新当前 UI 中的对应工具消息（running → done/error）
      final idx = messages.value.indexWhere((m) =>
          m.isToolResult &&
          m.toolType == AgentToolType.download &&
          m.toolStatus == AgentToolStatus.running &&
          (t.turnId == null || m.turnId == t.turnId));
      if (idx >= 0) {
        _updateToolMessage(
          messages.value[idx],
          status: success ? AgentToolStatus.done : AgentToolStatus.error,
          detail: message,
        );
      }
      // 页面在前台且不忙 → 触发 agent 续接（如"下载完成，是否安装？"）
      if (_isAgentPageVisible()) {
        _continueAfterAsyncTool(success, message);
      }
    }
    // 已切走：只通知（B2），不注入对话、不续接
    _publishToolDoneNotification(
      success: success,
      toolLabel: _toolLabelForName(t.toolName),
      message: message,
    );
  }

  /// 把异步任务终态写入归属会话的持久化消息（切回/重启后可见）
  void _persistAsyncTaskToSession(AgentAsyncTask task) {
    final store = _sessionStore;
    if (store == null) return;
    final session = store.sessions
        .where((s) => s.id == task.sessionId)
        .firstOrNull;
    if (session == null) return;
    // 找到该会话中对应的 running 下载工具消息，更新为终态
    for (var i = 0; i < session.messages.length; i++) {
      final m = session.messages[i];
      if (m.isToolResult &&
          m.toolType == AgentToolType.download.name &&
          m.toolStatus == AgentToolStatus.running.name &&
          (task.turnId == null || m.turnId == task.turnId)) {
        session.messages[i] = SessionMessage(
          isUser: false,
          text: task.message,
          isToolResult: true,
          toolType: m.toolType,
          toolStatus: task.success
              ? AgentToolStatus.done.name
              : AgentToolStatus.error.name,
          toolDetail: task.message,
          time: m.time,
          seq: m.seq,
          turnId: m.turnId,
          confirmOptions: m.confirmOptions,
        );
        session.updatedAt = DateTime.now().millisecondsSinceEpoch;
        store.save();
        _syncSessionCache(session);
        return;
      }
    }
  }

  /// 用户确认回调（view 注入，弹确认 UI）
  /// 参数为确认问题，返回 true=用户确认，false=取消
  Future<bool> Function(String question)? onConfirmRequest;

  /// 待确认的请求（key = 确认消息 id）
  /// UI 通过 [resolveConfirmation] 完成对应 Completer，
  /// 值为用户选择（多选一时为所选选项，二选一时为 '确认'/'取消'）
  final Map<String, Completer<String>> _pendingConfirmations = {};

  /// 工具名称常量：确认工具
  static const String confirmToolName = 'confirmAction';

  /// 工具执行控制器（AiActionProvider 原生工具调用）
  ActionController _actionController = ActionController();

  /// 工具执行控制器（view 注入，供 AiActionProvider 使用）
  ActionController get actionController => _actionController;

  /// 已持久化的工具消息 ID（避免同一工具运行→完成时重复新增记录）
  final Set<String> _persistedToolIds = {};

  /// 当前回合 ID（chat() 内设置，该轮的用户/助手/工具消息共享）
  String? _currentTurnId;

  /// 当前会话全量消息缓存（按 seq 排序），用于分页加载
  List<SessionMessage> _allSessionMessages = [];

  /// 已加载到 UI 的消息条数（从最新往前的数量）
  int _loadedMessageCount = 0;

  /// 分页加载初始条数
  /// 首次加载的完整回合数（每个回合 = 用户消息 + 对应 agent/工具回复）
  static const int initialTurnsCount = 5;

  /// 是否正在分页加载历史（分页期间禁止自动滚动到底，避免加载更多后跳回底部）
  bool isPaginatingHistory = false;

  /// 是否还有更早的历史消息可加载
  bool get hasMoreHistory => _loadedMessageCount < _allSessionMessages.length;

  /// 当前已加载的历史条数
  int get loadedHistoryCount => _loadedMessageCount;

  /// 是否初始化成功
  bool get isInitialized => _initialized;

  /// 是否正在生成回复
  bool get isBusy => _busy;

  /// 当前使用的模型
  AgentModel? get model => _model;

  /// 模型存储
  AgentModelStore? get store => _store;

  /// 会话存储
  AgentSessionStore? get sessionStore => _sessionStore;

  /// 当前会话
  AgentSession? get currentSession => _sessionStore?.current;

  /// 所有会话
  List<AgentSession> get sessions => _sessionStore?.sessions ?? [];

  /// 当前会话 ID
  String? get currentSessionId => _sessionStore?.currentSessionId;

  /// 对话消息（UI 监听；快照列表，元素对象引用稳定，字段变化后显式 notify）
  final ValueNotifier<List<AgentMessage>> messages =
      ValueNotifier(const []);

  /// 发布消息列表变更（结构性增删/整体替换后调用）。
  void _notifyMessages() => messages.value = List.of(messages.value);

  /// 追加一条消息（尾部）。
  void _addMessage(AgentMessage m) => messages.value = [...messages.value, m];

  /// 移除一条消息（按对象引用）。
  void _removeMessage(AgentMessage m) =>
      messages.value = messages.value.where((e) => e != m).toList();

  /// 头部插入更早历史消息。
  void _prependMessages(List<AgentMessage> older) =>
      messages.value = [...older, ...messages.value];

  /// 清空全部消息。
  void _clearMessages() => messages.value = const [];

  /// 系统提示词（含设备架构信息）
  String get _systemPrompt => '''
你是 GStore 软件商店的智能助手。你帮助用户搜索、下载和安装开源应用，并管理应用、备份、主题等。

${PlatformArch.platformDescription}

可用工具：
1. searchApp - 搜索应用。输入 keyword（关键词）。返回匹配的应用列表（含名称、包名、简介、来源渠道）。支持 GitHub 渠道（走代理搜索仓库）。
2. downloadApp - 下载应用。输入 appId（包名/仓库名）、channel（渠道代码，如 github/fdroid/vivo）、url（下载地址，可选）、name（应用名）、version（版本号）。GitHub 渠道时系统会自动选择匹配当前 CPU 架构的 APK。vivo 渠道需传 vivoId。如需下载完成后自动安装，传入 installAfterDownload=true；仅说下载则不传。下载完成后自动解析 APK 获取真实包名/图标/应用名并更新。
3. installApp - 安装已下载的 APK。输入 savePath（APK 文件路径）。
4. manageApp - 管理"我的应用"列表（首页聚合）。action 为 list/add/remove/isAdded。
5. channelApp - 管理应用渠道中的已添加应用（渠道数据库）。action 为 list（列出渠道应用，需 channel）、add（添加应用到渠道，需 appId+channel+name）、remove（从渠道移除，需 appId+channel）。GitHub 渠道 appId 用 owner/repo（如 termux/termux-app）。
6. getAppInfo - 获取应用详情或检查版本。输入 appId、channel。
7. updateApps - 检查应用更新。appId 和 channel 可选（不传则检查全部已添加应用）。返回每个已安装应用是否有更新（当前版本 → 最新版本）。
8. backup - 备份/恢复应用数据。action 为 export/import。
9. manageDownload - 管理下载任务。action 为 list/pause/resume/cleanCompleted/clearAll。
10. themeControl - 控制主题。action 为 mode/toggle/color。
11. fdroidRepo - 管理 F-Droid 仓库。action 为 list/load/search/stats。
12. webdavSync - WebDAV 云备份。action 为 list（查询网盘备份数据列表）/upload/download/status。
13. installedApps - 管理已安装应用。action 为 list/check/uninstall/clearData/clearCache/forceStop。卸载/清理/停止需 Shizuku 授权。
 14. confirmAction - 向用户发起确认或选择。输入 question（确认问题，需清晰说明要执行的操作）。用于敏感/不可逆操作；需要用户选择时传 options（选项数组或逗号分隔），需要用户**多选**（勾选多个）时再传 multiSelect=true。用户需在界面上确认/勾选。
15. cacheManage - 管理缓存与已下载文件（清理/释放空间）。无需参数：工具会枚举当前可清理项（缓存类别 + 已下载 APK）并弹多选框让用户勾选，确认后清理。
16. configManager - 管理应用配置。action 为 list（列出可配置项）/get（读取，需 key）/set（修改，需 key 和 value）/clear（清除，需 key）。修改后相关功能自动生效。敏感配置读取脱敏。

敏感操作清单（执行前**必须**调用 confirmAction 让用户确认）：
- 卸载应用（installedApps 的 uninstall）
- 清理应用数据/缓存（installedApps 的 clearData/clearCache）
- 强制停止应用（installedApps 的 forceStop）
- 恢复备份/覆盖现有数据（backup 的 import 且会影响当前数据）
- 删除会话/清空数据（manageDownload 的 clearAll、backup 相关删除）
- 移除"我的应用"或渠道中的应用（manageApp remove / channelApp remove）
- 清理缓存/删除已下载文件（cacheManage，会弹多选框让用户勾选）
- 其他不可逆或影响较大的操作

确认流程：先调用 confirmAction 展示操作内容，用户确认后再执行实际操作；用户取消则不要执行并告知用户。

选项选择场景（也必须调用 confirmAction，带 options 让用户选择）：
- 用户需要决策时：如"你想怎么处理""要不要继续""用哪个版本""选哪个方案"等
- 多选一：当存在 2 个以上合理选项时，用 options 传入选项数组，让用户点选
- 多选：需要用户勾选多项（如清理时勾选多个缓存/下载文件）时，传 options 并加 multiSelect=true；返回结果含被选项
- 示例：卸载应用前问"卸载后是否保留数据？"（options: ["保留数据", "清除数据"]）
- 示例：安装多个版本时问"安装哪个版本？"（options: ["稳定版", "测试版"]）
- 用户犹豫/征求建议且涉及实际执行时，优先用 confirmAction 给选项，而不是只回文字

注意：不要因为"不确定是否该调用"而跳过 confirmAction——只要涉及上述敏感操作或选择决策，就应调用。

使用规则：
- 用户要求"找/搜索/看看有没有 XX 应用"时，先调用 searchApp。
- 推荐策略：优先推荐开源应用（GitHub、F-Droid 渠道）；若开源无合适应用或用户明确要热门的，可推荐用户量更大的非开源应用（vivo 渠道）。推荐时标注来源渠道。
- 用户要求"下载 XX"时，用 searchApp 找到后调用 downloadApp。
- 用户要求"添加 XX 到我的应用"/"移除 XX"/"我的应用有哪些"时，调用 manageApp。
- 用户要求"添加 XX 到 XX 渠道"/"从渠道删除/移除 XX"/"XX 渠道有哪些应用"时，调用 channelApp。
- 用户要求"检查更新"/"更新 XX"时，调用 updateApps。
- 用户要求"备份"/"恢复"时，调用 backup。
- 用户要求"暂停/恢复/清理下载"时，调用 manageDownload。
- 用户要求"切换主题/换颜色"时，调用 themeControl。
- 用户要求"我装了什么应用"/"XX 装了吗"时，调用 installedApps。
- 用户要求"清理缓存""释放空间""删除下载的安装包/APK""清理下载文件"时，调用 cacheManage。
- 用户要求修改应用配置（如"修改下载设置""设置代理""修改更新策略""查看配置"）时，调用 configManager（list/get/set/clear），修改后功能自动生效。
- 若用户只说"下载"则仅下载不安装；若用户明确要求下载后安装，在 downloadApp 中传 installAfterDownload=true（Agent 会话内不再主动询问安装）。
- 执行上述敏感操作前，先调用 confirmAction 让用户确认；用户确认后再执行。
- 用户需要做选择或表达犹豫（"怎么弄""选哪个""要不要"等）时，调用 confirmAction 并提供 options 选项，让用户直接点选。
- 回答简洁，中文回复。当用户提到具体应用时，给出推荐并询问是否下载。

技能知识库（遇到对应场景时，严格按技能中的步骤执行）：
${AgentSkills.renderAll(language: PromptLanguage.zh)}

错误处理指引：
- 工具返回错误或异常时，先向用户说明问题，再给出可行的下一步建议，不要假装操作成功。
- 搜索无结果时：提示"未找到相关应用"，并建议用户换关键词、或检查网络/渠道是否可用。
- 下载失败时：提示可能原因（网络、URL 失效、服务器不支持断点续传等），并建议重试或换渠道。
- 下载地址获取失败时：提示"暂时无法获取该应用的下载地址"，可建议用户到详情页手动查看。
- 应用已下载但安装失败时：提示检查 APK 完整性，或建议手动从下载中心安装。
- 备份/恢复失败时：提示检查存储权限或文件路径是否正确。
- WebDAV 未配置时：明确提示"请先在设置中配置 WebDAV 网盘"。
- 模型/API 调用失败时：提示检查 API Key 配置、网络连接，或建议更换模型。
- 不确定如何操作时：明确告知能力边界，给出替代方案，不要编造不存在的功能。
- 所有失败情况：都要避免重复无意义的重试，及时告知用户当前状态。
''';

  /// 初始化 Agent（加载模型存储并初始化当前选中模型）
  Future<bool> initialize() async {
    _store = await AgentModelStore.load();
    _model = _store!.selected;
    _subscribeModelChanges();

    // 加载会话存储
    _sessionStore = await AgentSessionStore.load();
    // 确保有当前会话
    if (_sessionStore!.current == null) {
      await _sessionStore!.createSession(title: '新对话');
    }
    _loadSessionMessages();

    if (_model == null || !_model!.isConfigured) {
      appLog.error('AgentService: 未配置模型');
      _initialized = false;
      return false;
    }

    try {
      // 检测当前设备 CPU 架构（用于 GitHub 下载匹配）
      await PlatformArch.detectAbi();

      // 根据模型构建插件（使用局部变量让类型推断处理）
      final plugin = _buildPlugin(_model!);
      _ai = Genkit(plugins: [plugin]);

      // 注册 Agent 工具模块（默认全部上线；优先从 ModuleManager 拉取已注册工具）
      if (_agentTools.isEmpty) {
        // 通过模块中心注册的工具模块
        final toolsModule = ModuleManager.instance.getModule('agent_tools');
        if (toolsModule is AgentToolsModule) {
          registerAgentTools(toolsModule.tools);
        }
        if (_agentTools.isEmpty) {
          registerAgentTools(BuiltinAgentTools.all);
        }
      }

      // 定义工具
      _defineTools();

      _messages = [
        Message(
          role: Role.system,
          content: [TextPart(text: _systemPrompt)],
        ),
      ];
      // 从当前会话加载历史消息到 Genkit 上下文
      _restoreMessagesFromSession();

      _initialized = true;
      appLog.info(
          'AgentService: 初始化成功 provider=${_model!.provider.name} model=${_model!.effectiveModel} abi=${PlatformArch.abi} sessions=${_sessionStore!.sessions.length}');
      return true;
    } catch (e) {
      appLog.error('AgentService: 初始化失败 - $e');
      _initialized = false;
      return false;
    }
  }

  /// 加载当前会话消息到 UI（分页：仅加载最近的 [initialTurnsCount] 个完整回合）
  /// 以用户消息为锚点：从尾部往前找最近的 N 条用户消息，
  /// 加载从最早那条用户消息到末尾的全部消息（完整回合，避免切分对话）
  void _loadSessionMessages() {
    _persistedToolIds.clear();
    final session = _sessionStore?.current;
    if (session == null) {
      _clearMessages();
      _allSessionMessages = [];
      _loadedMessageCount = 0;
      return;
    }
    // 按 time 排序（真实创建时间，seq 作 tiebreaker，原始顺序兜底保证稳定）
    // 注：Dart List.sort 不稳定，同一毫秒 + 同 seq 时需用持久化顺序兜底，
    // 否则 agent 回复可能排到用户消息前面（乱序）。
    final indexed = session.messages.asMap().entries.toList();
    indexed.sort((a, b) {
      final t = a.value.time.compareTo(b.value.time);
      if (t != 0) return t;
      final s = a.value.seq.compareTo(b.value.seq);
      if (s != 0) return s;
      return a.key.compareTo(b.key);
    });
    _allSessionMessages = indexed.map((e) => e.value).toList();

    // 推进全局 seq 计数器到最大历史 seq + 1，
    // 防止应用重启后（_seqCounter 重置为 0）新消息 seq 与历史消息冲突导致顺序错乱
    if (_allSessionMessages.isNotEmpty) {
      final maxSeq = _allSessionMessages
          .map((m) => m.seq)
          .reduce((a, b) => a > b ? a : b);
      if (maxSeq >= AgentMessage._seqCounter) {
        AgentMessage._seqCounter = maxSeq + 1;
      }
    }

    // 从尾部往前找最近的 initialTurnsCount 个用户回合的锚点
    var anchorStart = 0;
    var userCount = 0;
    for (var i = _allSessionMessages.length - 1; i >= 0; i--) {
      if (_allSessionMessages[i].isUser) {
        userCount++;
        if (userCount >= initialTurnsCount) {
          anchorStart = i;
          break;
        }
      }
    }
    // 不足 initialTurnsCount 个回合时从 0 开始（加载全部）
    if (userCount < initialTurnsCount) {
      anchorStart = 0;
    }

    _loadedMessageCount = _allSessionMessages.length - anchorStart;
    messages.value = _buildAgentMessages(
      _allSessionMessages.sublist(anchorStart),
    );

    // B3：重启后恢复"待确认"交互——为 running 的确认消息重新注册 completer，
    // 用户重新进入页面点确认/取消仍能完成工具等待（原 completer 在内存中已丢失）
    _restorePendingConfirmations();
  }

  /// 为持久化的 running 确认消息重新注册等待 completer（重启/重进恢复交互）
  void _restorePendingConfirmations() {
    for (final msg in messages.value) {
      if (msg.isToolResult &&
          msg.toolType == AgentToolType.confirm &&
          msg.toolStatus == AgentToolStatus.running) {
        if (!_pendingConfirmations.containsKey(msg.id)) {
          final completer = Completer<String>();
          _pendingConfirmations[msg.id] = completer;
          // 挂起等待：resolveConfirmation 完成时收尾消息状态
          unawaited(completer.future.then((choice) {
            // 先清持久化中的 running 记录，避免重启后残留"待确认"UI
            _clearPendingConfirmation(msg.id);
            if (choice.isEmpty || choice == '取消') {
              _updateToolMessage(msg, status: AgentToolStatus.error, detail: '已取消');
            } else {
              _updateToolMessage(
                msg,
                status: AgentToolStatus.done,
                detail: msg.confirmOptions != null && msg.confirmOptions!.isNotEmpty
                    ? '已选择：$choice'
                    : '已确认',
              );
            }
            _pendingConfirmations.remove(msg.id);
            AgentNotificationService.instance.onConfirmResolved();
          }).catchError((_) {}));
        }
      }
    }
  }

  /// 加载更早的一组完整对话（以用户消息为锚点）
  /// 从尾部未加载区域往前找最近的一条用户消息，
  /// 加载该用户消息及其后续全部消息（该用户回合的完整事件线），
  /// 保证每次加载都能补全一组完整对话，而非按固定条数切分。
  /// 返回本次新增的 AgentMessage 列表（view 用于增量同步到 controller）
  List<AgentMessage> loadMoreHistory() {
    if (!hasMoreHistory) return const [];

    // 未加载区域：[0, unloadedEnd)，其中 unloadedEnd = L - loaded
    final unloadedEnd = _allSessionMessages.length - _loadedMessageCount;
    if (unloadedEnd <= 0) return const [];

    // 从未加载区域末尾往前找最近的用户消息作为锚点
    var anchor = unloadedEnd - 1;
    while (anchor >= 0 && !_allSessionMessages[anchor].isUser) {
      anchor--;
    }
    // 锚点 = 用户消息位置（含），加载它及后续全部未加载消息
    final from = anchor < 0 ? 0 : anchor;
    final count = unloadedEnd - from;
    final older = _buildAgentMessages(
      _allSessionMessages.sublist(from, from + count),
    );
    // 插入头部（更早消息在前）
    _prependMessages(older);
    _loadedMessageCount += count;
    appLog.info('AgentService: 加载更早历史 $count 条 (累计 $_loadedMessageCount)');
    return older;
  }

  /// 将 SessionMessage 列表构建为 AgentMessage 列表
  List<AgentMessage> _buildAgentMessages(List<SessionMessage> list) {
    return list.map((m) {
      if (m.isToolResult) {
        // 工具消息：还原工具类型/状态/详情
        final message = AgentMessage(
          isUser: false,
          text: m.text,
          toolType: _toolTypeFromName(m.toolType),
          toolStatus: _toolStatusFromName(m.toolStatus),
          toolDetail: m.toolDetail,
          isToolResult: true,
          time: DateTime.fromMillisecondsSinceEpoch(m.time),
          seq: m.seq,
          turnId: m.turnId,
          confirmOptions: m.confirmOptions,
        );
        // 多选标记（运行时字段，持久化恢复后补设）
        if (m.confirmMultiSelect) {
          message.confirmMultiSelect = true;
        }
        return message;
      } else {
        return AgentMessage(
          isUser: m.isUser,
          text: m.text,
          isToolResult: false,
          time: DateTime.fromMillisecondsSinceEpoch(m.time),
          seq: m.seq,
          turnId: m.turnId,
        );
      }
    }).toList();
  }

  /// 工具类型枚举名 → AgentToolType
  AgentToolType? _toolTypeFromName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final t in AgentToolType.values) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 工具状态枚举名 → AgentToolStatus
  AgentToolStatus? _toolStatusFromName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final s in AgentToolStatus.values) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 从会话恢复 Genkit 上下文消息
  /// 跳过工具消息（避免向 LLM 注入冗长工具记录，仅保留用户/助手文本）
  void _restoreMessagesFromSession() {
    if (_allSessionMessages.isEmpty) return;
    for (final m in _allSessionMessages) {
      if (m.isToolResult) continue;
      _messages.add(Message(
        role: m.isUser ? Role.user : Role.model,
        content: [TextPart(text: m.text)],
      ));
    }
  }

  /// 根据模型构建 Genkit 插件
  dynamic _buildPlugin(AgentModel model) {
    switch (model.provider) {
      case AgentLlmProvider.google:
        return googleAI(apiKey: model.apiKey);
      case AgentLlmProvider.openai:
        return openAI(
          name: 'custom',
          apiKey: model.apiKey,
          baseUrl: model.effectiveBaseUrl,
        );
    }
  }

  /// 获取当前使用的模型引用
  ModelRef<dynamic> _getModelRef(AgentModel model) {
    switch (model.provider) {
      case AgentLlmProvider.google:
        return googleAI.gemini(model.effectiveModel) as ModelRef<dynamic>;
      case AgentLlmProvider.openai:
        return openAI.model(
          model.effectiveModel,
          namespace: 'custom',
        ) as ModelRef<dynamic>;
    }
  }

  /// 重新加载配置并初始化（保存新配置后调用）
  Future<bool> reconfigure() async {
    _initialized = false;
    _ai = null;
    return initialize();
  }

  /// 模型切换订阅
  StreamSubscription? _modelChangeSub;

  /// 订阅 ConfigService：选中模型变化 → 主动重新初始化 Agent
  void _subscribeModelChanges() {
    if (_modelChangeSub != null) return;
    try {
      _modelChangeSub = ConfigService.instance
          .watch(ConfigKeys.agentSelectedModelId)
          .listen((event) async {
        final newId = event.newValue?.toString();
        if (newId == null || newId.isEmpty) return;
        if (_store == null || _store!.selectedId == newId) return;
        appLog.info('AgentService: 检测到模型切换 $newId，重新初始化');
        await reconfigure();
      });
    } catch (e) {
      appLog.error('AgentService: 订阅模型变化失败 - $e');
    }
  }

  /// 创建新会话
  Future<AgentSession> newSession() async {
    final store = _sessionStore;
    if (store == null) return AgentSession(id: '');
    final session = await store.createSession(title: '新对话');
    _switchToSession(session);
    return session;
  }

  /// 切换会话
  Future<void> switchSession(String id) async {
    final store = _sessionStore;
    if (store == null) return;
    await store.selectSession(id);
    final session = store.current;
    if (session != null) {
      _switchToSession(session);
    }
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    final store = _sessionStore;
    if (store == null) return;
    await store.deleteSession(id);
    // 重新加载当前会话
    final session = store.current;
    if (session != null) {
      _switchToSession(session);
    } else {
      await newSession();
    }
  }

  /// 切换到指定会话（重置 UI 消息和 Genkit 上下文）
  void _switchToSession(AgentSession session) {
    _messages = [
      Message(
        role: Role.system,
        content: [TextPart(text: _systemPrompt)],
      ),
    ];
    _loadSessionMessages();
    _restoreMessagesFromSession();
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    final store = _sessionStore;
    final session = store?.current;
    if (session == null) return;
    session.messages.clear();
    session.title = '新对话';
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store!.updateCurrent(session);
    _switchToSession(session);
  }

  /// 保存消息到当前会话（并持久化）
  /// 用户与助手文本消息 + 工具调用记录都会保存，以便重新进入会话时完整还原
  void _persistMessage(AgentMessage msg) {
    final session = _sessionStore?.current;
    if (session == null) return;

    // 工具消息：若已持久化过则更新对应记录（运行→完成），否则新增
    if (msg.isToolResult) {
      final idx = session.messages.indexWhere((m) =>
          m.isToolResult &&
          m.toolType == msg.toolType?.name &&
          m.toolDetail == msg.toolDetail);
      if (idx >= 0 && _persistedToolIds.contains(msg.id)) {
        session.messages[idx] = SessionMessage(
          isUser: false,
          text: msg.text,
          isToolResult: true,
          toolType: msg.toolType?.name,
          toolStatus: msg.toolStatus?.name,
          toolDetail: msg.toolDetail,
          time: session.messages[idx].time,
          seq: session.messages[idx].seq,
          turnId: msg.turnId ?? session.messages[idx].turnId,
        );
      } else {
        session.messages.add(SessionMessage(
          isUser: false,
          text: msg.text,
          isToolResult: true,
          toolType: msg.toolType?.name,
          toolStatus: msg.toolStatus?.name,
          toolDetail: msg.toolDetail,
          time: msg.time.millisecondsSinceEpoch,
          seq: msg.seq,
          turnId: msg.turnId,
        ));
        _persistedToolIds.add(msg.id);
      }
      session.updatedAt = DateTime.now().millisecondsSinceEpoch;
      _sessionStore?.save();
      _syncSessionCache(session);
      return;
    }

    // 设置会话标题为首条用户消息
    if (msg.isUser && session.title == '新对话') {
      session.title = msg.text.length > 20
          ? msg.text.substring(0, 20)
          : msg.text;
    }
    session.messages.add(SessionMessage(
      isUser: msg.isUser,
      text: msg.text,
      isToolResult: false,
      time: msg.time.millisecondsSinceEpoch,
      seq: msg.seq,
      turnId: msg.turnId,
    ));
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    // 异步持久化
    _sessionStore?.save();
    _syncSessionCache(session);
  }

  /// 同步全量消息缓存（分页边界保持最新）
  void _syncSessionCache(AgentSession session) {
    // 稳定排序：time 优先、seq 兜底、持久化顺序兜底（避免同毫秒乱序）
    final indexed = session.messages.asMap().entries.toList();
    indexed.sort((a, b) {
      final t = a.value.time.compareTo(b.value.time);
      if (t != 0) return t;
      final s = a.value.seq.compareTo(b.value.seq);
      if (s != 0) return s;
      return a.key.compareTo(b.key);
    });
    final newAll = indexed.map((e) => e.value).toList();
    final oldLen = _allSessionMessages.length;
    _allSessionMessages = newAll;
    if (_allSessionMessages.length >= oldLen) {
      // 新消息追加：已加载条数同步增加（新消息已显示在 UI）
      _loadedMessageCount += (_allSessionMessages.length - oldLen);
    } else {
      // 消息被删除（清空等）：重置
      _loadedMessageCount = _allSessionMessages.length;
    }
  }

  /// 定义 Agent 工具
  /// 定义 Agent 工具（委托到 ActionController 原生执行）
  void _defineTools() {
    final ai = _ai;
    if (ai == null) return;

    // 搜索应用工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: searchToolName,
      description: '在 GStore 软件商店中搜索应用。输入关键词 keyword，返回匹配的应用列表。',
      fn: (input, _) async {
        final keyword = input['keyword']?.toString() ?? '';
        return _runAction(
          searchToolName,
          {'keyword': keyword},
          detail: '搜索"$keyword"',
        );
      },
    );

    // 下载应用工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: downloadToolName,
      description:
          '下载应用 APK。需要 appId（包名）、channel（渠道代码，如 github/fdroid/vivo）、url（下载地址，可选）、name（应用名）、version（版本号）。vivo 渠道还需传入 vivoId（vivo 应用 ID）。',
      fn: (input, _) async {
        final appId = input['appId']?.toString() ?? '';
        final channel = input['channel']?.toString() ?? '';
        final url = input['url']?.toString() ?? '';
        final name = input['name']?.toString() ?? '';
        final version = input['version']?.toString() ?? 'unknown';
        final vivoId = input['vivoId']?.toString();
        final installAfterDownload =
            input['installAfterDownload'] == true ||
            input['installAfterDownload'] == 'true';
        return _runAction(
          downloadToolName,
          {
            'appId': appId,
            'channel': channel,
            'url': url,
            'name': name,
            'version': version,
            'vivoId': vivoId,
            'installAfterDownload': installAfterDownload,
          },
          detail: '下载 $name ($version)',
        );
      },
    );

    // 安装应用工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: installToolName,
      description: '安装已下载的 APK 文件。需要 savePath（APK 文件完整路径）。',
      fn: (input, _) async {
        final savePath = input['savePath']?.toString() ?? '';
        final fileName = savePath.split('/').last;
        return _runAction(
          installToolName,
          {'savePath': savePath},
          detail: '安装 $fileName',
        );
      },
    );

    // 管理已添加应用工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: manageAppToolName,
      description:
          '管理"我的应用"列表。action 为 list（列出所有已添加应用）、add（添加应用，需 appId+channel）、remove（移除应用，需 appId+channel）、isAdded（检查是否已添加）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final appId = input['appId']?.toString() ?? '';
        final channel = input['channel']?.toString() ?? '';
        final name = input['name']?.toString() ?? '';
        return _runAction(
          manageAppToolName,
          {'action': action, 'appId': appId, 'channel': channel, 'name': name},
          detail: '管理应用: $action',
        );
      },
    );

    // 渠道应用管理工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: channelAppToolName,
      description:
          '管理应用渠道中的已添加应用。action 为 list/add/remove。GitHub 渠道 appId 用 owner/repo（如 termux/termux-app）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final appId = input['appId']?.toString() ?? '';
        final channel = input['channel']?.toString() ?? '';
        final name = input['name']?.toString() ?? '';
        return _runAction(
          channelAppToolName,
          {'action': action, 'appId': appId, 'channel': channel, 'name': name},
          detail: '渠道管理: $action',
        );
      },
    );

    // 应用详情/更新检查工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: appInfoToolName,
      description:
          '获取应用详情或检查是否有更新。需要 appId（包名/仓库名）、channel（渠道代码）。返回应用版本、描述等信息。',
      fn: (input, _) async {
        final appId = input['appId']?.toString() ?? '';
        final channel = input['channel']?.toString() ?? '';
        return _runAction(
          appInfoToolName,
          {'appId': appId, 'channel': channel},
          detail: '查询应用详情: $appId',
        );
      },
    );

    // 批量更新工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: updateAppsToolName,
      description:
          '检查已安装应用是否有更新。appId 和 channel 可选（不传则检查全部已添加应用）。返回每个应用的当前版本与最新版本，并标记哪些可更新。',
      fn: (input, _) async {
        final appId = input['appId']?.toString() ?? '';
        final channel = input['channel']?.toString() ?? '';
        return _runAction(
          updateAppsToolName,
          {'appId': appId, 'channel': channel},
          detail: '检查应用更新',
        );
      },
    );

    // 备份/恢复工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: backupToolName,
      description:
          '备份或恢复应用数据。action 为 export（导出备份，返回文件路径）、import（从文件导入，需 filePath）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'export';
        final filePath = input['filePath']?.toString() ?? '';
        return _runAction(
          backupToolName,
          {'action': action, 'filePath': filePath},
          detail: '备份管理: $action',
        );
      },
    );

    // 下载管理工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: manageDownloadToolName,
      description:
          '管理下载任务。action 为 list（列出所有下载）、pause（暂停，需 fileName）、resume（恢复，需 fileName）、cleanCompleted（清理已完成）、clearAll（清空全部）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final fileName = input['fileName']?.toString() ?? '';
        return _runAction(
          manageDownloadToolName,
          {'action': action, 'fileName': fileName},
          detail: '下载管理: $action',
        );
      },
    );

    // 主题控制工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: themeToolName,
      description:
          '控制应用主题。action 为 mode（切换模式，mode 值 light/dark/system）、toggle（切换深浅色）、color（设置主题色，传 hexColor 如 0xFF1976D2）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'toggle';
        final mode = input['mode']?.toString() ?? '';
        final hexColor = input['hexColor']?.toString() ?? '';
        return _runAction(
          themeToolName,
          {'action': action, 'mode': mode, 'hexColor': hexColor},
          detail: '主题控制: $action',
        );
      },
    );

    // F-Droid 仓库管理工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: fdroidRepoToolName,
      description:
          '管理 F-Droid 仓库。action 为 list（列出仓库）、load（加载/刷新仓库，force 可选）、search（搜索应用，需 keyword）、stats（统计信息）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final keyword = input['keyword']?.toString() ?? '';
        final force = input['force']?.toString() == 'true';
        return _runAction(
          fdroidRepoToolName,
          {
            'action': action,
            'keyword': keyword,
            // ActionController 声明 force 为 string 参数，传字符串避免类型校验失败
            'force': force ? 'true' : 'false',
          },
          detail: 'F-Droid 仓库: $action',
        );
      },
    );

    // 应用配置管理工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: configManagerToolName,
      description:
          '管理 GStore 应用配置。action 为 list（返回结构化 JSON：全部可配置项的 key/类型/当前值/默认值/可选枚举值/示例/分组）、get（读取单配置，需 key，返回结构化 JSON）、set（修改配置，需 key 和 value）、clear（清除配置，需 key）。'
          '建议先调用 list 了解配置的类型、可选项与示例，再构造正确的 value 调用 set。'
          'JSON 类型配置（type 为 json）的 value 需传 JSON 对象字符串，如 {"fontStyle":3}；可只传要修改的部分字段（缺失字段用默认值）。'
          'theme_config 支持字段（数字索引）：fontStyle（0默认/1紧凑/2标准/3宽松/4大号）、radiusStyle（0默认/1圆润/2方正）、borderStyle（0默认/1粗/2细）、useCustomColors（布尔）。'
          'theme_mode（主题模式 0/1/2）、proxy_url（GitHub 代理前缀）、download_config（下载配置 JSON）、update_config（更新配置 JSON）、webdav_config（WebDAV 配置 JSON，敏感）、agent_selected_model_id（Agent 模型 ID）等。'
          '修改配置后相关功能会自动生效（如切换主题、更新代理），无需额外操作。'
          '敏感配置（如 WebDAV 密码）读取时脱敏显示，但可以设置。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final key = input['key']?.toString() ?? '';
        final value = input['value'];
        return _runAction(
          configManagerToolName,
          {'action': action, 'key': key, 'value': value},
          detail: '配置管理: $action',
        );
      },
    );

    // WebDAV 云备份工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: webdavSyncToolName,
      description:
          'WebDAV 云备份。action 为 list（查询网盘中的备份数据列表，可查看备份时间/大小）、upload（上传备份到网盘）、download（从网盘恢复）、status（检查配置状态）。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'status';
        return _runAction(
          webdavSyncToolName,
          {'action': action},
          detail: 'WebDAV 同步: $action',
        );
      },
    );

    // 已安装应用查询工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: installedAppsToolName,
      description:
          '管理设备上已安装的应用。action 为 list（列出已安装应用，可选 keyword 过滤）、check（检查是否已安装，需 packageName）、uninstall（卸载应用，需 packageName）、clearData（清理应用数据，需 packageName）、clearCache（清理应用缓存，需 packageName）、forceStop（强制停止应用，需 packageName）。卸载/清理/停止需要 Shizuku 授权。',
      fn: (input, _) async {
        final action = input['action']?.toString() ?? 'list';
        final keyword = input['keyword']?.toString() ?? '';
        final packageName = input['packageName']?.toString() ?? '';
        return _runAction(
          installedAppsToolName,
          {'action': action, 'keyword': keyword, 'packageName': packageName},
          detail: '已安装应用: $action',
        );
      },
    );

    // 用户确认工具（与用户交互：确认/取消/选项选择）
    ai.defineTool<Map<String, dynamic>, String>(
      name: confirmToolName,
      description:
          '向用户发起确认或选择请求。用于两类场景：'
          '1) 敏感/不可逆操作需要用户确认（如卸载应用、清理数据、恢复备份、删除会话、移除应用）；'
          '2) 需要用户在多个选项中做出选择（如"你想怎么处理""用哪个版本""选哪个方案"）。'
          '输入 question（清晰的问题）。'
          '当需要用户选择时传 options（选项数组或逗号分隔字符串，2-5 个选项）；不传则显示确认/取消按钮。'
          '调用后等待用户操作，返回用户的选择。'
          '遇到下列情况**必须调用**：用户表达犹豫/要求选择/涉及删除卸载清理覆盖/需要二次确认，'
          '不要用普通文字回复代替选项交互。',
      fn: (input, _) async {
        final question = input['question']?.toString() ?? '';
        // 解析选项：可能是 List 或逗号分隔字符串
        List<String>? options;
        final optRaw = input['options'];
        if (optRaw is List) {
          options = optRaw.map((o) => o.toString()).where((o) => o.isNotEmpty).toList();
        } else if (optRaw is String && optRaw.trim().isNotEmpty) {
          options = optRaw
              .split(RegExp(r'[,，]'))
              .map((o) => o.trim())
              .where((o) => o.isNotEmpty)
              .toList();
        }
        if (options != null && options.isEmpty) options = null;
        return _requestUserConfirmation(question, options: options);
      },
    );

    // 脚本渠道自定义方法执行（Agent 渠道包 JS 执行能力）
    ai.defineTool<Map<String, dynamic>, String>(
      name: runJsChannelToolName,
      description:
          '执行自定义脚本渠道（js_xxx）暴露的方法。用于脚本渠道特有的能力，'
          '如 getConfig（渠道配置）、versionOptions/switchVersion（版本/环境切换）、'
          '或脚本自定义的查询/操作方法。输入 channel（脚本渠道 key，如 js_pingan）、'
          'method（脚本 main 分发的函数名）、params（可选参数 map）。'
          '仅对脚本渠道可用；脚本未实现该方法时返回提示。',
      fn: (input, _) async {
        return _runAction(
          runJsChannelToolName,
          {
            'channel': input['channel']?.toString() ?? '',
            'method': input['method']?.toString() ?? '',
            'params': input['params'],
          },
          detail: '执行脚本方法 ${input['method']?.toString() ?? ''}',
        );
      },
    );

    // 模块化工具（热插拔）：注册 _agentTools 中未被硬编码覆盖的工具
    const builtinDefined = {
      searchToolName,
      downloadToolName,
      installToolName,
      manageAppToolName,
      channelAppToolName,
      appInfoToolName,
      updateAppsToolName,
      backupToolName,
      manageDownloadToolName,
      themeToolName,
      fdroidRepoToolName,
      webdavSyncToolName,
      installedAppsToolName,
      confirmToolName,
      configManagerToolName,
      runJsChannelToolName,
    };
    for (final tool in _agentTools) {
      if (builtinDefined.contains(tool.toolName)) continue;
      ai.defineTool<Map<String, dynamic>, String>(
        name: tool.toolName,
        description: tool.toolDescription,
        fn: (input, _) async {
          return _runAction(tool.toolName, input, detail: '工具: ${tool.toolName}');
        },
      );
    }
  }

  /// 请求用户确认（创建确认节点，等待用户选择）
  /// [question] 确认问题；[options] 选项列表（null 时二选一确认/取消）
  /// [multiSelect] 是否多选（勾选多个选项后统一确认，默认单选/二选一）
  /// 返回用户的选择结果字符串供模型使用：
  /// - 多选：多个选项用 "、" 连接（如 "缓存、图标"）
  /// - 单选：所选选项
  /// - 二选一：'确认' / '取消'
  Future<String> _requestUserConfirmation(
    String question, {
    List<String>? options,
    bool multiSelect = false,
  }) async {
    if (question.isEmpty) {
      return '确认问题不能为空';
    }

    // 定稿已输出的 agent 文本为独立消息（实现"回答→确认→结果"分步）
    _commitActiveStreamText();

    // 创建确认工具消息（step 节点显示确认 UI）
    final msg = _addToolMessage(AgentToolType.confirm, question);
    msg.confirmOptions = options;
    msg.confirmMultiSelect = multiSelect;
    final completer = Completer<String>();
    _pendingConfirmations[msg.id] = completer;

    // B3：持久化待确认消息（退出/重启后可恢复确认 UI）
    _persistPendingConfirmation(msg, question, options, multiSelect: multiSelect);

    // B3：页面不可见时升级为通知栏确认（带按钮，点按回写 resolveConfirmation）
    _notifyConfirmIfBackground(msg.id, question, options, multiSelect: multiSelect);

    // 等待 UI 选择（resolveConfirmation 完成）
    final choice = await completer.future;
    _pendingConfirmations.remove(msg.id);
    // 确认已解决：清理待确认持久化 + 关闭通知
    _clearPendingConfirmation(msg.id);
    AgentNotificationService.instance.onConfirmResolved();

    if (choice.isEmpty || choice == '取消') {
      _updateToolMessage(msg, status: AgentToolStatus.error, detail: '已取消');
      return '用户已取消';
    }
    if (multiSelect) {
      _updateToolMessage(msg, status: AgentToolStatus.done, detail: '已选择：$choice');
      return '用户已选择：$choice';
    }
    if (options != null && options.isNotEmpty) {
      _updateToolMessage(msg, status: AgentToolStatus.done, detail: '已选择：$choice');
      return '用户已选择：$choice';
    }
    _updateToolMessage(msg, status: AgentToolStatus.done, detail: '已确认');
    return '用户已确认';
  }

  /// 持久化待确认消息（B3：写入当前会话，重启后可恢复确认 UI）
  void _persistPendingConfirmation(
    AgentMessage msg,
    String question,
    List<String>? options, {
    bool multiSelect = false,
  }) {
    final session = _sessionStore?.current;
    if (session == null) return;
    session.messages.removeWhere((m) =>
        m.isToolResult && m.toolType == AgentToolType.confirm.name &&
        m.toolDetail == question);
    session.messages.add(SessionMessage(
      isUser: false,
      text: question,
      isToolResult: true,
      toolType: AgentToolType.confirm.name,
      toolStatus: AgentToolStatus.running.name,
      toolDetail: question,
      time: msg.time.millisecondsSinceEpoch,
      seq: msg.seq,
      turnId: msg.turnId,
      confirmOptions: options,
      confirmMultiSelect: multiSelect,
    ));
    // 登记为"已持久化的工具消息"：用户选择后 _updateToolMessage(done) →
    // _persistMessage 会走更新分支覆盖本条 running 记录，
    // 避免 session 中残留 running 确认导致重启后仍显示多选框。
    _persistedToolIds.add(msg.id);
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _sessionStore?.save();
    _syncSessionCache(session);
  }

  /// 清理已解决的待确认（从持久化中移除 running 记录）
  ///
  /// 该确认已解决（用户已选择/取消）时调用：删除会话中 running 状态的
  /// confirm 记录。终态记录由 _updateToolMessage(done/error) → _persistMessage
  /// 随后新增——若残留 running 记录，重启后 _restorePendingConfirmations 会
  /// 把它恢复成"待确认"UI（多选框/按钮仍可点），与实际已选择不符。
  void _clearPendingConfirmation(String msgId) {
    final session = _sessionStore?.current;
    if (session == null) return;
    final before = session.messages.length;
    session.messages.removeWhere((m) =>
        m.isToolResult &&
        m.toolType == AgentToolType.confirm.name &&
        m.toolStatus == AgentToolStatus.running.name);
    if (session.messages.length != before) {
      session.updatedAt = DateTime.now().millisecondsSinceEpoch;
      _sessionStore?.save();
      _syncSessionCache(session);
    }
  }

  /// 页面不可见时，将确认请求升级为通知栏按钮（B3）
  void _notifyConfirmIfBackground(
    String msgId,
    String question,
    List<String>? options, {
    bool multiSelect = false,
  }) {
    // 页面内对话：确认 UI 已在消息卡展示，无需通知打扰
    if (!_notifyOnlyWhenBackground) return;
    try {
      AgentNotificationService.instance.init();
      AgentNotificationService.instance.onConfirmRequest(
        msgId: msgId,
        question: question,
        options: options,
        multiSelect: multiSelect,
      );
    } catch (e) {
      appLog.error('AgentService: 确认通知失败 - $e');
    }
  }

  /// 处理用户确认结果（UI 调用）
  /// [msgId] 确认消息 id，[choice] 用户选择：
  /// - 多选一：所选选项字符串
  /// - 二选一：'确认' 或 '取消'
  /// - 空字符串视为取消
  void resolveConfirmation(String msgId, String choice) {
    final completer = _pendingConfirmations[msgId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(choice);
    }
  }

  /// 执行工具（委托 ActionController 原生执行）
  /// 返回执行结果字符串供模型使用
  Future<String> _runAction(
    String name,
    Map<String, dynamic> params, {
    String? detail,
  }) async {
    // 已请求停止 → 拒绝新的工具调用
    if (_cancelRequested) {
      return '已停止，工具调用被取消';
    }
    // B5 安全护栏：敏感工具（卸载/清数据/恢复备份等）必须先经 confirmAction 确认。
    // 页面不可见（后台执行）时，敏感工具未经用户确认 → 拒绝执行，避免静默破坏。
    // （confirmAction 是独立的确认工具调用；此处拦截的是"跳过确认直接执行敏感操作"）
    if (_isSensitiveTool(name, params) && !_isAgentPageVisible()) {
      return '安全拦截：$name 需要用户确认，但 AI 助手页不在前台。'
          '已通过通知发起确认，请先确认后再让助手执行。';
    }
    // 工具调用前，把已输出的流式文本定稿为独立 agent 消息
    // （实现"回复→工具→回复→工具"的分步展示）
    _commitActiveStreamText();
    // 创建工具消息（加入消息流，持久显示）
    final msg = _addToolMessage(_toolTypeForName(name), detail ?? name);
    // 记录当前工具消息：长任务（下载等）经 handler 回调实时更新进度卡
    _currentToolMsg = msg;
    // 异步长任务：注册会话级任务记录（绑定归属会话，防切换串扰）
    AgentAsyncTask? asyncTask;
    if (_isAsyncTool(name)) {
      asyncTask = _registerAsyncTask(
        toolName: name,
        detail: detail ?? name,
      );
      _currentAsyncTask = asyncTask;
    }
    try {
      // 确保 action 已注册（AiActionProvider 可能尚未 build）
      if (!_actionController.actions.containsKey(name)) {
        for (final action in buildActions()) {
          if (action.name == name) {
            _actionController.registerAction(action);
            break;
          }
        }
      }
      final result = await _actionController.executeAction(name, params);
      // 用户已停止 → 标记工具为取消（不当作错误）
      if (_cancelRequested) {
        _updateToolMessage(msg, status: AgentToolStatus.error, detail: '已取消');
        return '已取消（用户停止）';
      }
      // 更新工具消息状态 + 持久化
      final data = result.data;
      final text = result.success
          ? (data is Map && data['result'] != null
              ? data['result'].toString()
              : '执行成功')
          : (result.error ?? '执行失败');
      // 异步长任务工具（下载）：保持 running（进度条跟随），由 onFinished 终态定稿。
      // 其余工具立即定稿 done/error。
      if (_isAsyncTool(name)) {
        _updateToolMessage(msg, status: AgentToolStatus.running, detail: text);
      } else {
        _updateToolMessage(
          msg,
          status: result.success ? AgentToolStatus.done : AgentToolStatus.error,
          detail: text,
        );
        // 工具终态通知（B2：退出页面后仍可见结果）
        _publishToolDoneNotification(
          success: result.success,
          toolLabel: _toolLabelForName(name),
          message: text,
        );
      }
      return text;
    } catch (e) {
      _updateToolMessage(msg, status: AgentToolStatus.error, detail: '执行失败: $e');
      _publishToolDoneNotification(
        success: false,
        toolLabel: _toolLabelForName(name),
        message: '执行失败: $e',
      );
      return '执行失败: $e';
    } finally {
      _currentToolMsg = null;
      _currentAsyncTask = null;
    }
  }

  /// 是否为异步长任务工具（工具调用后后台继续，消息卡保持 running 直到终态）
  bool _isAsyncTool(String name) => name == downloadToolName;

  /// 异步工具完成后的 agent 继续生成。
  ///
  /// 下载等后台任务终态后调用：触发一轮新的 agent 生成（fire-and-forget，
  /// 不阻塞用户后续输入）——让 agent 能基于结果继续（如"下载完成，是否安装？"）。
  /// 若用户正在输入/其他生成中（busy），跳过继续（用户下条消息会自然带上上下文）。
  void _continueAfterAsyncTool(bool success, String message) {
    // busy 时（用户正在生成/输入中）不打断，留给下一条用户消息自然衔接
    if (_busy) return;
    appLog.info('AgentService: 异步工具完成，触发 agent 继续 - $message');
    unawaited(_runAgentContinuation(success, message));
  }

  /// 执行一轮"后台继续生成"：把异步工具结果作为续接指令注入 Genkit 上下文，
  /// 复用一个内部生成回合（不加用户消息，模型依据结果继续回复）。
  Future<void> _runAgentContinuation(bool success, String toolResult) async {
    if (!_initialized || _busy) return;
    _busy = true;
    busy.value = true;
    try {
      // 注入"异步工具完成"续接指令到上下文（用 user 角色——所有 LLM API 均接受，
      // 不依赖 Genkit 工具消息内部协议；内容明确告知模型应继续回复）
      _messages.add(Message(
        role: Role.user,
        content: [
          TextPart(
            text: '（系统续接：上一个异步工具已结束。结果：$toolResult）'
                ' 请基于此结果继续：若成功给出下一步建议（如是否安装），若失败说明原因与建议。',
          ),
        ],
      ));
      // 用新的 turnId，独立展示这一轮"完成 → 建议"的回复
      _currentTurnId = 'turn-${DateTime.now().millisecondsSinceEpoch}';
      _activeStreamMsg = AgentMessage(
        isUser: false,
        text: '',
        turnId: _currentTurnId,
      );
      _addMessage(_activeStreamMsg!);

      final stream = _ai!.generateStream<dynamic, void>(
        model: _getModelRef(_model!) as ModelRef<dynamic>,
        messages: _messages,
        toolNames: registeredToolNames.isNotEmpty ? registeredToolNames : null,
        maxTurns: 6,
      );
      await for (final chunk in stream) {
        if (_cancelRequested) break;
        final t = chunk.text;
        if (t.isNotEmpty) {
          if (_activeStreamMsg == null) {
            _activeStreamMsg = AgentMessage(
              isUser: false,
              text: '',
              turnId: _currentTurnId,
            );
            _addMessage(_activeStreamMsg!);
          }
          _activeStreamMsg?.text = (_activeStreamMsg?.text ?? '') + t;
          _notifyMessages();
        }
      }
      final response = await stream.onResult;
      _messages = List.of(response.messages ?? _messages);
      final msg = _activeStreamMsg;
      if (msg != null) {
        if (msg.text.trim().isNotEmpty) {
          msg.text = msg.text.trim();
          _notifyMessages();
          _persistStreamMessage(msg);
        } else {
          _removeMessage(msg);
        }
      }
      _activeStreamMsg = null;
    } catch (e) {
      appLog.error('AgentService: 后台继续生成失败 - $e');
    } finally {
      _activeStreamMsg = null;
      _busy = false;
      busy.value = false;
      _currentTurnId = null;
      _cancelRequested = false;
    }
  }

  /// 添加一条工具消息（running 状态，加入消息流持久显示）
  AgentMessage _addToolMessage(AgentToolType type, String detail) {
    final msg = AgentMessage(
      isUser: false,
      text: '',
      toolType: type,
      toolStatus: AgentToolStatus.running,
      toolDetail: detail,
      isToolResult: true,
      turnId: _currentTurnId,
    );
    _addMessage(msg);
    return msg;
  }

  /// 把当前已输出的流式文本"定稿"为独立 agent 消息。
  /// 定稿后置空 _activeStreamMsg，后续文本由流式循环懒创建——
  /// 这样新建消息的 seq 会排在工具消息之后，实现"回复→工具→回复"顺序。
  void _commitActiveStreamText() {
    final current = _activeStreamMsg;
    if (current == null) return;

    final text = current.text.trim();
    if (text.isNotEmpty) {
      // 定稿：创建独立 agent 消息（排在工具消息前）
      final committed = AgentMessage(
        isUser: false,
        text: text,
        turnId: current.turnId,
      );
      _addMessage(committed);
      _persistMessage(committed);
    }
    // 移除原流式消息（有文本则已定稿，无文本则丢弃空占位）
    _removeMessage(current);
    // 置空：后续文本由流式循环懒创建（在工具消息之后）
    _activeStreamMsg = null;
  }

  /// 更新工具消息状态（并持久化）
  void _updateToolMessage(
    AgentMessage msg, {
    bool? done,
    AgentToolStatus? status,
    String? detail,
    DownloadTask? downloadStatus,
  }) {
    final idx = messages.value.indexWhere((e) => e.id == msg.id);
    if (idx < 0) return;
    final current = messages.value[idx];
    current.toolStatus = status ?? (done == true ? AgentToolStatus.done : AgentToolStatus.running);
    if (detail != null) {
      current.toolDetail = detail;
      current.text = detail;
    }
    if (downloadStatus != null) {
      current.downloadStatus = downloadStatus;
    }
    // 工具完成或失败时持久化记录
    if (current.toolStatus == AgentToolStatus.done ||
        current.toolStatus == AgentToolStatus.error) {
      _persistMessage(current);
    }
    // 触发 Rx 更新
    _notifyMessages();
  }

  /// 更新当前执行中工具消息的阶段详情（step 进度：如"检查 1/N → 备份中 → 上传中"）。
  ///
  /// 供长任务工具（下载/更新检查/备份/WebDAV）内部多阶段调用：
  /// 保持工具状态 running，仅更新 toolDetail（UI 显示当前阶段），
  /// 不产生新的消息记录。工具结束时由 [_updateToolMessage] 定稿。
  void _updateToolStep(String step) {
    final msg = _currentToolMsg;
    if (msg == null) return;
    final idx = messages.value.indexWhere((e) => e.id == msg.id);
    if (idx < 0) return;
    final current = messages.value[idx];
    current.toolDetail = step;
    current.text = step;
    _notifyMessages();
  }

  /// 推送工具阶段通知（B2：退出页面后仍可见执行进度；页面内对话时消息卡已展示，跳过）
  void _publishToolStepNotification(String title, String step) {
    if (!_notifyOnlyWhenBackground) return;
    try {
      AgentNotificationService.instance.init();
      AgentNotificationService.instance.onToolProgress(
        title: 'AI 助手 · $title',
        message: step,
      );
    } catch (e) {
      appLog.error('AgentService: 工具阶段通知失败 - $e');
    }
  }

  /// 推送工具终态通知（B2：退出页面后仍可见结果；页面内对话时消息卡已展示，跳过）
  void _publishToolDoneNotification({
    required bool success,
    required String toolLabel,
    required String message,
  }) {
    if (!_notifyOnlyWhenBackground) return;
    try {
      AgentNotificationService.instance.init();
      AgentNotificationService.instance.onToolDone(
        success: success,
        message: '$toolLabel · ${message.length > 80 ? '${message.substring(0, 80)}…' : message}',
      );
    } catch (e) {
      appLog.error('AgentService: 工具终态通知失败 - $e');
    }
  }

  /// B5：AI 助手页是否在前台（后台执行时敏感操作需确认）
  /// AI 页是首页 tab 的内嵌子页（home PageView index 2）+ 独立路由页。
  /// 可见性由 UI 侧写入 [HomeTabVisibility]（服务层不反向依赖页面）。
  bool _isAgentPageVisible() => HomeTabVisibility.instance.agentActive;

  /// 通知门控：仅当用户**不在** AI 助手页时才发通知。
  /// 页面内对话时消息卡已实时展示进度/结果，通知会重复打扰；
  /// 用户离开页面（后台执行）才需通知兜底汇报。
  bool get _notifyOnlyWhenBackground => !_isAgentPageVisible();

  /// B5：敏感工具判定——破坏性/不可逆操作，必须经 confirmAction 确认
  /// 后台执行时未经确认直接调用将被安全拦截
  bool _isSensitiveTool(String name, Map<String, dynamic> params) {
    if (name == installedAppsToolName) {
      final action = params['action']?.toString() ?? '';
      return action == 'uninstall' ||
          action == 'clearData' ||
          action == 'clearCache' ||
          action == 'forceStop';
    }
    if (name == backupToolName) {
      return (params['action']?.toString() ?? '') == 'import'; // 恢复会覆盖数据
    }
    if (name == manageDownloadToolName) {
      final action = params['action']?.toString() ?? '';
      return action == 'clearAll' || action == 'cleanCompleted';
    }
    // 缓存管理会删除下载文件/缓存（不可逆），需页面可见 + 用户多选确认
    if (name == cacheManageToolName) {
      return true;
    }
    return false;
  }

  /// 工具名 → 中文标签（通知文案用）
  String _toolLabelForName(String name) {
    switch (name) {
      case searchToolName:
        return '搜索应用';
      case downloadToolName:
        return '下载应用';
      case installToolName:
        return '安装应用';
      case manageAppToolName:
        return '管理我的应用';
      case channelAppToolName:
        return '渠道应用管理';
      case appInfoToolName:
        return '应用详情';
      case updateAppsToolName:
        return '检查更新';
      case backupToolName:
        return '备份恢复';
      case manageDownloadToolName:
        return '下载管理';
      case themeToolName:
        return '主题控制';
      case fdroidRepoToolName:
        return 'F-Droid 仓库';
      case webdavSyncToolName:
        return 'WebDAV 云备份';
      case installedAppsToolName:
        return '已安装应用';
      case configManagerToolName:
        return '配置管理';
      case confirmToolName:
        return '确认操作';
      case cacheManageToolName:
        return '缓存管理';
      case runJsChannelToolName:
        return '脚本渠道执行';
      default:
        return name;
    }
  }

  /// 工具名 → AgentToolType（用于工具消息图标/标签）
  AgentToolType _toolTypeForName(String name) {
    switch (name) {
      case searchToolName:
        return AgentToolType.search;
      case downloadToolName:
        return AgentToolType.download;
      case installToolName:
        return AgentToolType.install;
      case manageAppToolName:
        return AgentToolType.manageApp;
      case channelAppToolName:
        return AgentToolType.manageApp;
      case appInfoToolName:
        return AgentToolType.appInfo;
      case updateAppsToolName:
        return AgentToolType.update;
      case backupToolName:
        return AgentToolType.backup;
      case manageDownloadToolName:
        return AgentToolType.manageDownload;
      case themeToolName:
        return AgentToolType.theme;
      case fdroidRepoToolName:
        return AgentToolType.fdroid;
      case webdavSyncToolName:
        return AgentToolType.webdav;
      case installedAppsToolName:
        return AgentToolType.installed;
      case configManagerToolName:
        return AgentToolType.config;
      case runJsChannelToolName:
        return AgentToolType.config;
      default:
        return AgentToolType.manageApp;
    }
  }

  /// 构建 13 个工具对应的 AiAction（供 AiActionProvider 原生工具调用）
  /// handler 复用内部工具实现，返回 ActionResult
  List<AiAction> buildActions() {
    return [
      AiAction(
        name: searchToolName,
        description: '在 GStore 软件商店中搜索应用。输入关键词 keyword，返回匹配的应用列表。',
        parameters: [
          ActionParameter.string(name: 'keyword', description: '搜索关键词', required: true),
        ],
        handler: (params) async {
          final keyword = params['keyword']?.toString() ?? '';
          final result = await _searchApps(keyword);
          return _successAction(result);
        },
      ),
      AiAction(
        name: downloadToolName,
        description: '下载应用 APK。需要 appId、channel（如 github/fdroid/vivo）、url（可选）、name、version。vivo 渠道还需传入 vivoId（vivo 应用 ID）。',
        parameters: [
          ActionParameter.string(name: 'appId', description: '包名/仓库名', required: true),
          ActionParameter.string(name: 'channel', description: '渠道代码', required: true),
          ActionParameter.string(name: 'url', description: '下载地址'),
          ActionParameter.string(name: 'name', description: '应用名'),
          ActionParameter.string(name: 'version', description: '版本号'),
          ActionParameter.string(name: 'vivoId', description: 'vivo 应用 ID（vivo 渠道必需）'),
          ActionParameter.boolean(
            name: 'installAfterDownload',
            description:
                '是否下载完成后自动安装（用户明确要求"下载完就安装"时传 true；仅说"下载"则不传或传 false）',
          ),
        ],
        handler: (params) async {
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final url = params['url']?.toString() ?? '';
          final name = params['name']?.toString() ?? '';
          final version = params['version']?.toString() ?? 'unknown';
          final vivoId = params['vivoId']?.toString();
          final installAfterDownload =
              params['installAfterDownload'] == true ||
              params['installAfterDownload'] == 'true';
          final asyncTask = _currentAsyncTask; // 同步段捕获（onFinished 异步触发时该字段已清空）
          final toolMsg = _currentToolMsg; // 同步段捕获（进度回调触发时该字段已被 finally 清空）
          final result = await _downloadApp(
            appId, channel, url, name, version,
            vivoId: vivoId,
            installAfterDownload: installAfterDownload,
            onStatus: (status) {
              _currentDownloadStatus = status;
              // 实时推送下载状态到工具消息（进度条/百分比 live 更新）。
              // 必须用同步段捕获的 toolMsg 引用——下载进度异步触发时
              // _currentToolMsg 已被 _runAction finally 置 null。
              if (toolMsg != null) {
                _updateToolMessage(toolMsg, downloadStatus: status);
              }
            },
            onFinished: (success, message) {
              _currentDownloadStatus = null;
              if (asyncTask != null) {
                _finalizeAsyncTask(
                  task: asyncTask,
                  success: success,
                  message: message,
                );
              }
            },
          );
          return _successAction(result);
        },
      ),
      AiAction(
        name: installToolName,
        description: '安装已下载的 APK 文件。需要 savePath（APK 文件完整路径）。',
        parameters: [
          ActionParameter.string(name: 'savePath', description: 'APK 文件路径', required: true),
        ],
        handler: (params) async {
          final savePath = params['savePath']?.toString() ?? '';
          final result = await _installApp(savePath);
          return _successAction(result);
        },
      ),
      AiAction(
        name: manageAppToolName,
        description: '管理"我的应用"列表。action 为 list/add/remove/isAdded。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'appId', description: '应用ID'),
          ActionParameter.string(name: 'channel', description: '渠道代码'),
          ActionParameter.string(name: 'name', description: '应用名'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final name = params['name']?.toString() ?? '';
          final result = await _manageApp(action, appId, channel, name);
          return _successAction(result);
        },
      ),
      AiAction(
        name: channelAppToolName,
        description: '管理应用渠道中的已添加应用。action 为 list/add/remove。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'appId', description: '应用ID'),
          ActionParameter.string(name: 'channel', description: '渠道代码'),
          ActionParameter.string(name: 'name', description: '应用名'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final name = params['name']?.toString() ?? '';
          final result = await _manageChannelApp(action, appId, channel, name);
          return _successAction(result);
        },
      ),
      AiAction(
        name: appInfoToolName,
        description: '获取应用详情或检查是否有更新。需要 appId、channel。',
        parameters: [
          ActionParameter.string(name: 'appId', description: '应用ID', required: true),
          ActionParameter.string(name: 'channel', description: '渠道代码', required: true),
        ],
        handler: (params) async {
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final result = await _getAppInfo(appId, channel);
          return _successAction(result);
        },
      ),
      AiAction(
        name: updateAppsToolName,
        description: '检查已安装应用是否有更新。appId 和 channel 可选。',
        parameters: [
          ActionParameter.string(name: 'appId', description: '应用ID'),
          ActionParameter.string(name: 'channel', description: '渠道代码'),
        ],
        handler: (params) async {
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final result = await _checkUpdates(appId, channel);
          return _successAction(result);
        },
      ),
      AiAction(
        name: backupToolName,
        description: '备份或恢复应用数据。action 为 export/import。',
        parameters: [
          ActionParameter.string(name: 'action', description: 'export/import', required: true),
          ActionParameter.string(name: 'filePath', description: '导入文件路径'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'export';
          final filePath = params['filePath']?.toString() ?? '';
          final result = await _backup(action, filePath);
          return _successAction(result);
        },
      ),
      AiAction(
        name: manageDownloadToolName,
        description: '管理下载任务。action 为 list/pause/resume/cleanCompleted/clearAll。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'fileName', description: '文件名'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final fileName = params['fileName']?.toString() ?? '';
          final result = await _manageDownloads(action, fileName);
          return _successAction(result);
        },
      ),
      AiAction(
        name: themeToolName,
        description: '控制应用主题。action 为 mode/toggle/color。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'mode', description: 'light/dark/system'),
          ActionParameter.string(name: 'hexColor', description: '主题色'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'toggle';
          final mode = params['mode']?.toString() ?? '';
          final hexColor = params['hexColor']?.toString() ?? '';
          final result = await _controlTheme(action, mode, hexColor);
          return _successAction(result);
        },
      ),
      AiAction(
        name: fdroidRepoToolName,
        description: '管理 F-Droid 仓库。action 为 list/load/search/stats。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'keyword', description: '搜索关键词'),
          ActionParameter.string(name: 'force', description: '是否强制刷新'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final keyword = params['keyword']?.toString() ?? '';
          final force = params['force']?.toString() == 'true';
          final result = await _fdroidRepo(action, keyword, force);
          return _successAction(result);
        },
      ),
      AiAction(
        name: webdavSyncToolName,
        description: 'WebDAV 云备份。action 为 list（查询网盘备份数据列表）/upload/download/status。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'status';
          final result = await _webdavSync(action);
          return _successAction(result);
        },
      ),
      AiAction(
        name: configManagerToolName,
        description:
            '管理 GStore 应用配置。action 为 list（结构化 JSON 快照）/get（需 key）/set（需 key 和 value）/clear（需 key）。修改后功能自动生效。建议先 list 了解类型与可选项。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'key', description: '配置键'),
          ActionParameter.string(name: 'value', description: '配置值（set 时使用）'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final key = params['key']?.toString() ?? '';
          final value = params['value'];
          final result = await _configManager(action, key, value);
          return _successAction(result);
        },
      ),
      AiAction(
        name: installedAppsToolName,
        description: '管理设备上已安装的应用。action 为 list/check/uninstall/clearData/clearCache/forceStop。',
        parameters: [
          ActionParameter.string(name: 'action', description: '操作类型', required: true),
          ActionParameter.string(name: 'keyword', description: '过滤关键词'),
          ActionParameter.string(name: 'packageName', description: '包名'),
        ],
        handler: (params) async {
          final action = params['action']?.toString() ?? 'list';
          final keyword = params['keyword']?.toString() ?? '';
          final packageName = params['packageName']?.toString() ?? '';
          final result = await _installedApps(action, keyword, packageName);
          return _successAction(result);
        },
      ),
      AiAction(
        name: runJsChannelToolName,
        description: '执行自定义脚本渠道（js_xxx）暴露的方法（getConfig/versionOptions/switchVersion 或脚本自定义方法）。',
        parameters: [
          ActionParameter.string(name: 'channel', description: '脚本渠道 key（如 js_pingan）', required: true),
          ActionParameter.string(name: 'method', description: '脚本 main 分发的函数名', required: true),
          ActionParameter.string(name: 'params', description: '可选参数 map（JSON 对象）'),
        ],
        handler: (params) async {
          final result = await _runJsChannel(
            params['channel']?.toString() ?? '',
            params['method']?.toString() ?? '',
            params['params'],
          );
          return _successAction(result);
        },
      ),
      // 模块化工具（热插拔）：生成 _agentTools 中未被硬编码覆盖的工具
      ..._extraActions(),
    ];
  }

  /// 构建模块化工具（未硬编码）的 AiAction 列表
  List<AiAction> _extraActions() {
    const builtinDefined = {
      searchToolName,
      downloadToolName,
      installToolName,
      manageAppToolName,
      channelAppToolName,
      appInfoToolName,
      updateAppsToolName,
      backupToolName,
      manageDownloadToolName,
      themeToolName,
      fdroidRepoToolName,
      webdavSyncToolName,
      installedAppsToolName,
      confirmToolName,
      configManagerToolName,
      runJsChannelToolName,
    };
    final result = <AiAction>[];
    for (final tool in _agentTools) {
      if (builtinDefined.contains(tool.toolName)) continue;
      result.add(AiAction(
        name: tool.toolName,
        description: tool.toolDescription,
        parameters: [
          for (final p in tool.toolParams)
            ActionParameter.string(
              name: p.name,
              description: p.description,
              required: p.required,
            ),
        ],
        handler: (params) async {
          final result = await tool.execute(_toolContext, params);
          return _successAction(result);
        },
      ));
    }
    return result;
  }

  /// 工具执行成功结果包装
  ActionResult _successAction(String result) {
    return ActionResult.createSuccess({'result': result});
  }

  /// 搜索应用（跨渠道聚合）
  Future<String> _searchApps(String keyword) async {
    if (keyword.isEmpty) return '搜索关键词不能为空';

    try {
      final manager = ChannelManager.instance;
      final results = <String>[];

      // 遍历所有渠道搜索
      for (final channel in ChannelType.values) {
        // 已请求停止 → 中断搜索
        if (_cancelRequested) return '已停止搜索';
        try {
          final result = await manager.searchApps(
            keyword,
            from: channel,
            forceRefresh: true,
          );
          if (result.success && result.data != null) {
            for (final app in result.data!) {
              // 附带渠道特有信息（如 vivo 的 vivoId）
              var extraInfo = '';
              if (channel == ChannelType.vivo && app.repositories.isNotEmpty) {
                extraInfo = '  vivoId=${app.repositories}';
              }
              results.add(
                  '• ${app.name ?? '未知'} (appId=${app.appId})'
                  '$extraInfo\n'
                  '  简介: ${app.des ?? '无'}\n'
                  '  渠道: ${channel.code}');
            }
          }
        } catch (e) {
          // 单个渠道失败不影响整体
        }
      }

      if (results.isEmpty) {
        return '未找到与"$keyword"相关的应用。';
      }

      return '找到 ${results.length} 个应用：\n${results.join('\n')}';
    } catch (e) {
      return '搜索失败: $e';
    }
  }

  /// 网络搜索（cn.bing.com，国内可直接访问）
  /// 用于推荐候选应用、补充应用背景资料、回答外部知识问题
  /// 下载应用
  /// 优先使用策略管理器走正常下载流程（与详情页一致）
  /// 若传入 URL 有效则直接下载；否则通过渠道详情获取真实下载地址
  /// [vivoId] vivo 渠道专用：vivo 应用在 vivo 应用市场的 ID（详情接口必需）
  /// [onStatus] 下载状态回调（用于 UI 显示进度）
  /// [installAfterDownload] 是否在下载完成后自动安装（默认 false，仅下载不安装）
  Future<String> _downloadApp(String appId, String channel, String url,
      String name, String version,
      {String? vivoId,
      bool installAfterDownload = false,
      void Function(DownloadTask)? onStatus,
      void Function(bool success, String message)? onFinished}) async {
    if (appId.isEmpty) return '下载参数不完整（缺少 appId）';

    try {
      // 下载模块下线 → 注册表取不到服务，降级提示不抛（先于渠道解析，保持降级语义）
      final service = ModuleManager.instance.get<IDownloadService>();
      if (service == null) {
        return '下载模块未启用';
      }

      // 方式1：已有完整 URL → 直接下载（只需下载服务，不依赖渠道注册）
      if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
        final task = await service.download(
          appId,
          name,
          version,
          url,
          name,
          installAfterDownload: installAfterDownload,
        );
        _watchDownloadProgress(service, task, onStatus, onFinished);
        return '已开始下载 $name，保存路径: ${task.filePath}';
      }

      // 解析渠道：优先枚举渠道 type.code，其次动态脚本渠道 channelKey（js_xxx）。
      // 脚本渠道不在 ChannelType 枚举内，必须用 _resolveChannel 才能解析。
      final channelInst = _resolveChannel(channel);
      if (channelInst == null) {
        return '未知渠道: $channel（支持: github/fdroid/vivo/http/local_db，及自定义脚本渠道 js_xxx）';
      }

      // 方式2：通过渠道详情获取真实下载地址
      // vivo 渠道需使用 vivoId 查询详情
      var detailAppId = appId;
      final isVivo = channelInst.info.type == ChannelType.vivo;
      if (isVivo && vivoId != null && vivoId.isNotEmpty) {
        detailAppId = vivoId;
      } else if (isVivo) {
        // 无 vivoId：尝试通过搜索获取（搜索结果含 vivoId）
        detailAppId = await _resolveVivoId(appId);
        if (detailAppId.isEmpty) {
          return '无法获取 $name 的 vivo 应用信息（缺少 vivoId），请在详情页查看或稍后重试';
        }
      }

      final detailResult = await channelInst.getAppDetail(detailAppId, forceRefresh: true);
      if (!detailResult.success || detailResult.data == null) {
        return '获取 $name 的下载信息失败: ${detailResult.error ?? '未知错误'}';
      }

      final detail = detailResult.data!;
      final downloads = detail.downloads;
      if (downloads.isEmpty) {
        return '该应用没有可用的下载文件';
      }

      // 选择与当前设备 CPU 架构匹配的下载文件（GitHub 等渠道有多个架构的 asset）
      final download = PlatformArch.selectBestAsset(
        downloads,
        (item) => item.name,
        isApk: (item) => item.name.toLowerCase().endsWith('.apk'),
      );
      if (download == null) {
        return '没有找到合适的下载文件';
      }
      debugPrint(
          'AgentService: 选择下载文件 ${download.name} (平台: ${download.platform ?? '未知'}, 设备 ABI: ${PlatformArch.abi})');

      // 使用策略管理器创建下载请求（自动选择对应渠道策略）
      final strategyManager = DownloadStrategyManager.instance;
      if (strategyManager.strategyCount == 0) {
        // 首次使用，注册所有策略
        strategyManager.registerAll([
          LocalDbDownloadStrategy(),
          VivoDownloadStrategy(),
          GitHubDownloadStrategy(),
          HttpDownloadStrategy(),
          FdroidDownloadStrategy(),
        ]);
      }

      final request = await strategyManager.createRequest(download, detail);
      final DownloadTask task;
      if (request == null) {
        // 策略创建失败，降级为直接下载（用详情 URL）
        task = await service.download(
          appId,
          name,
          download.version ?? version,
          download.url,
          download.name,
          installAfterDownload: installAfterDownload,
        );
      } else {
        task = await service.downloadWithContext(
          request,
          appId,
          name,
          download.version ?? version,
          download.name,
          installAfterDownload: installAfterDownload,
        );
      }

      _watchDownloadProgress(service, task, onStatus, onFinished);
      return '已开始下载 $name，保存路径: ${task.filePath}';
    } catch (e) {
      return '下载失败: $e';
    }
  }

  /// 订阅下载任务流，实时推送进度（进度条/百分比/终态）。
  ///
  /// [IDownloadService.download] 只创建排队任务（status=queued）并异步启动，
  /// 立即返回——需订阅 [IDownloadService.watch] 才能拿到真实进度与终态。
  /// 每次状态变化回调 [onStatus]（节流由引擎/仓库层保证），终态后自动取消订阅。
  /// [onFinished] 终态回调（success, message）——供异步任务等待：下载完成/失败时
  /// 更新消息卡并触发 agent 继续生成（不阻塞本轮生成流）。
  /// 附带下载进度通知汇报（退出 AI 页面后仍可见，B2）。
  void _watchDownloadProgress(
    IDownloadService service,
    DownloadTask task,
    void Function(DownloadTask)? onStatus,
    void Function(bool success, String message)? onFinished,
  ) {
    final id = task.id;
    if (id == null) {
      onStatus?.call(task);
      return;
    }

    // 先推送一次当前状态（可能已是终态：极快完成/缓存命中）
    onStatus?.call(task);
    _publishDownloadNotification(task);

    // 订阅流：progress/merging/completed/failed 均推送，终态后取消
    StreamSubscription<DownloadTask>? sub;
    sub = service.watch(id).listen((da) {
      if (_cancelRequested) {
        // 用户停止：取消下载并结束订阅
        try {
          service.cancel(id);
        } catch (_) {}
        sub?.cancel();
        _downloadWatchSubs.remove(id);
        return;
      }
      onStatus?.call(da);
      _publishDownloadNotification(da);
      _currentDownloadStatus = da;
      final terminal = da.status == DownloadStatusEnum.completed ||
          da.status == DownloadStatusEnum.failed ||
          da.status == DownloadStatusEnum.cancelled ||
          da.status == DownloadStatusEnum.paused;
      if (terminal) {
        sub?.cancel();
        _downloadWatchSubs.remove(id);
        _currentDownloadStatus = null;
        // 终态通知（成功/失败）
        _publishDownloadTerminal(da);
        // 异步任务完成回调：驱动 agent 继续
        final success = da.status == DownloadStatusEnum.completed;
        onFinished?.call(
          success,
          success
              ? '${da.appName} 已下载完成，保存路径: ${da.filePath}'
              : '${da.appName} 下载失败：${da.error ?? '未知原因'}',
        );
      }
    });

    // 竞态兜底：任务在订阅前已终态（watch 不再推送）时，读一次当前状态收尾
    unawaited(service.getTask(id).then((current) {
      if (current != null) {
        final terminal = current.status == DownloadStatusEnum.completed ||
            current.status == DownloadStatusEnum.failed ||
            current.status == DownloadStatusEnum.cancelled ||
            current.status == DownloadStatusEnum.paused;
        if (terminal) {
          onStatus?.call(current);
          _publishDownloadTerminal(current);
          sub?.cancel();
          _downloadWatchSubs.remove(id);
          _currentDownloadStatus = null;
          final success = current.status == DownloadStatusEnum.completed;
          onFinished?.call(
            success,
            success
                ? '${current.appName} 已下载完成，保存路径: ${current.filePath}'
                : '${current.appName} 下载失败：${current.error ?? '未知原因'}',
          );
        }
      }
    }));

    // 保留引用防止被 GC；终态后由回调 cancel
    _downloadWatchSubs[id] = sub;
  }

  /// 推送下载进度通知（B2：退出页面后仍可见；页面内对话时消息卡进度条已实时展示，跳过）
  void _publishDownloadNotification(DownloadTask task) {
    if (!_notifyOnlyWhenBackground) return;
    try {
      AgentNotificationService.instance.init();
      final percent =
          task.total > 0 ? (task.received / task.total * 100).round() : 0;
      AgentNotificationService.instance.onToolProgress(
        title: 'AI 助手 · 下载中',
        message: '${task.appName} · $percent%',
        progress: task.received,
        maxProgress: task.total,
      );
    } catch (e) {
      appLog.error('AgentService: 下载进度通知失败 - $e');
    }
  }

  /// 推送下载终态通知（成功/失败；页面内对话时消息卡已展示，跳过）
  void _publishDownloadTerminal(DownloadTask task) {
    if (!_notifyOnlyWhenBackground) return;
    try {
      AgentNotificationService.instance.init();
      final success = task.status == DownloadStatusEnum.completed;
      AgentNotificationService.instance.onToolDone(
        success: success,
        message: success
            ? '${task.appName} 已下载完成'
            : '${task.appName} 下载失败：${task.error ?? '未知原因'}',
      );
    } catch (e) {
      appLog.error('AgentService: 下载终态通知失败 - $e');
    }
  }

  /// 解析渠道实例：枚举渠道 type.code 优先，其次动态脚本渠道 channelKey（js_xxx）。
  /// 脚本渠道不在 ChannelType 枚举内，统一走 getChannelByCode 才能命中。
  IChannel? _resolveChannel(String code) {
    if (code.isEmpty) return null;
    final manager = ChannelManager.instance;
    final type = ChannelType.fromCode(code);
    if (type != null) {
      final ch = manager.getChannel(type);
      if (ch != null) return ch;
    }
    return manager.getChannelByCode(code);
  }

  /// 执行脚本渠道（js_xxx）的自定义方法——Agent 渠道包 JS 执行能力。
  ///
  /// [channel] 脚本渠道 channelKey（如 js_pingan）；
  /// [method] 脚本 main 分发的函数名（如 getConfig/versionOptions/自定义方法）；
  /// [params] 透传给脚本的参数 map。
  /// 依赖 JsChannel.callMethod 入口；脚本未实现/失败 → 返回 null 提示降级。
  Future<String> _runJsChannel(String channel, String method, dynamic params) async {
    if (channel.isEmpty) return '执行脚本渠道方法需要 channel（如 js_pingan）';
    if (method.isEmpty) return '执行脚本渠道方法需要 method';
    try {
      final inst = _resolveChannel(channel);
      if (inst is! JsChannel) {
        return '渠道 $channel 不是脚本渠道（js_xxx），无法执行脚本方法';
      }
      final args = params is Map
          ? params.map((k, v) => MapEntry(k.toString(), v))
          : null;
      _updateToolStep('执行脚本方法 $method…');
      final result = await inst.callMethod(method, args);
      _updateToolStep('脚本方法 $method 已返回');
      if (result == null) {
        return '脚本 $channel 未实现方法 $method 或执行失败（返回 null）';
      }
      return '脚本 $channel.$method 返回：\n${result.toString()}';
    } catch (e) {
      return '执行脚本方法失败: $e';
    }
  }

  /// 通过搜索解析 vivo 应用的 vivoId
  /// 搜索结果中 vivo 渠道应用的 repositories 字段存有 vivoId
  Future<String> _resolveVivoId(String packageName) async {
    try {
      final manager = ChannelManager.instance;
      final result = await manager.searchApps(
        packageName,
        from: ChannelType.vivo,
        forceRefresh: true,
      );
      if (result.success && result.data != null) {
        for (final app in result.data!) {
          // 精确匹配包名
          if (app.appId == packageName && app.repositories.isNotEmpty) {
            appLog.info('AgentService: 解析 vivoId - ${app.repositories} ($packageName)');
            return app.repositories;
          }
        }
        // 兜底：取第一个非空 repositories
        for (final app in result.data!) {
          if (app.repositories.isNotEmpty) {
            return app.repositories;
          }
        }
      }
    } catch (e) {
      appLog.error('AgentService: 解析 vivoId 失败 - $e');
    }
    return '';
  }

  /// 安装应用
  Future<String> _installApp(String savePath) async {
    // 安装模块下线 → 注册表取不到服务，降级提示不抛
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) return '安装模块未启用';
    if (savePath.isEmpty) return '安装路径不能为空';

    try {
      if (!savePath.endsWith('.apk')) {
        return '仅支持安装 APK 文件: $savePath';
      }
      final file = File(savePath);
      if (!await file.exists()) {
        return 'APK 文件不存在: $savePath';
      }

      // 使用 InstallManager 统一安装（Shizuku 静默安装优先，回退系统安装）
      final (success, method) = await manager.installApk(savePath);
      if (!success) {
        return '安装失败，请检查 APK 文件或重试';
      }
      return method == InstallMethod.shizuku
          ? '已静默安装 $savePath'
          : '安装请求已发送，请在弹出的系统安装界面确认。';
    } catch (e) {
      return '安装失败: $e';
    }
  }

  /// 管理已添加应用（list/add/remove/isAdded）
  Future<String> _manageApp(String action, String appId, String channel, String name) async {
    try {
      final aggregator = AppAggregatorManager.instance;

      switch (action) {
        case 'list':
          final apps = await aggregator.getAllAddedApps();
          if (apps.isEmpty) return '我的应用中还没有添加任何应用。';
          final lines = apps
              .map((a) => '• ${a.appId} 渠道: ${a.channelId}')
              .toList();
          return '我的应用共 ${apps.length} 个：\n${lines.join('\n')}';

        case 'add':
          if (appId.isEmpty || channel.isEmpty) {
            return '添加应用需要 appId 和 channel';
          }
          final manager = ChannelManager.instance;
          final channelInst = manager.getChannelByCode(channel);
          if (channelInst == null) return '渠道 $channel 不可用';
          final result = await channelInst.getAppInfo(appId);
          if (!result.success || result.data == null) {
            return '获取应用信息失败: ${result.error ?? '未知错误'}';
          }
          await aggregator.addApp(channelCode: channel, appInfo: result.data!);
          return '已添加 ${result.data!.name ?? appId} 到我的应用';

        case 'remove':
          if (appId.isEmpty || channel.isEmpty) {
            return '移除应用需要 appId 和 channel';
          }
          await aggregator.removeApp(channelCode: channel, appId: appId);
          return '已移除 $name（$appId）';

        case 'isAdded':
          if (appId.isEmpty || channel.isEmpty) {
            return '检查需要 appId 和 channel';
          }
          final isAdded = await aggregator.isAppAdded(channelCode: channel, appId: appId);
          return isAdded ? '$appId 已在我的应用中' : '$appId 尚未添加';

        default:
          return '未知操作: $action（支持 list/add/remove/isAdded）';
      }
    } catch (e) {
      return '管理应用失败: $e';
    }
  }

  /// 渠道应用管理（渠道数据库中的已添加应用）
  Future<String> _manageChannelApp(
    String action,
    String appId,
    String channel,
    String name,
  ) async {
    if (channel.isEmpty) return '渠道管理需要指定 channel';
    try {
      final manager = ChannelManager.instance;
      final inst = _resolveChannel(channel);
      if (inst == null) return '未知渠道: $channel';
      final channelLabel =
          ChannelType.fromCode(channel)?.description ?? '脚本渠道 $channel';

      switch (action) {
        case 'list':
          final result = await inst.getAllApps(forceRefresh: true);
          if (!result.success || result.data == null) {
            return '获取渠道应用失败: ${result.error ?? '未知错误'}';
          }
          if (result.data!.isEmpty) {
            return '$channelLabel 渠道暂无已添加应用';
          }
          final lines = result.data!
              .map((a) => '• ${a.name} (${a.appId})')
              .toList();
          return '$channelLabel 渠道应用共 ${result.data!.length} 个：\n${lines.join('\n')}';

        case 'add':
          if (appId.isEmpty) return '添加渠道应用需要 appId';
          final appInfo = AppSummary(
            appId: appId,
            packageName: null,
            name: name.isEmpty ? appId : name,
            user: '',
            repositories: '',
            icon: '',
            des: '',
          );
          final r = await inst.addApp(appInfo);
          return r.success
              ? '已添加 ${name.isEmpty ? appId : name} 到$channelLabel渠道'
              : '添加失败: ${r.error ?? '未知错误'}';

        case 'remove':
          if (appId.isEmpty) return '移除渠道应用需要 appId';
          final r = await inst.removeApp(appId);
          return r.success
              ? '已从$channelLabel渠道移除 $appId'
              : '移除失败: ${r.error ?? '未知错误'}';

        default:
          return '未知操作: $action（支持 list/add/remove）';
      }
    } catch (e) {
      return '渠道管理失败: $e';
    }
  }

  /// 获取应用详情（含版本、简介等）
  Future<String> _getAppInfo(String appId, String channel) async {
    if (appId.isEmpty) return '需要 appId';
    try {
      final manager = ChannelManager.instance;
      final inst = channel.isNotEmpty ? _resolveChannel(channel) : null;
      if (inst == null) {
        // 未指定渠道，尝试从所有渠道获取
        for (final ch in ChannelType.values) {
          final c = manager.getChannel(ch);
          if (c == null) continue;
          final r = await c.getAppInfo(appId);
          if (r.success && r.data != null) {
            return _formatAppInfo(r.data!, ch);
          }
        }
        return '未找到应用 $appId';
      }
      final r = await inst.getAppInfo(appId, forceRefresh: true);
      if (!r.success || r.data == null) {
        return '获取应用信息失败: ${r.error ?? '未知错误'}';
      }
      final type = inst.info.type;
      return _formatAppInfo(r.data!, type);
    } catch (e) {
      return '获取应用详情失败: $e';
    }
  }

  /// 格式化应用信息
  String _formatAppInfo(AppSummary app, ChannelType channel) {
    final buffer = StringBuffer()
      ..writeln('应用: ${app.name}')
      ..writeln('包名: ${app.appId}')
      ..writeln('渠道: ${channel.code}')
      ..writeln('开发者: ${app.user}');
    if (app.des.isNotEmpty) {
      buffer.writeln('简介: ${app.des}');
    }
    return buffer.toString();
  }

  /// 检查应用更新
  Future<String> _checkUpdates(String appId, String channel) async {
    try {
      final manager = UpdateManagerService.instance;

      // 指定应用时只查该应用（渠道直查或读缓存，不污染全量）
      if (appId.isNotEmpty) {
        _updateToolStep('检查 $appId 更新…');
        if (channel.isEmpty) {
          return '检查更新需要指定渠道 channel';
        }
        final info = await manager.checkApp(appId, channelCode: channel);
        if (info == null) {
          return '$appId 未发现可更新（未安装/渠道无版本/已是最新）';
        }
        final appName = info.appName;
        return '$appName 有更新: ${info.installedVersion} → ${info.latestVersion}';
      }

      // 检查所有已添加应用：触发懒检测（锁+时间窗防重），然后读共享结果
      _updateToolStep('正在检查全部已添加应用的更新…');
      await manager.ensureChecked();
      final updates = manager.updatableApps;
      _updateToolStep('检查完成：发现 ${updates.length} 个可更新');
      if (updates.isEmpty) {
        return '已检查所有应用，均是最新版本。';
      }
      final lines = updates
          .map((u) => '• ${u.appName}: ${u.installedVersion} → ${u.latestVersion} ⬆ 可更新')
          .toList();
      return '发现 ${updates.length} 个可更新应用：\n${lines.join('\n')}';
    } catch (e) {
      return '更新检查失败: $e';
    }
  }

  /// 备份/恢复
  Future<String> _backup(String action, String filePath) async {
    try {
      // 经注册表取实现：backup 模块下线 → 降级提示（不抛）
      final service = ModuleManager.instance.get<IBackupService>();
      if (service == null) {
        return '备份模块未启用';
      }
      switch (action) {
        case 'export':
          // 统一 tar.gz 格式：生成压缩包字节并写入默认备份文件
          _updateToolStep('正在导出备份数据…');
          final bytes = await service.exportCompressedBackup();
          if (bytes.isEmpty) return '备份导出失败：生成字节为空';
          _updateToolStep('备份数据生成完成，写入文件…');
          final directory = await getApplicationDocumentsDirectory();
          final backupDir = Directory('${directory.path}/backups');
          if (!await backupDir.exists()) {
            await backupDir.create(recursive: true);
          }
          final timestamp =
              DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
          final target = '${backupDir.path}/gstore_backup_$timestamp.tar.gz';
          await File(target).writeAsBytes(bytes);
          _updateToolStep('备份完成');
          return '备份已导出: $target';
        case 'import':
          if (filePath.isEmpty) return '导入需要 filePath';
          _updateToolStep('正在从备份恢复…');
          await service.importFromFile(filePath);
          _updateToolStep('恢复完成');
          return '已从 $filePath 恢复';
        default:
          return '未知操作: $action（支持 export/import）';
      }
    } catch (e) {
      return '备份操作失败: $e';
    }
  }

  /// 下载管理
  Future<String> _manageDownloads(String action, String fileName) async {
    try {
      final repository = DownloadRepository();
      final service = ModuleManager.instance.get<IDownloadService>();
      switch (action) {
        case 'list':
          final items = await repository.all();
          if (items.isEmpty) return '暂无下载记录';
          final lines = items
              .map((d) => '• ${d.appName} ${d.fileName} 状态: ${_statusLabel(d.status)}')
              .toList();
          return '下载记录共 ${items.length} 条：\n${lines.join('\n')}';

        case 'pause':
          if (fileName.isEmpty) return '暂停需要 fileName';
          if (service == null) return '下载模块未启用';
          final items = await repository.all();
          final item = items.where((d) => d.fileName == fileName).firstOrNull;
          if (item == null) return '未找到下载: $fileName';
          final id = item.id;
          if (id == null) return '未找到下载: $fileName';
          await service.pause(id);
          return '已暂停 $fileName';

        case 'resume':
          if (fileName.isEmpty) return '恢复需要 fileName';
          if (service == null) return '下载模块未启用';
          final items = await repository.all();
          final item = items.where((d) => d.fileName == fileName).firstOrNull;
          if (item == null) return '未找到下载: $fileName';
          final id = item.id;
          if (id == null) return '未找到下载: $fileName';
          await service.resume(id);
          return '已恢复下载 $fileName';

        case 'cleanCompleted':
          final db = await downloadTaskDatabase;
          await db.database.delete(
            'DownloadTaskEntity',
            where: 'status IN (?, ?, ?)',
            whereArgs: [
              DownloadStatusEnum.completed.index,
              DownloadStatusEnum.failed.index,
              DownloadStatusEnum.cancelled.index,
            ],
          );
          return '已清理所有已完成下载记录';

        case 'clearAll':
          final db = await downloadTaskDatabase;
          await db.database.delete('DownloadTaskEntity');
          return '已清空所有下载记录';

        default:
          return '未知操作: $action（支持 list/pause/resume/cleanCompleted/clearAll）';
      }
    } catch (e) {
      return '下载管理失败: $e';
    }
  }

  /// 下载状态文字
  String _statusLabel(DownloadStatusEnum status) {
    switch (status) {
      case DownloadStatusEnum.queued:
      case DownloadStatusEnum.connecting:
      case DownloadStatusEnum.downloading:
        return '下载中';
      case DownloadStatusEnum.paused:
        return '已暂停';
      case DownloadStatusEnum.completed:
        return '已完成';
      case DownloadStatusEnum.failed:
        return '失败';
      case DownloadStatusEnum.cancelled:
        return '已取消';
    }
  }

  /// 应用配置管理（统一 ConfigService 门面，结构化快照输出）
  ///
  /// list/get 返回结构化 JSON（含类型/当前值/默认值/可选项/示例/分组），
  /// set/clear 返回结构化结果。修改后相关功能自动生效。
  Future<String> _configManager(String action, String key, Object? value) async {
    final service = ConfigService.instance;
    switch (action) {
      case 'list':
        final snapshots = await service.snapshots();
        if (snapshots.isEmpty) return '暂无可配置项';
        final json = jsonEncode(
          snapshots.map((s) => s.toJson()).toList(),
        );
        return json;

      case 'get':
        if (key.isEmpty) return 'get 需要 key';
        if (!service.has(key)) return '未知配置项: $key';
        if (!service.isAgentAccessible(key)) {
          return '配置项 $key 不允许 Agent 读取';
        }
        final snapshot = await service.snapshot(key);
        if (snapshot == null) return '配置 $key 未设置';
        return jsonEncode(snapshot.toJson());

      case 'set':
        if (key.isEmpty) return 'set 需要 key';
        if (!service.has(key)) return '未知配置项: $key';
        if (!service.isAgentAccessible(key)) {
          return '配置项 $key 不允许 Agent 修改';
        }
        final result = await service.set(
          key,
          value,
          source: ConfigChangeSource.agent,
        );
        return _formatOpResult(result);

      case 'clear':
        if (key.isEmpty) return 'clear 需要 key';
        if (!service.has(key)) return '未知配置项: $key';
        if (!service.isAgentAccessible(key)) {
          return '配置项 $key 不允许 Agent 修改';
        }
        final result = await service.clear(
          key,
          source: ConfigChangeSource.agent,
        );
        return _formatOpResult(result);

      default:
        return '未知操作: $action（支持 list/get/set/clear）';
    }
  }

  /// 格式化配置操作结果为结构化 JSON
  String _formatOpResult(ConfigOpResult result) {
    return jsonEncode({
      'success': result.success,
      'message': result.message,
      'key': result.key,
      'value': result.value,
      'defaultValue': result.defaultValue,
    });
  }

  /// 主题控制
  Future<String> _controlTheme(String action, String mode, String hexColor) async {
    try {
      // 主题模块下线 → 注册表取不到服务，降级提示不抛
      final controller = ModuleManager.instance.get<IThemeService>();
      if (controller == null) {
        return '主题模块未启用';
      }
      switch (action) {
        case 'mode':
          final appMode = switch (mode) {
            'light' => AppThemeMode.light,
            'dark' => AppThemeMode.dark,
            _ => AppThemeMode.system,
          };
          await controller.setThemeMode(appMode);
          return '已切换主题模式: $mode';

        case 'toggle':
          await controller.toggleTheme();
          return '已切换深浅色主题';

        case 'color':
          if (hexColor.isEmpty) return '设置颜色需要 hexColor（如 0xFF1976D2）';
          final color = _parseHexColor(hexColor);
          if (color == null) return '无法解析颜色: $hexColor（请用 0xFFRRGGBB 格式）';
          await controller.setCustomColorTheme(primaryColor: color);
          return '已设置主题色为 $hexColor';

        default:
          return '未知操作: $action（支持 mode/toggle/color）';
      }
    } catch (e) {
      return '主题操作失败: $e';
    }
  }

  /// 解析十六进制颜色
  Color? _parseHexColor(String hex) {
    try {
      var h = hex.replaceAll('0x', '').replaceAll('#', '');
      if (h.length == 6) h = 'FF$h';
      if (h.length != 8) return null;
      return Color(int.parse(h, radix: 16));
    } catch (_) {
      return null;
    }
  }

  /// F-Droid 仓库管理
  Future<String> _fdroidRepo(String action, String keyword, bool force) async {
    try {
      final manager = FdroidRepoManager.instance;
      switch (action) {
        case 'list':
          final sources = manager.getSources();
          if (sources.isEmpty) return '暂无 F-Droid 仓库';
          final lines = sources.map((s) => '• ${s.name} (${s.repoUrl})').toList();
          return 'F-Droid 仓库共 ${sources.length} 个：\n${lines.join('\n')}';

        case 'load':
          appLog.info('AgentService: fdroidRepo load 开始, force=$force');
          await manager.loadRepository(forceRefresh: force);
          final stats = await manager.getStatistics();
          appLog.info('AgentService: fdroidRepo load 完成');
          return 'F-Droid 仓库加载完成。应用总数: ${stats['apps'] ?? 0}';

        case 'search':
          if (keyword.isEmpty) return '搜索需要 keyword';
          final apps = await manager.searchApps(keyword, limit: 20);
          if (apps.isEmpty) return '未找到与"$keyword"相关的 F-Droid 应用';
          final lines = apps
              .take(10)
              .map((a) => '• ${a['name'] ?? '未知'} (${a['packageName'] ?? ''})')
              .toList();
          return '找到 ${apps.length} 个应用（显示前 ${lines.length} 个）：\n${lines.join('\n')}';

        case 'stats':
          final stats = await manager.getStatistics();
          return 'F-Droid 应用总数: ${stats['apps'] ?? 0}';

        default:
          return '未知操作: $action（支持 list/load/search/stats）';
      }
    } catch (e) {
      return 'F-Droid 操作失败: $e';
    }
  }

  /// WebDAV 云备份
  Future<String> _webdavSync(String action) async {
    final service = ModuleManager.instance.get<IWebDavService>();
    if (service == null) {
      // webdav 模块下线 → 降级返回，不抛
      return 'WebDAV 模块未启用，无法执行云备份操作';
    }

    try {
      final hasConfig = await WebDavConfigManager.instance.hasConfig();
      if (!hasConfig) {
        return '尚未配置 WebDAV，请先在"备份管理"中配置网盘。';
      }
      final config = await WebDavConfigManager.instance.loadConfig();

      switch (action) {
        case 'list':
          _updateToolStep('正在读取 WebDAV 网盘备份列表…');
          final client = WebDavClient(config!);
          final files = await client.listFiles(
            config.backupPath,
            pattern: 'gstore_backup_*.tar.gz',
          );
          if (files.isEmpty) {
            return 'WebDAV 网盘中暂无备份（路径: ${config.backupPath}）';
          }
          files.sort((a, b) => b.modified.compareTo(a.modified));
          final lines = files
              .take(20)
              .map((f) =>
                  '• ${f.name}  (${f.formattedSize}, ${f.modified.toLocal().toString().substring(0, 16)})')
              .toList();
          _updateToolStep('读取完成：${files.length} 个备份');
          return 'WebDAV 网盘共有 ${files.length} 个备份（显示前 ${lines.length} 个）：\n${lines.join('\n')}';

        case 'upload':
          _updateToolStep('正在上传备份到 WebDAV…');
          await service.uploadToWebDav(config: config!, compressed: true);
          _updateToolStep('上传完成');
          return '已备份到 WebDAV 网盘';

        case 'download':
          final remotePath = '${config!.backupPath}/';
          await service.downloadFromWebDav(
            config: config,
            remotePath: remotePath,
          );
          return '已从 WebDAV 网盘恢复';

        case 'status':
          return 'WebDAV 已配置: ${config!.url}';

        default:
          return '未知操作: $action（支持 list/upload/download/status）';
      }
    } catch (e) {
      return 'WebDAV 操作失败: $e';
    }
  }

  /// 已安装应用查询
  Future<String> _installedApps(String action, String keyword, String packageName) async {
    try {
      switch (action) {
        case 'list':
          final apps = await InstalledApps.getInstalledApps();
          if (apps.isEmpty) return '未获取到已安装应用';
          if (keyword.isNotEmpty) {
            final filtered = apps
                .where((a) =>
                    a.name.toLowerCase().contains(keyword.toLowerCase()) ||
                    a.packageName.toLowerCase().contains(keyword.toLowerCase()))
                .toList();
            if (filtered.isEmpty) return '未找到包含"$keyword"的应用';
            final lines = filtered
                .take(20)
                .map((a) => '• ${a.name} (${a.packageName})')
                .toList();
            return '找到 ${filtered.length} 个应用（显示前 ${lines.length} 个）：\n${lines.join('\n')}';
          }
          final lines = apps
              .take(30)
              .map((a) => '• ${a.name} (${a.packageName})')
              .toList();
          return '已安装应用共 ${apps.length} 个（显示前 ${lines.length} 个）：\n${lines.join('\n')}';

        case 'check':
          if (packageName.isEmpty) return '检查需要 packageName';
          final isInstalled = await InstalledApps.isAppInstalled(packageName);
          return (isInstalled == true) ? '$packageName 已安装' : '$packageName 未安装';

        case 'uninstall':
        case 'clearData':
        case 'clearCache':
        case 'forceStop':
          if (packageName.isEmpty) return '$action 需要 packageName';
          return _manageInstalledPackage(action, packageName);

        default:
          return '未知操作: $action（支持 list/check/uninstall/clearData/clearCache/forceStop）';
      }
    } catch (e) {
      return '已安装应用操作失败: $e';
    }
  }

  /// 管理已安装应用（卸载/清理/停止，需 Shizuku）
  Future<String> _manageInstalledPackage(String action, String packageName) async {
    // 安装模块下线 → 注册表取不到服务，降级提示不抛
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) return '安装模块未启用';
    if (!manager.isShizukuAvailable) {
      if (!manager.isChecked) await manager.checkShizuku();
      if (!manager.isShizukuAvailable) {
        return '需要 Shizuku 授权才能执行此操作。请先在"设置 → 安装与权限"中授权 Shizuku。';
      }
    }

    final actionLabel = switch (action) {
      'uninstall' => '卸载',
      'clearData' => '清理数据',
      'clearCache' => '清理缓存',
      'forceStop' => '强制停止',
      _ => '操作',
    };

    final ok = switch (action) {
      'uninstall' => await manager.managePackage(packageName, 'uninstall'),
      'clearData' => await manager.clearAppData(packageName),
      'clearCache' => await manager.clearAppCache(packageName),
      'forceStop' => await manager.forceStopApp(packageName),
      _ => false,
    };

    return ok ? '已$actionLabel $packageName' : '$actionLabel失败，请检查 Shizuku 权限或应用是否可操作';
  }

  /// 停止当前生成（对话流 + 工具调用）
  /// 由 AiChatWidget 的停止按钮回调调用
  void stopGenerating() {
    _cancelRequested = true;
    // 中断正在执行的下载工具
    final download = _currentDownloadStatus;
    if (download != null && download.isActive) {
      appLog.info('AgentService: 停止下载 - ${download.fileName}');
      final service = ModuleManager.instance.get<IDownloadService>();
      final id = download.id;
      if (service != null && id != null) {
        service.cancel(id);
      }
    }
    appLog.info('AgentService: 请求停止生成');
  }

  /// 发送用户消息并获取回复（流式输出）
  Future<void> chat(String userText) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) {
        _addAssistantMessage('请先在设置中配置 LLM 模型（我的 → AI 助手 → 模型设置）。',
            isToolResult: true);
        return;
      }
    }

    if (_busy) return;
    _busy = true;
    busy.value = true;

    // 开启新回合（该轮的用户/助手/工具消息共享 turnId）
    _currentTurnId = 'turn-${DateTime.now().millisecondsSinceEpoch}';

    _addUserMessage(userText);

    try {
      _messages.add(Message(
        role: Role.user,
        content: [TextPart(text: userText)],
      ));

      final ai = _ai!;
      final model = _getModelRef(_model!);

      // 创建一条流式消息（初始为空）
      // 工具调用时会被"定稿"为独立消息并新建承接，实现分步展示
      _activeStreamMsg = AgentMessage(
        isUser: false,
        text: '',
        turnId: _currentTurnId,
      );
      _addMessage(_activeStreamMsg!);

      final stream = ai.generateStream<dynamic, void>(
        model: model as ModelRef<dynamic>,
        messages: _messages,
        toolNames: registeredToolNames.isNotEmpty
            ? registeredToolNames
            : [
                searchToolName,
                downloadToolName,
                installToolName,
                manageAppToolName,
                appInfoToolName,
                updateAppsToolName,
                backupToolName,
                manageDownloadToolName,
                themeToolName,
                fdroidRepoToolName,
                webdavSyncToolName,
                installedAppsToolName,
                confirmToolName,
                configManagerToolName,
              ],
        maxTurns: 12,
      );

      // 流式累积文本
      await for (final chunk in stream) {
        // 用户请求停止 → 中断
        if (_cancelRequested) break;
        final text = chunk.text;
        if (text.isNotEmpty) {
          // 工具调用后 _activeStreamMsg 被置空：懒创建新消息，
          // 使其 seq 排在工具消息之后，保证"回复→工具→回复"顺序
          if (_activeStreamMsg == null) {
            _activeStreamMsg = AgentMessage(
              isUser: false,
              text: '',
              turnId: _currentTurnId,
            );
            _addMessage(_activeStreamMsg!);
          }
          _activeStreamMsg?.text = (_activeStreamMsg?.text ?? '') + text;
          _notifyMessages();
        }
      }

      // 若已停止，不再等待最终响应
      if (_cancelRequested) {
        appLog.info('AgentService: 已停止生成，保留已输出内容');
        final msg = _activeStreamMsg;
        if (msg != null) {
          msg.text = msg.text.trim().isEmpty ? '（已停止生成）' : msg.text.trim();
          _notifyMessages();
          _persistStreamMessage(msg);
        }
        _activeStreamMsg = null;
        return;
      }

      // 获取最终响应，更新消息历史
      final response = await stream.onResult;
      _messages = List.of(response.messages ?? _messages);

      // 最终文本兜底
      final msg = _activeStreamMsg;
      if (msg != null) {
        if (msg.text.trim().isEmpty) {
          // 工具调用后无后续文本的残留空消息：移除，不展示
          _removeMessage(msg);
        } else {
          msg.text = msg.text.trim();
          _notifyMessages();
          // 持久化助手消息
          _persistStreamMessage(msg);
        }
      }
      _activeStreamMsg = null;
    } catch (e) {
      appLog.error('AgentService: 生成失败 - $e');
      _addAssistantMessage('抱歉，请求失败：$e');
    } finally {
      _activeStreamMsg = null;
      _busy = false;
      busy.value = false;
      _currentTurnId = null;
      _cancelRequested = false;
    }
  }

  void _addUserMessage(String text) {
    final msg = AgentMessage(
      isUser: true,
      text: text,
      turnId: _currentTurnId,
    );
    _addMessage(msg);
    _persistMessage(msg);
  }

  void _addAssistantMessage(String text,
      {AgentToolType? toolType, bool isToolResult = false}) {
    final msg = AgentMessage(
      isUser: false,
      text: text,
      toolType: toolType,
      isToolResult: isToolResult,
      turnId: _currentTurnId,
    );
    _addMessage(msg);
    _persistMessage(msg);
  }

  /// 持久化流式助手消息（chat 完成后调用）
  void _persistStreamMessage(AgentMessage msg) {
    _persistMessage(msg);
  }

  /// 释放资源（模块下线时由 AgentToolsModule 调用；替代原 GetX onClose）
  void dispose() {
    _ai = null;
    _modelChangeSub?.cancel();
    _messages = [];
    messages.dispose();
    busy.dispose();
  }
}
