import 'package:flutter/foundation.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// LocalDbChannel 详情数据代理
/// 代理本地数据库 + GitHub API 的数据
class LocalDbChannelDetailProxy extends ChannelDetailProxy {
  LocalDbChannelDetailProxy(super.data);


  ChannelType get channelType => ChannelType.localDb;


  String get appId => data['appId'] ?? '';


  String get name => data['name'] ?? '';


  String get appName => name;


  String get icon => data['icon'] ?? '';


  String get description => data['description'] ?? '';


  String? get version => data['version']?.toString();


  String? get developer => data['developer']?.toString();


  String get packageName => data['packageName']?.toString() ?? '';


  String? get projectUrl => data['projectUrl']?.toString();


  String? get readme {
    final readmeValue = extra['readme']?.toString();
    debugPrint('LocalDbChannelDetailProxy: readme getter 调用');
    debugPrint('LocalDbChannelDetailProxy: extra keys = ${extra.keys.toList()}');
    debugPrint('LocalDbChannelDetailProxy: readme value = ${readmeValue != null ? "${readmeValue.substring(0, readmeValue.length > 50 ? 50 : readmeValue.length)}..." : "null"}');
    debugPrint('LocalDbChannelDetailProxy: readme length = ${readmeValue?.length ?? 0}');
    return readmeValue;
  }


  List<DownloadInfo> get downloads {
    final downloadsList = data['downloads'];
    debugPrint('LocalDbChannelDetailProxy: downloads 类型 = ${downloadsList.runtimeType}');
    debugPrint('LocalDbChannelDetailProxy: downloads 值 = $downloadsList');

    if (downloadsList is List) {
      debugPrint('LocalDbChannelDetailProxy: downloads 列表长度 = ${downloadsList.length}');
      // 安全地转换每个元素
      final result = <DownloadInfo>[];
      for (final item in downloadsList) {
        debugPrint('LocalDbChannelDetailProxy: 处理项类型 = ${item.runtimeType}, 值 = $item');
        if (item is DownloadInfo) {
          debugPrint('LocalDbChannelDetailProxy: ✓ 添加 DownloadInfo - ${item.name}');
          result.add(item);
        } else if (item is Map) {
          // 尝试从 Map 构造 DownloadInfo
          try {
            final info = DownloadInfo(
              url: item['url']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              size: item['size'] as int?,
              downloadCount: item['downloadCount'] as int?,
              version: item['version']?.toString(),
              publishedAt: item['publishedAt'] is DateTime
                  ? item['publishedAt'] as DateTime
                  : (item['publishedAt'] is String
                      ? DateTime.tryParse(item['publishedAt'])
                      : null),
              platform: item['platform']?.toString(),
            );
            debugPrint('LocalDbChannelDetailProxy: ✓ 从 Map 构造 DownloadInfo - ${info.name}');
            result.add(info);
          } catch (e) {
            debugPrint('LocalDbChannelDetailProxy: ✗ 转换失败 - $e');
            // 忽略无法转换的项
          }
        }
      }
      debugPrint('LocalDbChannelDetailProxy: 最终返回 ${result.length} 个下载项');
      return result;
    }
    debugPrint('LocalDbChannelDetailProxy: downloads 不是 List，返回空列表');
    return const [];
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
    return const [DetailSection.downloads];
  }


  List<StatTag> buildStatTags() {
    final tags = <StatTag>[];

    // 从 extra 中的 apiData 获取 GitHub 统计数据
    final apiData = extra['apiData'] as Map?;
    if (apiData != null) {
      final stars = apiData['stargazers_count'] as int?;
      final watchers = apiData['watchers_count'] as int?;
      final forks = apiData['forks_count'] as int?;

      if (stars != null && stars > 0) {
        tags.add(StatTag.stars(stars));
      }
      if (watchers != null && watchers > 0) {
        tags.add(StatTag.watchers(watchers));
      }
      if (forks != null && forks > 0) {
        tags.add(StatTag.forks(forks));
      }
    }

    return tags;
  }
}
