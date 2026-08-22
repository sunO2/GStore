import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppIdentity.dart';
import 'package:gstore/core/model/AppSummary.dart';

void main() {
  group('AppIdentity.canonicalKey', () {
    test('格式为 channel.code:channelAppId（与 discovery 多选键同构）', () {
      const identity = AppIdentity(
        channel: ChannelType.github,
        channelAppId: 'owner/repo',
        packageName: 'com.example.app',
      );
      expect(identity.canonicalKey, 'github:owner/repo');
    });
  });

  group('AppIdentity 相等性', () {
    const base = AppIdentity(
      channel: ChannelType.github,
      channelAppId: 'owner/repo',
      packageName: 'com.example.app',
    );

    test('相同字段 == true 且 hashCode 相等', () {
      const same = AppIdentity(
        channel: ChannelType.github,
        channelAppId: 'owner/repo',
        packageName: 'com.example.app',
      );
      expect(base == same, isTrue);
      expect(base.hashCode, same.hashCode);
    });

    test('packageName 不同 == false', () {
      const other = AppIdentity(
        channel: ChannelType.github,
        channelAppId: 'owner/repo',
        packageName: 'com.example.other',
      );
      expect(base == other, isFalse);
    });

    test('channelAppId 不同 == false', () {
      const other = AppIdentity(
        channel: ChannelType.github,
        channelAppId: 'other/repo',
        packageName: 'com.example.app',
      );
      expect(base == other, isFalse);
    });

    test('channel 不同 == false', () {
      const other = AppIdentity(
        channel: ChannelType.fdroid,
        channelAppId: 'owner/repo',
        packageName: 'com.example.app',
      );
      expect(base == other, isFalse);
    });
  });

  group('AppIdentity.fromSummary', () {
    test('channelAppId 来自 addedAppInfo.appId，packageName 来自 appInfo.packageName', () {
      final added = AddedAppInfo(channelId: 'github', appId: 'owner/repo');
      final appInfo = AppSummary(
        appId: 'owner/repo',
        packageName: 'com.example.app',
        name: 'Example',
        user: 'owner',
        repositories: 'owner/repo',
        icon: '',
        des: '',
      );
      final agg = AggregatedAppInfo(
        addedAppInfo: added,
        appInfo: appInfo,
        channel: ChannelType.github,
        channelCode: 'github',
      );

      final identity = AppIdentity.fromSummary(agg);
      expect(identity.channel, ChannelType.github);
      expect(identity.channelAppId, 'owner/repo');
      expect(identity.packageName, 'com.example.app');
      expect(identity.canonicalKey, 'github:owner/repo');
    });

    test('appInfo 为占位（packageName null）时 identity.packageName 为 null，不抛异常', () {
      final added = AddedAppInfo(channelId: 'github', appId: 'some.id');
      final placeholder = AppSummary(
        appId: 'some.id',
        packageName: null,
        name: 'some.id',
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );
      final agg = AggregatedAppInfo(
        addedAppInfo: added,
        appInfo: placeholder,
        channel: ChannelType.github,
        channelCode: 'github',
      );

      final identity = AppIdentity.fromSummary(agg);
      expect(identity.packageName, isNull);
      expect(identity.canonicalKey, 'github:some.id');
    });
  });
}
