/// 详情页 extra 键常量定义
///
/// `ChannelDetailProxy.extra => _data`（extra 就是整个原始数据 map，无嵌套子 map），
/// 详情级区块数据直接写 `_data` 顶层；下载项级标签通过 `DownloadInfo.extra` 承载。
library;

/// 详情级（区块）extra 键常量
///
/// 对应 `IDetailInfo.extra` 或 `AppDetailInfo.extra` 中原数据 map 的顶层键。
/// 使用时直接通过 `extra[key]` 访问，例如 `extra[DetailExtra.sections]`。
abstract final class DetailExtra {
  DetailExtra._();

  /// 可展示的区块列表
  /// 值类型：`List<DetailSection>` 或 `List<String>`
  static const String sections = 'sections';

  /// 下载信息列表
  /// 值类型：`List<Map<String, dynamic>>` 或 `List<DownloadInfo>`
  static const String downloads = 'downloads';

  /// README / 详情文本
  /// 值类型：`String?`
  static const String readme = 'readme';

  /// 应用截图列表
  /// 值类型：`List<Map<String, dynamic>>` 或 `List<String>`
  static const String screenshots = 'screenshots';

  /// 更新日志
  /// 值类型：`String?`
  static const String changelog = 'changelog';

  /// 权限说明列表
  /// 值类型：`List<String>`
  static const String permissions = 'permissions';

  /// 统计数据（GitHub: stars/forks, 商店: 下载量/评分等）
  /// 值类型：`StatisticsInfo` 或 `Map<String, dynamic>`
  static const String statistics = 'statistics';

  /// 应用信息行（自定义键值对展示行）
  /// 值类型：`List<Map<String, String>>`，每项含 label/value
  static const String appInfoRows = 'appInfoRows';

  /// 标签列表（自由标签，如 "开源"、"免费"）
  /// 值类型：`List<String>`
  static const String tags = 'tags';

  /// GitHub API 原始数据（如 stargazers_count / forks_count 等）
  /// 值类型：`Map<String, dynamic>`
  static const String apiData = 'apiData';

  /// 元数据（渠道自定义的附加元信息）
  /// 值类型：`Map<String, dynamic>`
  static const String metadata = 'metadata';

  /// 代理/镜像配置（如 GitHub 代理前缀）
  /// 值类型：`String?` 或 `Map<String, String>`
  static const String proxy = 'proxy';

  /// 仓库名称（GitHub 渠道：owner/repo）
  /// 值类型：`String?`
  static const String repositoryName = 'repositoryName';

  /// 开发者/作者名
  /// 值类型：`String?`
  static const String developer = 'developer';
}

/// 下载项级 extra 键常量（纯展示标签）
///
/// 对应 `DownloadInfo.extra` 中 `Map<String, DownloadTag>` 的键。
/// 每个标签以 `DownloadTag{icon, text}` 形式展示。
/// 使用时通过 `downloadInfo.extra?[key]` 访问。
abstract final class DownloadItemExtra {
  DownloadItemExtra._();

  /// 文件大小（格式化字符串，如 "12.5 MB"）
  /// 建议 icon: `Icons.storage` 或 `Icons.sd_storage`
  static const String size = 'size';

  /// 平台标识（如 "Android"、"arm64-v8a"）
  /// 建议 icon: `Icons.phone_android`
  static const String platform = 'platform';

  /// 版本号
  /// 建议 icon: `Icons.tag`
  static const String version = 'version';

  /// 下载次数
  /// 建议 icon: `Icons.download`
  static const String downloadCount = 'downloadCount';

  /// 构建编号
  /// 建议 icon: `Icons.build`
  static const String build = 'build';

  /// 环境标识（如 "prd"、"sit"）
  /// 建议 icon: `Icons.cloud`
  static const String env = 'env';

  /// 安装次数
  /// 建议 icon: `Icons.install_mobile`
  static const String installTimes = 'installTimes';

  /// 更新时间（格式化字符串，如 "2024-01-01"）
  /// 建议 icon: `Icons.update`
  static const String updateTime = 'updateTime';

  /// 下载次数（与 downloadCount 不同维度的统计）
  /// 建议 icon: `Icons.downloading`
  static const String downloadTimes = 'downloadTimes';
}