/// 内置 Agent 工具模块
///
/// 15 个内置工具独立为 AgentToolModule，由 AgentService 统一注册到
/// ModuleManager；上下线即增删模型可调用的工具清单。
library;

import '../agent_tool_module.dart';

/// 搜索应用工具
class SearchTool extends AgentToolModule {
  @override
  String get toolName => 'searchApp';

  @override
  String get toolDescription =>
      '在 GStore 软件商店中搜索应用。输入关键词 keyword，返回匹配的应用列表（含渠道）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'keyword', description: '搜索关键词', required: true),
      ];
}

/// 下载应用工具
class DownloadTool extends AgentToolModule {
  @override
  String get toolName => 'downloadApp';

  @override
  String get toolDescription =>
      '下载应用 APK。需要 appId、channel（如 github/fdroid/vivo）、url（可选）、name、version。vivo 渠道还需 vivoId。GitHub 渠道自动匹配 CPU 架构。如需下载完成后自动安装，传入 installAfterDownload=true；仅说下载则不传。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'appId', description: '包名/仓库名', required: true),
        AgentToolParam(name: 'channel', description: '渠道代码', required: true),
        AgentToolParam(name: 'url', description: '下载地址'),
        AgentToolParam(name: 'name', description: '应用名'),
        AgentToolParam(name: 'version', description: '版本号'),
        AgentToolParam(name: 'vivoId', description: 'vivo 应用 ID（vivo 渠道必需）'),
        AgentToolParam(
          name: 'installAfterDownload',
          description:
              '是否下载完成后自动安装（用户明确要求"下载完就安装"时传 true；仅说"下载"则不传或传 false）',
          type: 'bool',
        ),
      ];
}

/// 安装应用工具
class InstallTool extends AgentToolModule {
  @override
  String get toolName => 'installApp';

  @override
  String get toolDescription =>
      '安装已下载的 APK 文件。需要 savePath（APK 文件完整路径）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'savePath', description: 'APK 文件路径', required: true),
      ];
}

/// 我的应用管理工具
class ManageAppTool extends AgentToolModule {
  @override
  String get toolName => 'manageApp';

  @override
  String get toolDescription =>
      '管理"我的应用"列表（首页聚合）。action 为 list/add/remove/isAdded。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/add/remove/isAdded', required: true),
        AgentToolParam(name: 'appId', description: '应用 ID'),
        AgentToolParam(name: 'channel', description: '渠道代码'),
        AgentToolParam(name: 'name', description: '应用名'),
      ];
}

/// 渠道应用管理工具
class ChannelAppTool extends AgentToolModule {
  @override
  String get toolName => 'channelApp';

  @override
  String get toolDescription =>
      '管理渠道中的应用（渠道数据库）。action 为 list（需 channel）/add（需 appId+channel+name）/remove（需 appId+channel）。GitHub 渠道 appId 用 owner/repo。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/add/remove', required: true),
        AgentToolParam(name: 'appId', description: '应用 ID'),
        AgentToolParam(name: 'channel', description: '渠道代码'),
        AgentToolParam(name: 'name', description: '应用名'),
      ];
}

/// 应用详情工具
class GetAppInfoTool extends AgentToolModule {
  @override
  String get toolName => 'getAppInfo';

  @override
  String get toolDescription =>
      '获取应用详情或检查版本。输入 appId、channel。版本信息优先取 metadata（从 release APK 提取，更准确）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'appId', description: '应用 ID', required: true),
        AgentToolParam(name: 'channel', description: '渠道代码', required: true),
      ];
}

/// 检查更新工具
class UpdateAppsTool extends AgentToolModule {
  @override
  String get toolName => 'updateApps';

