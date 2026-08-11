import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/update/app_update_info.dart';
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
        title: const Text('应用更新'),
        actions: [
          IconButton(
            tooltip: '检查更新',
            icon: const Icon(Icons.refresh),
            onPressed: logic.state.isLoading.value ? null : logic.checkUpdates,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Obx(() {
        final state = logic.state;
        // 检测中或检测完成（无更新）时，停留在检测页展示完整日志
        if (state.isLoading.value || state.checkFinished.value) {
          return _buildChecking(context, state);
        }
        if (state.errorMessage.value != null && state.updateList.isEmpty) {
          return _buildEmpty(context, state.errorMessage.value!, hasError: true);
        }
        if (state.updateList.isEmpty) {
          return _buildEmpty(context, '所有已添加应用均已是最新版本');
        }
        return _buildUpdateList(context, logic, state);
      }),
    );
  }

  /// 检测中 / 检测完成
  Widget _buildChecking(BuildContext context, UpdateState state) {
    final total = state.totalCount.value;
    final percent = total > 0
        ? (state.checkedCount.value / total).clamp(0.0, 1.0)
        : 0.0;
    final finished = state.checkFinished.value;
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
              // 正在检测的应用名（滚轮效果：可看到上一个/当前/下一个）
              _CheckingWheel(state: state),
              const SizedBox(height: AppSpacing.xs),
              Text(
                finished
                    ? '检测完成（${total} 个应用，均无更新）'
                    : (total > 0
                        ? '正在检测更新 ${state.checkedCount.value}/${total}'
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
  Widget _buildEmpty(BuildContext context, String message, {bool hasError = false}) {
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
              FilledButton.tonalIcon(
                onPressed: state.updatingAppId.value != null
                    ? null
                    : logic.updateAll,
                icon: const Icon(Icons.system_update_alt, size: 18),
                label: const Text('全部更新'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: AppSpacing.onlyBottomXL,
            itemCount: state.updateList.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final info = state.updateList[index];
              return _UpdateTile(
                info: info,
                isUpdating: state.updatingAppId.value == info.appId,
                download: state.currentDownload.value,
                onUpdate: () => logic.updateApp(info),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 单个应用更新项
class _UpdateTile extends StatelessWidget {
  final AppUpdateInfo info;
  final bool isUpdating;
  final DownloadStatus? download;
  final VoidCallback onUpdate;

  const _UpdateTile({
    required this.info,
    required this.isUpdating,
    required this.download,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
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
                        maxLines: 1,
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
      return const SizedBox(
        height: 96,
        child: Center(child: Text('正在检测更新...')),
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
        return const SizedBox.shrink();
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
