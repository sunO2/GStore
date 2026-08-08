import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart'
    hide AgentState;
import 'package:get/get.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_session_store.dart';
import 'package:gstore/core/agent/agent_skills.dart';
import 'package:gstore/core/agent/platform_arch.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
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
}

/// 工具执行状态
enum AgentToolStatus { running, done, error }

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
  DownloadStatus? downloadStatus;

  final DateTime time;

  /// 是否是工具消息
  final bool isToolResult;

  /// 消息序号（用于持久化后恢复顺序，实时按创建顺序递增）
  final int seq;

  /// 回合 ID（同一轮对话共享，用于绑定工具调用记录）
  final String? turnId;

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
class AgentService extends GetxService {
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

  Genkit? _ai;
  AgentModel? _model;
  AgentModelStore? _store;
  AgentSessionStore? _sessionStore;
  List<Message> _messages = [];
  bool _initialized = false;
  bool _busy = false;

  /// 是否请求停止当前生成（用户点击停止按钮）
  bool _cancelRequested = false;

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
  static const int initialHistoryPageSize = 30;

  /// 分页加载每页条数
  static const int historyPageSize = 30;

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

  /// 对话消息（UI 监听）
  final RxList<AgentMessage> messages = <AgentMessage>[].obs;

  /// 系统提示词（含设备架构信息）
  String get _systemPrompt => '''
你是 GStore 软件商店的智能助手。你帮助用户搜索、下载和安装开源应用，并管理应用、备份、主题等。

${PlatformArch.platformDescription}

可用工具：
1. searchApp - 搜索应用。输入 keyword（关键词）。返回匹配的应用列表（含名称、包名、简介、来源渠道）。支持 GitHub 渠道（走代理搜索仓库）。
2. downloadApp - 下载应用。输入 appId（包名/仓库名）、channel（渠道代码，如 github/fdroid/vivo）、url（下载地址，可选）、name（应用名）、version（版本号）。GitHub 渠道时系统会自动选择匹配当前 CPU 架构的 APK。vivo 渠道需传 vivoId。下载完成后自动解析 APK 获取真实包名/图标/应用名并更新。
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
14. confirmAction - 向用户发起确认。输入 question（确认问题，需清晰说明要执行的操作）。用于敏感/不可逆操作，用户需在界面上确认或取消。

敏感操作清单（执行前**必须**调用 confirmAction 让用户确认）：
- 卸载应用（installedApps 的 uninstall）
- 清理应用数据/缓存（installedApps 的 clearData/clearCache）
- 强制停止应用（installedApps 的 forceStop）
- 恢复备份/覆盖现有数据（backup 的 import 且会影响当前数据）
- 删除会话/清空数据（manageDownload 的 clearAll、backup 相关删除）
- 移除"我的应用"或渠道中的应用（manageApp remove / channelApp remove）
- 其他不可逆或影响较大的操作

确认流程：先调用 confirmAction 展示操作内容，用户确认后再执行实际操作；用户取消则不要执行并告知用户。

选项选择场景（也必须调用 confirmAction，带 options 让用户选择）：
- 用户需要决策时：如"你想怎么处理""要不要继续""用哪个版本""选哪个方案"等
- 多选一：当存在 2 个以上合理选项时，用 options 传入选项数组，让用户点选
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
- 下载完成后询问用户是否安装；确认后调用 installApp。
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

  /// 加载当前会话消息到 UI（分页：仅加载最近的 [initialHistoryPageSize] 条）
  /// 按消息序号（seq）排序恢复，保证与实时显示顺序一致
  void _loadSessionMessages() {
    _persistedToolIds.clear();
    final session = _sessionStore?.current;
    if (session == null) {
      messages.clear();
      _allSessionMessages = [];
      _loadedMessageCount = 0;
      return;
    }
    // 按 seq 排序（用户→助手→工具），与实时创建顺序一致
    _allSessionMessages = List.of(session.messages)
      ..sort((a, b) => a.seq.compareTo(b.seq));

    // 只加载最近的 initialHistoryPageSize 条
    _loadedMessageCount = _allSessionMessages.length > initialHistoryPageSize
        ? initialHistoryPageSize
        : _allSessionMessages.length;
    messages.value = _buildAgentMessages(
      _allSessionMessages.sublist(_allSessionMessages.length - _loadedMessageCount),
    );
  }

  /// 加载更早的一页历史消息，插入到消息列表头部（更早的位置）
  void loadMoreHistory() {
    if (!hasMoreHistory) return;
    final start = _allSessionMessages.length - _loadedMessageCount - historyPageSize;
    final from = start < 0 ? 0 : start;
    final count = _allSessionMessages.length - _loadedMessageCount - from;
    final older = _buildAgentMessages(
      _allSessionMessages.sublist(from, from + count),
    );
    // 插入头部（更早消息在前）
    messages.insertAll(0, older);
    _loadedMessageCount += count;
    appLog.info('AgentService: 加载更早历史 $count 条 (累计 $_loadedMessageCount)');
  }

  /// 将 SessionMessage 列表构建为 AgentMessage 列表
  List<AgentMessage> _buildAgentMessages(List<SessionMessage> list) {
    return list.map((m) {
      if (m.isToolResult) {
        // 工具消息：还原工具类型/状态/详情
        return AgentMessage(
          isUser: false,
          text: m.text,
          toolType: _toolTypeFromName(m.toolType),
          toolStatus: _toolStatusFromName(m.toolStatus),
          toolDetail: m.toolDetail,
          isToolResult: true,
          time: DateTime.fromMillisecondsSinceEpoch(m.time),
          seq: m.seq,
          turnId: m.turnId,
        );
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
    final newAll = List.of(session.messages)
      ..sort((a, b) => a.seq.compareTo(b.seq));
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
        return _runAction(
          downloadToolName,
          {
            'appId': appId,
            'channel': channel,
            'url': url,
            'name': name,
            'version': version,
            'vivoId': vivoId,
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
          {'action': action, 'keyword': keyword, 'force': force},
          detail: 'F-Droid 仓库: $action',
        );
      },
    );

    // WebDAV 云备份工具
    ai.defineTool<Map<String, dynamic>, String>(
      name: webdavSyncToolName,
      description:
          'WebDAV 云备份。action 为 upload（上传备份到网盘）、download（从网盘恢复）、status（检查配置状态）。',
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
    // 创建工具消息（加入消息流，持久显示）
    final msg = _addToolMessage(_toolTypeForName(name), detail ?? name);
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
      // 更新工具消息状态 + 持久化
      final data = result.data;
      final text = result.success
          ? (data is Map && data['result'] != null
              ? data['result'].toString()
              : '执行成功')
          : (result.error ?? '执行失败');
      _updateToolMessage(
        msg,
        status: result.success ? AgentToolStatus.done : AgentToolStatus.error,
        detail: text,
      );
      return text;
    } catch (e) {
      _updateToolMessage(msg, status: AgentToolStatus.error, detail: '执行失败: $e');
      return '执行失败: $e';
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
    messages.add(msg);
    return msg;
  }

  /// 更新工具消息状态（并持久化）
  void _updateToolMessage(
    AgentMessage msg, {
    bool? done,
    AgentToolStatus? status,
    String? detail,
    DownloadStatus? downloadStatus,
  }) {
    final idx = messages.indexWhere((e) => e.id == msg.id);
    if (idx < 0) return;
    final current = messages[idx];
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
    messages.refresh();
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
        ],
        handler: (params) async {
          final appId = params['appId']?.toString() ?? '';
          final channel = params['channel']?.toString() ?? '';
          final url = params['url']?.toString() ?? '';
          final name = params['name']?.toString() ?? '';
          final version = params['version']?.toString() ?? 'unknown';
          final vivoId = params['vivoId']?.toString();
          final result = await _downloadApp(
            appId, channel, url, name, version,
            vivoId: vivoId,
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
        description: 'WebDAV 云备份。action 为 upload/download/status。',
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
    ];
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
  Future<String> _downloadApp(String appId, String channel, String url,
      String name, String version,
      {String? vivoId, void Function(DownloadStatus)? onStatus}) async {
    if (appId.isEmpty) return '下载参数不完整（缺少 appId）';

    try {
      // 解析渠道类型
      final channelType = ChannelType.fromCode(channel);
      if (channelType == null) {
        return '未知渠道: $channel（支持: github/fdroid/vivo/http/local_db）';
      }

      DownloadStatus? status;
      final service = Get.find<DownloadService>();

      // 方式1：已有完整 URL，直接下载
      if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
        status = await service.download(
          appId,
          name,
          version,
          url,
          name,
        );
        onStatus?.call(status);
        return '已开始下载 $name，保存路径: ${status.savePath}';
      }

      // 方式2：通过渠道详情获取真实下载地址
      final manager = ChannelManager.instance;
      final channelInst = manager.getChannel(channelType);
      if (channelInst == null) {
        return '渠道 $channel 不可用';
      }

      // vivo 渠道需使用 vivoId 查询详情
      var detailAppId = appId;
      if (channelType == ChannelType.vivo && vivoId != null && vivoId.isNotEmpty) {
        detailAppId = vivoId;
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

      // 使用策略管理器创建下载上下文（自动选择对应渠道策略）
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

      final context = await strategyManager.createContext(download, detail);
      if (context == null) {
        // 策略创建失败，降级为直接下载（用详情 URL）
        status = await service.download(
          appId,
          name,
          download.version ?? version,
          download.url,
          download.name,
        );
      } else {
        status = await service.downloadWithContext(
          context,
          appId,
          name,
          download.version ?? version,
          download.name,
        );
      }

      onStatus?.call(status);
      return '已开始下载 $name，保存路径: ${status.savePath}';
    } catch (e) {
      return '下载失败: $e';
    }
  }

  /// 安装应用
  Future<String> _installApp(String savePath) async {
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
      final (success, method) = await InstallManager.instance.installApk(savePath);
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
              .map((a) => '• ${a.appName} (${a.appId}) 渠道: ${a.channelId}')
              .toList();
          return '我的应用共 ${apps.length} 个：\n${lines.join('\n')}';

        case 'add':
          if (appId.isEmpty || channel.isEmpty) {
            return '添加应用需要 appId 和 channel';
          }
          final channelType = ChannelType.fromCode(channel);
          if (channelType == null) return '未知渠道: $channel';
          // 通过渠道获取应用信息
          final manager = ChannelManager.instance;
          final channelInst = manager.getChannel(channelType);
          if (channelInst == null) return '渠道 $channel 不可用';
          final result = await channelInst.getAppInfo(appId);
          if (!result.success || result.data == null) {
            return '获取应用信息失败: ${result.error ?? '未知错误'}';
          }
          await aggregator.addApp(channel: channelType, appInfo: result.data!);
          return '已添加 ${result.data!.name ?? appId} 到我的应用';

        case 'remove':
          if (appId.isEmpty || channel.isEmpty) {
            return '移除应用需要 appId 和 channel';
          }
          final channelType = ChannelType.fromCode(channel);
          if (channelType == null) return '未知渠道: $channel';
          await aggregator.removeApp(channel: channelType, appId: appId);
          return '已移除 $name（$appId）';

        case 'isAdded':
          if (appId.isEmpty || channel.isEmpty) {
            return '检查需要 appId 和 channel';
          }
          final channelType = ChannelType.fromCode(channel);
          if (channelType == null) return '未知渠道: $channel';
          final isAdded = await aggregator.isAppAdded(channel: channelType, appId: appId);
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
      final channelType = ChannelType.fromCode(channel);
      if (channelType == null) return '未知渠道: $channel';
      final manager = ChannelManager.instance;
      final inst = manager.getChannel(channelType);
      if (inst == null) return '渠道 $channel 不可用';

      switch (action) {
        case 'list':
          final result = await inst.getAllApps(forceRefresh: true);
          if (!result.success || result.data == null) {
            return '获取渠道应用失败: ${result.error ?? '未知错误'}';
          }
          if (result.data!.isEmpty) {
            return '${channelType.description} 渠道暂无已添加应用';
          }
          final lines = result.data!
              .map((a) => '• ${a.name} (${a.appId})')
              .toList();
          return '${channelType.description} 渠道应用共 ${result.data!.length} 个：\n${lines.join('\n')}';

        case 'add':
          if (appId.isEmpty) return '添加渠道应用需要 appId';
          final appInfo = db.AppInfo(
            appId,
            name.isEmpty ? appId : name,
            '',
            '',
            '',
            '',
            null,
          );
          final r = await inst.addApp(appInfo);
          return r.success
              ? '已添加 ${name.isEmpty ? appId : name} 到${channelType.description}渠道'
              : '添加失败: ${r.error ?? '未知错误'}';

        case 'remove':
          if (appId.isEmpty) return '移除渠道应用需要 appId';
          final r = await inst.removeApp(appId);
          return r.success
              ? '已从${channelType.description}渠道移除 $appId'
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
      final channelType = channel.isNotEmpty ? ChannelType.fromCode(channel) : null;
      final manager = ChannelManager.instance;
      if (channelType == null) {
        // 未指定渠道，尝试从所有渠道获取
        for (final ch in ChannelType.values) {
          final inst = manager.getChannel(ch);
          if (inst == null) continue;
          final r = await inst.getAppInfo(appId);
          if (r.success && r.data != null) {
            return _formatAppInfo(r.data!, ch);
          }
        }
        return '未找到应用 $appId';
      }
      final inst = manager.getChannel(channelType);
      if (inst == null) return '渠道 $channel 不可用';
      final r = await inst.getAppInfo(appId, forceRefresh: true);
      if (!r.success || r.data == null) {
        return '获取应用信息失败: ${r.error ?? '未知错误'}';
      }
      return _formatAppInfo(r.data!, channelType);
    } catch (e) {
      return '获取应用详情失败: $e';
    }
  }

  /// 格式化应用信息
  String _formatAppInfo(AppInfo app, ChannelType channel) {
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
      final aggregator = AppAggregatorManager.instance;
      final manager = ChannelManager.instance;

      // 指定应用时只查该应用
      if (appId.isNotEmpty) {
        final channelType = channel.isNotEmpty
            ? ChannelType.fromCode(channel)
            : null;
        if (channelType == null) {
          return '检查更新需要指定渠道 channel';
        }
        final inst = manager.getChannel(channelType);
        if (inst == null) return '渠道 ${channelType.code} 不可用';

        final added =
            await aggregator.isAppAdded(channel: channelType, appId: appId);
        if (!added) return '$appId 不在我的应用中，无法检查更新';

        final checkResult = await inst.checkAppUpdate(appId);
        if (!checkResult.success || checkResult.data == null) {
          return '$appId 更新检查失败: ${checkResult.error ?? '未知错误'}';
        }
        final check = checkResult.data!;
        final appName = check.name.isNotEmpty ? check.name : appId;
        final latest = check.latestVersion ?? '未知';

        // 对比已安装版本
        final packageName = check.packageName.trim().isNotEmpty
            ? check.packageName.trim()
            : appId;
        final installed = await InstalledApps.getAppInfo(packageName);
        final installedVersion = installed?.versionName;
        if (installedVersion == null || latest == '未知') {
          return '$appName 最新版本: $latest（设备上未安装或无法获取版本）';
        }
        final hasUpdate = compareVersion(installedVersion, latest) == 1;
        return hasUpdate
            ? '$appName 有更新: $installedVersion → $latest'
            : '$appName 已是最新版本 ($latest)';
      }

      // 检查所有已添加应用
      final addedApps = await aggregator.getAllAddedApps();
      if (addedApps.isEmpty) return '我的应用列表为空，没有可检查的更新。';

      final updates = <String>[];
      int checked = 0;
      for (final added in addedApps) {
        try {
          final channelType = ChannelType.fromCode(added.channelId);
          if (channelType == null) continue;
          final inst = manager.getChannel(channelType);
          if (inst == null) continue;
          final checkResult = await inst.checkAppUpdate(added.appId);
          if (!checkResult.success || checkResult.data == null) continue;
          final check = checkResult.data!;
          checked++;

          final packageName = check.packageName.trim().isNotEmpty
              ? check.packageName.trim()
              : added.appId;
          final installed = await InstalledApps.getAppInfo(packageName);
          final installedVersion = installed?.versionName;
          final latest = check.latestVersion;
          final appName =
              check.name.isNotEmpty ? check.name : added.appName;

          if (installedVersion == null || latest == null) {
            updates.add('• $appName: 最新 $latest ?? 未安装');
            continue;
          }
          if (compareVersion(installedVersion, latest) == 1) {
            updates.add('• $appName: $installedVersion → $latest ⬆ 可更新');
          } else {
            updates.add('• $appName: 已是最新 ($latest)');
          }
        } catch (e) {
          // 单个应用失败不影响整体
        }
      }
      if (checked == 0) return '检查了 ${addedApps.length} 个应用，但未能获取更新信息。';
      return '已检查 ${addedApps.length} 个应用：\n${updates.join('\n')}';
    } catch (e) {
      return '更新检查失败: $e';
    }
  }

  /// 备份/恢复
  Future<String> _backup(String action, String filePath) async {
    try {
      final service = BackupService.instance;
      switch (action) {
        case 'export':
          final result = await service.exportToCompressedFile();
          return '备份已导出: ${result ?? '未知路径'}';
        case 'import':
          if (filePath.isEmpty) return '导入需要 filePath';
          await service.importFromFile(filePath);
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
      final db = await downloadStatusDatabase;
      switch (action) {
        case 'list':
          final items = await db.downloadStatusDao.getAllDownload().first;
          if (items.isEmpty) return '暂无下载记录';
          final lines = items
              .map((d) => '• ${d.appName} ${d.fileName} 状态: ${_statusLabel(d.status)}')
              .toList();
          return '下载记录共 ${items.length} 条：\n${lines.join('\n')}';

        case 'pause':
          if (fileName.isEmpty) return '暂停需要 fileName';
          final items = await db.downloadStatusDao.getAllDownload().first;
          final item = items.where((d) => d.fileName == fileName).firstOrNull;
          if (item == null) return '未找到下载: $fileName';
          item.cancelDownload();
          return '已暂停 $fileName';

        case 'resume':
          if (fileName.isEmpty) return '恢复需要 fileName';
          final items = await db.downloadStatusDao.getAllDownload().first;
          final item = items.where((d) => d.fileName == fileName).firstOrNull;
          if (item == null) return '未找到下载: $fileName';
          final service = Get.find<DownloadService>();
          await service.download(
            item.appId, item.appName, item.version, item.downloadUrl, item.fileName,
            downloadSize: item.total,
          );
          return '已恢复下载 $fileName';

        case 'cleanCompleted':
          await db.downloadStatusDao.deleteCompletedDownloads();
          return '已清理所有已完成下载记录';

        case 'clearAll':
          await db.downloadStatusDao.deleteAllDownloads();
          return '已清空所有下载记录';

        default:
          return '未知操作: $action（支持 list/pause/resume/cleanCompleted/clearAll）';
      }
    } catch (e) {
      return '下载管理失败: $e';
    }
  }

  /// 下载状态文字
  String _statusLabel(int status) {
    switch (status) {
      case DownloadStatus.DOWNLOAD_LOADING:
        return '下载中';
      case DownloadStatus.DOWNLOAD_SUCCESS:
        return '已完成';
      case DownloadStatus.DOWNLOAD_ERROR:
        return '失败';
      default:
        return '等待中';
    }
  }

  /// 主题控制
  Future<String> _controlTheme(String action, String mode, String hexColor) async {
    try {
      final controller = Get.find<ThemeController>();
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
          await manager.loadRepository(forceRefresh: force);
          final stats = await manager.getStatistics();
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
    try {
      final hasConfig = await WebDavConfigManager.instance.hasConfig();
      if (!hasConfig) {
        return '尚未配置 WebDAV，请先在"备份管理"中配置网盘。';
      }
      final config = await WebDavConfigManager.instance.loadConfig();
      final service = BackupService.instance;

      switch (action) {
        case 'upload':
          await service.uploadToWebDav(config: config!, compressed: true);
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
          return '未知操作: $action（支持 upload/download/status）';
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
    final manager = InstallManager.instance;
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
      final streamMsg = AgentMessage(
        isUser: false,
        text: '',
        turnId: _currentTurnId,
      );
      messages.add(streamMsg);

      final stream = ai.generateStream<dynamic, void>(
        model: model as ModelRef<dynamic>,
        messages: _messages,
        toolNames: [
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
        ],
        maxTurns: 12,
      );

      // 流式累积文本
      final buffer = StringBuffer();
      await for (final chunk in stream) {
        // 用户请求停止 → 中断
        if (_cancelRequested) break;
        final text = chunk.text;
        if (text.isNotEmpty) {
          buffer.write(text);
          streamMsg.text = buffer.toString();
          messages.refresh();
        }
      }

      // 若已停止，不再等待最终响应
      if (_cancelRequested) {
        appLog.info('AgentService: 已停止生成，保留已输出内容');
        streamMsg.text = buffer.toString().trim().isEmpty
            ? '（已停止生成）'
            : buffer.toString().trim();
        messages.refresh();
        _persistStreamMessage(streamMsg);
        return;
      }

      // 获取最终响应，更新消息历史
      final response = await stream.onResult;
      _messages = List.of(response.messages ?? _messages);

      // 最终文本兜底
      final finalText = buffer.toString().trim();
      streamMsg.text = finalText.isEmpty ? '（没有生成回复，请重试）' : finalText;
      messages.refresh();
      // 持久化助手消息
      _persistStreamMessage(streamMsg);
    } catch (e) {
      appLog.error('AgentService: 生成失败 - $e');
      _addAssistantMessage('抱歉，请求失败：$e');
    } finally {
      _busy = false;
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
    messages.add(msg);
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
    messages.add(msg);
    _persistMessage(msg);
  }

  /// 持久化流式助手消息（chat 完成后调用）
  void _persistStreamMessage(AgentMessage msg) {
    _persistMessage(msg);
  }

  @override
  void onClose() {
    _ai = null;
    _messages.clear();
    messages.clear();
    super.onClose();
  }
}
