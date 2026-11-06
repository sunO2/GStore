import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/service/app_icon_service.dart';

/// 下载列表中的应用图标。
///
/// 取图优先级：
/// 1. 本地文件路径（catalog 已缓存 / `file://`）→ [Image.file]
/// 2. 合法 http(s) 图标 URL → [CachedNetworkImage]
/// 3. 已安装应用图标（[AppIconService]，仅 Android）
/// 4. 应用名首字母头像（兜底，保证任何情况下都有"正常"图标，而不是空白/机器人）
class DownloadAppIcon extends StatelessWidget {
  const DownloadAppIcon({
    super.key,
    required this.appId,
    required this.appName,
    required this.iconUrl,
    this.size = 48,
  });

  final String appId;
  final String appName;
  final String? iconUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = iconUrl?.trim() ?? '';
    final localPath = _localPathOf(url);
    final networkUrl = _networkUrlOf(url);

    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: AppRadius.allMD,
        child: localPath != null
            ? Image.file(
                File(localPath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _InstalledIconFallback(appId: appId, appName: appName),
              )
            : networkUrl != null
                ? CachedNetworkImage(
                    imageUrl: networkUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const AppLoading(size: AppLoadingSize.small),
                    errorWidget: (_, __, ___) =>
                        _InstalledIconFallback(appId: appId, appName: appName),
                  )
                : _InstalledIconFallback(appId: appId, appName: appName),
      ),
    );
  }

  /// `file://` 或绝对路径 → 本地文件路径。
  static String? _localPathOf(String url) {
    if (url.isEmpty) return null;
    final path = url.startsWith('file://') ? url.substring(7) : url;
    return path.startsWith('/') ? path : null;
  }

  /// 仅接受完整的 http(s) URL（相对路径交给已安装应用图标兜底）。
  static String? _networkUrlOf(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return null;
  }
}

/// 已安装应用图标兜底：解析失败 / 非 Android 时显示应用名首字母头像。
class _InstalledIconFallback extends StatefulWidget {
  const _InstalledIconFallback({
    required this.appId,
    required this.appName,
  });

  final String appId;
  final String appName;

  @override
  State<_InstalledIconFallback> createState() => _InstalledIconFallbackState();
}

class _InstalledIconFallbackState extends State<_InstalledIconFallback> {
  String? _installedPath;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _InstalledIconFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appId != widget.appId) {
      _installedPath = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    // 测试宿主 / 非 Android 不触碰平台通道，直接走首字母头像。
    if (!Platform.isAndroid) return;
    String? path;
    try {
      path = await AppIconService.instance.getInstalledAppIcon(widget.appId);
    } catch (_) {
      path = null;
    }
    if (!mounted || path == null) return;
    setState(() => _installedPath = path);
  }

  @override
  Widget build(BuildContext context) {
    final path = _installedPath;
    if (path == null) {
      return _MonogramAvatar(name: widget.appName);
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _MonogramAvatar(name: widget.appName),
    );
  }
}

/// 应用名首字母头像（无图标时的稳定兜底）。
class _MonogramAvatar extends StatelessWidget {
  const _MonogramAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final letter = trimmed.isEmpty
        ? '?'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();

    return Container(
      color: scheme.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        letter,
        maxLines: 1,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: AppTypography.weightSemiBold,
            ),
      ),
    );
  }
}
