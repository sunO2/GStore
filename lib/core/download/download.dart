// Download 模块入口
// 导出所有下载相关的公共接口

// 模型
export 'model/DownloadContext.dart';

// 策略接口和基类
export 'strategy/IDownloadStrategy.dart';
export 'strategy/BaseDownloadStrategy.dart';

// 策略管理器
export 'DownloadStrategyManager.dart';

// 异常定义
export 'exception/DownloadException.dart';

// 多段下载核心
export 'segment/segment_planner.dart';
export 'segment/segment_downloader.dart';
export 'segment/segment_merger.dart';
