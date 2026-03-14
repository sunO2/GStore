// Channel 核心接口
export 'IChannel.dart';

// Channel 管理器
export 'ChannelManager.dart';

// 数据模型
export 'model/ChannelType.dart';
export 'model/ChannelInfo.dart';
export 'model/ChannelResult.dart';

// 具体实现
export 'impl/LocalDbChannel.dart';
export 'impl/GitHubChannel.dart';
export 'impl/HttpChannel.dart';
export 'impl/VivoChannel.dart';
