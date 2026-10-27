/// F1 cutover-compliance contract (final verification, not a paper checklist).
///
/// This file asserts the parts of the Wave 6 closeout contract that are only
/// visible by reading the production sources:
///
/// * no production `CoreFlags.set(...)` call exists under `lib/` (the runtime
///   mirror flip is a test seam; the durable flip is `Flags::WAVE06_CLOSEOUT`
///   plus the one-time `cutover_v6.done` marker);
/// * the migrated facades have real production callers (not only tests);
/// * `ScriptUiHandlerRegistry` is registered from
///   `ChannelIntegration.initialize` and the router owns exactly the eight
///   `ui.*` kinds.
///
/// The Rust-side default snapshot (criterion 1), the one-time marker logic and
/// the pre-closeout snapshot/parity ordering (criteria 3/4) are asserted by
/// `rust/gstore_core/tests/flags_cutover_default.rs`,
/// `test/core_cutover_test.dart` and `test/core_bootstrap_test.dart`; the
/// legacy-writer guard inventory is owned by
/// `test/legacy_write_guard_coverage_test.dart`. Those are cited, not copied.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Removes `//` line comments and `/* ... */` block comments while leaving
/// string literals untouched, so a commented-out call never satisfies a scan.
String _stripComments(String source) {
  final out = StringBuffer();
  var index = 0;
  var quote = '';
  while (index < source.length) {
    final char = source[index];
    if (quote.isNotEmpty) {
      out.write(char);
      if (char == '\\' && index + 1 < source.length) {
        out.write(source[index + 1]);
        index += 2;
        continue;
      }
      if (char == quote) quote = '';
      index++;
      continue;
    }
    if (source.startsWith("'''", index) || source.startsWith('"""', index)) {
      final delimiter = source.substring(index, index + 3);
      final end = source.indexOf(delimiter, index + 3);
      final stop = end == -1 ? source.length : end + 3;
      out.write(source.substring(index, stop));
      index = stop;
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      out.write(char);
      index++;
      continue;
    }
    if (source.startsWith('//', index)) {
      final end = source.indexOf('\n', index);
      index = end == -1 ? source.length : end;
      continue;
    }
    if (source.startsWith('/*', index)) {
      final end = source.indexOf('*/', index + 2);
      index = end == -1 ? source.length : end + 2;
      continue;
    }
    out.write(char);
    index++;
  }
  return out.toString();
}

/// All Dart sources under [root], recursively, with forward-slash paths.
List<File> _dartFiles(String root) {
  final files = <File>[];
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) files.add(entity);
  }
  return files;
}

String _normalized(File file) => file.path.replaceAll(r'\', '/');

/// All `file:line` hits under `lib/`, excluding [definition].
List<(String path, int line)> _productionHits(
  String literal, {
  required String definition,
}) {
  final hits = <(String, int)>[];
  final pattern = RegExp(RegExp.escape(literal));
  for (final file in _dartFiles('lib')) {
    final path = _normalized(file);
    if (path == definition) continue;
    final lines = _stripComments(file.readAsStringSync()).split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) hits.add((path, i + 1));
    }
  }
  return hits;
}

/// Extracts the brace-balanced body of the declaration of [method].
String? _methodBody(String source, String method) {
  final declaration = RegExp(
    r'(?:Future<[^;{}]*>|void|bool|String\??|int|double)'
    '\\s+${RegExp.escape(method)}\\s*\\(',
  );
  for (final match in declaration.allMatches(source)) {
    var index = match.end - 1;
    var parens = 0;
    for (; index < source.length; index++) {
      final char = source[index];
      if (char == '(') {
        parens++;
      } else if (char == ')') {
        parens--;
        if (parens == 0) break;
      }
    }
    if (parens != 0) continue;

    var cursor = index + 1;
    while (cursor < source.length &&
        source[cursor] != '{' &&
        source[cursor] != ';' &&
        source[cursor] != '=') {
      cursor++;
    }
    if (cursor >= source.length || source[cursor] != '{') continue;

    var braces = 0;
    var end = cursor;
    for (; end < source.length; end++) {
      if (source[end] == '{') {
        braces++;
      } else if (source[end] == '}') {
        braces--;
        if (braces == 0) {
          end++;
          break;
        }
      }
    }
    return source.substring(cursor, end);
  }
  return null;
}

/// The eight `ui.*` kinds declared by the router, in declaration order.
List<String> _declaredUiKinds(String routerSource) {
  const marker = 'static const List<String> uiKinds = <String>[';
  final start = routerSource.indexOf(marker);
  if (start < 0) return const <String>[];
  final end = routerSource.indexOf('];', start);
  if (end < 0) return const <String>[];
  final block = routerSource.substring(start + marker.length, end);
  return RegExp(r"'([^']+)'")
      .allMatches(block)
      .map((match) => match.group(1)!)
      .toList();
}

/// Facade -> the production file that must call it, derived by scanning `lib/`.
///
/// `ScriptApi` is checked separately because the F1 contract requires it to be
/// called from production, not merely exposed as a tested facade.
const Map<String, String> _facades = <String, String>{
  'RustChannelFacade': 'lib/core/channel/rust_channel_facade.dart',
  'CatalogFacade': 'lib/core/catalog/catalog_facade.dart',
  'AddedAppsFacade': 'lib/core/aggregate/added_apps_facade.dart',
  'UpdateFacade': 'lib/core/update/update_facade.dart',
};