  @override
  String get toolDescription =>
      '检查应用更新。appId 和 channel 可选（不传则检查全部已添加应用）。返回每个已安装应用是否有更新（当前版本 → 最新版本）。版本信息优先取 metadata（从 release APK 提取，更准确）。更新时可手动选择 APK（文件名相似度记忆，偏好持久化，下次检测优先匹配）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'appId', description: '应用 ID'),
        AgentToolParam(name: 'channel', description: '渠道代码'),
      ];
}

/// 备份恢复工具
class BackupTool extends AgentToolModule {
  @override
  String get toolName => 'backup';

  @override
  String get toolDescription =>
      '备份/恢复应用数据。action 为 export/import（import 需 filePath，恢复会覆盖数据，执行前必须 confirmAction 确认）。备份内容（v2.1）：已添加应用、渠道库、应用配置（主题等）、应用分类标签、代理配置、F-Droid 仓库源、Agent 模型配置；不含下载记录。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'export/import', required: true),
        AgentToolParam(name: 'filePath', description: '备份文件路径（import 时）'),
      ];
}

/// 下载管理工具
class ManageDownloadTool extends AgentToolModule {
  @override
  String get toolName => 'manageDownload';

  @override
  String get toolDescription =>
      '管理下载任务。action 为 list/pause/resume/cleanCompleted/clearAll。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/pause/resume/cleanCompleted/clearAll', required: true),
        AgentToolParam(name: 'fileName', description: '文件名（pause/resume 时）'),
      ];
}

/// 主题控制工具
class ThemeTool extends AgentToolModule {
  @override
  String get toolName => 'themeControl';

  @override
  String get toolDescription =>
      '控制应用主题。action 为 mode（mode 值 light/dark/system）、toggle（切换深浅色）、color（设置主题色，传 hexColor 如 0xFF1976D2）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'mode/toggle/color', required: true),
        AgentToolParam(name: 'mode', description: 'light/dark/system'),
        AgentToolParam(name: 'hexColor', description: '主题色（0xFFRRGGBB）'),
      ];
}

/// F-Droid 仓库工具
class FdroidRepoTool extends AgentToolModule {
  @override
  String get toolName => 'fdroidRepo';

  @override
  String get toolDescription =>
      '管理 F-Droid 仓库。action 为 list（列出仓库）/load（加载/刷新仓库，force 可选）/search（搜索应用，需 keyword）/stats（统计信息）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/load/search/stats', required: true),
        AgentToolParam(name: 'keyword', description: '搜索关键词'),
        AgentToolParam(name: 'force', description: '是否强制刷新'),
      ];
}

/// 配置管理工具
class ConfigManagerTool extends AgentToolModule {
  @override
  String get toolName => 'configManager';

  @override
  String get toolDescription =>
      '管理 GStore 应用配置。action 为 list（返回结构化 JSON：全部可配置项的 key/类型/当前值/默认值/可选枚举值/示例/分组）/get（读取单配置，需 key，返回结构化 JSON）/set（修改配置，需 key 和 value）/clear（清除配置，需 key）。建议先调用 list 了解配置类型与可选项，再构造正确的 value 调用 set。修改后相关功能自动生效。敏感配置读取时脱敏显示。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/get/set/clear', required: true),
        AgentToolParam(name: 'key', description: '配置键'),
        AgentToolParam(name: 'value', description: '配置值（set 时使用）'),
      ];
}

/// WebDAV 云备份工具
class WebdavSyncTool extends AgentToolModule {
  @override
  String get toolName => 'webdavSync';

  @override
  String get toolDescription =>
      'WebDAV 云备份。action 为 list（查询网盘中的备份数据列表，可查看备份时间/大小）/upload（上传备份到网盘）/download（从网盘恢复）/status（检查配置状态）。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/upload/download/status', required: true),
      ];
}

/// 已安装应用工具
class InstalledAppsTool extends AgentToolModule {
  @override
  String get toolName => 'installedApps';

