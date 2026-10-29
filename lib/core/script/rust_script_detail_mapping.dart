/// Typed FRB value → page `Map<String, dynamic>` adapters for the JS detail
/// channel (Todo 8).
///
/// The detail page's rendering contract is the raw `JsChannelDetailProxy` map —
/// the shape a pack's `getAppDetail` / `switchVersion` / `versionOptions` /
/// `buildHistory` reply has. The unified channel entry (`ChannelApi` via
/// [RustChannelFacade]) returns typed FRB DTOs instead, so these adapters
/// project the typed values back to exactly that shape. Unknown pack keys are
/// carried in `extra_json` and merged verbatim.
library;

import 'dart:convert';

import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// [rust.ChannelAppDetailInfo] → the detail page's `JsChannelDetailProxy` map.
///
/// The Rust `AppDetail.extra` is the pack's **whole** reply (`convert::detail`
/// clones the source map), so `extra_json` already carries every key the page
/// reads (downloads with their `extra` tags, statistics, screenshots, changelog,
/// permissions, `extra.env`, ...). It is decoded as the base; the typed
/// projection only fills keys the pack reply did not carry.
Map<String, dynamic> detailToMap(rust.ChannelAppDetailInfo detail) {
  final map = <String, dynamic>{};
  final extra = _decodeJsonObject(detail.extraJson);
  if (extra != null) map.addAll(extra);
  map.putIfAbsent('appId', () => detail.appId);
  map.putIfAbsent('name', () => detail.name);
  map.putIfAbsent('icon', () => detail.icon);
  map.putIfAbsent('description', () => detail.description);
  final version = detail.version;
  if (version != null) map.putIfAbsent('version', () => version);
  final developer = detail.developer;
  if (developer != null) map.putIfAbsent('developer', () => developer);
  final packageName = detail.packageName;
  if (packageName != null) map.putIfAbsent('packageName', () => packageName);
  final projectUrl = detail.projectUrl;
  if (projectUrl != null) map.putIfAbsent('projectUrl', () => projectUrl);
  map.putIfAbsent('sections', () => detail.sections);
  // The pack reply (and so `extra_json`) always carries the raw `downloads`
  // array; the typed projection carries no key the raw map lacks, so an absent
  // key degrades to an empty list rather than a fabricated download.
  map.putIfAbsent('downloads', () => const <Object?>[]);
  return map;
}

/// [rust.ScriptVersionOptions] → the `versionOptions` map the picker reads.
Map<String, dynamic> versionOptionsToMap(rust.ScriptVersionOptions options) {
  final map = <String, dynamic>{
    'envs': options.envs,
    'versions': [
      for (final version in options.versions)
        <String, dynamic>{
          'version': version.version,
          'envs': version.envs,
          'buildCount': version.buildCount.toInt(),
        },
    ],
  };
  final title = options.title;
  if (title != null) map['title'] = title;
  final currentEnv = options.currentEnv;
  if (currentEnv != null) map['currentEnv'] = currentEnv;
  final currentVersion = options.currentVersion;
  if (currentVersion != null) map['currentVersion'] = currentVersion;
  final extra = _decodeJsonObject(options.extraJson);
  if (extra != null) {
    extra.forEach((key, value) => map.putIfAbsent(key, () => value));
  }
  return map;
}

/// [rust.ScriptBuild] → one `builds` entry (unknown keys from `extra_json`,
/// e.g. `builtBy` / `ipaName`).
Map<String, dynamic> buildToMap(rust.ScriptBuild build) {
  final map = <String, dynamic>{'num': build.num.toInt()};
  final publishedAt = build.publishedAt;
  if (publishedAt != null) map['publishedAt'] = publishedAt;
  final size = build.size;
  if (size != null) map['size'] = size.toInt();
  final changelog = build.changelog;
  if (changelog != null) map['changelog'] = changelog;
  final installTimes = build.installTimes;
  if (installTimes != null) map['installTimes'] = installTimes.toInt();
  final extra = _decodeJsonObject(build.extraJson);
  if (extra != null) {
    extra.forEach((key, value) => map.putIfAbsent(key, () => value));
  }
  return map;
}

/// Decodes a JSON object string (`extra_json`) to a Map; null when empty or not
/// an object.
Map<String, dynamic>? _decodeJsonObject(String raw) {
  if (raw.trim().isEmpty) return null;
  final Object? decoded = jsonDecode(raw);
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return null;
}