void main() {
  group('F1-2 no production flag flip', () {
    test('no CoreFlags.set call exists under lib/ (test seam only)', () {
      final offenders = <String>[];
      final pattern = RegExp(r'CoreFlags\s*\.\s*set\s*\(');
      for (final file in _dartFiles('lib')) {
        final lines = _stripComments(file.readAsStringSync()).split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            offenders.add('${_normalized(file)}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'the durable flip is Flags::WAVE06_CLOSEOUT + the one-time '
              'cutover marker; CoreFlags.set is a test seam only. '
              'Offenders: $offenders');

      // Prove the seam really is exercised by tests, so "no production caller"
      // is not confused with "the API does not exist".
      expect(File('test/core_flags_set_test.dart').readAsStringSync(),
          contains('CoreFlags.set('));
    });
  });

  group('F1-5 facade production callers', () {
    for (final entry in _facades.entries) {
      test('${entry.key} is called from production code', () {
        final callSites = <(String, int)>[
          ..._productionHits('${entry.key}.instance', definition: entry.value),
          ..._productionHits('${entry.key}(', definition: entry.value),
        ];
        expect(callSites, isNotEmpty,
            reason: '${entry.key} must have a production caller in lib/, '
                'not only tests');
      });
    }

    test('the pinned production call sites stay in place', () {
      // Positive pins so a refactor that removes the facade migration fails
      // here even while some unrelated reference keeps the generic scan green.
      final expected = <String, String>{
        'RustChannelFacade': 'lib/core/channel/ChannelManager.dart',
        'CatalogFacade': 'lib/core/update/update_manager.dart',
        'AddedAppsFacade': 'lib/core/service/apk_info_service.dart',
        'UpdateFacade': 'lib/page/update/logic.dart',
      };
      for (final entry in expected.entries) {
        final hits =
            _productionHits(entry.key, definition: _facades[entry.key]!);
        expect(hits.map((hit) => hit.$1), contains(entry.value),
            reason: '${entry.key} must still be called from ${entry.value}');
      }
    });

    test('the ScriptApi facade is called from production code', () {
      const definition = 'lib/core/script/script_api.dart';
      final hits = <(String, int)>[
        ..._productionHits('ScriptApi.instance', definition: definition),
        ..._productionHits('ScriptApi(', definition: definition),
      ];
      final importers = <String>[];
      for (final file in _dartFiles('lib')) {
        final path = _normalized(file);
        if (_stripComments(file.readAsStringSync())
            .contains('package:gstore/core/script/script_api.dart')) {
          importers.add(path);
        }
      }

      expect(hits, isNotEmpty,
          reason: 'the ScriptApi facade must have a production caller in lib/, '
              'not only test/script_api_dart_test.dart and '
              'test/jschannel_cutover_parity_test.dart');
      expect(importers, isNotEmpty,
          reason: 'a production file must import the ScriptApi facade');
    });
  });

  group('F1-6 ui.* handler path', () {
    test('ChannelIntegration.initialize registers the 8-kind registry', () {
      final source =
          File('lib/core/channel/ChannelIntegration.dart').readAsStringSync();
      final initialize = _methodBody(source, 'initialize');
      expect(initialize, isNotNull,
          reason: 'ChannelIntegration.initialize must exist');
      expect(initialize, contains('_attachScriptUiRouter()'),
          reason: 'initialize must attach the script UI router');

      final attach = _methodBody(source, '_attachScriptUiRouter');
      expect(attach, isNotNull,
          reason: 'the private attach helper must exist');
      expect(
          attach,
          contains('ScriptUiHandlerRegistry.instance.registerOn('
              'ScriptUiRequestRouter.instance)'),
          reason: 'the process-wide registry must register on the live router');

      final router =
          File('lib/core/channel/script_ui_request_router.dart')
              .readAsStringSync();
      expect(_declaredUiKinds(router), <String>[
        'showVersionPicker',
        'showBuildHistory',
        'refreshDetail',
        'updateDownloadList',
        'showUAPicker',
        'updateDetail',
        'setBusy',
        'download',
      ]);

      final registry = File('lib/core/script/script_ui_handler_registry.dart')
          .readAsStringSync();
      expect(registry, contains('for (final kind in ScriptUiRequestRouter.uiKinds)'),
          reason: 'the registry must derive one handler per declared kind');
      expect(registry, contains('router.registerAll(buildHandlers())'),
          reason: 'registerOn must install the whole map in one call');
      expect(registry, contains('static const String noActiveDetailCode'),
          reason: 'a missing active page must be a typed code');
    });

    test('the detail page binds/unbinds the process-wide registry', () {
      final logic = File('lib/page/detail/logic.dart').readAsStringSync();
      expect(logic, contains('ScriptUiHandlerRegistry.instance.bind('),
          reason: 'the active detail page must bind its callbacks');
      expect(logic, contains('ScriptUiHandlerRegistry.instance.unbind('),
          reason: 'the detail page teardown must release the binding');
    });
  });
}
