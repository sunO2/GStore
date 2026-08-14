import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/update/apk_matcher.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/core/update/update_time_format.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'logic.dart';
import 'state.dart';

/// 应用更新页面
/// 检测已添加且已安装的应用是否有新版本，支持单个/全部更新
class UpdateManager extends StatelessWidget {
  const UpdateManager({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(UpdateLogic());
    return Scaffold(
      appBar: AppBar(
        // 标题 + 上次检测时间副标题（1 小时内显示 x 分钟前，超过显示实际时间）
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('应用更新'),
            Obx(() {
              final state = logic.state;
              final last = UpdateManagerService.instance.lastCheckedAt.value;
              final subtitle = state.isLoading.value
                  ? '检测中...'
                  : formatLastChecked(last, DateTime.now());
              return Text(
                subtitle,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              );
            }),
          ],
        ),
        actions: [
          // 检测日志 ⇄ 更新列表 切换（仅在有可更新应用时显示）
          Obx(() {
            final state = logic.state;
            if (state.updateList.isEmpty) return const SizedBox.shrink();
            final showLog = state.showLog.value;
            return IconButton(
              tooltip: showLog ? '查看更新列表' : '检测日志',
              icon: Icon(showLog ? Icons.list_alt : Icons.receipt_long),
              onPressed: () => logic.toggleLogView(),
            );
          }),
          IconButton(
            tooltip: '检查更新',
            icon: const Icon(Icons.refresh),
            onPressed: logic.state.isLoading.value
                ? null
                : () => logic.checkUpdates(force: true),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Obx(() {
        final state = logic.state;
        // 检测中：停留在检测页展示滚轮/图标/进度/日志
        if (state.isLoading.value) {
          return _buildChecking(context, state);
        }
        // 无更新完成：停留检测页展示完整日志
        if (state.checkFinished.value && state.updateList.isEmpty) {
          return _buildChecking(context, state);
        }
        // 有更新：showLog 控制"检测日志页 ⇄ 更新列表页"切换
        if (state.updateList.isNotEmpty) {
          if (state.showLog.value) {
            return _buildChecking(context, state);
          }
          return _buildUpdateList(context, logic, state);
        }
        if (state.errorMessage.value != null && state.updateList.isEmpty) {
          return _buildEmpty(context, state.errorMessage.value!,
              hasError: true);
        }
        return _buildEmpty(context, '所有已添加应用均已是最新版本');
      }),
    );
  }

  /// 检测中 / 检测完成（日志页）
  Widget _buildChecking(BuildContext context, UpdateState state) {
    final total = state.totalCount.value;
    final percent =
        total > 0 ? (state.checkedCount.value / total).clamp(0.0, 1.0) : 0.0;
    // 完成态判定：无更新完成（checkFinished）或有更新时手动切到日志页（showLog）
    final finished = state.checkFinished.value ||
        (state.updateList.isNotEmpty && state.showLog.value);
    final hasUpdates = state.updateList.isNotEmpty;
    return Column(
      children: [
        // 顶部：loading/完成图标 + 滚轮 + 进度
        Padding(
          padding: AppSpacing.allLG,
          child: Column(
            children: [
              if (finished)
                Icon(
                  Icons.check_circle,
                  size: AppTypography.sizeXL,
                  color: Theme.of(context).colorScheme.primary,
                )
              else
                // loading 圆环 + 被检测应用图标叠加
                _CheckingAppIconLoading(state: state),
              const SizedBox(height: AppSpacing.lg),
              // 正在检测的应用名（滚轮效果：完整预填待检测名单，随进度滚动）
              _CheckingWheel(state: state),
              const SizedBox(height: AppSpacing.xs),
              Text(
                finished
                    ? (hasUpdates
                        ? '检测完成：发现 ${state.updateList.length} 个可更新应用'
                        : (total > 0
                            ? '检测完成（$total 个应用，均无更新）'
                            : '检测完成：所有应用均已是最新版本'))
                    : (total > 0
                        ? '正在检测更新 ${state.checkedCount.value}/$total'
                        : '正在检测更新...'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              if (total > 0) ...[
                const SizedBox(height: AppSpacing.md),
                ClipRRect(
                  borderRadius: AppRadius.allSM,
                  child: LinearProgressIndicator(
                    value: percent,
                    minHeight: AppSpacing.sm,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
              // 切换到更新列表的按钮已移至导航头（AppBar actions）
            ],
          ),
        ),
        const Divider(height: 1),
        // 底部：检测日志输出
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: _CheckLogView(state: state),
        ),
      ],
    );
  }

  /// 空状态 / 错误
  Widget _buildEmpty(BuildContext context, String message,
      {bool hasError = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasError ? Icons.error_outline : Icons.check_circle_outline,
            size: AppTypography.sizeXXL,
            color: hasError
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: AppSpacing.onlyHorizontalLG,
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  /// 更新列表
  Widget _buildUpdateList(
    BuildContext context,
    UpdateLogic logic,
    UpdateState state,
  ) {
    return Column(
      children: [
        // 顶部操作栏
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '发现 ${state.updateList.length} 个可更新应用',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                ),
              ),
              // 切换到检测日志的按钮已移至导航头（AppBar actions）
              const SizedBox(width: AppSpacing.xs),
              FilledButton.tonalIcon(
                onPressed:
                    state.updatingAppId.value != null ? null : logic.updateAll,
                icon: const Icon(Icons.system_update_alt, size: 18),
                label: const Text('全部更新'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          // 显式订阅用户 APK 选择（RxMap.operator[] 不注册依赖，
          // 且 ListView itemBuilder 惰性布局时 Obx 代理已失效 → 直接订阅 length）
          child: _UpdateListBody(
            state: state,
            logic: logic,
          ),
        ),
      ],
    );
  }
}

/// 更新列表主体：独立 Obx 订阅 selectedApkName，换选后即时刷新勾选
class _UpdateListBody extends StatelessWidget {
  final UpdateState state;
  final UpdateLogic logic;

  const _UpdateListBody({required this.state, required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 订阅 RxMap 变更（map 值读取在 itemBuilder 惰性布局期，无法注册依赖）
      state.selectedApkName.length;
      return ListView.separated(
        padding: AppSpacing.onlyBottomXL,
        itemCount: state.updateList.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final info = state.updateList[index];
          return _UpdateTile(
            info: info,
            isUpdating: state.updatingAppId.value == info.appId,
            download: state.currentDownload.value,
            selectedApkName: state.selectedApkName[info.appId],
            onUpdate: () => logic.updateApp(info),
            onSelectApk: (dl) => logic.selectApk(info, dl),
          );
        },
      );
    });
  }
}

/// 单个应用更新项
class _UpdateTile extends StatelessWidget {
  final AppUpdateInfo info;
  final bool isUpdating;
  final DownloadStatus? download;
  final VoidCallback onUpdate;

  /// 用户选择的 APK 文件名（null/空 = 未选，默认 latestDownload）
  final String? selectedApkName;

  /// 用户换选候选 APK 回调
  final void Function(DownloadInfo download) onSelectApk;

  const _UpdateTile({
    required this.info,
    required this.isUpdating,
    required this.download,
    required this.onUpdate,
    required this.selectedApkName,
    required this.onSelectApk,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 展开候选列表：仅 Android 可安装文件（.apk/.aab），且 detail 存在且候选 >1 时显示
    // （缓存恢复 detail=null → 无候选）；zip/txt 等非安装文件不进入候选
    final candidates = filterInstallableDownloads(
      info.detail?.downloads ?? const <DownloadInfo>[],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 图标
              _AppIcon(url: info.iconUrl, name: info.appName),
              const SizedBox(width: AppSpacing.md),
              // 名称 + 版本信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            info.appName,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        _ChannelTag(
                          channelName: info.channelName,
                          color: scheme.secondaryContainer,
                          textColor: scheme.onSecondaryContainer,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${info.installedVersion} → ${info.latestVersion}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                    if (isUpdating && download != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _buildDownloadProgress(context, download!),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              // 更新按钮
              if (isUpdating)
                const AppLoading(size: AppLoadingSize.small)
              else
                FilledButton.tonal(
                  onPressed: onUpdate,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('更新'),
                ),
            ],
          ),
          // APK 候选展开选择（候选 >1 才显示入口）
          if (candidates.length > 1) ...[
            const SizedBox(height: AppSpacing.xs),
            _ApkSelector(
              candidates: candidates,
              selectedName: selectedApkName,
              defaultName: info.latestDownload.name,
              onSelect: onSelectApk,
            ),
          ],
        ],
      ),
    );
  }

  /// 下载进度
  Widget _buildDownloadProgress(BuildContext context, DownloadStatus data) {
    final progress = data.total > 0 ? data.count / data.total : 0.0;
    final percent = (progress * 100).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.allSM,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: AppSpacing.sm,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$percent%',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// APK 候选展开选择器
/// 展开后列出全部候选，勾选标识当前选中（用户所选 ?? 默认 latestDownload.name）
class _ApkSelector extends StatefulWidget {
  final List<DownloadInfo> candidates;
  final String? selectedName;
  final String defaultName;
  final void Function(DownloadInfo download) onSelect;

  const _ApkSelector({
    required this.candidates,
    required this.selectedName,
    required this.defaultName,
    required this.onSelect,
  });

  @override
  State<_ApkSelector> createState() => _ApkSelectorState();
}

class _ApkSelectorState extends State<_ApkSelector> {
  bool _expanded = false;

  /// 当前生效的选中文件名（用户所选优先，回退默认规则结果）
  String get _effectiveSelected =>
      (widget.selectedName != null && widget.selectedName!.isNotEmpty)
          ? widget.selectedName!
          : widget.defaultName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 展开入口：标题 + 当前选中文件名 + 展开箭头
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: AppRadius.allSM,
          child: Padding(
            padding: AppSpacing.horizontalSM_verticalXS,
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: AppTypography.iconSM,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  '选择 APK',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    _effectiveSelected,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: AppSpacing.xs),
          for (final dl in widget.candidates)
            _ApkOption(
              download: dl,
              selected: dl.name == _effectiveSelected,
              onTap: () {
                if (dl.name != _effectiveSelected) {
                  widget.onSelect(dl);
                }
              },
            ),
        ],
      ],
    );
  }
}

/// 单个 APK 候选行：勾选图标 + 文件名
class _ApkOption extends StatelessWidget {
  final DownloadInfo download;
  final bool selected;
  final VoidCallback onTap;

