import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart';

void main() {
  group('AppSummary.fromDbAppInfo', () {
    test('extra 中 packageName 非空时提升为一级字段', () {
      final app = AppInfo.withExtra(
        'com.foo',
        'Foo',
        'foo',
        'com.foo',
        'https://icon',
        'des',
        ['工具'],
        jsonEncode({'packageName': 'com.foo'}),
      );
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.packageName, 'com.foo');
    });

    test('extra 缺失 packageName 时 packageName 为 null（不用 repositories 兜底）', () {
      final app = AppInfo.withExtra(
        'com.foo',
        'Foo',
        'foo',
        'com.foo',
        'https://icon',
        'des',
        ['工具'],
        jsonEncode({'other': 'value'}),
      );
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.packageName, isNull);
      expect(summary.repositories, 'com.foo');
    });

    test('extra 为空时 packageName 为 null', () {
      final app = AppInfo('com.foo', 'Foo', 'foo', 'com.foo', 'https://icon', 'des', ['工具']);
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.packageName, isNull);
    });

    test('extra 为非法 JSON 时不抛异常且 packageName 为 null', () {
      final app = AppInfo.withExtra(
        'com.foo',
        'Foo',
        'foo',
        'com.foo',
        'https://icon',
        'des',
        ['工具'],
        'not-a-json{{',
      );
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.packageName, isNull);
    });

    test('extra 中 packageName 为空串时 packageName 为 null', () {
      final app = AppInfo.withExtra(
        'com.foo',
        'Foo',
        'foo',
        'com.foo',
        'https://icon',
        'des',
        ['工具'],
        jsonEncode({'packageName': ''}),
      );
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.packageName, isNull);
    });

    test('其余字段与 db.AppInfo 同构映射', () {
      final app = AppInfo.withReadme(
        'com.foo',
        'Foo',
        'foo',
        'com.foo',
        'https://icon',
        'des',
        '# readme',
        ['工具', '系统'],
      );
      final summary = AppSummary.fromDbAppInfo(app);
      expect(summary.appId, 'com.foo');
      expect(summary.name, 'Foo');
      expect(summary.user, 'foo');
      expect(summary.repositories, 'com.foo');
      expect(summary.icon, 'https://icon');
      expect(summary.des, 'des');
      expect(summary.readme, '# readme');
      expect(summary.category, ['工具', '系统']);
      expect(summary.extra, isNull);
    });
  });

  group('AppSummary.fromChannelAddedApp', () {
    test('extra 中 packageName 提升、category 逗号拆分、apprepo 不映射', () {
      final c = ChannelAddedApp(
        appId: 'owner/repo',
        name: 'Repo',
        user: 'owner',
        repositories: 'com.foo',
        apprepo: 'owner/repo',
        icon: 'https://icon',
        description: 'des',
        category: '工具,系统',
        addTime: 123,
        channelCode: 'github',
        extra: jsonEncode({'packageName': 'com.foo'}),
      );
      final summary = AppSummary.fromChannelAddedApp(c);
      expect(summary.appId, 'owner/repo');
      expect(summary.packageName, 'com.foo');
      expect(summary.name, 'Repo');
      expect(summary.user, 'owner');
      expect(summary.repositories, 'com.foo');
      expect(summary.icon, 'https://icon');
      expect(summary.des, 'des');
      expect(summary.category, ['工具', '系统']);
      // extra 保留（与现状 GitHubChannel._buildStoredAppInfo 一致：packageName 已知时 extra 随记录保留）
      expect(summary.extra, {'packageName': 'com.foo'});
    });

    test('extra 无 packageName 时 packageName 为 null', () {
      final c = ChannelAddedApp(
        appId: 'owner/repo',
        name: 'Repo',
        user: 'owner',
        repositories: 'com.foo',
        icon: 'https://icon',
        description: 'des',
        addTime: 123,
        channelCode: 'github',
      );
      final summary = AppSummary.fromChannelAddedApp(c);
      expect(summary.packageName, isNull);
    });
  });

  group('AppSummary.getExtra', () {
    test('typed 读取命中返回对应类型值', () {
      final summary = AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
        extra: {'version': '1.2.3', 'size': 42, 'enabled': true},
      );
      expect(summary.getExtra<String>('version'), '1.2.3');
      expect(summary.getExtra<int>('size'), 42);
      expect(summary.getExtra<bool>('enabled'), isTrue);
    });

    test('类型不匹配返回 null 不抛', () {
      final summary = AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
        extra: {'packageName': 123},
      );
      expect(summary.getExtra<String>('packageName'), isNull);
    });

    test('缺失 key 返回 null 不抛', () {
      final summary = AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
        extra: {'other': 'value'},
      );
      expect(summary.getExtra<String>('missing'), isNull);
    });

    test('extra 为 null 时返回 null 不抛', () {
      final summary = AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
      );
      expect(summary.getExtra<String>('version'), isNull);
    });
  });

  group('AppSummary.copyWith', () {
    AppSummary build() => const AppSummary(
          appId: 'a',
          packageName: 'com.a',
          name: 'A',
          user: 'u',
          repositories: 'r',
          icon: 'i',
          des: 'd',
          readme: 'rm',
          category: ['工具'],
          extra: {'k': 'v'},
        );

    test('修改字段更新，其余字段保持', () {
      final summary = build().copyWith(name: 'B');
      expect(summary.name, 'B');
      expect(summary.appId, 'a');
      expect(summary.packageName, 'com.a');
      expect(summary.user, 'u');
      expect(summary.repositories, 'r');
      expect(summary.icon, 'i');
      expect(summary.des, 'd');
      expect(summary.readme, 'rm');
      expect(summary.category, ['工具']);
      expect(summary.extra, {'k': 'v'});
    });

    test('packageName 可单独更新', () {
      final summary = build().copyWith(packageName: 'com.b');
      expect(summary.packageName, 'com.b');
      expect(summary.name, 'A');
    });

    test('空参 copyWith 保持原值', () {
      final summary = build();
      final copied = summary.copyWith();
      expect(copied.appId, summary.appId);
      expect(copied.packageName, summary.packageName);
      expect(copied.name, summary.name);
      expect(copied.user, summary.user);
      expect(copied.repositories, summary.repositories);
      expect(copied.icon, summary.icon);
      expect(copied.des, summary.des);
      expect(copied.readme, summary.readme);
      expect(copied.category, summary.category);
      expect(copied.extra, summary.extra);
    });

    test('copyWith 不修改原对象（不可变）', () {
      final summary = build();
      summary.copyWith(name: 'B');
      expect(summary.name, 'A');
    });
  });

  group('AppSummary 不可变性', () {
    test('字段赋值抛 NoSuchMethodError（字段为 final）', () {
      final summary = const AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
      );
      expect(() => (summary as dynamic).name = 'x', throwsNoSuchMethodError);
      expect(() => (summary as dynamic).appId = 'x', throwsNoSuchMethodError);
      expect(() => (summary as dynamic).packageName = 'x', throwsNoSuchMethodError);
    });

    test('const 构造可用', () {
      const summary = AppSummary(
        appId: 'a',
        name: 'n',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        des: 'd',
      );
      expect(summary.appId, 'a');
    });
  });
}
