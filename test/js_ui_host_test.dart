import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';

/// host.ui 能力组测试脚本：JS 侧调 showVersionPicker / refreshDetail / showBuildHistory
const String _uiScript = '''
async function pickVersion() {
  const res = await host.ui.showVersionPicker({
    title: '选择版本', envs: ['sit'], versions: [], currentEnv: 'sit', currentVersion: '1.0'
  });
  return res;
}

async function pickNoOptions() {
  const res = await host.ui.showVersionPicker();
  return res;
}

async function refreshDetail() {
  const res = await host.ui.refreshDetail({appId: 'x', env: 'sit', version: '1.0'});
  return res;
}

async function pickBuildHistory() {
  const res = await host.ui.showBuildHistory({
    version: '1.0.0', env: 'uat',
    builds: [
      { num: 3, publishedAt: '2024-01-03', size: 2048, changelog: '修复', installTimes: 5, builtBy: 'ci', ipaName: 'app-1.0.0.apk' },
      { num: 2, publishedAt: '2024-01-02', size: 1024, changelog: '初版', installTimes: 2, builtBy: 'ci', ipaName: 'app-1.0.0.apk' }
    ]
  });
  return res;
}

async function pickBuildNoOptions() {
  const res = await host.ui.showBuildHistory();
  return res;
}
''';

void main() {
  test('① 注入 uiShowVersionPicker → 回调被调（参数正确）→ JS 得 {env, version}', () async {
    Map<String, dynamic>? received;
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiShowVersionPicker: (options) async {
        received = options;
        return {'env': 'sit', 'version': '1.0'};
      },
    );
    await runtime.initialize();

    final result = await runtime.call('pickVersion');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isTrue);
    final data = map['data'] as Map;
    expect(data['env'], 'sit');
    expect(data['version'], '1.0');

    // 回调收到的 options 正确（title/envs/versions/currentEnv/currentVersion）
    expect(received, isNotNull);
    expect(received!['title'], '选择版本');
    expect(received!['envs'], ['sit']);
    expect(received!['versions'], <dynamic>[]);
    expect(received!['currentEnv'], 'sit');
    expect(received!['currentVersion'], '1.0');

    await runtime.dispose();
  });

  test('② 回调返回 null（用户取消）→ JS 得 {ok:true, data:null}', () async {
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiShowVersionPicker: (options) async => null,
    );
    await runtime.initialize();

    final result = await runtime.call('pickVersion');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isTrue);
    expect(map['data'], isNull);

    await runtime.dispose();
  });

  test('③ 未注入回调 → {ok:false} 提示未注册', () async {
    final runtime = JsChannelRuntime(channelKey: 'js.test', script: _uiScript);
    await runtime.initialize();

    final result = await runtime.call('pickVersion');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isFalse);
    expect(map['error'].toString(), contains('未注册'));

    await runtime.dispose();
  });

  test('④ 注入 uiRefreshDetail → 回调被调（参数正确）→ {ok:true}', () async {
    Map<String, dynamic>? received;
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiRefreshDetail: (params) async {
        received = params;
      },
    );
    await runtime.initialize();

    final result = await runtime.call('refreshDetail');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isTrue);

    expect(received, isNotNull);
    expect(received!['appId'], 'x');
    expect(received!['env'], 'sit');
    expect(received!['version'], '1.0');

    await runtime.dispose();
  });

  test('⑤ 回调抛异常 → {ok:false} 不崩', () async {
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiShowVersionPicker: (options) async =>
          throw Exception('picker broken'),
      uiRefreshDetail: (params) async => throw Exception('refresh broken'),
    );
    await runtime.initialize();

    final pick = await runtime.call('pickVersion');
    expect((pick as Map)['ok'], isFalse);
    expect(pick['error'].toString(), contains('picker broken'));

    final refresh = await runtime.call('refreshDetail');
    expect((refresh as Map)['ok'], isFalse);
    expect(refresh['error'].toString(), contains('refresh broken'));

    // 异常后 runtime 仍可用
    final sum = await runtime.call('pickNoOptions');
    expect((sum as Map)['ok'], isFalse);

    await runtime.dispose();
  });

  test('⑥ 注入 uiShowBuildHistory → 回调收到 options（version/env/builds）→ JS 得选中 build', () async {
    Map<String, dynamic>? received;
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiShowBuildHistory: (options) async {
        received = options;
        return {'num': 3, 'ipaName': 'app-1.0.0.apk'};
      },
    );
    await runtime.initialize();

    final result = await runtime.call('pickBuildHistory');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isTrue);
    final data = map['data'] as Map;
    expect(data['num'], 3);
    expect(data['ipaName'], 'app-1.0.0.apk');

    // 回调收到的 options 正确（version/env/builds 全量透传）
    expect(received, isNotNull);
    expect(received!['version'], '1.0.0');
    expect(received!['env'], 'uat');
    final builds = received!['builds'] as List;
    expect(builds.length, 2);
    final first = builds.first as Map;
    expect(first['num'], 3);
    expect(first['ipaName'], 'app-1.0.0.apk');
    expect(first['changelog'], '修复');

    await runtime.dispose();
  });

  test('⑦ 回调返回 null（用户取消）→ JS 得 {ok:true, data:null}', () async {
    final runtime = JsChannelRuntime(
      channelKey: 'js.test',
      script: _uiScript,
      uiShowBuildHistory: (options) async => null,
    );
    await runtime.initialize();

    final result = await runtime.call('pickBuildHistory');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isTrue);
    expect(map['data'], isNull);

    await runtime.dispose();
  });

  test('⑧ 未注入回调 → {ok:false} 提示未注册', () async {
    final runtime = JsChannelRuntime(channelKey: 'js.test', script: _uiScript);
    await runtime.initialize();

    final result = await runtime.call('pickBuildHistory');
    expect(result, isA<Map>());
    final map = result as Map;
    expect(map['ok'], isFalse);
    expect(map['error'].toString(), contains('未注册'));

    // 无 options 调 showBuildHistory → 不崩，回调收到空 map
    final noOpts = await runtime.call('pickBuildNoOptions');
    expect((noOpts as Map)['ok'], isFalse);

    await runtime.dispose();
  });
}
