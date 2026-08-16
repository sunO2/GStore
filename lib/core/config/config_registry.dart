/// 配置注册表
///
/// 集中声明 GStore 所有应用配置项（内置注册表），
/// 供 ConfigService 统一管理、Agent 枚举访问。
/// 新增配置只需添加一个 ConfigEntry（或实现 ConfigModule 注册），
/// Agent 与观察者自动支持。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_service.dart';
import 'config_store.dart';

/// 内置配置 key 常量
class ConfigKeys {
  ConfigKeys._();

  /// 主题配置（JSON，桥接 ThemeConfigProvider）
  static const String themeConfig = 'theme_config';

  /// 主题模式（0=system 1=light 2=dark）
  static const String themeMode = 'theme_mode';

  /// 下载配置（JSON，桥接 DownloadConfigProvider）
  static const String downloadConfig = 'download_config';

  /// 更新配置（JSON，桥接 UpdateConfigProvider）
  static const String updateConfig = 'update_config';

  /// WebDAV 配置（JSON，敏感，桥接 WebDavConfigProvider）
  static const String webdavConfig = 'webdav_config';

  /// GitHub 代理前缀
  static const String proxyUrl = 'proxy_url';

  /// Agent 模型列表（JSON）
  static const String agentModels = 'agent_models';

  /// Agent 当前选中模型 id
  static const String agentSelectedModelId = 'agent_selected_model_id';

  /// F-Droid 源列表（JSON）
  static const String fdroidSources = 'fdroid_sources';

  /// F-Droid 当前源 id
  static const String lastSourceId = 'last_source_id';

  /// 发现页选中的渠道（字符串列表）
  static const String selectedChannels = 'selected_channels';

  // ---- 模块开关（module.<name>.enabled，见 ModuleToggleConfig.keyOf）----

  /// 渠道模块开关
  static const String moduleChannelEnabled = 'module.channel.enabled';

  /// 下载模块开关
  static const String moduleDownloadEnabled = 'module.download.enabled';

  /// 备份模块开关
  static const String moduleBackupEnabled = 'module.backup.enabled';

  /// WebDAV 模块开关
  static const String moduleWebdavEnabled = 'module.webdav.enabled';

  /// F-Droid 模块开关
  static const String moduleFdroidEnabled = 'module.fdroid.enabled';

  /// 主题模块开关
  static const String moduleThemeEnabled = 'module.theme.enabled';

  /// 安装模块开关
  static const String moduleInstallEnabled = 'module.install.enabled';

  /// 聚合模块开关
  static const String moduleAggregateEnabled = 'module.aggregate.enabled';

  /// Agent 工具模块开关
  static const String moduleAgentToolsEnabled = 'module.agent_tools.enabled';

  /// 更新模块开关（预留，接口就绪前恒启用）
  static const String moduleUpdateEnabled = 'module.update.enabled';

  /// 角标模块开关（预留，接口就绪前恒启用）
  static const String moduleBadgeEnabled = 'module.badge.enabled';
}

/// 应用核心配置模块
///
/// 承载 GStore 内置配置项，作为 ConfigModule 的范例；
/// 后期新模块实现 ConfigModule 并在初始化时 registerModule 即可。
class AppCoreConfigModule extends ConfigModule {
  AppCoreConfigModule();

  @override
  String get moduleName => 'app_core';