  @override
  String get toolDescription =>
      '管理设备上已安装的应用。action 为 list（列出已安装应用，可选 keyword 过滤）/check（检查是否已安装，需 packageName）/uninstall（卸载）/clearData（清理数据）/clearCache（清理缓存）/forceStop（强制停止）。卸载/清理/停止需 Shizuku 授权，执行前必须 confirmAction 确认。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'action', description: 'list/check/uninstall/clearData/clearCache/forceStop', required: true),
        AgentToolParam(name: 'keyword', description: '过滤关键词'),
        AgentToolParam(name: 'packageName', description: '包名'),
      ];
}

/// 缓存管理工具
///
/// 用户表达清理缓存/释放空间/清理下载文件等意图时调用。
/// 工具会枚举当前可清理的缓存类别（网络图片/README/图标/通用缓存等）与
/// 已下载文件，自动弹出多选框让用户勾选要清理的内容，勾选后执行清理。
/// 无需额外参数——选项由工具根据当前占用动态生成。
class CacheManageTool extends AgentToolModule {
  @override
  String get toolName => 'cacheManage';

  @override
  String get toolDescription =>
      '管理缓存与已下载文件（清理/释放空间）。当用户说"清理缓存""释放空间""删除下载的安装包/APK"'
      '"清理下载文件"等时调用。工具会枚举当前可清理项并弹出多选框（checkbox）'
      '让用户勾选要删除的内容——包括各类缓存（网络图片缓存、README 缓存、应用图标缓存、'
      '通用缓存、临时文件等）与已下载的 APK 文件。勾选确认后执行清理并反馈结果。'
      '删除下载文件不可恢复，务必通过多选确认让用户明确勾选。';

  @override
  List<AgentToolParam> get toolParams => const [];
}

/// 用户确认工具
class ConfirmTool extends AgentToolModule {
  @override
  String get toolName => 'confirmAction';

  @override
  String get toolDescription =>
      '向用户发起确认或选择请求。用于敏感/不可逆操作（卸载、清理、恢复备份、删除等）需要用户确认，或多选一决策（传 options）。输入 question；需要选择时传 options（选项数组或逗号分隔，2-5 个）。调用后等待用户操作，返回用户的选择。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'question', description: '确认问题', required: true),
        AgentToolParam(name: 'options', description: '选项数组或逗号分隔字符串'),
      ];
}

/// 脚本渠道方法执行工具（Agent 渠道包 JS 执行能力）
class RunJsChannelTool extends AgentToolModule {
  @override
  String get toolName => 'runJsChannel';

  @override
  String get toolDescription =>
      '执行自定义脚本渠道（js_xxx）暴露的方法。用于脚本渠道特有能力的调用，'
      '如 getConfig（渠道配置）、versionOptions/switchVersion（版本/环境切换）、'
      '或脚本自定义的查询/操作方法。输入 channel（脚本渠道 key，如 js_pingan）、'
      'method（脚本 main 分发的函数名）、params（可选参数 map）。仅对脚本渠道可用。';

  @override
  List<AgentToolParam> get toolParams => const [
        AgentToolParam(name: 'channel', description: '脚本渠道 key（如 js_pingan）', required: true),
        AgentToolParam(name: 'method', description: '脚本 main 分发的函数名', required: true),
        AgentToolParam(name: 'params', description: '可选参数 map（JSON 对象）'),
      ];
}

/// 内置工具注册表
class BuiltinAgentTools {
  BuiltinAgentTools._();

  /// 全部内置工具模块
  static List<AgentToolModule> get all => [
        SearchTool(),
        DownloadTool(),
        InstallTool(),
        ManageAppTool(),
        ChannelAppTool(),
        GetAppInfoTool(),
        UpdateAppsTool(),
        BackupTool(),
        ManageDownloadTool(),
        ThemeTool(),
        FdroidRepoTool(),
        ConfigManagerTool(),
        WebdavSyncTool(),
        InstalledAppsTool(),
        ConfirmTool(),
        CacheManageTool(),
        RunJsChannelTool(),
      ];
}
