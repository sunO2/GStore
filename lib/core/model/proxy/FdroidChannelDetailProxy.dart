import 'package:flutter/foundation.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/model/detail_extra_keys.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// F-Droid 渠道详情数据代理
/// 代理 F-Droid API 返回的数据
class FdroidChannelDetailProxy extends ChannelDetailProxy {
  FdroidChannelDetailProxy(super.data);

  // 缓存 downloads 列表，避免重复解析
  List<DownloadInfo>? _cachedDownloads;

  


  ChannelType get channelType => ChannelType.fdroid;


  String get appId => data['appId'] ?? '';


  String get name => data['name'] ?? '';


  String get appName => name;


  String get icon => data['icon'] ?? '';


  String get description => data['description'] ?? '';


  String? get version => data['version']?.toString();


  String? get developer => data['developer']?.toString();


  String get packageName => data['packageName']?.toString() ?? '';


  String? get projectUrl => data['projectUrl']?.toString();


  List<DownloadInfo> get downloads {
    // 返回缓存的结果
    if (_cachedDownloads != null) {
      return _cachedDownloads!;
    }

    final downloadsList = data['downloads'];

    if (downloadsList is List) {
      final result = <DownloadInfo>[];
      for (final item in downloadsList) {
        if (item is DownloadInfo) {
          result.add(item);
        } else if (item is Map) {
          try {
            final size = item['size'] as int?;
            final platform = item['platform']?.toString();
            final version = item['version']?.toString();
            final info = DownloadInfo(
              url: item['url']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              size: size,
              downloadCount: item['downloadCount'] as int?,
              version: version,
              // 功能数据（hash/hashType/versionCode 等）仍从 item 顶层键读取
              // （extra == _data，非嵌套）
              versionCode: item['versionCode'] as int?,
              publishedAt: item['publishedAt'] is DateTime
                  ? item['publishedAt'] as DateTime
                  : (item['publishedAt'] is String
                      ? DateTime.tryParse(item['publishedAt'])
                      : null),
              platform: platform,
              hash: item['hash']?.toString(),
              hashType: item['hashType']?.toString(),
              // extra 仅承载展示标签（与 FdroidChannel 构造行为一致）
              extra: {
                if (size != null)
                  DownloadItemExtra.size:
                      DownloadTag(text: formatFileSize(size), iconName: 'sd_card'),
                if (platform != null && platform.isNotEmpty)
                  DownloadItemExtra.platform:
                      DownloadTag(text: platform, iconName: 'phone_android'),
                if (version != null && version.isNotEmpty)
                  DownloadItemExtra.version:
                      DownloadTag(text: version, iconName: 'label'),
              },
            );
            result.add(info);
          } catch (e) {
            appLog.error('FdroidChannelDetailProxy: 转换 DownloadInfo 失败 - $e');
          }
        }
      }
      _cachedDownloads = result;
      return result;
    }
    _cachedDownloads = const [];
    return _cachedDownloads!;
  }


  List<DetailSection> get sections {
    final sectionsList = data['sections'];
    if (sectionsList is List) {
      return sectionsList.map((e) {
        if (e is DetailSection) return e;
        if (e is String) {
          return DetailSection.values.firstWhere(
            (v) => v.name == e,
            orElse: () => DetailSection.downloads,
          );
        }
        return DetailSection.downloads;
      }).toList();
    }

    // 默认显示的区块
    final sections = <DetailSection>[];

    // 版本信息 - 只在有下载时显示
    if (downloads.isNotEmpty) {
      sections.add(DetailSection.version);
    }

    // 下载列表
    sections.add(DetailSection.downloads);

    // README（如果有描述；截图已统一内嵌在详情区内，不再单独成区块）
    if (description.isNotEmpty) {
      sections.add(DetailSection.readme);
    }

    return sections;
  }


  List<StatTag> buildStatTags() {
    final tags = <StatTag>[];

    // F-Droid 没有类似的统计数据，但可以显示许可证信息
    final license = data['license'] as String?;
    if (license != null && license.isNotEmpty) {
      // 可以创建一个许可证标签（如果 StatTag 支持）
      debugPrint('FdroidChannelDetailProxy: License = $license');
    }

    return tags;
  }


  List<ScreenshotInfo>? get screenshots {
    final screenshotsData = data['screenshots'];
    if (screenshotsData is List) {
      return screenshotsData.map((e) {
        if (e is ScreenshotInfo) return e;
        if (e is String) return ScreenshotInfo(url: e);
        if (e is Map) {
          return ScreenshotInfo(
            url: e['url']?.toString() ?? '',
            description: e['description']?.toString(),
          );
        }
        return ScreenshotInfo(url: e.toString());
      }).toList();
    }
    return null;
  }


  String? get readme {
    // F-Droid 使用 description 作为 readme
    return description.isNotEmpty ? description : null;
  }


  String? get changelog {
    // F-Droid API 不直接提供 changelog
    return data['changelog']?.toString();
  }


  List<String>? get permissions {
    // F-Droid 可能从 metadata 中获取权限
    final metadata = data['metadata'] as Map?;
    if (metadata != null) {
      final permissions = metadata['permissions'];
      if (permissions is List) {
        return permissions.map((e) => e.toString()).toList();
      }
    }
    return null;
  }
}
