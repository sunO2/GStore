/// 详情页面可复用的 Section 组件
library;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailData.dart';

/// 版本信息 Section
class VersionSection extends StatelessWidget {
  final IDetailData info;

  const VersionSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    if (info.version == null && info.packageName == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.version != null) ...[
            Text(
              '版本',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.version!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (info.version != null && info.packageName != null)
            const SizedBox(height: 12),
          if (info.packageName != null) ...[
            Text(
              '包名',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.packageName!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final String value;
  final Widget? trailing;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.0,
          color: Theme.of(context).colorScheme.primaryFixed.withAlpha(100),
        ),
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryFixed.withAlpha(80),
              borderRadius: const BorderRadius.all(Radius.circular(10)),
            ),
            child: Text(
              value,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 2),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 应用截图 Section
class ScreenshotsSection extends StatelessWidget {
final IDetailData info;

  const ScreenshotsSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final screenshots = info.screenshots;
    if (screenshots == null || screenshots.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '应用截图',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: screenshots.length,
              itemBuilder: (context, index) {
                final screenshot = screenshots[index];
                return Container(
                  width: 120,
                  margin: const EdgeInsets.only(right: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: screenshot.url,
                      fit: BoxFit.contain,
                      placeholder: (context, url) => Container(
                        color: Colors.grey[200],
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// README/详情文本 Section
class ReadmeSection extends StatelessWidget {
final IDetailData info;
  final void Function(String)? onLinkTap;

  const ReadmeSection({super.key, required this.info, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    final readme = info.readme;
    if (readme == null || readme.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '详细介绍',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          MarkdownBody(
            data: readme,
            onTapLink: (text, href, title) {
              if (href != null && onLinkTap != null) {
                onLinkTap?.call(href);
              }
            },
            styleSheet: MarkdownStyleSheet(
              a: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            imageBuilder: (uri, title, alt) {
              final url = uri.toString();
              return Image(
                image: CachedNetworkImageProvider(url),
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.broken_image),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 下载链接 Section
class DownloadsSection extends StatelessWidget {
final IDetailData info;
  final void Function(DownloadInfo)? onDownloadTap;
  final void Function(DownloadInfo)? onLongPress;

  const DownloadsSection({
    super.key,
    required this.info,
    this.onDownloadTap,
    this.onLongPress,
  });

  /// 过滤出当前平台的可下载文件
  /// 只显示 .apk、.aab (Android App Bundle) 或 .zip 文件
  List<DownloadInfo> _filterPlatformDownloads(List<DownloadInfo> downloads) {
    return downloads.where((download) {
      final fileName = download.name.toLowerCase();
      // 检查文件扩展名
      if (fileName.endsWith('.apk')) return true;
      if (fileName.endsWith('.aab')) return true; // Android App Bundle
      if (fileName.endsWith('.zip')) {
        // zip 文件需要进一步检查名称
        // 通常包含 "universal", "android", "arm" 等关键词的是 Android 包
        final keywords = ['universal', 'android', 'arm', 'mobile', 'app'];
        return keywords.any((keyword) => fileName.contains(keyword));
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // 过滤出当前平台的文件
    final filteredDownloads = _filterPlatformDownloads(info.downloads);

    if (filteredDownloads.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: Colors.grey[600],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                info.downloads.isEmpty
                    ? '该应用暂无可下载文件'
                    : '该应用暂无适配当前平台的文件',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.download_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '下载文件',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${filteredDownloads.length} 个文件',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 11,
                          ),
                    ),
                  ),
                ],
              ),
              if (filteredDownloads.first.publishedAt != null)
                Text(
                  '更新于 ${_formatDate(filteredDownloads.first.publishedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        color: Colors.grey[600],
                      ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...filteredDownloads.map((download) => _DownloadItem(
                download: download,
                onTap: onDownloadTap,
                onLongPress: onLongPress,
              )),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return '刚刚';
        }
        return '${difference.inMinutes} 分钟前';
      }
      return '${difference.inHours} 小时前';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} 天前';
    } else {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
  }
}

class _DownloadItem extends StatelessWidget {
  final DownloadInfo download;
  final void Function(DownloadInfo)? onTap;
  final void Function(DownloadInfo)? onLongPress;

  const _DownloadItem({
    required this.download,
    this.onTap,
    this.onLongPress,
  });

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'apk':
        return Icons.android;
      case 'aab':
        return Icons.android; // Android App Bundle 使用相同的图标
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.archive;
      case 'exe':
        return Icons.desktop_windows;
      case 'dmg':
      case 'pkg':
        return Icons.desktop_mac;
      case 'sh':
        return Icons.terminal;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _getFileTypeLabel(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'apk':
        return 'Android APK';
      case 'aab':
        return 'Android Bundle'; // Android App Bundle
      case 'exe':
        return 'Windows';
      case 'dmg':
        return 'macOS';
      case 'zip':
      case 'rar':
      case '7z':
        return '压缩包';
      case 'sh':
        return '脚本';
      default:
        return '文件';
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = download.name;
    final fileIcon = _getFileIcon(fileName);
    final fileType = _getFileTypeLabel(fileName);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap != null ? () => onTap!(download) : null,
        onLongPress: onLongPress != null ? () => onLongPress!(download) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.primaryContainer,
                Theme.of(context).colorScheme.primaryContainer.withAlpha(200),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withAlpha(60),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件名和类型图标
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      fileIcon,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withAlpha(80),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                fileType,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                          fontSize: 10,
                                        ),
                              ),
                            ),
                            if (download.version != null) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.label,
                                size: 12,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(width: 2),
                              Text(
                                download.version!,
                                style:
                                    Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Colors.grey[600],
                                          fontSize: 10,
                                        ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 下载按钮
                  if (onTap != null)
                    Icon(
                      Icons.download_rounded,
                      size: 24,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
              // 详细信息行
              const SizedBox(height: 8),
              Row(
                children: [
                  if (download.size != null)
                    _buildInfoChip(
                      context,
                      Icons.sd_card,
                      download.formattedSize,
                      Colors.blue,
                    ),
                  if (download.size != null) const SizedBox(width: 8),
                  if (download.platform != null)
                    _buildInfoChip(
                      context,
                      Icons.phone_android,
                      download.platform!,
                      Colors.green,
                    ),
                  const Spacer(),
                  if (download.downloadCount != null)
                    _buildInfoChip(
                      context,
                      Icons.cloud_download,
                      _formatNumber(download.downloadCount!),
                      Colors.orange,
                    ),
                  // 二维码按钮
                  if (onLongPress != null)
                    GestureDetector(
                      onLongPress: onLongPress != null
                          ? () => onLongPress!(download)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.qr_code_2,
                          size: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int num) {
    if (num >= 1000000) return '${(num / 1000000).toStringAsFixed(1)}M';
    if (num >= 1000) return '${(num / 1000).toStringAsFixed(1)}K';
    return '$num';
  }
}

/// 开发者信息 Section
class DeveloperSection extends StatelessWidget {
final IDetailData info;

  const DeveloperSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    if (info.developer == null && info.projectUrl == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.developer != null) ...[
            Text(
              '开发者',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.developer!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (info.developer != null && info.projectUrl != null)
            const SizedBox(height: 12),
          if (info.projectUrl != null) ...[
            Text(
              '项目主页',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              info.projectUrl!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 更新日志 Section
class ChangelogSection extends StatelessWidget {
final IDetailData info;

  const ChangelogSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final changelog = info.changelog;
    if (changelog == null || changelog.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '更新日志',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            changelog,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// 权限说明 Section
class PermissionsSection extends StatelessWidget {
final IDetailData info;

  const PermissionsSection({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final permissions = info.permissions;
    if (permissions == null || permissions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '权限说明',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          ...permissions.map((permission) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.security, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        permission,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
