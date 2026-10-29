import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';

/// GStore AppBar 的「检查更新」动作。
///
/// 运行中显示 [AppLoading] 小圈并禁用点击（避免重复下载）。
class GStoreUpdateAction extends StatelessWidget {
  const GStoreUpdateAction({
    super.key,
    required this.updating,
    required this.onPressed,
  });

  /// 是否正在检查/下载/物化。
  final bool updating;

  /// 未运行时的点击回调。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (updating) {
      return const Padding(
        padding: AppSpacing.onlyHorizontalMD,
        child: Center(
          child: SizedBox(
            width: AppTypography.iconMD,
            height: AppTypography.iconMD,
            child: AppLoading(size: AppLoadingSize.small),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: '检查更新',
      icon: const Icon(TablerIcons.refresh),
      onPressed: onPressed,
    );
  }
}

/// AppBar 标题：GStore + 当前目录版本（版本未知时不显示副标题）。
class GStoreTitle extends StatelessWidget {
  const GStoreTitle({super.key, this.version});

  /// 当前目录版本（`repoStatus().currentVersion`）。
  final String? version;

  @override
  Widget build(BuildContext context) {
    final version = this.version;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('GStore'),
        if (version != null && version.isNotEmpty)
          Text('版本 $version', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
