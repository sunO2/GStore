/// Regression for the JS-channel (`js_*`, Rust script lane) DETAIL page.
///
/// Todo 8 rerouted this channel's data reads through the unified
/// [RustChannelFacade] (`ChannelApi`) surface: `getAppDetail` + the four
/// detail-page methods are typed facade calls, and the typed results are mapped
/// back to the `Map<String, dynamic>` shape the page's `JsChannelDetailProxy`
/// consumes. The old `ScriptApi.run` JSON path is gone.
///
/// The Rust host collapses "no detail" — the pack having no `getAppDetail` case
/// (undefined), a `{ok:false, data:null, error}` envelope, and a JS throw — into
/// the typed `not_found` error (`rust/gstore_core/src/channel/script/channel.rs`
/// `MISSING_DETAIL`). [RustScriptDetailChannel.load] therefore keeps the prefill
/// already rendered on `not_found` (no hard error) instead of replacing the body
/// with the error view; only a non-`not_found` failure sets a typed
/// `errorMessage`.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_detail_channel.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_ui_handler_registry.dart';
import 'package:gstore/page/detail/state.dart';

/// In-memory [ChannelApiBackend] (the FRB facade seam).
///
/// It is seeded with the same raw JSON strings the Rust `run` would have
/// returned and projects them to the typed facade values the real host returns
/// — so the test bodies keep their JSON setup while the assertions prove the
/// channel reached the *facade* backend. Calls are recorded under the pack
/// method names (`getAppDetail` / `versionOptions` / `switchVersion` /
/// `buildHistory` / `detailMenu`) with a JSON `params` string, mirroring the old
/// `ScriptApi.run` seam so the scenario assertions stay readable.
class _FakeFacadeBackend implements ChannelApiBackend {
  _FakeFacadeBackend({this.reply = 'null', this.throwError, this.replies, this.replyFor});

  /// Raw JSON string the script reply decodes to (`'null'` = no detail).
  String reply;

  /// When non-null, the reply is thrown (a real FRB failure).
  Object? throwError;

  /// Per-method raw JSON overrides; a method absent here falls back to [reply].
  Map<String, String>? replies;

  /// When non-null, consulted AFTER [replies] and BEFORE [reply]: lets a test
  /// vary the reply by method AND request params.
  String Function(String method, String paramsJson)? replyFor;

  final List<Map<String, Object?>> runCalls = [];
  final List<Map<String, Object?>> actionCalls = [];

  String _raw(String method, String paramsJson) {
    final err = throwError;
    if (err != null) throw err;
    final byMethod = replies;
    if (byMethod != null && byMethod.containsKey(method)) {
      return byMethod[method]!;
    }
    final byFn = replyFor;
    if (byFn != null) return byFn(method, paramsJson);
    return reply;
  }

