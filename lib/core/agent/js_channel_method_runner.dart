/// Runs one script-channel (`js_*`) method through the unified channel entry.
///
/// The JS **data** path is `ChannelApi` / [RustChannelFacade]; a raw
/// `ScriptApi.run` is no longer on it. The agent's `runJsChannel` tool therefore
/// dispatches here and projects the typed FRB DTOs back to JSON-shaped maps.
/// A method the unified entry does not expose returns `null`, so the caller can
/// fall back to a hint and point the model at the preset tools.
library;

import 'dart:convert';

import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_detail_mapping.dart';

/// Dispatches [method] for [channel] through [RustChannelFacade].
///
/// Returns a JSON-encodable value, or `null` when the unified entry does not
/// expose [method]. [args] is the tool's raw params map; only the keys the
/// mapped methods read are consulted.
Future<Object?> runScriptChannelMethod({
  required String channel,
  required String method,
  required Map<String, dynamic> args,
}) async {
  final facade = RustChannelFacade.instance;
  final forceRefresh = args['forceRefresh'] == true;
  switch (method) {
    case 'getAllApps':
      final apps =
          await facade.getAllApps(key: channel, forceRefresh: forceRefresh);
      return apps.map(_appToMap).toList();
    case 'searchApps':
      final apps = await facade.search(
        key: channel,
        keyword: '${args['keyword'] ?? ''}',
        forceRefresh: forceRefresh,
      );
      return apps.map(_appToMap).toList();
    case 'getAppInfo':
      final app = await facade.getAppInfo(
        key: channel,
        appId: '${args['appId'] ?? ''}',
        forceRefresh: forceRefresh,
      );
      return _appToMap(app);
    case 'getAppDetail':
      final detail = await facade.getAppDetail(
        key: channel,
        appId: '${args['appId'] ?? ''}',
        forceRefresh: forceRefresh,
      );
      return detailToMap(detail);
    case 'getConfig':
      final config =
          await facade.getConfig(key: channel, forceRefresh: forceRefresh);
      if (config == null) return null;
      return <String, Object?>{'version': config.version, 'proxy': config.proxy};
    case 'checkUpdate':
    case 'checkAppUpdate':
      return facade.checkUpdate(key: channel);
    case 'versionOptions':
      final options = await facade.scriptVersionOptions(
        key: channel,
        appId: '${args['appId'] ?? ''}',
        env: args['env']?.toString(),
        currentVersion: args['currentVersion']?.toString(),
      );
      return options == null ? null : versionOptionsToMap(options);
    case 'switchVersion':
      final detail = await facade.scriptSwitchVersion(
        key: channel,
        appId: '${args['appId'] ?? ''}',
        env: '${args['env'] ?? ''}',
        version: '${args['version'] ?? ''}',
        buildJson: args['build'] == null ? null : jsonEncode(args['build']),
      );
      return detail == null ? null : detailToMap(detail);
    case 'buildHistory':
      final builds = await facade.scriptBuildHistory(
        key: channel,
        appId: '${args['appId'] ?? ''}',
        env: '${args['env'] ?? ''}',
        version: '${args['version'] ?? ''}',
      );
      return builds.map(buildToMap).toList();
    case 'detailMenu':
      final actions = await facade.scriptDetailMenu(
        key: channel,
        appId: '${args['appId'] ?? ''}',
      );
      return actions.map(_actionToMap).toList();
    default:
      return null;
  }
}

Map<String, Object?> _appToMap(rust.ChannelAppInfo app) => <String, Object?>{
      'appId': app.appId,
      'packageName': app.packageName,
      'name': app.name,
      'user': app.user,
      'repositories': app.repositories,
      'icon': app.icon,
      'des': app.des,
      'readme': app.readme,
      'category': app.category,
      'extra': _decodeExtra(app.extraJson),
    };

Map<String, Object?> _actionToMap(rust.ChannelDetailAction action) =>
    <String, Object?>{
      'action': action.action,
      'jscall': action.jscall,
      'icon': action.icon,
      'clickIsDimiss': action.clickIsDimiss,
    };

Object? _decodeExtra(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return jsonDecode(raw);
}