  @override
  List<ConfigEntry> get configs => [
        const ConfigEntry(
          key: ConfigKeys.themeConfig,
          type: ConfigValueType.json,
          agentAccessible: true,
          category: 'theme',
          example: '{"fontStyle":3}（3=宽松，4=大号）；可传部分字段',
          description: '主题配置（颜色/字体/圆角等，JSON；字段值用数字索引）',
          descriptionEn: 'Theme config (colors/font/radius etc., JSON; use numeric indices)',
        ),
        const ConfigEntry(
          key: ConfigKeys.themeMode,
          type: ConfigValueType.int,
          defaultValue: 0,
          agentAccessible: true,
          enumValues: ['0', '1', '2'],
          category: 'theme',
          example: '0（跟随系统）/ 1（浅色）/ 2（深色）',
          description: '主题模式：0=跟随系统 1=浅色 2=深色',
          descriptionEn: 'Theme mode: 0=system 1=light 2=dark',
        ),
        const ConfigEntry(
          key: ConfigKeys.downloadConfig,
          type: ConfigValueType.json,
          agentAccessible: true,
          category: 'download',
          description: '下载配置（多段下载开关/段数/段大小）',
          descriptionEn: 'Download config (multi-segment toggle/count/size)',
        ),
        const ConfigEntry(
          key: ConfigKeys.updateConfig,
          type: ConfigValueType.json,
          agentAccessible: true,
          category: 'update',
          description: '更新配置（渠道/自动更新策略/检查间隔）',
          descriptionEn: 'Update config (channel/auto-update policy/interval)',
        ),
        const ConfigEntry(
          key: ConfigKeys.webdavConfig,
          type: ConfigValueType.json,
          sensitive: true,
          agentAccessible: true,
          category: 'webdav',
          description: 'WebDAV 配置（服务器/账号/密码，密码读取时脱敏）',
          descriptionEn:
              'WebDAV config (server/account/password, masked on read)',
        ),
        const ConfigEntry(
          key: ConfigKeys.proxyUrl,
          type: ConfigValueType.string,
          defaultValue: '',
          agentAccessible: true,
          category: 'network',
          example: 'https://gh-proxy.org/',
          description: 'GitHub 代理前缀（空串表示不使用）',
          descriptionEn: 'GitHub proxy prefix (empty = disabled)',
        ),
        const ConfigEntry(
          key: ConfigKeys.agentModels,
          type: ConfigValueType.json,
          agentAccessible: false,
          category: 'agent',
          description: 'Agent 模型列表',
          descriptionEn: 'Agent model list',
        ),
        const ConfigEntry(
          key: ConfigKeys.agentSelectedModelId,
          type: ConfigValueType.string,
          agentAccessible: true,
          category: 'agent',
          description: 'Agent 当前选中模型 ID',
          descriptionEn: 'Agent selected model ID',
        ),
        const ConfigEntry(
          key: ConfigKeys.fdroidSources,
          type: ConfigValueType.json,
          agentAccessible: false,
          category: 'fdroid',
          description: 'F-Droid 源列表',
          descriptionEn: 'F-Droid source list',
        ),
        const ConfigEntry(
          key: ConfigKeys.lastSourceId,
          type: ConfigValueType.string,
          agentAccessible: false,
          category: 'fdroid',
          description: 'F-Droid 当前源 ID',
          descriptionEn: 'F-Droid current source ID',
        ),
        const ConfigEntry(
          key: ConfigKeys.selectedChannels,
          type: ConfigValueType.stringList,
          defaultValue: <String>[],
          agentAccessible: false,
          category: 'discovery',
          description: '发现页选中的渠道',
          descriptionEn: 'Selected channels on discovery page',
        ),
        // ---- 模块开关（持久化，未设置默认启用）----
        const ConfigEntry(
          key: ConfigKeys.moduleChannelEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '渠道模块开关（false 时渠道模块下线）',
          descriptionEn: 'Channel module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleDownloadEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '下载模块开关（false 时下载模块下线）',
          descriptionEn: 'Download module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleBackupEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '备份模块开关（false 时备份模块下线）',
          descriptionEn: 'Backup module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleWebdavEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: 'WebDAV 模块开关（false 时 WebDAV 模块下线）',
          descriptionEn: 'WebDAV module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleFdroidEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: 'F-Droid 模块开关（false 时 F-Droid 模块下线）',
          descriptionEn: 'F-Droid module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleThemeEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '主题模块开关（false 时主题模块下线）',
          descriptionEn: 'Theme module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleInstallEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '安装模块开关（false 时安装模块下线）',
          descriptionEn: 'Install module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleAggregateEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '聚合模块开关（false 时聚合模块下线）',
          descriptionEn: 'Aggregate module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleAgentToolsEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: 'Agent 工具模块开关（false 时 Agent 工具下线）',
          descriptionEn: 'Agent tools module toggle (false = offline)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleUpdateEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '更新模块开关（预留，接口就绪前恒启用）',
          descriptionEn: 'Update module toggle (reserved, always on)',
        ),
        const ConfigEntry(
          key: ConfigKeys.moduleBadgeEnabled,
          type: ConfigValueType.bool,
          defaultValue: true,
          category: 'module',
          description: '角标模块开关（预留，接口就绪前恒启用）',
          descriptionEn: 'Badge module toggle (reserved, always on)',
        ),
      ];

  @override
  void registerProviders(ConfigService service) {
    // 桥接由 ConfigInitializer 完成（需要 ConfigManager 中的实例）
  }
}

/// 内置注册表
class ConfigRegistry {
  ConfigRegistry._();

  /// 全部内置配置项
  static List<ConfigEntry> get entries => AppCoreConfigModule().configs;

  /// 注册全部内置配置项（旧入口，保留兼容）
  static void registerAll(ConfigService service) {
    service.registerModule(AppCoreConfigModule());
  }

  /// 存量迁移：将散落的旧 prefs/secure key 迁移到统一存储
  ///
  /// 策略：读旧值 → 写入统一存储（新 key 或同 key）→ 删除旧 key。
  /// 老数据不丢，迁移完成后新写入全部走 ConfigService。
  static Future<void> migrateLegacy(ConfigStore store) async {
    final prefs = await SharedPreferences.getInstance();

    // 裸 key（无 config_ 前缀）的旧散落配置
    const legacyKeys = <String>{
      ConfigKeys.fdroidSources,
      ConfigKeys.lastSourceId,
      ConfigKeys.selectedChannels,
      ConfigKeys.agentModels,
      ConfigKeys.agentSelectedModelId,
      'webdav_url',
      'webdav_username',
      'webdav_password',
      'webdav_backup_path',
      'webdav_enable_https',
    };

    for (final key in legacyKeys) {
      try {
        final value = prefs.get(key);
        if (value == null) continue;
        // 写入统一存储（ConfigStore 自动加 config_ 前缀）
        await store.write(key, value);
        await prefs.remove(key);
        debugPrint(
            'ConfigRegistry: 迁移配置 $key -> ${store.isSensitive(key) ? 'secure' : 'normal'} 存储');
      } catch (e) {
        debugPrint('ConfigRegistry: 迁移配置 $key 失败 - $e');
      }
    }
  }
}
