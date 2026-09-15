/// Agent 工具协议注册表（单一来源）
///
/// 背景：此前工具元数据（名称/描述/参数）在 4 处各写一遍 ——
/// [AgentPrompt]、`AgentService._systemPrompt`、`_defineTools()`、`builtin_tools.dart`，
/// 极易漂移（如 `cacheManage` 曾漏登记）。这里收敛为**唯一事实来源**：
/// - [AgentToolSpec]：声明式描述一个工具（分组/简介/完整协议/参数/敏感动作）
/// - [AgentToolCatalog]：收集全部 spec，并据此**自动生成**
///   系统提示词的"工具目录"、function-calling 描述、AiAction 定义、敏感操作清单
///
/// 分层注入（协议化）：
/// - 常驻上下文 = 分组 + 一行 [AgentToolSpec.brief]（见 [AgentToolCatalog.briefDirectory]）
/// - 按需详情 = 模型调用元工具 `toolProtocol` 取 [AgentToolSpec.protocol]
library;

import 'agent_tool_module.dart';

/// 工具分组（决定提示词目录的编排顺序）
class AgentToolGroup {
  AgentToolGroup._();

  static const String discover = '发现与信息';
  static const String acquire = '获取与安装';
  static const String manage = '管理与偏好';
  static const String snapshot = '快照与版本分析';
  static const String interact = '交互与扩展';
  static const String meta = '元能力';

  /// 分组展示顺序
  static const List<String> order = [
    discover,
    acquire,
    manage,
    snapshot,
    interact,
    meta,
  ];
}

/// 单个 Agent 工具的协议描述
class AgentToolSpec {
  /// 工具名（function calling 标识，如 searchApp）
  final String name;

  /// 所属分组（见 [AgentToolGroup]）
  final String group;

  /// 中文标签（UI 时间轴/通知文案）
  final String label;

  /// 一行简介：常驻系统提示词 + function-calling 描述
  ///
  /// 必须自解释"何时用/用哪个"，因为它是模型路由的唯一依据。
  final String brief;

  /// 完整协议：参数细节、使用规则、注意事项、示例。
  /// 不常驻，模型经 `toolProtocol` 按需读取。
  final String protocol;

  /// 参数定义（生成 AiAction 参数 + 协议文本）
  final List<AgentToolParam> params;

  /// 需要用户确认（confirmAction）的 action 取值；空表示无敏感动作
  final List<String> sensitiveActions;

  /// 敏感动作的可读说明（生成提示词清单用；为空则回退到 [sensitiveActions]）
  final List<String> sensitiveNotes;

  /// 是否整个工具都属敏感操作（如 cacheManage 一律需确认）
  final bool alwaysSensitive;

  /// 是否为异步长任务（如下载：消息卡保持 running 至终态）
  final bool async;

  /// 是否为元能力工具（读取其它工具/技能协议；由 AgentService 内部实现，
  /// 不作为可插拔模块参与上下线）
  final bool meta;

  /// 是否默认启用（false 时不注册到模型）
  final bool enabled;

  const AgentToolSpec({
    required this.name,
    required this.group,
    required this.label,
    required this.brief,
    required this.protocol,
    this.params = const [],
    this.sensitiveActions = const [],
    this.sensitiveNotes = const [],
    this.alwaysSensitive = false,
    this.async = false,
    this.meta = false,
    this.enabled = true,
  });

  /// 是否为敏感工具调用（按 action 判定）
  bool isSensitiveCall(Map<String, dynamic> params) {
    if (alwaysSensitive) return true;
    if (sensitiveActions.isEmpty) return false;
    final action = params['action']?.toString() ?? '';
    return sensitiveActions.contains(action);
  }

  /// 渲染为"目录"行
  String renderBriefLine() => '  • $name — $brief';