  const _ApkOption({
    required this.download,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('apk_option_${download.name}'),
      onTap: onTap,
      borderRadius: AppRadius.allSM,
      child: Padding(
        padding: AppSpacing.horizontalSM_verticalXS,
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: AppTypography.iconSM,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                download.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用图标
class _AppIcon extends StatelessWidget {
  final String? url;
  final String name;

  const _AppIcon({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    final size = AppTypography.iconXL * 1.6;
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.allMD,
        ),
        child: Icon(
          Icons.android,
          size: AppTypography.iconMD,
          color: AppColors.textSecondary,
        ),
      );
    }
    return ClipRRect(
      borderRadius: AppRadius.allMD,
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          width: size,
          height: size,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.android, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 渠道标签
class _ChannelTag extends StatelessWidget {
  final String channelName;
  final Color color;
  final Color textColor;

  const _ChannelTag({
    required this.channelName,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        channelName,
        style: AppTypography.labelSmall.copyWith(color: textColor),
      ),
    );
  }
}

/// 检测中 loading：圆环 + 被检测应用图标叠加
class _CheckingAppIconLoading extends StatelessWidget {
  final UpdateState state;

  const _CheckingAppIconLoading({required this.state});

  @override
  Widget build(BuildContext context) {
    final iconUrl = state.checkingIconUrl.value;
    const double iconSize = 26.0;

    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const AppLoading(size: AppLoadingSize.medium),
          // 被检测应用图标（无图标用默认安卓图标）
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: iconUrl != null && iconUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: iconUrl,
                    width: iconSize,
                    height: iconSize,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        _defaultIcon(context, iconSize),
                  )
                : _defaultIcon(context, iconSize),
          ),
        ],
      ),
    );
  }

