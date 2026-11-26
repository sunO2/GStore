import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/theme/theme_provider.dart';
import 'package:gstore/page/download/download_settings_sheet.dart';
import 'package:go_router/go_router.dart';

/// Main settings page with appearance and other settings
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.filePicker});

  /// 选择 .zip 渠道包文件并返回（文件名 + 字节；null = 取消/失败）。
  ///
  /// 测试注入假实现（FilePicker 平台通道在测试环境不可用）；
  /// 为 null 时走 [FilePicker.platform.pickFiles] 真实实现（SAF，无需权限）。
  final ZipPackagePick? filePicker;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 选择 .zip 渠道包文件（文件名 + 字节；null = 取消/失败）。
typedef ZipPackagePick = Future<({String name, Uint8List bytes})?> Function();

/// 选中的渠道包（文件名 + 派生渠道标识 + 解析结果 + 原始字节）。
typedef _SelectedPackage = ({
  String fileName,
  String channelKey,
  ChannelPackage pkg,
  Uint8List bytes,
});

/// 已导入渠道的统一视图（Rust 脚本通道；Dart 旧轨 [JsChannel] 已随纯 Rust 清理删除）。
///
/// env 读取/保存与删除均走 Rust 脚本通道（`ScriptApi.getEnv/setEnv`、
/// `ChannelLoader.removeChannel`）。
typedef _ImportedChannel = ({
  String key,
  String name,
  String description,
});

class _SettingsPageState extends State<SettingsPage> {
  /// theme 模块是否在线（随模块上下线实时更新；下线时主题入口禁用）
  bool _themeModuleOnline = false;

  /// theme 模块上下线事件订阅（dispose 取消，防泄漏）
  StreamSubscription<ModuleEvent>? _themeSub;

  @override
  void initState() {
    super.initState();
    _themeModuleOnline = ModuleManager.instance.isModuleEnabled('theme');
    _themeSub = ModuleManager.instance.watchModule('theme').listen((_) {
      if (!mounted) return;
      setState(() {
        _themeModuleOnline = ModuleManager.instance.isModuleEnabled('theme');
      });
    });
    // Rust 脚本通道（flag on）：「已导入渠道」计数/列表读 Rust lane 缓存，
    // 打开设置页时刷新一次，保证计数反映真实导入。
    unawaited(_refreshRustLane());
  }

  /// 刷新 Rust 脚本通道缓存（flag off 时 no-op），并刷新「已导入渠道」计数。
  Future<void> _refreshRustLane() async {
    final lane = RustScriptChannelLane.instance;
    if (!lane.enabled) return;
    await lane.refresh();
    if (mounted) setState(() {});
  }

  /// 已导入渠道数：Rust 通道 flag on 时读 Rust lane，否则读 Dart 注册表。
  int _importedChannelCount() {
    final lane = RustScriptChannelLane.instance;
    if (lane.enabled) return lane.packs.length;
    return ChannelManager.instance.dynamicChannels.length;
  }

  /// 已导入渠道视图列表（Rust 脚本通道；Dart 旧轨已删除）。
  List<_ImportedChannel> _importedChannels() {
    final lane = RustScriptChannelLane.instance;
    return [
      for (final pack in lane.packs)
        (
          key: pack.key,
          name: pack.name.isEmpty ? pack.key : pack.name,
          description: pack.description,
        ),
    ];
  }