  /// 渲染为按需协议文本
  String renderProtocol() {
    final buf = StringBuffer()
      ..writeln('【工具】$name（$label｜分组：$group）')
      ..writeln('【简介】$brief');
    if (params.isNotEmpty) {
      buf.writeln('【参数】');
      for (final p in params) {
        buf.writeln(
            '  - ${p.name}${p.required ? '(必填)' : ''}: ${p.description}［${p.type}］');
      }
    }
    if (alwaysSensitive) {
      buf.writeln('【安全】该工具属敏感操作，执行前必须先经 confirmAction 确认。');
    } else if (sensitiveActions.isNotEmpty) {
      buf.writeln('【安全】action=${sensitiveActions.join('/')} 时属敏感操作，'
          '执行前必须先经 confirmAction 确认。');
    }
    buf.writeln('【协议】');
    buf.write(protocol);
    return buf.toString().trimRight();
  }
}

/// 工具协议注册表
///
/// 收集全部 [AgentToolSpec]（内置 + 运行时注册），并派生所有下游视图。
class AgentToolCatalog {
  AgentToolCatalog._();

  static final List<AgentToolSpec> _specs = [];

  /// 内置协议是否已装载（首次访问任一视图时惰性装载）
  static bool _builtinsLoaded = false;

  static void _ensureBuiltins() {
    if (_builtinsLoaded) return;
    _builtinsLoaded = true;
    registerAll(kBuiltinToolSpecs);
  }

  /// 运行时注册（自动收集；同 name 覆盖）
  static void register(AgentToolSpec spec) {
    final idx = _specs.indexWhere((s) => s.name == spec.name);
    if (idx >= 0) {
      _specs[idx] = spec;
    } else {
      _specs.add(spec);
    }
  }

  /// 批量注册
  static void registerAll(Iterable<AgentToolSpec> specs) {
    for (final s in specs) {
      register(s);
    }
  }

  /// 全部工具规格
  static List<AgentToolSpec> get all {
    _ensureBuiltins();
    return List.unmodifiable(_specs);
  }

  /// 已启用工具
  static List<AgentToolSpec> get enabled {
    _ensureBuiltins();
    return _specs.where((s) => s.enabled).toList();
  }

