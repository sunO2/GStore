import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 渠道库“源标识”落库/读回契约（P1-2）
///
/// 源标识是记录**自己的**属性（多源下定详情/资源地址都要用它），
/// 所以它有自己的列 `sourceId`；v5 之前的历史数据存在 `extra['sourceId']`，
/// 读侧必须两者都认，否则老记录会被当成“无源标识”而退回当前源（拼错镜像）。
void main() {
  ChannelAddedApp build({String? sourceId, String? extra}) => ChannelAddedApp.withChannel(
        appId: 'com.x8bit.bitwarden',
        name: 'Bitwarden',
        user: 'Bitwarden',
        repositories: 'com.x8bit.bitwarden',
        icon: 'com.x8bit.bitwarden/en-US/icon_a=.png',
        description: '密码管理器',
        addTime: 1700000000000,
        channel: ChannelType.fdroid,
        sourceId: sourceId,
        extra: extra,
      );

  test('列优先：sourceId 列有值时以它为准', () {
    final rec = build(sourceId: 'fp:ABCD', extra: '{"sourceId":"url:https://old"}');
    expect(rec.sourceIdentity, 'fp:ABCD');
  });

  test('历史数据兼容：列缺失时回落到 extra["sourceId"]（v5 之前的老记录）', () {
    final rec = build(extra: '{"sourceId":"url:https://mobileapp.bitwarden.com/fdroid/repo"}');
    expect(rec.sourceIdentity, 'url:https://mobileapp.bitwarden.com/fdroid/repo');
  });

  test('确实没有源标识 → null（读侧据此走跨源兜底，而不是猜一个源）', () {
    expect(build().sourceIdentity, isNull);
    expect(build(extra: '{"packageName":"x"}').sourceIdentity, isNull);
    expect(build(extra: '不是 json').sourceIdentity, isNull);
  });
}