  @override
  void dispose() {
    _themeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          // Appearance section
          _buildSectionHeader('外观'),
          _buildAppearanceSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Data & Sync section
          _buildSectionHeader('数据与同步'),
          _buildDataSyncSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Data source section
          _buildSectionHeader('数据源管理'),
          _buildDataSourceSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Install & Permission section
          _buildSectionHeader('安装与权限'),
          _buildInstallSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Download section
          _buildSectionHeader('下载'),
          _buildDownloadSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Module section（低频配置，放在最后，避免抢占常用设置）
          _buildSectionHeader('模块'),
          _buildModuleSection(context),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: TextStyle(
          fontSize: AppTypography.sizeSM,
          fontWeight: AppTypography.weightMedium,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildAppearanceSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            enabled: _themeModuleOnline,
            leading: const Icon(TablerIcons.palette),
            title: const Text('主题'),
            // theme 模块下线 → 入口禁用并提示未启用（响应式 trailing 保留不动）
            subtitle: _themeModuleOnline ? null : const Text('主题模块未启用'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 当前主题模式（Riverpod 权威；theme 模块下线仅禁用入口，此处仍可读）
                Consumer(builder: (context, ref, _) {
                  final modeName = ref.watch(
                    themeProvider.select((t) => t.mode.displayName),
                  );
                  return Text(
                    modeName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: AppTypography.weightMedium,
                    ),
                  );
                }),
                const Icon(TablerIcons.chevron_right),
              ],
            ),
            onTap: _themeModuleOnline
                ? () => context.push(AppRoute.themeSettings)
                : null,
          ),
        ],
      ),
    );
  }

  /// 数据与同步：**本机数据**的维护（备份 / 缓存 / 数据库）
  Widget _buildDataSyncSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(TablerIcons.cloud_upload,
                size: AppTypography.iconMD),
            title: const Text('数据备份'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.backup),
          ),
          const Divider(height: 1),
          // 缓存管理（图片/README/图标等可再生缓存，单项或一键清理）
          ListTile(
            leading:
                const Icon(TablerIcons.clear_all, size: AppTypography.iconMD),
            title: const Text('缓存管理'),
            subtitle: const Text('清理图片 / README 等缓存与已下载文件'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.cacheManage),
          ),
        ],
      ),
    );
  }

  /// 数据源管理：所有决定"应用数据从哪儿来"的入口（F-Droid 源 + 渠道包）
  ///
  /// 与「数据与同步」分开：那边是本机数据的维护，这边是**数据来源**的配置。
  Widget _buildDataSourceSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          // 多源仓库：源 + 镜像配置
          ListTile(
            leading:
                const Icon(TablerIcons.source_code, size: AppTypography.iconMD),
            title: const Text('F-Droid 源管理'),
            subtitle: const Text('配置多个源与其镜像'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.fdroidRepo),
          ),
          const Divider(height: 1),
          // 渠道包导入（Android 应用私有目录无法读取公共 Documents 文件，走应用内导入）
          ListTile(
            leading: const Icon(TablerIcons.puzzle_filled,
                size: AppTypography.iconMD),
            title: const Text('脚本渠道'),
            subtitle: const Text('从 .zip 渠道包文件导入自定义渠道'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => _showScriptImportDialog(context),
          ),
          const Divider(height: 1),
          // 已导入渠道包管理（列表 + 环境变量编辑 + 删除）
          ListTile(
            key: const Key('script_channel_manage_entry'),
            leading: const Icon(TablerIcons.code, size: AppTypography.iconMD),
            title: const Text('已导入渠道'),
            subtitle: Text('${_importedChannelCount()} 个渠道包'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => _showScriptChannelManageDialog(context),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading:
                const Icon(TablerIcons.adjustments, size: AppTypography.iconMD),
            title: const Text('模块管理'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.moduleManage),
          ),
        ],
      ),
    );
  }

  /// 从系统选择 .zip 渠道包文件并读取字节（null = 取消/失败）。
  ///
  /// 真实实现：SAF 选文件（无需存储权限）→ 读 bytes；
  /// 测试注入 [SettingsPage.filePicker] 时直接返回注入结果。
  Future<({String name, Uint8List bytes})?> _pickZipPackage() async {
    final injected = widget.filePicker;
    if (injected != null) return injected();

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        AppDialogs.showInfo('已取消选择文件');
        return null;
      }
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        AppDialogs.showError('无法读取所选渠道包内容');
        return null;
      }
      return (name: file.name, bytes: bytes);
    } catch (e) {
      AppDialogs.showError('读取渠道包文件失败: $e');
      return null;
    }
  }

  /// 渠道包预览：包文件名 + 渠道标识 + 包 meta（名称/描述）或 entry.js 大小。
  Widget _buildZipPackagePreview(
      BuildContext context, _SelectedPackage selected) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final meta = selected.pkg.meta;
    final name = meta?['name']?.toString();
    final description = meta?['description']?.toString();
    return Container(
      key: const Key('script_channel_preview'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('包文件: ${selected.fileName}', style: textTheme.bodySmall),
          Text('渠道标识: ${selected.channelKey}', style: textTheme.bodySmall),
          if (name != null && name.isNotEmpty)
            Text('名称: $name', style: textTheme.bodySmall),
          if (description != null && description.isNotEmpty)
            Text('描述: $description', style: textTheme.bodySmall),
          Text(
            'entry.js 大小: ${selected.pkg.entryScript.length} 字符'
            ' · detail: ${selected.pkg.detailScript == null ? '未提供（必须）' : '已包含'}'
            ' · meta: ${selected.pkg.meta == null ? '未提供（必须）' : '已包含'}',
            style: textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// 显示渠道包导入对话框：选择 .zip 文件 → 校验 → 预览 meta → 确认导入；
  /// 可选配置环境变量。
  ///
  /// Android 应用私有目录无法读取公共 Documents 文件，走应用内导入；
  /// channelKey 取 zip 文件名（去 .zip，校验合法标识符，自动加 js_ 前缀）；
  /// 环境变量在导入成功后逐项 [JsChannel.setEnv]（渠道隔离持久化，
  /// 脚本通过 `host.env.get` 读取）。
  Future<void> _showScriptImportDialog(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    var envVars = <String, String>{};
    _SelectedPackage? selected;
    // 必需环境变量键集合（导入时用户不可修改键名，只填值）
    var requiredKeys = <String>{};

    final confirmed = await AppDialogs.showBottomSheet<bool>(
      title: '导入渠道包',
      children: [
        StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            // children 无水平 padding（标题才带），内容整体补左右边距避免贴边
            return Padding(
              padding: AppSpacing.onlyHorizontalLG,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '从 .zip 渠道包文件导入自定义渠道',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 从文件选择 .zip 渠道包
                    OutlinedButton.icon(
                      key: const Key('script_channel_file_button'),
                      onPressed: () async {
                        final picked = await _pickZipPackage();
                        if (picked == null) return;
                        final baseName = picked.name
                                .toLowerCase()
                                .endsWith('.zip')
                            ? picked.name.substring(0, picked.name.length - 4)
                            : picked.name;
                        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$')
                            .hasMatch(baseName)) {
                          AppDialogs.showError(
                              '渠道包文件名不能作为渠道标识（需字母/下划线开头，仅含字母数字/下划线）');
                          return;
                        }
                        final pkg = ChannelPackage.decode(picked.bytes);
                        if (pkg == null) {
                          AppDialogs.showError(
                              '无效的渠道包：zip 根目录必须直接包含 entry.js'
                              '（不要套文件夹；detail.js / meta.json 也必须提供）');
                          return;
                        }
                        // 从 meta.json 读取必需环境变量，预填入编辑器
                        final reqVars = pkg.requiredEnvVars;
                        final channelKey = 'js_$baseName';
                        // 尝试加载已存在的环境变量（回显之前填过的值）：
                        // Rust 轨读 ScriptApi 的渠道 env（与脚本 host.env.get 同一
                        // 存储，敏感项从密钥存储解析）。Dart 旧轨已删除。
                        var existingEnv = <String, String>{};
                        try {
                          existingEnv =
                              await ScriptApi.instance.getEnv(key: channelKey);
                        } catch (_) {
                          // 读取失败不影响，使用空值
                        }
                        final initial = <String, String>{};
                        for (final key in reqVars) {
                          initial[key] = existingEnv[key] ?? '';
                        }
                        requiredKeys = reqVars.toSet();
                        envVars = Map.from(initial);
                        setDialogState(() {
                          selected = (
                            fileName: picked.name,
                            channelKey: 'js_$baseName',
                            pkg: pkg,
                            bytes: picked.bytes,
                          );
                        });
                      },
                      icon: const Icon(TablerIcons.upload),
                      label: const Text('从文件选择渠道包 (.zip)'),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _buildZipPackagePreview(dialogContext, selected!),
                      const SizedBox(height: AppSpacing.sm),
                      // 必需环境变量（meta.json 声明）
                      if (requiredKeys.isNotEmpty) ...[
                        Text('必需环境变量',
                            style: textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpacing.xs),
                        Text('脚本通过 host.env.get 读取，请填写以下值',
                            style: textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                        const SizedBox(height: AppSpacing.sm),
                        _ScriptChannelEnvEditor(
                          initial: envVars,
                          readOnlyKeys: requiredKeys,
                          onChanged: (map) => envVars = map,
                        ),
                      ],
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    // 操作按钮
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => AppDialogs.popSheet(false),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        FilledButton(
                          onPressed: () async {
                            final pkg = selected;
                            if (pkg == null) {
                              AppDialogs.showError('请先选择 .zip 渠道包文件');
                              return;
                            }
                            // 校验必需环境变量是否已填写
                            for (final key in requiredKeys) {
                              if ((envVars[key] ?? '').trim().isEmpty) {
                                AppDialogs.showError('请填写必需环境变量 $key');
                                return;
                              }
                            }
                            AppDialogs.popSheet(true);
                          },
                          child: const Text('导入'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );

    if (confirmed != true) return;

    final pkg = selected;
    if (pkg == null) return;

    try {
      final imported = await ChannelLoader().importZip(
        channelKey: pkg.channelKey,
        zipBytes: pkg.bytes,
      );
      // CoreFlags.jsChannel inside ChannelLoader routes to the Rust lane: the
      // installed pack is returned and the env snapshot goes through
      // ScriptApi.setEnv. Nothing is written to the legacy channel directory.
      final pack = imported.pack;
      if (envVars.isNotEmpty) {
        await ScriptApi.instance.setEnv(
          key: pack.key,
          env: envVars,
        );
        AppDialogs.showSuccess(
            '渠道包已导入（${pack.name}），环境变量已保存，脚本通过 host.env.get 读取');
      } else {
        AppDialogs.showSuccess('渠道包已导入（${pack.name}），可切到发现页查看');
      }
      if (mounted) setState(() {});
    } catch (e) {
      AppDialogs.showError('导入失败: $e');
    }
  }

  /// 显示渠道包管理对话框：列出已导入渠道 + 环境变量编辑 + 删除。
  ///
  /// 列表来源按 `CoreFlags.jsChannel` 分轨：flag on 时 Rust ScriptApi 拥有渠道
  /// 包（Dart `dynamicChannels` 为空），从 `RustScriptChannelLane` 读取；flag off
  /// 时沿用 Dart `JsChannel` 注册表（逐字节不变）。
  Future<void> _showScriptChannelManageDialog(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    await AppDialogs.showDialog(
      title: '渠道包管理',
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final channels = _importedChannels();
          if (channels.isEmpty) {
            return Text(
              '暂无已导入的渠道包，请先通过「脚本渠道」导入',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final channel in channels)
                Padding(
                  key: Key('script_channel_manage_${channel.key}'),
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(channel.name, style: textTheme.bodyLarge),
                            Text(
                              channel.key,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: Key('script_channel_env_edit_${channel.key}'),
                        tooltip: '编辑环境变量',
                        icon: const Icon(TablerIcons.settings),
                        onPressed: () async {
                          await _showScriptChannelEnvDialog(channel);
                          setDialogState(() {});
                        },
                      ),
                      IconButton(
                        key: Key('script_channel_delete_${channel.key}'),
                        tooltip: '删除渠道',
                        icon: const Icon(TablerIcons.trash),
                        onPressed: () =>
                            _removeScriptChannel(channel, setDialogState),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      confirmText: '关闭',
      cancelText: null,
    );

    if (mounted) setState(() {}); // 刷新「已导入渠道」计数
  }

  /// 删除渠道包：危险确认 → [ChannelLoader.removeChannel]（Rust/Dart 轨均由
  /// 其按 `CoreFlags.jsChannel` 分派：注销 + 删文件 + 清 env）。
  Future<void> _removeScriptChannel(
      _ImportedChannel channel, StateSetter setDialogState) async {
    final confirmed = await AppDialogs.showDialog(
      title: '删除渠道包',
      content: '确定删除「${channel.name}」（${channel.key}）？渠道包文件与环境变量将一并删除。',
      confirmText: '删除',
      cancelText: '取消',
      isDangerous: true,
    );
    if (confirmed != true) return;

    try {
      await ChannelLoader().removeChannel(channel.key);
      if (context.mounted) {
        setDialogState(() {});
        AppDialogs.showSuccess('渠道包已删除');
      }
    } catch (e) {
      AppDialogs.showError('删除失败: $e');
    }
  }

  /// 读取渠道当前环境变量（Rust 脚本通道）。
  ///
  /// 走 `ScriptApi.getEnv`（读 Rust 脚本存储，与脚本 `host.env.get`
  /// 同一份数据，敏感项从密钥存储解析）。读取失败仅作空初值，不影响编辑器。
  Future<Map<String, String>> _loadChannelEnv(_ImportedChannel channel) async {
    try {
      return await ScriptApi.instance.getEnv(key: channel.key);
    } catch (_) {
      // 读取失败不影响，使用空值
    }
    return const {};
  }

  /// 编辑已导入渠道的环境变量：加载当前值 → 键值对编辑 → 保存。
  ///
  /// Rust 通道保存走 `ScriptApi.setEnv`（全量替换语义，脚本下次 host.env.get
  /// 立即生效）；Dart 旧轨差异应用 setEnv/removeEnv（逐字节不变）。
  Future<void> _showScriptChannelEnvDialog(_ImportedChannel channel) async {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final initial = await _loadChannelEnv(channel);
    if (!context.mounted) return;
    var envVars = Map<String, String>.of(initial);

    final saved = await AppDialogs.showDialog(
      title: '环境变量',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            channel.key,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '脚本通过 host.env.get 读取；保存后立即生效，无需重建引擎',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // 内容过长时由统一 sheet 内部滚动，无需再包一层滚动视图
          _ScriptChannelEnvEditor(
            initial: initial,
            onChanged: (map) => envVars = map,
          ),
        ],
      ),
      confirmText: '保存',
      cancelText: '取消',
    );

    if (saved != true) return;

    // Rust 脚本通道：全量替换语义（脚本下次 host.env.get 立即生效）。
    await ScriptApi.instance.setEnv(key: channel.key, env: envVars);
    if (context.mounted) {
      AppDialogs.showSuccess('环境变量已保存，脚本通过 host.env.get 读取');
    }
  }

  Widget _buildInstallSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          // Shizuku 授权状态
          _ShizukuTile(),
          const Divider(height: 1),
          // 安装方式提示
          ListTile(
            leading: const Icon(TablerIcons.device_mobile_down,
                size: AppTypography.iconMD),
            title: const Text('安装方式'),
            subtitle: const Text('开启 Shizuku 后可静默安装应用，无需逐次确认；未授权时使用系统安装'),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }

  /// 下载设置入口（唯一可编辑控件在统一弹层内，此处只做跳转）。
  Widget _buildDownloadSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: ListTile(
        key: const Key('settings_download_entry'),
        leading: const Icon(TablerIcons.download, size: AppTypography.iconMD),
        title: const Text('下载设置'),
        subtitle: const Text('多段下载 · 并发数 · 仅 WiFi · 重试次数 · GitHub 代理'),
        trailing: const Icon(TablerIcons.chevron_right,
            size: AppTypography.iconSM),
        onTap: () => showDownloadSettingsSheet(context),
      ),
    );
  }
}

/// 环境变量键值对编辑器（导入对话框 / 渠道管理编辑对话框共用）。
///
/// 行 = 键 TextField + 值 TextField + 删除按钮；「添加环境变量」追加一行。
/// 变更（增/删/改）通过 [onChanged] 上报：键去空格，空键行忽略（值允许为空）。
class _ScriptChannelEnvEditor extends StatefulWidget {
  const _ScriptChannelEnvEditor({
    required this.initial,
    required this.onChanged,
    this.readOnlyKeys = const {},
  });

  /// 初始键值（编辑已导入渠道时来自 [JsChannel.getAllEnv]）
  final Map<String, String> initial;

  /// 编辑结果回调（每次增删改后触发）
  final ValueChanged<Map<String, String>> onChanged;

  /// 只读键集合（导入时来自 meta.json requiredEnvVars，用户不可修改键名）
  final Set<String> readOnlyKeys;

  @override
  State<_ScriptChannelEnvEditor> createState() =>
      _ScriptChannelEnvEditorState();
}

class _ScriptChannelEnvEditorState extends State<_ScriptChannelEnvEditor> {
  late final List<_EnvRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final entry in widget.initial.entries)
        _EnvRow(
          TextEditingController(text: entry.key),
          TextEditingController(text: entry.value),
        ),
    ];
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.key.dispose();
      row.value.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collect() {
    final result = <String, String>{};
    for (final row in _rows) {
      final key = row.key.text.trim();
      if (key.isNotEmpty) result[key] = row.value.text;
    }
    return result;
  }

  void _notify() => widget.onChanged(_collect());

  void _addRow() {
    setState(() =>
        _rows.add(_EnvRow(TextEditingController(), TextEditingController())));
    _notify();
  }

  void _removeRow(int index) {
    setState(() {
      final row = _rows.removeAt(index);
      row.key.dispose();
      row.value.dispose();
    });
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _rows.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.xs),
          Row(
            key: Key('script_channel_env_row_$i'),
            children: [
              Expanded(
                child: TextField(
                  key: Key('script_channel_env_key_$i'),
                  controller: _rows[i].key,
                  readOnly: widget.readOnlyKeys.contains(_rows[i].key.text),
                  decoration: InputDecoration(
                    labelText: '键',
                    hintText: '如 PINGAN_USER',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    filled: widget.readOnlyKeys.contains(_rows[i].key.text),
                    fillColor: widget.readOnlyKeys.contains(_rows[i].key.text)
                        ? Theme.of(context).colorScheme.surfaceContainerLow
                        : null,
                  ),
                  onChanged: (_) => _notify(),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: TextField(
                  key: Key('script_channel_env_value_$i'),
                  controller: _rows[i].value,
                  decoration: const InputDecoration(
                    labelText: '值',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _notify(),
                ),
              ),
              IconButton(
                key: Key('script_channel_env_remove_$i'),
                tooltip: '删除该环境变量',
                icon: const Icon(TablerIcons.trash),
                onPressed: widget.readOnlyKeys.contains(_rows[i].key.text)
                    ? null
                    : () => _removeRow(i),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          key: const Key('script_channel_env_add'),
          onPressed: _addRow,
          icon: const Icon(TablerIcons.plus),
          label: const Text('添加环境变量'),
        ),
      ],
    );
  }
}

/// 环境变量行（键/值控制器）
class _EnvRow {
  _EnvRow(this.key, this.value);

  final TextEditingController key;
  final TextEditingController value;
}

/// 版本 Tile：异步读取实际版本号（package_info_plus）
/// 加载中显示 '…'；获取失败（如测试环境）显示 'unknown'
/// Shizuku 授权状态 Tile
class _ShizukuTile extends StatefulWidget {
  @override
  State<_ShizukuTile> createState() => _ShizukuTileState();
}

class _ShizukuTileState extends State<_ShizukuTile> {
  bool _checking = true;
  bool _available = false;
  bool _granted = false;

  /// install 模块是否在线（随模块上下线实时更新；下线时 tile 禁用）
  bool _moduleOnline = false;

  /// install 模块上下线事件订阅（dispose 取消，防泄漏）
  StreamSubscription<ModuleEvent>? _moduleSub;

  /// 安装管理器（按类型从注册表取；模块下线 → null）
  InstallManager? get _installManager =>
      ModuleManager.instance.get<InstallManager>();

  @override
  void initState() {
    super.initState();
    _moduleOnline = ModuleManager.instance.isModuleEnabled('install');
    _moduleSub = ModuleManager.instance.watchModule('install').listen((_) {
      if (!mounted) return;
      setState(() {
        _moduleOnline = ModuleManager.instance.isModuleEnabled('install');
      });
      // 重新上线后重新检测 Shizuku 状态
      if (_moduleOnline) _check();
    });
    _check();
  }

  @override
  void dispose() {
    _moduleSub?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    // 模块下线（注册表无服务）→ 直接置不可用态，不访问安装管理器
    final manager = _installManager;
    if (manager == null) {
      if (mounted) {
        setState(() {
          _checking = false;
          _available = false;
          _granted = false;
        });
      }
      return;
    }
    await manager.checkShizuku();
    if (mounted) {
      setState(() {
        _checking = false;
        _available = manager.isBinderRunning;
        _granted = manager.isPermissionGranted;
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _checking = true);
    final manager = _installManager;
    if (manager == null) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    final granted = await manager.requestPermission();
    if (mounted) {
      setState(() {
        _checking = false;
        _available = manager.isBinderRunning;
        _granted = granted;
      });
    }
    if (mounted && granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shizuku 授权成功，可静默安装应用')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // install 模块下线 → tile 禁用，显示未启用提示
    if (!_moduleOnline) {
      return ListTile(
        enabled: false,
        leading: const Icon(TablerIcons.shield, size: AppTypography.iconMD),
        title: const Text('Shizuku 状态'),
        subtitle: const Text('安装模块未启用'),
      );
    }

    if (_checking) {
      return const ListTile(
        leading: Icon(TablerIcons.shield, size: AppTypography.iconMD),
        title: Text('Shizuku 状态'),
        subtitle: Text('检测中...'),
      );
    }

    if (!_available) {
      return ListTile(
        leading: const Icon(TablerIcons.shield, size: AppTypography.iconMD),
        title: const Text('Shizuku 状态'),
        subtitle: const Text('未运行（需安装 Shizuku 并启动）'),
        trailing: TextButton(
          onPressed: () async {
            final manager = _installManager;
            if (manager == null) return;
            await manager.checkShizuku();
            if (mounted)
              setState(() {
                _available = manager.isBinderRunning;
                _granted = manager.isPermissionGranted;
              });
          },
          child: const Text('重新检测'),
        ),
      );
    }

    if (!_granted) {
      return ListTile(
        leading: const Icon(TablerIcons.shield, size: AppTypography.iconMD),
        title: const Text('Shizuku 状态'),
        subtitle: const Text('已运行，未授权'),
        trailing: TextButton(
          onPressed: _requestPermission,
          child: const Text('授权'),
        ),
      );
    }

    return const ListTile(
      leading: Icon(TablerIcons.shield_filled,
          size: AppTypography.iconMD, color: Colors.green),
      title: Text('Shizuku 状态'),
      subtitle: Text('已授权，可静默安装'),
    );
  }
}