  /// 按名查找
  static AgentToolSpec? byName(String name) {
    _ensureBuiltins();
    for (final s in _specs) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 当前出现过的分组（按 [AgentToolGroup.order] 排序）
  static List<String> get groups {
    final present = <String>{for (final s in enabled) s.group};
    return [
      for (final g in AgentToolGroup.order)
        if (present.contains(g)) g,
      // 非标准分组的兜底（自定义工具）
      ...present.where((g) => !AgentToolGroup.order.contains(g)),
    ];
  }

  /// 按分组取工具
  static List<AgentToolSpec> groupOf(String group) =>
      enabled.where((s) => s.group == group).toList();

  /// 常驻"工具目录"（分组 + 一行简介）
  ///
  /// 这是模型看到的全部工具元信息；详细参数经 `toolProtocol` 按需获取。
  static String briefDirectory() {
    final buf = StringBuffer();
    for (final g in groups) {
      buf.writeln('▸ $g');
      for (final s in groupOf(g)) {
        buf.writeln(s.renderBriefLine());
      }
    }
    return buf.toString().trimRight();
  }

  /// 生成式敏感操作清单（单一来源：spec.sensitiveActions / alwaysSensitive）
  static List<String> get sensitiveLines {
    final lines = <String>[];
    for (final s in enabled) {
      if (s.alwaysSensitive) {
        lines.add('- ${s.label}（${s.name}）');
      } else if (s.sensitiveActions.isNotEmpty) {
        final notes =
            s.sensitiveNotes.isNotEmpty ? s.sensitiveNotes.join('、') : s.label;
        lines.add(
            '- ${s.label}：$notes（${s.name}: ${s.sensitiveActions.join('/')}）');
      }
    }
    return lines;
  }

  /// 取某工具的完整协议（元工具 loadProtocol 的数据源）
  static String? protocolFor(String name) => byName(name)?.renderProtocol();

  /// 清空（测试用；同时重置内置装载标记，便于重新装载）
  static void clear() {
    _specs.clear();
    _builtinsLoaded = false;
  }
}

/// 内置工具协议声明（唯一来源）
///
/// 注意：这里同时是 `builtin_tools.dart`、系统提示词、AiAction 的元数据来源。
const List<AgentToolSpec> kBuiltinToolSpecs = [
  // ==================== 发现与信息 ====================
  AgentToolSpec(
    name: 'searchApp',
    group: AgentToolGroup.discover,
    label: '搜索应用',
    brief: '跨渠道搜索应用；输入 keyword，返回名称/包名/简介/来源渠道。',
    params: [
      AgentToolParam(name: 'keyword', description: '搜索关键词', required: true),
    ],
    protocol: '''
1. 用户说"找/搜索/有没有 XX 应用"时先调用本工具。
2. 遍历全部渠道（GitHub 走代理、F-Droid、vivo、脚本渠道 js_xxx）。
3. 结果含 appId 与渠道 code，供 downloadApp/getAppInfo 复用。
4. 优先推荐开源渠道（GitHub/F-Droid），无合适再推荐 vivo 热门，并标注来源。
5. 只做推荐，不要直接下载；询问用户后再走 downloadApp。
6. 无结果时换关键词或检查渠道/网络，不要重复无意义搜索。''',
  ),
  AgentToolSpec(
    name: 'getAppInfo',
    group: AgentToolGroup.discover,
    label: '应用详情',
    brief: '取应用详情/版本；需 appId+channel，版本优先取 release APK 元数据。',
    params: [
      AgentToolParam(name: 'appId', description: '应用 ID/包名/仓库名', required: true),
      AgentToolParam(name: 'channel', description: '渠道代码', required: true),
    ],
    protocol: '''
1. 需要确认应用名称/开发者/简介/最新版本时调用。
2. appId 与 channel 必须成对传入（channel 为渠道 code，脚本渠道传 js_xxx）。
3. 版本信息优先取 metadata（从 release APK 提取，比 tag 更准）。
4. 未指定渠道时会遍历常规渠道查找，命中即返回。''',
  ),
  AgentToolSpec(
    name: 'updateApps',
    group: AgentToolGroup.discover,
    label: '检查更新',
    brief: '检查更新；appId/channel 可选（缺省检查全部已添加应用）。',
    params: [
      AgentToolParam(name: 'appId', description: '应用 ID（可选）'),
      AgentToolParam(name: 'channel', description: '渠道代码（可选）'),
    ],
    protocol: '''
1. 用户问"有更新吗/检查更新/更新 XX"时调用。
2. 传 appId+channel 只查该应用；不传则检查全部已添加应用。
3. 返回"当前版本 → 最新版本"，并标记可更新项。
4. 更新时可手动选择 APK（文件名相似度记忆，偏好已持久化）。
5. 无更新直接告知已是最新；单应用失败说明原因并建议重试。''',
  ),
  AgentToolSpec(
    name: 'installedApps',
    group: AgentToolGroup.discover,
    label: '已安装应用',
    brief: '管理本机已安装应用；action=list/check/uninstall/clearData/clearCache/forceStop。',
    params: [
      AgentToolParam(
          name: 'action',
          description: 'list/check/uninstall/clearData/clearCache/forceStop',
          required: true),
      AgentToolParam(name: 'keyword', description: 'list 时的过滤关键词'),
      AgentToolParam(name: 'packageName', description: '包名（check/uninstall/clear*/forceStop 必填）'),
    ],
    sensitiveActions: ['uninstall', 'clearData', 'clearCache', 'forceStop'],
    sensitiveNotes: ['卸载应用', '清理应用数据', '清理应用缓存', '强制停止应用'],
    protocol: '''
1. 查询用 list（可带 keyword 过滤）或 check（需 packageName）。
2. uninstall/clearData/clearCache/forceStop 为**不可逆/高影响**操作，
   必须先经 confirmAction 取得用户确认，再执行。
3. 卸载/清理/停止依赖 Shizuku 授权；未授权时提示用户到"设置 → 安装与权限"授权。
4. 反馈要区分成功/失败及原因，不要编造结果。''',
  ),
  AgentToolSpec(
    name: 'fdroidRepo',
    group: AgentToolGroup.discover,
    label: 'F-Droid 仓库',
    brief: '管理 F-Droid 仓库；action=list/load/search/stats。',
    params: [
      AgentToolParam(name: 'action', description: 'list/load/search/stats', required: true),
      AgentToolParam(name: 'keyword', description: 'search 时的关键词'),
      AgentToolParam(name: 'force', description: 'load 时是否强制刷新（"true"/"false"）'),
    ],
    protocol: '''
1. list 列出已配置仓库（多源逐条展示）；load 加载/刷新索引（force 可选）；
   search 搜索（需 keyword）；stats 按源统计应用数 + 合计。
2. 多源场景下统计与详情都要**逐源**呈现，不要合并成单一数字。
3. 大索引刷新耗时，先告知用户正在进行。''',
  ),

  // ==================== 获取与安装 ====================
  AgentToolSpec(
    name: 'downloadApp',
    group: AgentToolGroup.acquire,
    label: '下载应用',
    brief: '下载 APK；需 appId+channel，可带 url/name/version/vivoId，GitHub 自动匹配 CPU 架构。',
    params: [
      AgentToolParam(name: 'appId', description: '包名/仓库名', required: true),
      AgentToolParam(name: 'channel', description: '渠道代码', required: true),
      AgentToolParam(name: 'url', description: '直链下载地址（可选）'),
      AgentToolParam(name: 'name', description: '应用名'),
      AgentToolParam(name: 'version', description: '版本号'),
      AgentToolParam(name: 'vivoId', description: 'vivo 应用 ID（vivo 渠道必需）'),
      AgentToolParam(
          name: 'installAfterDownload',
          description: '下载完成后自动安装（用户明确要求时才传 true）',
          type: 'bool'),
    ],
    async: true,
    protocol: '''
1. 先 searchApp 拿到 appId/channel，再调用本工具；用户明确"下载完就安装"才传 installAfterDownload=true。
2. channel 为渠道 code：github/fdroid/vivo/http/local_db，或脚本渠道 js_xxx。
3. 有直链时优先传 url；否则由渠道详情解析真实下载地址。
4. GitHub 渠道自动选择匹配当前设备 CPU 架构的 APK。
5. 脚本渠道详情会给出完整下载 URL，直接下载即可，无需猜架构。
6. 下载为异步长任务：会持续推送进度，结束后才继续对话。''',
  ),
  AgentToolSpec(
    name: 'installApp',
    group: AgentToolGroup.acquire,
    label: '安装应用',
    brief: '安装已下载的 APK；需 savePath。',
    params: [
      AgentToolParam(name: 'savePath', description: 'APK 文件完整路径', required: true),
    ],
    protocol: '''
1. savePath 必须是已下载 APK 的完整路径（通常来自 downloadApp 的返回）。
2. 优先 Shizuku 静默安装；未授权时回退系统安装界面，提示用户确认。
3. 安装失败提示检查 APK 完整性，或建议到下载中心手动安装。''',
  ),
  AgentToolSpec(
    name: 'manageDownload',
    group: AgentToolGroup.acquire,
    label: '下载管理',
    brief: '下载任务管理；action=list/pause/resume/cleanCompleted/clearAll。',
    params: [
      AgentToolParam(
          name: 'action',
          description: 'list/pause/resume/cleanCompleted/clearAll',
          required: true),
      AgentToolParam(name: 'fileName', description: '文件名（pause/resume 必填）'),
    ],
    sensitiveActions: ['clearAll', 'cleanCompleted'],
    sensitiveNotes: ['清空全部下载记录', '清理已完成下载'],
    protocol: '''
1. 查看用 list；暂停/恢复需 fileName（可先 list 再指定）。
2. cleanCompleted/clearAll 会删除下载记录，必须先 confirmAction 确认。
3. 操作后反馈当前状态，不要重复无意义重试。''',
  ),

  // ==================== 管理与偏好 ====================
  AgentToolSpec(
    name: 'manageApp',
    group: AgentToolGroup.manage,
    label: '管理我的应用',
    brief: '管理"我的应用"列表；action=list/add/remove/isAdded。',
    params: [
      AgentToolParam(name: 'action', description: 'list/add/remove/isAdded', required: true),
      AgentToolParam(name: 'appId', description: '应用 ID'),
      AgentToolParam(name: 'channel', description: '渠道代码'),
      AgentToolParam(name: 'name', description: '应用名'),
    ],
    sensitiveActions: ['remove'],
    sensitiveNotes: ['从"我的应用"移除应用'],
    protocol: '''
1. list 查看全部；isAdded 检查是否已添加；add 需 appId+channel；remove 需 appId+channel。
2. remove 属敏感操作，必须先 confirmAction 确认。
3. add 会先经渠道拉取应用信息，失败时说明原因。''',
  ),
  AgentToolSpec(
    name: 'channelApp',
    group: AgentToolGroup.manage,
    label: '渠道应用管理',
    brief: '管理渠道内应用；action=list/add/remove（GitHub 用 owner/repo）。',
    params: [
      AgentToolParam(name: 'action', description: 'list/add/remove', required: true),
      AgentToolParam(name: 'appId', description: '应用 ID'),
      AgentToolParam(name: 'channel', description: '渠道代码'),
      AgentToolParam(name: 'name', description: '应用名'),
    ],
    sensitiveActions: ['remove'],
    sensitiveNotes: ['从渠道移除应用'],
    protocol: '''
1. 与 manageApp 的区别：这里操作的是**渠道数据库**，manageApp 操作首页"我的应用"聚合。
2. list 需 channel；add 需 appId+channel（可带 name）；remove 需 appId+channel。
3. GitHub 渠道 appId 用 owner/repo（如 termux/termux-app）。
4. remove 属敏感操作，必须先 confirmAction 确认。''',
  ),
  AgentToolSpec(
    name: 'themeControl',
    group: AgentToolGroup.manage,
    label: '主题设置',
    brief: '主题控制；action=mode/toggle/color。',
    params: [
      AgentToolParam(name: 'action', description: 'mode/toggle/color', required: true),
      AgentToolParam(name: 'mode', description: 'light/dark/system（action=mode）'),
      AgentToolParam(name: 'hexColor', description: '主题色 0xFFRRGGBB（action=color）'),
    ],
    protocol: '''
1. mode 切换明暗模式（light/dark/system）；toggle 直接反转；color 设置主题色（0xFFRRGGBB）。
2. 修改即时生效，无需额外操作。''',
  ),
  AgentToolSpec(
    name: 'configManager',
    group: AgentToolGroup.manage,
    label: '配置管理',
    brief: '应用配置读取/修改；action=list/get/set/clear。',
    params: [
      AgentToolParam(name: 'action', description: 'list/get/set/clear', required: true),
      AgentToolParam(name: 'key', description: '配置键（get/set/clear 必填）'),
      AgentToolParam(name: 'value', description: '配置值（set 时按类型构造）'),
    ],
    protocol: '''
1. **先 list** 获取结构化快照（key/类型/当前值/默认值/枚举/示例/分组），再构造 value 调 set。
2. get 读单项（需 key）；clear 清除（需 key），清除后回落默认值。
3. JSON 类型配置的 value 传 JSON 对象字符串（可只传部分字段）。
4. 敏感配置读取时脱敏，但可以设置。
5. 修改后相关功能自动生效。
6. 失败要说明原因（未知键/类型错误/不允许 Agent 修改）并重新 list 确认可用项。''',
  ),
  AgentToolSpec(
    name: 'backup',
    group: AgentToolGroup.manage,
    label: '备份恢复',
    brief: '备份/恢复；action=export/import（import 需 filePath，须先确认）。',
    params: [
      AgentToolParam(name: 'action', description: 'export/import', required: true),
      AgentToolParam(name: 'filePath', description: '备份文件路径（import 必填）'),
    ],
    sensitiveActions: ['import'],
    sensitiveNotes: ['恢复备份（会覆盖当前数据）'],
    protocol: '''
1. export 导出统一 tar.gz 备份包，返回保存路径并告知用户。
2. import 会**覆盖当前数据**，必须先 confirmAction 确认。
3. 备份内容（v2.1）：已添加应用、渠道库、应用配置（主题等）、应用分类标签、
   代理配置、F-Droid 仓库源、Agent 模型配置；不含下载记录。
4. 失败提示检查存储权限或文件路径。''',
  ),
  AgentToolSpec(
    name: 'webdavSync',
    group: AgentToolGroup.manage,
    label: 'WebDAV 云备份',
    brief: 'WebDAV 云备份；action=list/upload/download/status。',
    params: [
      AgentToolParam(name: 'action', description: 'list/upload/download/status', required: true),
    ],
    sensitiveActions: ['download'],
    sensitiveNotes: ['从网盘恢复（会覆盖当前数据）'],
    protocol: '''
1. 先 status 检查配置；未配置则引导用户到设置里配置 WebDAV。
2. list 查询网盘备份列表（时间/大小），供用户选择。
3. upload 上传本地备份到网盘。
4. download 会从网盘恢复并覆盖当前数据，必须先 confirmAction 确认。
5. 失败提示检查网络/服务器地址/备份路径是否存在。''',
  ),
  AgentToolSpec(
    name: 'cacheManage',
    group: AgentToolGroup.manage,
    label: '缓存管理',
    brief: '清理缓存与已下载文件；无参数，自动枚举并弹多选。',
    params: [],
    alwaysSensitive: true,
    protocol: '''
1. 用户说"清理缓存/释放空间/删除下载的安装包/清理下载文件"时调用。
2. 无参数：工具自动枚举可清理项（网络图片/README/图标/通用缓存/临时文件等，
   以及已下载的 APK），弹出多选框让用户勾选后执行。
3. 删除下载文件不可恢复，务必让用户明确勾选。
4. 可清理项过多时会提示用户改用"缓存管理"页手动清理。''',
  ),

  // ==================== 交互与扩展 ====================
  AgentToolSpec(
    name: 'confirmAction',
    group: AgentToolGroup.interact,
    label: '确认操作',
    brief: '向用户确认/选择；question（+options，可 multiSelect）。敏感操作前必须先调。',
    params: [
      AgentToolParam(name: 'question', description: '确认问题（需清晰说明要执行的操作）', required: true),
      AgentToolParam(name: 'options', description: '选项数组或逗号分隔字符串（2-5 个）'),
    ],
    protocol: '''
1. 两类场景：① 敏感/不可逆操作前确认；② 需要在多个方案中选择。
2. 二选一：不传 options，展示"确认/取消"。
3. 多选一：传 options（数组或逗号分隔），用户点选。
4. 多选：传 options 且 multiSelect=true，用户勾选多项后统一确认（结果用"、"连接）。
5. 用户取消则不要执行，并明确告知未执行。
6. 不要用普通文字代替确认/选择交互。''',
  ),
  AgentToolSpec(
    name: 'runJsChannel',
    group: AgentToolGroup.interact,
    label: '脚本渠道执行',
    brief: '执行脚本渠道(js_xxx)暴露的方法；channel+method（+params）。',
    params: [
      AgentToolParam(name: 'channel', description: '脚本渠道 key（如 js_pingan）', required: true),
      AgentToolParam(name: 'method', description: '脚本 main 分发的函数名', required: true),
      AgentToolParam(name: 'params', description: '可选参数 map（JSON 对象）'),
    ],
    protocol: '''
1. 仅对脚本渠道（js_ 前缀）可用；先确认渠道确实为脚本渠道。
2. 常见方法：getConfig（渠道配置）、versionOptions（版本/环境选项）、
   switchVersion（切换版本/环境），以及脚本自定义的查询/操作方法。
3. 脚本未实现该方法时返回提示，改用预置工具或告知用户。
4. 脚本渠道可能需先配置环境变量（如账号密码），失败时引导到"设置 → 脚本渠道"。''',
  ),

  // ==================== 快照与版本分析 ====================
  AgentToolSpec(
    name: 'appSnapshot',
    group: AgentToolGroup.snapshot,
    label: '应用快照',
    brief: '创建/查看应用快照；action=create/list/apps/detail/delete。'
        '快照固化某个版本的应用构成，供后续对比版本更新。',
    params: [
      AgentToolParam(
          name: 'action',
          description: 'create/list/apps/detail/delete',
          required: true),
      AgentToolParam(name: 'packageName', description: '应用包名（create/list 需要）'),
      AgentToolParam(name: 'note', description: '备注（create 可选，如"更新前"）'),
      AgentToolParam(name: 'id', description: '快照 id（detail/delete 需要）'),
    ],
    sensitiveActions: ['delete'],
    sensitiveNotes: ['删除快照（不可恢复）'],
    protocol: '''
1. 用途：把"某个版本的应用构成"（原生库/DEX/权限/组件/签名/资源/包结构）固化下来，
   之后可对比出新版本究竟改了什么。
2. create：需 packageName；应用必须**已安装**（否则拿不到安装包）。
   可选 note 标注用途（如"更新前"/"更新后"）。版本号与应用名由系统从真实 APK 读取，
   **不需要你提供**，也不要转述上一个页面的版本值。
3. list：列出该应用全部快照（含 id / 版本 / 采集时间 / 概要），用于挑两份做对比。
4. apps：列出已有快照的全部应用（用户没指定应用时可先用它看看）。
5. detail：查看单份快照概要（需 id）。
6. delete：删除快照（需 id），属敏感操作，**必须先 confirmAction 确认**。
7. 典型用法：更新前 create(note="更新前") → 更新后再 create(note="更新后")
   → snapshotCompare 出差异 → 结合「版本差异分析」技能解读。
8. 采集较重（要扫描 APK / DEX / 资源），一次只对一个应用操作，不要对未安装应用反复重试。''',
  ),
  AgentToolSpec(
    name: 'snapshotCompare',
    group: AgentToolGroup.snapshot,
    label: '快照对比',
    brief: '对比同一应用的两份快照，逐节列出差异（签名/DEX/原生库/权限/组件/资源/体积）。'
        '省略 id 时对比最近两份。',
    params: [
      AgentToolParam(name: 'packageName', description: '应用包名', required: true),
      AgentToolParam(name: 'oldId', description: '基准快照 id（可选，省略则取次新一份）'),
      AgentToolParam(name: 'newId', description: '目标快照 id（可选，省略则取最新一份）'),
    ],
    protocol: '''
1. 输入 packageName；oldId/newId 省略时取该应用**最近两份**（时间早者为基准）。
2. 指定 id 时按采集时间自动纠正方向，始终"旧 → 新"。
3. 返回内容：结论（重新构建/仅资源更新/仅原生更新/重新签名等）、各节指纹是否变化、
   逐节差异（字段级 旧值/新值、内容指纹是否同一文件、疑似改名/移动）、APK 体积变化。
4. 阅读要点（判断"版本更新内容"的关键）：
   - 先看【结论】与"指纹判定"；**签名变化要特别提醒用户**（可能被重新签名/非同一来源）；
   - DEX 变 → 代码有改动；原生库变 → 底层库/SDK 有改动；
     assets / 资源表变 → 资源、文案、多语言变化；
   - 关注新增/移除的**权限**、**导出组件**、**新增深链**（快捷启动）；
   - 标记「待确认」的条目源于两次快照载荷版本不同，解读时要说明这一点；
   - 体积变化已给出 +/− 数值，直接转述，不要让用户自己相减。
5. 只读操作，无副作用。快照不足两份时返回提示（先用 appSnapshot 创建）。''',
  ),
  AgentToolSpec(
    name: 'apkBrowser',
    group: AgentToolGroup.snapshot,
    label: 'APK 文件浏览',
    brief: '浏览 APK 内的文件：目录树、嵌套 zip 均可逐层进入；读取文本类文件内容。'
        'action=browse/read。',
    params: [
      AgentToolParam(
          name: 'action', description: 'browse/read', required: true),
      AgentToolParam(
          name: 'packageName', description: '应用包名', required: true),
      AgentToolParam(
          name: 'dir', description: 'browse：当前容器内目录前缀（如 assets/models），省略为容器根'),
      AgentToolParam(
          name: 'chain',
          description: 'browse/read：嵌套容器链（如 assets/pack.zip），省略为 APK 根'),
      AgentToolParam(name: 'path', description: 'read：条目在容器内的路径'),
    ],
    protocol: '''
1. 用途：把 APK 当容器打开，回答"包里有什么文件 / 某个资源文件的内容是什么"。
   应用必须**已安装**（否则拿不到安装包）。
2. browse：列一层目录。默认列 APK 根；用 dir 指定目录（如 dir=assets）。
   返回条目形如：
   - [D] 目录名
   - [F] 文件名  (类型 · 大小 …)
   - [Z] 压缩包名  (… · 可进入)  ← zip/apk/jar/aar 可以继续进入
3. 进入嵌套压缩包：不要拼路径，直接把该条目的**容器路径**作为 chain 传入，
   例如 chain=assets/plugins/pack.zip，再配合 dir 列内层目录。
   chain 可多层，但最多 4 层；每层容器都有大小上限。
4. read：读取某条目内容（需 path）。文本/JSON 直接返回文本；二进制返回
   十六进制摘要。单次只读前 64 KB，大文件会提示截断。
5. 典型用法：browse(packageName) → 看有哪些目录 → browse(dir=assets) →
   browse(chain=assets/model.zip) → read(path=config.json) 读配置。
6. 只读操作，无副作用；不解压、不修改目标 APK。条目过多时返回会被截断，
   请用 dir 收窄而不是反复刷新。''',
  ),

  // ==================== 元能力 ====================
  AgentToolSpec(
    name: 'loadProtocol',
    group: AgentToolGroup.meta,
    label: '读取协议',
    brief: '按需读取工具或技能的完整协议（参数/用法/步骤）。不确定时先读再执行。',
    meta: true,
    params: [
      AgentToolParam(
          name: 'target',
          description: '工具名（如 downloadApp）或技能名（如 下载安装流程）；传 "all" 列出全部',
          required: true),
    ],
    protocol: '''
1. 系统提示里只有"工具目录（一行简介）"和"技能目录（名称+触发场景）"；
   调用本工具可取完整协议。
2. target 优先按工具名匹配，其次按技能名匹配（中/英文名均可）。
3. 适用于：不确定参数名/取值、需要完整使用规则、需要技能的具体执行步骤、
   或要确认敏感操作的前置条件。
4. target 传 "all" 返回全部工具与技能协议（内容很长，仅在没有其他线索时使用）。''',
  ),
];
