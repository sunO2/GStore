/// Agent 技能库（类 Skills 机制）
library;

/// 每个技能封装一类任务的完整工作流知识（触发条件 + 执行步骤 + 注意点），
/// 注入到系统提示词中，让 Agent 面对对应场景时按最佳实践执行，
/// 而非仅依赖零散的工具描述。
///
/// 技能按"启用/禁用"管理，可动态注入。支持中英双语渲染。

/// 提示词语言
enum PromptLanguage {
  /// 英文（默认，专业严谨）
  en,

  /// 中文
  zh,
}

/// 单个技能定义
class AgentSkill {
  /// 技能名称（中文）
  final String name;

  /// 技能名称（英文）
  final String nameEn;

  /// 触发场景描述（中文）
  final String triggers;

  /// 触发场景描述（英文）
  final String triggersEn;

  /// 工作流步骤指引（中文）
  final String workflow;

  /// 工作流步骤指引（英文）
  final String workflowEn;

  /// 是否启用（默认启用）
  final bool enabled;

  const AgentSkill({
    required this.name,
    required this.nameEn,
    required this.triggers,
    required this.triggersEn,
    required this.workflow,
    required this.workflowEn,
    this.enabled = true,
  });

  /// 渲染为系统提示词片段
  String render(PromptLanguage language) {
    final isEn = language == PromptLanguage.en;
    final n = isEn ? nameEn : name;
    final t = isEn ? triggersEn : triggers;
    final w = isEn ? workflowEn : workflow;
    return '''
[Skill: $n]
Trigger: $t
Workflow:
$w
''';
  }
}

