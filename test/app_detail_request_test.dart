import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';

/// AppDetailRequest 详情请求构造测试
///
/// 验证 fromAggregatedAppInfo 的包名优先级（B1 后 packageName 为一级字段）：
/// - 优先 appInfo.packageName 字段
/// - 缺失时回退 repositories（占位）
void main() {
  AddedAppInfo addedApp(String appId) => AddedAppInfo(
        channelId: 'github',
        appId: appId,
      );

  group('fromAggregatedAppInfo', () {
    test('有真实包名（packageName 字段）：优先使用', () {
      final appInfo = AppSummary(
        appId: 'termux/termux-app',
        packageName: 'com.termux',
        name: 'Termux',
        user: 'termux',
        repositories: 'termux/termux-app',
        icon: 'https://icon.png',
        des: 'desc',
      );
      final aggregated = AggregatedAppInfo(
        addedAppInfo: addedApp('termux/termux-app'),
        appInfo: appInfo,
        channel: ChannelType.github,
        channelCode: 'github',
      );

      final request = AppDetailRequest.fromAggregatedAppInfo(aggregated);
      expect(request.packageName, 'com.termux');
      // appId 原样传递（渠道查询键），由渠道内部处理
      expect(request.appId, 'termux/termux-app');
      expect(request.name, 'Termux');
      expect(request.channel, ChannelType.github);
    });

    test('无真实包名：回退 repositories（占位）', () {
      final appInfo = AppSummary(
        appId: 'termux/termux-app',
        packageName: null,
        name: 'termux-app',
        user: 'termux',
        repositories: 'termux-app',
        icon: '',
        des: 'desc',
      );
      final aggregated = AggregatedAppInfo(
        addedAppInfo: addedApp('termux/termux-app'),
        appInfo: appInfo,
        channel: ChannelType.github,
        channelCode: 'github',
      );

      final request = AppDetailRequest.fromAggregatedAppInfo(aggregated);
      expect(request.packageName, 'termux-app',
          reason: '未收录时回退 repositories 占位');
      expect(request.appId, 'termux/termux-app');
    });

    test('占位兜底（聚合缓存回退场景）：repositories 为空串', () {
      final appInfo = AppSummary(
        appId: 'unknown/app-x',
        packageName: null,
        name: 'unknown/app-x',
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );
      final aggregated = AggregatedAppInfo(
        addedAppInfo: addedApp('unknown/app-x'),
        appInfo: appInfo,
        channel: ChannelType.github,
        channelCode: 'github',
        isFromCache: true,
      );

      final request = AppDetailRequest.fromAggregatedAppInfo(aggregated);
      // repositories 为空 → packageName 为占位空串（详情页会用 detail 的包名）
      expect(request.packageName, '');
    });
  });
}