  Widget _defaultIcon(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.android,
        size: 16,
        color: AppColors.textSecondary,
      ),
    );
  }
}

/// 检测中的应用名滚轮
/// 类似日期选择器：中间高亮当前项，上下可见相邻项
class _CheckingWheel extends StatefulWidget {
  final UpdateState state;

  const _CheckingWheel({required this.state});
  @override
  State<_CheckingWheel> createState() => _CheckingWheelState();
}

class _CheckingWheelState extends State<_CheckingWheel> {
  FixedExtentScrollController? _controller;
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(initialItem: 0);
  }

  @override
  void didUpdateWidget(_CheckingWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idx = widget.state.checkIndex.value;
    if (idx != _lastIndex) {
      _lastIndex = idx;
      final c = _controller;
      if (c != null && c.hasClients) {
        c.animateToItem(
          idx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.state.checkList;
    if (names.isEmpty) {
      // 缓存优先场景无本次检测名单：完成态显示"暂无检测记录"，
      // 检测中才显示"正在检测更新..."
      final finished = widget.state.checkFinished.value ||
          (widget.state.updateList.isNotEmpty && widget.state.showLog.value);
      return SizedBox(
        height: 96,
        child: Center(
          child: Text(
            finished ? '暂无检测记录' : '正在检测更新...',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 96,
      child: ListWheelScrollView(
        controller: _controller,
        itemExtent: 32,
        diameterRatio: 2.0,
        useMagnifier: true,
        magnification: 1.2,
        // 上下条目更淡，突出当前项
        overAndUnderCenterOpacity: 0.3,
        // 禁用用户手动翻页，仅由检测进度驱动
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < names.length; i++)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  names[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 检测日志视图（页面底部）
/// 颜色规则（整体偏浅）：
/// - info 信息   ：灰蓝
/// - installed   ：浅蓝
/// - update 更新 ：浅绿
/// - none 无更新 ：浅灰
/// - skip 跳过   ：浅橙
/// - error 错误  ：浅红
class _CheckLogView extends StatefulWidget {
  final UpdateState state;

  const _CheckLogView({required this.state});

  @override
  State<_CheckLogView> createState() => _CheckLogViewState();
}

class _CheckLogViewState extends State<_CheckLogView> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _logSubscription;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    // 监听日志追加，自动滚动到底部
    _logSubscription = widget.state.checkLog.listen((logs) {
      if (logs.length != _lastCount) {
        _lastCount = logs.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// 根据日志级别获取颜色（浅色系，便于深色/浅色主题下阅读）
  Color _logColor(CheckLogLevel level, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (level) {
      case CheckLogLevel.info:
        return AppColors.textSecondary;
      case CheckLogLevel.installed:
        return scheme.primary.withAlpha(200);
      case CheckLogLevel.update:
        return scheme.tertiary.withAlpha(200);
      case CheckLogLevel.none:
        return AppColors.textTertiary;
      case CheckLogLevel.skip:
        return const Color(0xFFB08D57);
      case CheckLogLevel.error:
        return const Color(0xFFE57373);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final logs = widget.state.checkLog;
      if (logs.isEmpty) {
        // 缓存优先进入时无本次检测日志（未触发检测）
        return Center(
          child: Text(
            '暂无检测日志\n点击右上角"检查更新"执行一次检测',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        );
      }
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xs,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final entry = logs[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.timeText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    entry.text,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _logColor(entry.level, context),
                          height: 1.4,
                        ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    });
  }
}
