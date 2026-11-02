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
import 'package:go_router/go_router.dart';

/// GitHub 代理预设地址
const List<String> presetProxyHosts = [
  'https://gh-proxy.org/',
  'https://v4.gh-proxy.org/',
  'https://v6.gh-proxy.org/',
  'https://cdn.gh-proxy.org/',
  'https://axisnow.gh-proxy.org/',
];

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

  /// 数据与同步：**本机数据**的维护（备份 / 代理 / 缓存 / 数据库）
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
          // GitHub 代理设置
          ListTile(
            leading: const Icon(TablerIcons.cloud_filled,
                size: AppTypography.iconMD),
            title: const Text('GitHub 代理'),
            subtitle: Text(
              '当前: ${getProxy().isEmpty ? '未设置' : getProxy()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => _showProxySettingDialog(context),
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

  /// 显示 GitHub 代理设置底部弹层
  Future<void> _showProxySettingDialog(BuildContext context) async {
    final controller = TextEditingController(text: getProxy());
    final result = await AppDialogs.showBottomSheet<String>(
      title: 'GitHub 代理设置',
      children: [
        StatefulBuilder(
          builder: (context, setDialogState) {
            // children 无水平 padding（标题才带），内容整体补左右边距避免贴边
            return Padding(
              padding: AppSpacing.onlyHorizontalLG,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('设置 GitHub 相关下载的代理前缀，用于加速国内访问。'),
                  const SizedBox(height: AppSpacing.md),
                  // 代理输入框 + 下拉选择预设（可手动输入；下拉选择即生效）
                  DropdownMenu<String>(
                    controller: controller,
                    // 必须开启：Android 平台默认 canRequestFocus=false → 输入框只读
                    requestFocusOnTap: true,
                    // 手动输入不过滤菜单（始终显示全部预设）
                    enableFilter: false,
                    // 撑满弹层宽度（bottom sheet 内容宽度受左右 padding 约束）
                    width: double.infinity,
                    onSelected: (value) {
                      if (value != null) {
                        controller.text = value;
                        // 下拉选择即生效（手动输入仍走保存按钮）
                        updateProxy(value);
                        setDialogState(() {});
                      }
                    },
                    // 无边框胶囊样式（高对比容器底色，与弹层背景区分）
                    decorationBuilder: (context, controller) {
                      final scheme = Theme.of(context).colorScheme;
                      final capsuleBorder = OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.circle),
                        borderSide: BorderSide.none,
                      );
                      return InputDecoration(
                        labelText: '代理前缀',
                        hintText: 'https://gh-proxy.org/',
                        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        border: capsuleBorder,
                        enabledBorder: capsuleBorder,
                        focusedBorder: capsuleBorder,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                          vertical: AppSpacing.md,
                        ),
                      );
                    },
                    dropdownMenuEntries: [
                      for (final host in presetProxyHosts)
                        DropdownMenuEntry(
                          value: host,
                          label: host,
                          // 当前选中项前 ✅ 标记
                          labelWidget: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (controller.text == host)
                                const Text('✅ ',
                                    style: TextStyle(fontSize: 14)),
                              Flexible(
                                child: Text(
                                  host,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '设置了代理则下载走代理；留空表示不使用代理',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 操作按钮
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        // 取消：返回 null，不触发保存逻辑（此前与保存按钮同样返回输入值导致误保存）
                        onPressed: () => AppDialogs.popSheet<String?>(null),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton(
                        onPressed: () => AppDialogs.popSheet<String?>(
                            controller.text.trim()),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
    controller.dispose();

    if (result != null) {
      var value = result;
      // 确保以 / 结尾（空字符串表示不使用代理）
      if (value.isNotEmpty && !value.endsWith('/')) {
        value = '$value/';
      }
      updateProxy(value.isNotEmpty ? value : null);
      if (mounted)
        setState(() {}); // 刷新代理 subtitle（StatelessWidget → StatefulWidget）
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(value.isEmpty ? '已禁用 GitHub 代理' : '代理已更新: $value')),
        );
      }
    }
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
          Text('entry.js 大小: ${selected.pkg.entryScript.length} 字符',
              style: textTheme.bodySmall),
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
                              '无效的渠道包：非 zip 文件 / 缺 entry.js / 含路径穿越');
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

  Widget _buildDownloadSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          // 多段下载开关
          const _MultiSegmentDownloadTile(),
          const Divider(height: 1),
          // 最大并发下载数
          const _MaxConcurrentDownloadTile(),
          const Divider(height: 1),
          // 仅WiFi下载
          const _WifiOnlyDownloadTile(),
          const Divider(height: 1),
          // 最大重试次数
          const _MaxRetryCountTile(),
        ],
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

/// 多段下载开关 Tile
///
/// 控制是否启用多段并行下载（自适应分段，可显著加速大文件下载）。
/// 弱网/网络不稳定时可关闭，回退为单连接下载。
class _MultiSegmentDownloadTile extends StatefulWidget {
  const _MultiSegmentDownloadTile();

  @override
  State<_MultiSegmentDownloadTile> createState() =>
      _MultiSegmentDownloadTileState();
}

class _MultiSegmentDownloadTileState extends State<_MultiSegmentDownloadTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await ConfigService.instance
          .getT<bool>(ConfigKeys.downloadMultiSegmentEnabled);
      if (mounted) {
        setState(() {
          _enabled = enabled ?? true;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('SettingsPage: 读取多段下载配置失败 - $e');
      if (mounted) {
        setState(() {
          _enabled = true;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMultiSegmentEnabled,
        value,
        source: ConfigChangeSource.user,
      );
      if (result.success) {
        appLog.info('SettingsPage: 多段下载已${value ? "开启" : "关闭"}');
      } else {
        debugPrint('SettingsPage: 保存多段下载配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('SettingsPage: 保存多段下载配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(
        TablerIcons.route,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('多段下载'),
      subtitle: const Text('自适应分段并行下载（最大 8 段），大文件下载更快。弱网或不稳定时可关闭'),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 最大并发下载数 Tile
///
/// 滑块控制同时下载的最大任务数（范围 1-10），
/// 多任务同时下载可提高总带宽利用率，但过高可能导致网络拥塞。
class _MaxConcurrentDownloadTile extends StatefulWidget {
  const _MaxConcurrentDownloadTile();

  @override
  State<_MaxConcurrentDownloadTile> createState() =>
      _MaxConcurrentDownloadTileState();
}

class _MaxConcurrentDownloadTileState
    extends State<_MaxConcurrentDownloadTile> {
  int _value = 3;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ConfigService.instance
          .getT<int>(ConfigKeys.downloadMaxConcurrent);
      if (mounted) {
        setState(() {
          _value = value ?? 3;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('SettingsPage: 读取并发数配置失败 - $e');
      if (mounted) {
        setState(() {
          _value = 3;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _update(int value) async {
    // 滑块已限定 1-10；这里再 clamp 一次，避免程序化调用写入越界值
    // （ConfigService 仍会按注册表范围校验并拒绝非法写入）。
    final clamped = value.clamp(1, 10);
    setState(() => _value = clamped);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMaxConcurrent,
        clamped,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('SettingsPage: 保存并发数配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('SettingsPage: 保存并发数配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        TablerIcons.download,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('最大并发下载数'),
      subtitle: Text('同时下载的最大任务数: $_value'),
      trailing: SizedBox(
        width: 150,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: _value.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$_value',
                onChanged: _loaded ? (v) => _update(v.round()) : null,
              ),
            ),
            Text('$_value', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 仅WiFi下载 Tile
///
/// 开关控制是否仅在 WiFi 环境下下载，
/// 开启后可避免消耗移动数据流量。
///
/// **已知 UI-only 设置**：`download.wifi_only` 是 Dart 侧偏好，Rust 下载引擎
/// 当前不消费该键（见 `gstore_mod_download/src/config/mod.rs`）；此处仅负责
/// 通过 [ConfigService] 持久化，供下载入口/后续消费方读取。不要静默删除键或
/// Tile——迁移工具与备份仍需要它。
class _WifiOnlyDownloadTile extends StatefulWidget {
  const _WifiOnlyDownloadTile();

  @override
  State<_WifiOnlyDownloadTile> createState() => _WifiOnlyDownloadTileState();
}

class _WifiOnlyDownloadTileState extends State<_WifiOnlyDownloadTile> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled =
          await ConfigService.instance.getT<bool>(ConfigKeys.downloadWifiOnly);
      if (mounted) {
        setState(() {
          _enabled = enabled ?? false;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('SettingsPage: 读取WiFi-only配置失败 - $e');
      if (mounted) {
        setState(() {
          _enabled = false;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadWifiOnly,
        value,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('SettingsPage: 保存WiFi-only配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('SettingsPage: 保存WiFi-only配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(
        TablerIcons.wifi,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('仅WiFi下载'),
      subtitle: const Text('开启后仅在WiFi环境下下载，避免消耗移动数据'),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 最大重试次数 Tile
///
/// 滑块控制下载失败后的自动重试次数（范围 0-5），
/// 设为 0 表示不重试，较高的重试次数可提高弱网环境下的成功率。
class _MaxRetryCountTile extends StatefulWidget {
  const _MaxRetryCountTile();

  @override
  State<_MaxRetryCountTile> createState() => _MaxRetryCountTileState();
}

class _MaxRetryCountTileState extends State<_MaxRetryCountTile> {
  int _value = 3;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value =
          await ConfigService.instance.getT<int>(ConfigKeys.downloadMaxRetries);
      if (mounted) {
        setState(() {
          _value = value ?? 3;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('SettingsPage: 读取重试次数配置失败 - $e');
      if (mounted) {
        setState(() {
          _value = 3;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _update(int value) async {
    // 滑块已限定 0-5；这里再 clamp 一次，避免程序化调用写入越界值
    // （ConfigService 仍会按注册表范围校验并拒绝非法写入）。
    final clamped = value.clamp(0, 5);
    setState(() => _value = clamped);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMaxRetries,
        clamped,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('SettingsPage: 保存重试次数配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('SettingsPage: 保存重试次数配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        TablerIcons.reload,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('最大重试次数'),
      subtitle: Text('下载失败后自动重试: $_value 次'),
      trailing: SizedBox(
        width: 150,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: _value.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: '$_value',
                onChanged: _loaded ? (v) => _update(v.round()) : null,
              ),
            ),
            Text('$_value', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