/// GStore Agent 技能库
class AgentSkills {
  /// 全部技能
  static const List<AgentSkill> all = [
    AgentSkill(
      name: '推荐应用',
      nameEn: 'App Recommendation',
      triggers: '用户询问"推荐/找个 XX 应用"、描述需求想找工具时',
      triggersEn: 'When the user asks for a recommendation or describes a need for an app',
      workflow: '1. 从用户描述中提取核心需求（如"截图""终端""阅读器"），确定关键词\n2. 调用 searchApp 搜索，遍历多渠道结果\n3. 优先推荐开源应用（GitHub、F-Droid），标注来源渠道\n4. 若开源无合适选择，推荐 vivo 渠道热门应用\n5. 给出 1-3 个候选，说明各自特点（开源/免费/功能/体积）\n6. 询问用户是否下载，不要直接下载',
      workflowEn: '1. Extract the core need from the user\'s description (e.g. screenshot, terminal, reader) and determine keywords\n2. Call searchApp and search across all channels\n3. Prefer open-source apps (GitHub, F-Droid); state the source channel\n4. If no suitable open-source option, recommend popular apps from the vivo channel\n5. Present 1-3 candidates with their traits (open-source/free/features/size)\n6. Ask whether to download; do not download directly',
    ),
    AgentSkill(
      name: '下载安装流程',
      nameEn: 'Download & Install Flow',
      triggers: '用户要求下载或安装应用时',
      triggersEn: 'When the user asks to download or install an app',
      workflow: '1. 下载前先 searchApp 找到目标应用，确认 appId、channel\n2. 调用 downloadApp 下载（GitHub 渠道自动匹配 CPU 架构）\n3. 下载完成后告知用户保存路径\n4. 询问用户是否安装，确认后调用 installApp\n5. 安装成功提示完成；失败给出原因（网络/APK损坏/权限）\n6. 注意：下载大文件或敏感操作前，先用 confirmAction 确认',
      workflowEn: '1. Use searchApp to locate the target app first; confirm appId and channel\n2. Call downloadApp (GitHub auto-matches the device CPU architecture)\n3. After download, inform the user of the save path\n4. Ask whether to install; on confirmation call installApp\n5. Report success; on failure explain cause (network/corrupted APK/permission)\n6. For large files or sensitive operations, confirm with confirmAction first',
    ),
    AgentSkill(
      name: '应用更新检查',
      nameEn: 'App Update Check',
      triggers: '用户询问"有更新吗""检查更新"或要求更新某应用时',
      triggersEn: 'When the user asks about updates or wants to update an app',
      workflow: '1. 调用 updateApps 检查（可指定 appId+channel，或全部）\n2. 无更新：告知已是最新\n3. 有更新：列出每个应用的 当前版本 → 最新版本，标记可更新项\n4. 询问用户是否下载更新，确认后走下载流程\n5. 单应用更新失败时，提示可能原因并建议重试',
      workflowEn: '1. Call updateApps (optionally scoped by appId+channel, or all)\n2. No update: inform the user it is up to date\n3. Updates available: list current → latest per app and mark updatable items\n4. Ask whether to download updates; on confirmation proceed with the download flow\n5. If a single app fails, suggest likely causes and retry',
    ),
    AgentSkill(
      name: '备份与恢复',
      nameEn: 'Backup & Restore',
      triggers: '用户要求备份、恢复、导出、导入数据时',
      triggersEn: 'When the user asks to back up, restore, export, or import data',
      workflow: '1. 导出备份：调用 backup export，可选择是否包含应用配置。备份内容（v2.1）：已添加应用、渠道库、应用配置（主题等）、应用分类标签、代理配置、F-Droid 仓库源、Agent 模型配置；不含下载记录\n2. 导入/恢复：调用 backup import（需 filePath）\n3. 恢复会覆盖现有数据，**必须先 confirmAction 确认**\n4. 备份文件保存位置告知用户\n5. WebDAV 云备份：确认已配置网盘，未配置先引导到设置\n6. 操作完成告知结果，失败给出存储权限/路径检查建议',
      workflowEn: '1. Export: call backup export; optionally include app config. Backup contents (v2.1): added apps, channel databases, app config (theme etc.), app category tags, proxy config, F-Droid repository sources, Agent model config; download records are not included\n2. Import/restore: call backup import (needs filePath)\n3. Restore overwrites existing data - you MUST confirm with confirmAction first\n4. Inform the user where the backup file was saved\n5. WebDAV backup: verify the drive is configured; guide to Settings if not\n6. Report results; on failure suggest checking storage permission or path',
    ),
    AgentSkill(
      name: '已安装应用管理',
      nameEn: 'Installed Apps Management',
      triggers: '用户询问"我装了什么""XX装了吗"，或要求卸载/清理/停止应用时',
      triggersEn: 'When the user asks what is installed, whether X is installed, or wants to uninstall/clean/stop an app',
      workflow: '1. 查询：调用 installedApps list（可按关键词过滤）或 check\n2. 卸载/清理数据/清缓存/强制停止：**必须先 confirmAction 确认**（不可逆或影响大）\n3. 确认后执行，Shizuku 未授权时提示到设置授权\n4. 结果反馈：成功/失败及原因',
      workflowEn: '1. Query: call installedApps list (optionally filtered) or check\n2. Uninstall/clear data/cache/force-stop: you MUST confirm with confirmAction first (irreversible or impactful)\n3. Execute after confirmation; if Shizuku is not authorized, direct the user to Settings\n4. Report success or failure with the reason',
    ),
    AgentSkill(
      name: '敏感操作与选择',
      nameEn: 'Sensitive Operations & Choices',
      triggers: '涉及删除、卸载、覆盖、清理、强制操作，或用户需要做选择时',
      triggersEn: 'When operations involve deletion, uninstall, overwrite, cleaning, force actions, or the user needs to choose',
      workflow: '1. **确认类**（是否执行）：用 confirmAction（不带 options）让用户确认/取消\n2. **选择类**（多个方案）：用 confirmAction 并传 options 选项数组，让用户点选\n3. 用户取消则不执行，并说明未执行\n4. 用户确认后执行实际操作\n5. 不要用普通文字代替确认/选择交互',
      workflowEn: '1. Confirmation (yes/no): call confirmAction without options\n2. Choice (multiple options): call confirmAction with an options array\n3. If the user cancels, do not execute and explain that it was not performed\n4. Execute the real action only after the user confirms\n5. Never replace confirm/choice interaction with plain text',
    ),
    AgentSkill(
      name: '下载管理',
      nameEn: 'Download Management',
      triggers: '用户询问"下载列表""暂停/继续下载""清理下载"时',
      triggersEn: 'When the user asks about the download list, pausing/resuming, or cleaning downloads',
      workflow: '1. 查看：调用 manageDownload list\n2. 暂停/恢复：调用 manageDownload（需 fileName）\n3. 清理已完成/清空：先 confirmAction 确认，再执行\n4. 反馈当前状态',
      workflowEn: '1. View: call manageDownload list\n2. Pause/resume: call manageDownload (needs fileName)\n3. Clean completed/clear all: confirm with confirmAction first, then execute\n4. Report the current state',
    ),
    AgentSkill(
      name: 'F-Droid 仓库',
      nameEn: 'F-Droid Repository',
      triggers: '用户询问"F-Droid"、要求加载/搜索 F-Droid 仓库时',
      triggersEn: 'When the user asks about F-Droid or wants to load/search an F-Droid repository',
      workflow: '1. 查看仓库列表：调用 fdroidRepo list\n2. 加载/刷新：调用 fdroidRepo load（force 可选）\n3. 搜索 F-Droid 应用：调用 fdroidRepo search（需 keyword）\n4. 反馈应用数量/结果',
      workflowEn: '1. List repositories: call fdroidRepo list\n2. Load/refresh: call fdroidRepo load (force optional)\n3. Search F-Droid apps: call fdroidRepo search (needs keyword)\n4. Report app count/results',
    ),
    AgentSkill(
      name: 'WebDAV 云备份',
      nameEn: 'WebDAV Cloud Backup',
      triggers: '用户要求上传到网盘/从网盘恢复，或询问网盘备份数据时',
      triggersEn: 'When the user wants to upload to/restore from a cloud drive, or asks about cloud backup data',
      workflow: '1. 先检查配置：调用 webdavSync status；未配置则引导到设置\n2. 查询备份数据：调用 webdavSync list，反馈网盘中的备份列表（时间/大小），供用户选择\n3. 上传：调用 webdavSync upload\n4. 下载恢复：调用 webdavSync download（覆盖数据前 confirmAction 确认）\n5. 反馈结果',
      workflowEn: '1. Check configuration first: call webdavSync status; guide to Settings if not configured\n2. Query backup data: call webdavSync list to show the cloud backup files (time/size) for the user to pick from\n3. Upload: call webdavSync upload\n4. Download/restore: call webdavSync download (confirm with confirmAction before overwriting)\n5. Report the result',
    ),
    AgentSkill(
      name: '应用配置管理',
      nameEn: 'App Config Management',
      triggers: '用户要求修改应用配置、查看设置、调整下载/更新策略、设置代理时',
      triggersEn: 'When the user asks to change app config, view settings, adjust download/update policy, or set proxy',
      workflow: '1. 先调用 configManager list 获取结构化 JSON 快照（含 key/类型/当前值/默认值/可选枚举值/示例/分组），敏感项已脱敏\n2. 查看单个配置：configManager get（需 key），返回结构化 JSON\n3. 根据快照中的 type/enumValues/example 构造正确类型的 value，调用 configManager set（需 key 和 value）；修改后相关功能自动生效，无需额外操作\n4. 清除配置：configManager clear（需 key）\n5. 反馈结果（结构化 success/message/key/value）；失败时说明原因（未知键/类型错误/不允许修改）并重新 list 确认可用项',
      workflowEn: '1. Call configManager list first to get a structured JSON snapshot (key/type/current value/default/enum values/example/category); sensitive values are masked\n2. Read a single item: configManager get (needs key), returns structured JSON\n3. Build a correctly typed value from type/enumValues/example, then call configManager set (needs key+value); the related feature updates automatically\n4. Clear config: configManager clear (needs key)\n5. Report the structured result (success/message/key/value); on failure explain why (unknown key / wrong type / not accessible) and re-list to confirm valid items',
    ),
    AgentSkill(
      name: '问题诊断与失败处理',
      nameEn: 'Troubleshooting & Failure Handling',
      triggers: '任何工具返回错误、搜索无结果、下载/安装失败时',
      triggersEn: 'When any tool returns an error, search yields nothing, or download/install fails',
      workflow: '1. 先向用户说明问题，不假装成功\n2. 分类处理：\n   - 搜索无结果：换关键词/检查渠道\n   - 下载失败：网络/URL失效/服务器不支持断点\n   - 安装失败：APK完整性/手动从下载中心安装\n   - 备份失败：存储权限/路径\n   - 模型/API失败：检查API Key/网络\n   - 配置失败：用 configManager list 确认可用项\n3. 给出可行的下一步建议\n4. 避免重复无意义重试',
      workflowEn: '1. Explain the issue first; never pretend success\n2. Handle by category:\n   - No search results: change keywords / check channels\n   - Download failed: network / invalid URL / server without resumable support\n   - Install failed: APK integrity / manual install from download center\n   - Backup failed: storage permission / path\n   - Model/API failure: check API key / network\n   - Config failed: use configManager list to confirm valid items\n3. Give actionable next steps\n4. Avoid meaningless repeated retries',
    ),
  AgentSkill(
      name: '脚本渠道应用操作',
      nameEn: 'JS Script Channel Apps',
      triggers: '用户提到 js_ 开头渠道、自定义脚本渠道、或应用来自脚本渠道（如平安渠道）时',
      triggersEn: 'When the user mentions a js_-prefixed channel, a custom script channel, or an app that came from a script channel',
      workflow: '1. 脚本渠道标识为 js_ 开头（如 js_pingan），不在常规渠道枚举中\n2. 搜索：searchApp 的 channel 参数直接传脚本渠道 key（如 js_pingan）\n3. 查详情：getAppInfo 的 channel 传脚本渠道 key\n4. 下载：downloadApp 的 channel 传脚本渠道 key；脚本渠道详情会给出完整下载 URL，agent 直接下载即可，无需猜架构\n5. 管理渠道应用：channelApp 的 channel 传脚本渠道 key\n6. 检查更新：updateApps 的 channel 传脚本渠道 key\n7. 脚本渠道可能需先配置环境变量（如账号密码）才能搜索/下载；失败时提示用户到 设置→脚本渠道 配置',
      workflowEn: '1. Script channels are identified by the js_ prefix (e.g. js_pingan); they are not in the regular channel enum\n2. Search: pass the script channel key (e.g. js_pingan) as the channel param of searchApp\n3. Details: pass the script channel key as channel of getAppInfo\n4. Download: pass the script channel key as channel of downloadApp; the script channel detail returns a full download URL, so download it directly without guessing the architecture\n5. Manage channel apps: pass the script channel key as channel of channelApp\n6. Update check: pass the script channel key as channel of updateApps\n7. Script channels may require environment variables (e.g. credentials) to search/download; if it fails, direct the user to Settings → Script Channels',
    ),
    AgentSkill(
      name: '脚本渠道方法执行',
      nameEn: 'JS Channel Method Execution',
      triggers: '需要调用脚本渠道特有方法（配置读取、版本/环境切换、自定义脚本能力）时',
      triggersEn: 'When a script channel-specific method is needed (config read, version/environment switching, custom script capability)',
      workflow: '1. 调用 runJsChannel 执行脚本渠道暴露的方法\n2. 参数：channel（脚本渠道 key，如 js_pingan）、method（脚本方法名）、params（可选参数 map）\n3. 常见方法：getConfig（渠道配置）、versionOptions（版本/环境选项）、switchVersion（切换版本/环境）\n4. 脚本未实现该方法时返回提示，改用预置工具或告知用户\n5. 先搜索确认渠道是否为脚本渠道（js_ 前缀）再调用',
      workflowEn: '1. Call runJsChannel to execute a method exposed by the script channel\n2. Params: channel (script channel key, e.g. js_pingan), method (script method name), params (optional map)\n3. Common methods: getConfig (channel config), versionOptions (version/env options), switchVersion (switch version/env)\n4. If the script does not implement the method, a hint is returned; fall back to preset tools or inform the user\n5. Confirm the channel is a script channel (js_ prefix) before calling',
    ),
  ];

  /// 渲染全部启用的技能为系统提示片段
  static String renderAll({PromptLanguage language = PromptLanguage.en}) {
    final enabled = all.where((s) => s.enabled).toList();
    return enabled.map((s) => s.render(language)).join('\n');
  }
}