  void _record(String key, String method, Map<String, Object?> params) {
    runCalls.add({
      'key': key,
      'method': method,
      'params': jsonEncode(params),
    });
  }

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    final params = <String, Object?>{'appId': appId};
    _record(key, 'getAppDetail', params);
    final raw = _raw('getAppDetail', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const ChannelApiException(
        'not_found',
        '脚本未返回详情数据（脚本未实现或数据获取失败）',
      );
    }
    return _detailFromJson(decoded, raw);
  }

  @override
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) async {
    final params = <String, Object?>{
      'appId': appId,
      if (env != null) 'env': env,
      if (currentVersion != null) 'currentVersion': currentVersion,
    };
    _record(key, 'versionOptions', params);
    final raw = _raw('versionOptions', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return _versionOptionsFromJson(decoded, raw);
  }

  @override
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) async {
    final params = <String, Object?>{
      'appId': appId,
      'env': env,
      'version': version,
      if (buildJson != null) 'build': jsonDecode(buildJson),
    };
    _record(key, 'switchVersion', params);
    final raw = _raw('switchVersion', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return _detailFromJson(decoded, raw);
  }

  @override
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) async {
    final params = <String, Object?>{
      'appId': appId,
      'version': version,
      'env': env,
    };
    _record(key, 'buildHistory', params);
    final raw = _raw('buildHistory', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return const [];
    final rawBuilds = decoded['builds'];
    if (rawBuilds is! List) return const [];
    return [
      for (final entry in rawBuilds)
        if (entry is Map) _buildFromJson(entry),
    ];
  }

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async {
    final params = <String, Object?>{'appId': appId};
    _record(key, 'detailMenu', params);
    final raw = _raw('detailMenu', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map)
          rust.ChannelDetailAction(
            action: entry['action']?.toString() ?? '',
            jscall: entry['jscall']?.toString() ?? '',
            icon: entry['icon']?.toString(),
            clickIsDimiss: entry['clickIsDimiss'] as bool?,
          ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unexpected facade call: ${invocation.memberName}');

  @override
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) async {
    actionCalls.add({'key': key, 'appId': appId, 'jscall': jscall});
    runCalls.add({
      'key': key,
      'method': jscall,
      'params': jsonEncode(<String, Object?>{'appId': appId}),
    });
  }

  static rust.ChannelAppDetailInfo _detailFromJson(Map<dynamic, dynamic> json, String extraJson) {
    final rawSections = json['sections'];
    return rust.ChannelAppDetailInfo(
      appId: json['appId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      icon: json['icon']?.toString() ?? '',
      description: (json['description'] ?? json['des'])?.toString() ?? '',
      version: json['version']?.toString(),
      developer: (json['developer'] ?? json['user'])?.toString(),
      packageName: json['packageName']?.toString(),
      projectUrl: json['projectUrl']?.toString(),
      channel: 'js_local',
      sections:
          rawSections is List ? rawSections.map((e) => e.toString()).toList() : const [],
      downloads: const [],
      // The real host stores the whole pack reply in `AppDetail.extra`; the
      // channel decodes it as the base map.
      extraJson: extraJson,
      labels: const <rust.ChannelLabel>[],
    );
  }

  static rust.ScriptVersionOptions _versionOptionsFromJson(
      Map<dynamic, dynamic> json, String extraJson) {
    final rawVersions = json['versions'];
    final versions = <rust.ScriptVersionOption>[];
    if (rawVersions is List) {
      for (final entry in rawVersions) {
        if (entry is Map) {
          versions.add(rust.ScriptVersionOption(
            version: entry['version']?.toString() ?? '',
            envs: (entry['envs'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [],
            buildCount: (entry['buildCount'] as num?)?.toInt() ?? 0,
          ));
        }
      }
    }
    return rust.ScriptVersionOptions(
      title: json['title']?.toString(),
      envs: (json['envs'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      versions: versions,
      currentEnv: json['currentEnv']?.toString(),
      currentVersion: json['currentVersion']?.toString(),
      extraJson: extraJson,
    );
  }

  static rust.ScriptBuild _buildFromJson(Map<dynamic, dynamic> json) {
    const known = {'num', 'publishedAt', 'size', 'changelog', 'installTimes'};
    final extra = <String, Object?>{};
    json.forEach((key, value) {
      if (!known.contains(key)) extra[key.toString()] = value;
    });
    return rust.ScriptBuild(
      num: (json['num'] as num?)?.toInt() ?? 0,
      publishedAt: json['publishedAt']?.toString(),
      size: (json['size'] as num?)?.toInt(),
      changelog: json['changelog']?.toString(),
      installTimes: (json['installTimes'] as num?)?.toInt(),
      extraJson: jsonEncode(extra),
    );
  }
}

/// [ScriptDetailAppDetailSource] fake: the production backend's detail.js lane.
class _DetailLaneFacadeBackend extends _FakeFacadeBackend
    implements ScriptDetailAppDetailSource {
  _DetailLaneFacadeBackend({super.replies});

  final List<Map<String, Object?>> scriptGetAppDetailCalls = [];

  @override
  Future<rust.ChannelAppDetailInfo?> scriptGetAppDetail({
    required String key,
    required String appId,
  }) async {
    final params = <String, Object?>{'appId': appId};
    scriptGetAppDetailCalls.add({
      'key': key,
      'params': jsonEncode(params),
    });
    final raw = _raw('getAppDetail', jsonEncode(params));
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return _FakeFacadeBackend._detailFromJson(decoded, raw);
  }
}

/// Minimal [ScriptApiBackend]: only `releaseDetail` (retained for `dispose`).
class _NoopScriptBackend implements ScriptApiBackend {  @override
  Future<void> releaseDetail({required String key, required String appId}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused ScriptApi method: ${invocation.memberName}');
}

/// Flags backend that turns the Rust lane on.
class _OnFlagsBackend implements CoreFlagsBackend {
  @override
  Future<CoreFlagsSnapshot> read() async =>
      const CoreFlagsSnapshot(jsChannel: true);

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
}

/// Capturing callbacks mirroring `DetailLogic.refreshDetail`
/// (`state.detailInfo = JsChannelDetailProxy(detailData)`) so the assertions
/// prove the prefill reached the bound state, not a fake's invention.
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> refreshCalls = [];
  final List<String> errors = [];
  DetailState? state;

  /// The channel under test, so the simulated picker/sheet callbacks can drive
  /// the same top-level `dc.*` calls `DetailVersionPickerMixin` would.
  RustScriptDetailChannel? channel;

  final List<Map<String, dynamic>> versionPickerCalls = [];
  final List<Map<String, dynamic>> buildHistoryCalls = [];

  ({String env, String version})? versionSelection;
  Map<String, dynamic>? buildSelection;

  @override
  Future<void> refreshDetail({
    required Map<String, dynamic> detailData,
  }) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
    state?.detailInfo = JsChannelDetailProxy(detailData);
  }

  @override
  void showError(String message, {String? title}) => errors.add(message);

  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {
    versionPickerCalls.add(Map<String, dynamic>.from(options));
    final sel = versionSelection;
    if (sel == null) return;
    final detail = await channel?.switchVersion(
      appId: appId,
      env: sel.env,
      version: sel.version,
    );
    if (detail != null) await refreshDetail(detailData: detail);
  }

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {
    buildHistoryCalls.add({
      'builds': builds,
      'appId': appId,
      'version': version,
      'env': env,
    });
    final sel = buildSelection;
    if (sel == null) return;
    final detail = await channel?.switchVersion(
      appId: appId,
      env: env,
      version: version,
      build: sel,
    );
    if (detail != null) await refreshDetail(detailData: detail);
  }

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {}

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {}

  @override
  void showSuccess(String message, {String? title}) {}

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async =>
      null;

  @override
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  }) async {}

  @override
  void syncDownloadToFB(DownloadInfo download) {}

  @override
  Future<void> startDownload(
    DownloadInfo download, {
    int? downloadSize,
    bool fromScript = false,
  }) async {}

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) async =>
      null;

  @override
  void startApp(String packageName) {}

  @override
  void openBrowser(String url) {}

  @override
  void openProjectBrowser() {}

  @override
  Future<void> submitAppMetadata() async {}

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    CoreFlags.installBackend(_OnFlagsBackend());
    await CoreFlags.refresh();
    expect(CoreFlags.jsChannel, isTrue);
  });

  tearDown(() {
    CoreFlags.resetBackend();
    RustChannelFacade.resetBackend();
    ScriptApi.resetBackend();
    ScriptUiHandlerRegistry.instance.resetForTest();
  });

  const request = AppDetailRequest(
    appId: 'com.example.one',
    name: 'Req App',
    channel: ChannelType.custom,
    channelCode: 'js_probe',
    packageName: 'com.example.one',
    icon: 'icon://req',
    description: '请求描述',
  );

  /// Builds the channel bound to a fresh state + capturing callbacks, installing
  /// [backend] as the process-wide facade backend for the test.
  (RustScriptDetailChannel, DetailState, _CapturingCallbacks) build(
    _FakeFacadeBackend backend,
  ) {
    RustChannelFacade.installBackend(backend);
    final channel = RustScriptDetailChannel(
      appId: request.appId,
      channelKey: 'js_probe',
      request: request,
      api: ScriptApi(backend: _NoopScriptBackend()),
    );
    final cb = _CapturingCallbacks();
    final state = DetailState()..request = request;
    cb.state = state;
    channel.bind(state, cb);
    return (channel, state, cb);
  }

  group('RustScriptDetailChannel.load — null reply keeps the prefill', () {
    test('raw "null" reply: no error, prefill applied, page not blank', () async {
      final backend = _FakeFacadeBackend(reply: 'null');
      final (channel, state, cb) = build(backend);

      await channel.load();

      // The facade was reached with the documented shape (getAppDetail first,
      // then the independent detailMenu refresh).
      expect(backend.runCalls, hasLength(2));
      expect(backend.runCalls.first['method'], 'getAppDetail');
      expect(backend.runCalls.last['method'], 'detailMenu');
      expect(
        (jsonDecode(backend.runCalls.first['params']! as String)
            as Map)['appId'],
        'com.example.one',
      );

      expect(state.errorMessage, isEmpty,
          reason: 'a null reply must not hard-error the detail page');
      expect(cb.errors, isEmpty);

      expect(cb.refreshCalls, hasLength(1));
      expect(state.detailInfo, isNotNull, reason: 'page must not be blank');
      expect(state.detailInfo!.appId, 'com.example.one');
      expect(state.detailInfo!.name, 'Req App');
      expect(state.detailInfo!.packageName, 'com.example.one');

      expect(state.isLoadingDetail, isFalse);
      expect(state.downloadsLoading, isFalse);
      expect(state.readmeLoading, isFalse);
      expect(state.statisticsLoading, isFalse);
    });

    test('whitespace-padded "null" reply: still no error, prefill kept',
        () async {
      final backend = _FakeFacadeBackend(reply: '  null \n');
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isEmpty);
      expect(state.detailInfo, isNotNull);
      expect(state.detailInfo!.name, 'Req App');
      expect(cb.refreshCalls, hasLength(1));
    });
  });

  group('RustScriptDetailChannel.load — object reply applies the detail', () {
    test('object reply: detail replaced, no error', () async {
      final backend = _FakeFacadeBackend(
        reply: jsonEncode({
          'appId': 'com.example.one',
          'name': 'Full App',
          'packageName': 'com.example.one',
          'downloads': <Object?>[],
          'sections': ['downloads'],
        }),
      );
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isEmpty);
      expect(cb.refreshCalls, hasLength(2),
          reason: 'prefill then full detail');
      expect(state.detailInfo!.name, 'Full App');
      expect(state.isLoadingDetail, isFalse);
    });
  });

  group('RustScriptDetailChannel.load — detail.js lane', () {
    test('capability backend: initial load reads detail.js, intro/screenshots/tags render',
        () async {
      final backend = _DetailLaneFacadeBackend(replies: {
        'getAppDetail': jsonEncode({
          'appId': 'com.example.one',
          'name': 'Detail App',
          'description': '平安口袋银行介绍',
          'sections': ['downloads', 'screenshots'],
          'screenshots': ['https://example.com/shot.png'],
          'downloads': [
            {
              'url': 'https://example.com/a.apk',
              'name': 'a.apk',
              'version': '1.0',
              'extra': {
                'size': {'icon': 'sd_card', 'text': '10 MB'},
              },
            },
          ],
          'extra': {
            'env': 'sit',
            'builtBy': 'ci-bot',
            'num': 7,
            'installTimes': 12000,
            'versionOptions': {
              'envs': ['sit', 'prod'],
              'versions': [
                {'version': '1.0.0', 'envs': ['sit'], 'buildCount': 3},
              ],
              'currentEnv': 'sit',
              'currentVersion': '1.0.0',
            },
          },
        }),
        'detailMenu': 'null',
      });
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(backend.scriptGetAppDetailCalls, hasLength(1));
      expect(
        backend.runCalls.map((c) => c['method']),
        isNot(contains('getAppDetail')),
        reason: 'the detail.js lane must not fall back to the entry lane',
      );
      expect(cb.refreshCalls, hasLength(2));
      expect(state.errorMessage, isEmpty);

      final info = state.detailInfo!;
      expect(info.readme, '平安口袋银行介绍');
      expect(info.screenshots, isNotEmpty);
      expect(info.downloads.single.extra, isNotNull);
      expect(info.downloads.single.extra!['size']!.text, '10 MB');
      expect(info.extra['builtBy'], 'ci-bot');
      expect(info.extra['num'], 7);
      expect(info.extra['installTimes'], 12000);
      expect(info.extra['env'], 'sit');

      backend.runCalls.clear();
      final options = await channel.versionOptions('com.example.one', env: 'sit');
      expect((options!['versions'] as List).single['version'], '1.0.0');
      expect(
        backend.runCalls,
        isEmpty,
        reason: 'detail.extra.versionOptions must seed the page cache',
      );
    });

    test('backend without the capability falls back to getAppDetail', () async {
      final backend = _FakeFacadeBackend(reply: 'null');
      final (channel, state, _) = build(backend);

      await channel.load();

      expect(backend.runCalls.first['method'], 'getAppDetail');
      expect(state.detailInfo, isNotNull);
    });

    test('detail.js returns null → entry lane fallback keeps the page', () async {
      final backend = _DetailLaneFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': 'null',
      });
      final (channel, state, _) = build(backend);

      await channel.load();

      expect(backend.scriptGetAppDetailCalls, hasLength(1));
      expect(
        backend.runCalls.map((c) => c['method']),
        contains('getAppDetail'),
        reason: 'a pack without detail.js getAppDetail keeps the entry-lane data',
      );
      expect(state.errorMessage, isEmpty);
      expect(state.detailInfo, isNotNull);
    });
  });

  group('RustScriptDetailChannel.load — real exception still errors', () {
    test('api throws: errorMessage set, prefill was still applied first',
        () async {
      final backend = _FakeFacadeBackend(
        throwError: StateError('pack not found'),
      );
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isNotEmpty,
          reason: 'a real exception must still surface a typed error');
      expect(state.errorMessage, contains('详情加载失败'));
      expect(cb.refreshCalls, hasLength(1));
      expect(state.detailInfo, isNotNull);
      expect(state.isLoadingDetail, isFalse);
      expect(state.downloadsLoading, isFalse);
      expect(state.readmeLoading, isFalse);
      expect(state.statisticsLoading, isFalse);
    });
  });

  group('RustScriptDetailChannel "更多" actions — detailMenu', () {
    test('load refreshes actions; a jsswitchUA action routes through scriptDetailAction',
        () async {
      final backend = _FakeFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': jsonEncode([
          {'action': '切换版本', 'jscall': 'jsswitchVersion'},
          {'action': '历史构建', 'jscall': 'jsBuildHistory'},
          {'action': '切换UA', 'jscall': 'jsswitchUA'},
        ]),
      });
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(channel.getActions().map((a) => a.label).toList(),
          ['切换版本', '历史构建', '切换UA']);
      expect(state.errorMessage, isEmpty);
      expect(cb.errors, isEmpty);

      // `jsswitchUA` has no top-level handler → it runs the pack's jscall through
      // the facade's fresh-runtime `scriptDetailAction` (no shared entry `op`,
      // no deadlock, and no `_api.run`).
      backend.runCalls.clear();
      backend.actionCalls.clear();
      await channel.getActions().last.onTap();
      expect(backend.actionCalls, [
        {'key': 'js_probe', 'appId': 'com.example.one', 'jscall': 'jsswitchUA'},
      ]);
    });

    test('null detailMenu: empty actions, no error, page not blank', () async {
      final backend = _FakeFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': 'null',
      });
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(channel.getActions(), isEmpty);
      expect(state.errorMessage, isEmpty);
      expect(cb.errors, isEmpty);
      expect(state.detailInfo, isNotNull, reason: 'page must not be blank');
    });

    test('absent detailMenu (default null): empty actions, no error', () async {
      final backend = _FakeFacadeBackend(reply: 'null');
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(channel.getActions(), isEmpty);
      expect(state.errorMessage, isEmpty);
      expect(cb.errors, isEmpty);
    });
  });

  group('RustScriptDetailChannel versions — pack methods', () {
    test('versionOptions/switchVersion/buildHistory decode and forward params',
        () async {
      final backend = _FakeFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': 'null',
        'versionOptions': jsonEncode({
          'envs': ['sit', 'prod'],
          'versions': [
            {'version': '2.0', 'envs': ['sit'], 'buildCount': 3},
          ],
          'currentEnv': 'sit',
          'currentVersion': '2.0',
        }),
        'switchVersion': jsonEncode({
          'appId': 'com.example.one',
          'name': 'Switched',
          'version': '2.0',
        }),
        'buildHistory': jsonEncode({
          'builds': [
            {'num': 7, 'ipaName': 'a.apk'},
          ],
        }),
      });
      final (channel, _, _) = build(backend);

      await channel.load();
      backend.runCalls.clear();

      final opts = await channel.versionOptions('com.example.one', env: 'sit');
      expect(opts!['currentVersion'], '2.0');
      expect(backend.runCalls.single['method'], 'versionOptions');
      expect(
        jsonDecode(backend.runCalls.single['params']! as String),
        {'appId': 'com.example.one', 'env': 'sit'},
      );

      backend.runCalls.clear();
      final switched = await channel.switchVersion(
        appId: 'com.example.one',
        env: 'sit',
        version: '2.0',
        build: {'num': 7},
      );
      expect(switched!['name'], 'Switched');
      expect(backend.runCalls.single['method'], 'switchVersion');
      expect(
        jsonDecode(backend.runCalls.single['params']! as String),
        {
          'appId': 'com.example.one',
          'env': 'sit',
          'version': '2.0',
          'build': {'num': 7},
        },
      );

      backend.runCalls.clear();
      final history = await channel.buildHistory(
        appId: 'com.example.one',
        version: '2.0',
        env: 'sit',
      );
      expect((history!['builds'] as List).single['num'], 7);
      expect(backend.runCalls.single['method'], 'buildHistory');
      expect(
        jsonDecode(backend.runCalls.single['params']! as String),
        {'appId': 'com.example.one', 'version': '2.0', 'env': 'sit'},
      );
    });

    test('versionOptions omits env when null; non-map reply → null', () async {
      final backend = _FakeFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': 'null',
        'versionOptions': jsonEncode({'envs': ['sit']}),
      });
      final (channel, _, _) = build(backend);

      await channel.load();
      backend.runCalls.clear();

      await channel.versionOptions('com.example.one');
      expect(
        jsonDecode(backend.runCalls.single['params']! as String),
        {'appId': 'com.example.one'},
      );

      final backendNull = _FakeFacadeBackend(replies: {
        'getAppDetail': 'null',
        'detailMenu': 'null',
        'switchVersion': 'null',
      });
      final (channelNull, _, _) = build(backendNull);
      await channelNull.load();
      expect(
        await channelNull.switchVersion(
          appId: 'a',
          env: 'sit',
          version: '1',
        ),
        isNull,
      );
    });
  });

  group('RustScriptDetailChannel actions — no parked-eval deadlock', () {
    // DEADLOCK invariant: the pack's own `jsswitchVersion`/`jsBuildHistory`
    // jscalls run a whole Rust eval that holds `op` while the pack's synchronous
    // `host.ui.call('showVersionPicker'/'showBuildHistory')` parks that eval. The
    // Flutter handler then calls back into the script via
    // `versionOptions`/`switchVersion`; Todo 7's guard rejects that re-entrant
    // dispatch with `CORE_E_SCRIPT_UI_REENTRANT`. The fix routes those actions to
    // the TOP-LEVEL facade detail methods (no parked eval, no nested run).

    _FakeFacadeBackend deadlockBackend() => _FakeFacadeBackend(replies: {
          'getAppDetail': 'null',
          'detailMenu': jsonEncode([
            {'action': '切换版本', 'jscall': 'jsswitchVersion'},
            {'action': '历史构建', 'jscall': 'jsBuildHistory'},
            {'action': '切换UA', 'jscall': 'jsswitchUA'},
          ]),
          'versionOptions': jsonEncode({
            'envs': ['sit', 'prod'],
            'versions': [
              {'version': '2.0', 'envs': ['sit'], 'buildCount': 3},
            ],
            'currentEnv': 'sit',
            'currentVersion': '2.0',
          }),
          'switchVersion': jsonEncode({
            'appId': 'com.example.one',
            'name': 'Switched',
            'version': '2.0',
            'downloads': <Object?>[],
          }),
          'buildHistory': jsonEncode({
            'builds': [
              {'num': 7, 'ipaName': 'a.apk'},
              {'num': 6, 'ipaName': 'b.apk'},
            ],
          }),
        });

    test('(i) 切换版本 onTap: top-level versionOptions+switchVersion, refresh applied',
        () async {
      final backend = deadlockBackend();
      final (channel, state, cb) = build(backend);
      cb.channel = channel;
      cb.versionSelection = (env: 'sit', version: '2.0');

      await channel.load();
      backend.runCalls.clear();

      await channel
          .getActions()
          .first
          .onTap()
          .timeout(const Duration(seconds: 5));

      expect(
        backend.runCalls.map((c) => c['method']).toList(),
        ['versionOptions', 'switchVersion'],
        reason: 'the parking jsswitchVersion eval must NOT run',
      );
      expect(cb.versionPickerCalls, hasLength(1));
      expect(cb.versionPickerCalls.single['currentVersion'], '2.0');
      expect(cb.refreshCalls.last['name'], 'Switched');
      expect(state.detailInfo?.name, 'Switched');
      expect(cb.errors, isEmpty);
    });

    test('(i) 历史构建 onTap: top-level versionOptions+buildHistory, showBuildHistory fired',
        () async {
      final backend = deadlockBackend();
      final (channel, state, cb) = build(backend);
      cb.channel = channel;
      cb.buildSelection = {'num': 7, 'ipaName': 'a.apk'};

      await channel.load();
      backend.runCalls.clear();

      await channel
          .getActions()[1]
          .onTap()
          .timeout(const Duration(seconds: 5));

      expect(
        backend.runCalls.map((c) => c['method']).toList(),
        ['versionOptions', 'buildHistory', 'switchVersion'],
        reason: 'the parking jsBuildHistory eval must NOT run',
      );
      expect(cb.buildHistoryCalls, hasLength(1));
      final bh = cb.buildHistoryCalls.single;
      expect(bh['version'], '2.0');
      expect(bh['env'], 'sit');
      expect((bh['builds'] as List), hasLength(2));
      expect((bh['builds'] as List).first, {'num': 7, 'ipaName': 'a.apk'});
      expect(cb.refreshCalls.last['name'], 'Switched');
      expect(state.detailInfo?.name, 'Switched');
      expect(cb.errors, isEmpty);
    });

    test('(ii) second tap: both complete, callbacks fire twice', () async {
      final backend = deadlockBackend();
      final (channel, _, cb) = build(backend);
      cb.channel = channel;
      cb.versionSelection = (env: 'sit', version: '2.0');

      await channel.load();
      final action = channel.getActions().first;

      await action.onTap().timeout(const Duration(seconds: 5));
      await action.onTap().timeout(const Duration(seconds: 5));

      expect(cb.versionPickerCalls, hasLength(2));
      expect(
        backend.runCalls.where((c) => c['method'] == 'switchVersion').length,
        2,
      );
      expect(
        cb.refreshCalls.where((r) => r['name'] == 'Switched').length,
        2,
      );
    });

    test('(iv) parked actions never run jsswitchVersion/jsBuildHistory; UA/refresh handlers run nothing',
        () async {
      final backend = deadlockBackend();
      final (channel, _, cb) = build(backend);
      cb.channel = channel;
      cb.versionSelection = (env: 'sit', version: '2.0');
      cb.buildSelection = {'num': 7, 'ipaName': 'a.apk'};

      await channel.load();
      backend.runCalls.clear();

      await channel.getActions().first.onTap(); // 切换版本
      await channel.getActions()[1].onTap(); // 历史构建

      final methods = backend.runCalls.map((c) => c['method']).toSet();
      expect(methods, {'versionOptions', 'buildHistory', 'switchVersion'});
      expect(methods, isNot(contains('jsswitchVersion')),
          reason: 'the parking pack eval must never be run from onTap');
      expect(methods, isNot(contains('jsBuildHistory')),
          reason: 'the parking pack eval must never be run from onTap');

      // The `showUAPicker`/`refreshDetail` ui.* handlers only touch Flutter
      // state — dispatched while a pack eval may be parked, they must issue
      // ZERO facade data calls (else they would re-enter and deadlock).
      backend.runCalls.clear();
      ScriptUiHandlerRegistry.instance.resetForTest();
      ScriptUiHandlerRegistry.instance.bind(
        callbacks: cb,
        appId: () => 'com.example.one',
        channelKey: () => 'js_probe',
      );
      final handlers = ScriptUiHandlerRegistry.instance.buildHandlers();
      await handlers['showUAPicker']!({
        'options': [
          {'ua': 'Firefox'},
        ],
        'current': 'Firefox',
      });
      await handlers['refreshDetail']!({'name': 'X'});
      expect(backend.runCalls, isEmpty,
          reason: 'showUAPicker/refreshDetail handlers must not re-enter the script');
      expect(cb.refreshCalls.last['name'], 'X');
      ScriptUiHandlerRegistry.instance.resetForTest();
    });
  });

  group('RustScriptDetailChannel — 历史构建 uses the tracked current version', () {
    // ROOT CAUSE: the pack's `getVersionOptions` (scripts/channels/src/pingan/
    // detail.js :696) defaults `currentVersion` to `versions[0].version` (latest)
    // and the pack's `main('versionOptions')` (:1042) does NOT forward the pack's
    // own `_currentVersion` (set by getAppDetail :643 / switchVersion :754). So
    // reading the version from `versionOptions['currentVersion']` always yields
    // the entry/latest version — after switching versions the 历史构建 sheet
    // showed the OLD version's builds. The Rust lane bypasses the pack's
    // `jsBuildHistory` (which uses `_currentVersion`, :915) to avoid the
    // parked-eval deadlock, so it must track the current version itself.

    String entryDetailJson() => jsonEncode({
          'appId': 'com.example.one',
          'name': 'App One',
          'version': 'A', // pack getAppDetail :642 sets detail.version = group.version
          'extra': {'env': 'sit'}, // pack buildDetailFromGroup :357 extra.env = cred.env
          'downloads': <Object?>[],
        });

    String versionOptionsJson() => jsonEncode({
          'envs': ['sit', 'prod'],
          'versions': [
            {'version': 'A', 'envs': ['sit'], 'buildCount': 3},
            {'version': 'B', 'envs': ['sit'], 'buildCount': 1},
          ],
          'currentEnv': 'sit',
          'currentVersion': 'A',
        });

    String switchVersionJson(String version) => jsonEncode({
          'appId': 'com.example.one',
          'name': 'Switched $version',
          'version': version,
          'extra': {'env': 'sit'},
          'downloads': <Object?>[],
        });

    String buildHistoryJson(String version) => jsonEncode({
          'builds': [
            {'num': version == 'B' ? 20 : 10, 'ipaName': '$version.apk'},
          ],
        });

    _FakeFacadeBackend trackedBackend({
      String? getAppDetail,
    }) =>
        _FakeFacadeBackend(
          replies: {
            'getAppDetail': getAppDetail ?? entryDetailJson(),
            'detailMenu': jsonEncode([
              {'action': '切换版本', 'jscall': 'jsswitchVersion'},
              {'action': '历史构建', 'jscall': 'jsBuildHistory'},
            ]),
            'versionOptions': versionOptionsJson(),
          },
          replyFor: (method, params) {
            final p = jsonDecode(params) as Map;
            switch (method) {
              case 'switchVersion':
                return switchVersionJson(p['version']?.toString() ?? '');
              case 'buildHistory':
                return buildHistoryJson(p['version']?.toString() ?? '');
              default:
                return 'null';
            }
          },
        );

    test('(i) after switchVersion B, 历史构建 issues buildHistory with version B',
        () async {
      final backend = trackedBackend();
      final (channel, _, cb) = build(backend);
      cb.channel = channel;
      cb.versionSelection = (env: 'sit', version: 'B');

      await channel.load(); // getAppDetail → version A (tracked)
      backend.runCalls.clear();

      await channel.getActions().first.onTap();
      backend.runCalls.clear();

      await channel.getActions()[1].onTap();

      final bhCall = backend.runCalls.singleWhere(
        (c) => c['method'] == 'buildHistory',
      );
      expect(
        backend.runCalls.where((c) => c['method'] == 'versionOptions'),
        isEmpty,
        reason: 'tracked version/env must skip the redundant versionOptions call',
      );
      expect(
        (jsonDecode(bhCall['params']! as String) as Map)['version'],
        'B',
        reason: 'must use the tracked current version, not the latest/entry A',
      );
      expect(cb.buildHistoryCalls, hasLength(1));
      expect(cb.buildHistoryCalls.single['version'], 'B');
      expect(cb.buildHistoryCalls.single['env'], 'sit');
      expect(
        (cb.buildHistoryCalls.single['builds'] as List).single,
        {'num': 20, 'ipaName': 'B.apk'},
      );
    });

    test('(ii) before any switch, 历史构建 uses the entry version A', () async {
      final backend = trackedBackend();
      final (channel, _, cb) = build(backend);
      cb.channel = channel;

      await channel.load(); // tracked = A
      backend.runCalls.clear();

      await channel.getActions()[1].onTap();

      final bhCall = backend.runCalls.singleWhere(
        (c) => c['method'] == 'buildHistory',
      );
      expect(
        (jsonDecode(bhCall['params']! as String) as Map)['version'],
        'A',
      );
      expect(cb.buildHistoryCalls.single['version'], 'A');
      expect(
        (cb.buildHistoryCalls.single['builds'] as List).single,
        {'num': 10, 'ipaName': 'A.apk'},
      );
    });

    test('(iii) 切换版本 issues versionOptions carrying the tracked currentVersion',
        () async {
      final backend = trackedBackend();
      final (channel, _, cb) = build(backend);
      cb.channel = channel;

      await channel.load(); // tracked = A
      backend.runCalls.clear();

      await channel.getActions().first.onTap();

      final voCall = backend.runCalls.singleWhere(
        (c) => c['method'] == 'versionOptions',
      );
      final voParams =
          jsonDecode(voCall['params']! as String) as Map<String, dynamic>;
      expect(
        voParams['currentVersion'],
        'A',
        reason: 'the picker must be told the tracked current version (A)',
      );
      expect(
        voParams['env'],
        'sit',
        reason: 'the picker must query the tracked env, not the pack default',
      );
      expect(cb.versionPickerCalls, hasLength(1));
    });

    test('(iv) null tracked version → 历史构建 falls back to versionOptions.currentVersion',
        () async {
      final backend = trackedBackend(
        getAppDetail: jsonEncode({
          'appId': 'com.example.one',
          'name': 'App One',
          'extra': {'env': 'sit'},
        }),
      );
      final (channel, _, cb) = build(backend);
      cb.channel = channel;

      await channel.load();
      backend.runCalls.clear();

      await channel.getActions()[1].onTap();

      final bhCall = backend.runCalls.singleWhere(
        (c) => c['method'] == 'buildHistory',
      );
      expect(
        (jsonDecode(bhCall['params']! as String) as Map)['version'],
        'A',
        reason: 'null tracked version must fall back to versionOptions.currentVersion',
      );
      expect(cb.buildHistoryCalls.single['version'], 'A');
    });
  });
}
