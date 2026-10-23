/// G6A.3 guard coverage: every legacy writer is guarded by its per-domain
/// marker, and the guard blocks even while the global `CoreFlags.coreWrites`
/// mirror is false.
///
/// The source table below is the enumeration: a writer that loses its
/// `assertAllowed('<domain>')` call makes this suite red. Runtime tests prove
/// the marker (not the global flag) decides, and that no client-side cache
/// exists between two probes.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

/// One legacy writer: the file that owns it, its public entry point and the
/// domain whose marker must block it.
class _Writer {
  const _Writer(this.file, this.method, this.domain, {this.occurrences = 1});

  final String file;
  final String method;
  final String domain;

  /// How many `assertAllowed('<domain>')` calls the method body must contain.
  ///
  /// One entry per declaration is not enough for a method that guards several
  /// writes (e.g. `AgentService._manageDownloads` guards `cleanCompleted` and
  /// `clearAll` separately): counting the occurrences makes removing any single
  /// guard fail.
  final int occurrences;

  @override
  String toString() => '$file::$method ($domain x$occurrences)';
}

const List<_Writer> _writers = <_Writer>[
  // ---------------------------------------------------------------- channel
  _Writer('lib/core/channel/impl/GitHubChannel.dart', 'addApp', 'channel'),
  _Writer('lib/core/channel/impl/GitHubChannel.dart', 'removeApp', 'channel'),
  _Writer('lib/core/channel/impl/GitHubChannel.dart', '_loadChannelApps',
      'channel'),
  _Writer(
      'lib/core/channel/impl/GitHubChannel.dart', 'migrateAppId', 'channel'),
  _Writer('lib/core/channel/impl/GitHubChannel.dart', '_buildStoredAppInfo',
      'channel'),
  _Writer(
      'lib/core/channel/impl/VivoChannel.dart', 'saveSearchResult', 'channel'),
  _Writer('lib/core/channel/impl/VivoChannel.dart', 'deleteSearchResult',
      'channel'),
  _Writer('lib/core/channel/impl/FdroidChannel.dart', 'addApp', 'channel'),
  _Writer('lib/core/channel/impl/FdroidChannel.dart', 'removeApp', 'channel'),
  _Writer('lib/core/channel/impl/JsChannel.dart', '_persistApps', 'channel'),
  _Writer('lib/core/channel/impl/JsChannel.dart', 'removeApp', 'channel'),
  _Writer('lib/core/js/js_channel_runtime.dart', '_registerDatabaseHost',
      'channel'),
  _Writer('lib/core/service/apk_info_service.dart',
      '_updateNameAndIconAfterInstall', 'channel'),
  _Writer(
      'lib/core/service/backup_service.dart', '_importChannelApps', 'channel'),
  _Writer('lib/core/service/db_manager.dart', 'addDBRepositroy', 'channel'),
  // ---------------------------------------------------------------- catalog
  _Writer('lib/core/aggregate/AppAggregatorManager.dart', 'addApp', 'catalog'),
  _Writer('lib/core/aggregate/AppAggregatorManager.dart', 'addApps', 'catalog'),
  _Writer(
      'lib/core/aggregate/AppAggregatorManager.dart', 'removeApp', 'catalog'),
  _Writer(
      'lib/core/aggregate/AppAggregatorManager.dart', 'renameApp', 'catalog'),
  _Writer('lib/core/aggregate/AppAggregatorManager.dart', 'setTags', 'catalog'),
  _Writer('lib/core/aggregate/AppAggregatorManager.dart', 'addTag', 'catalog'),
  _Writer(
      'lib/core/aggregate/AppAggregatorManager.dart', 'removeTag', 'catalog'),
  _Writer('lib/core/aggregate/AppAggregatorManager.dart', 'clearChannel',
      'catalog'),
  _Writer(
      'lib/core/aggregate/AppAggregatorManager.dart', 'clearAll', 'catalog'),
  _Writer('lib/core/aggregate/added_apps_facade.dart', 'setOrder', 'catalog'),
  _Writer('lib/core/service/db_manager.dart', '_checkUpdateDBOfRepositroy',
      'catalog'),
  _Writer('lib/core/service/backup_service.dart', 'importData', 'catalog'),
  _Writer('lib/core/service/backup_service.dart', '_addAllAppsToAggregator',
      'catalog'),
  // ----------------------------------------------------------------- update
  _Writer('lib/core/update/update_cache.dart', 'saveCheckedAt', 'update'),
  _Writer('lib/core/update/update_cache.dart', 'saveResults', 'update'),
  _Writer('lib/core/update/update_cache.dart', 'saveLogs', 'update'),
  _Writer('lib/core/update/update_cache.dart', 'savePreferredApk', 'update'),
  _Writer('lib/core/config/providers/update_config_provider.dart', 'save',
      'update'),
  _Writer('lib/core/config/providers/update_config_provider.dart', 'clear',
      'update'),
  // --------------------------------------------------------------- download
  _Writer(
      'lib/core/download/manager/download_repository.dart', 'save', 'download'),
  _Writer('lib/core/download/manager/download_repository.dart', 'deleteById',
      'download'),
  _Writer('lib/page/download/download_page_providers.dart', 'deleteDownload',
      'download'),
  _Writer('lib/page/download/download_page_providers.dart',
      'deleteDownloadsByAppId', 'download'),
  _Writer('lib/page/download/download_page_providers.dart', 'clearCompleted',
      'download'),
  _Writer(
      'lib/page/download/download_page_providers.dart', 'clearAll', 'download'),
  _Writer('lib/core/agent/agent_service.dart', '_manageDownloads', 'download',
      occurrences: 2),
  // ---------------------------------------------------------------- install
  // Wave 6B cutover: a direct user-picked APK install creates no core state,
  // so `_installApkDirect` is intentionally NOT a guarded legacy writer.
  // ---------------------------------------------------- cross-domain raw delete
  // `deleteRow` maps the selected table onto its owning domain; one entry per
  // mapped branch keeps the literal-domain assertion honest.
  _Writer('lib/page/database_manage/logic.dart', 'deleteRow', 'channel'),
  _Writer('lib/page/database_manage/logic.dart', 'deleteRow', 'catalog'),
  _Writer('lib/page/database_manage/logic.dart', 'deleteRow', 'download'),
];

/// Extracts the brace-balanced body of the declaration of [method] in
/// [source], or `null` when no declaration is found.
///
/// The regex requires a return type before the name so call sites
/// (`await foo(...)`) never match. Parameter lists are paren-balanced first
/// (default values contain braces), then the body is brace-balanced.
String? _extractMethodBody(String source, String method) {
  final declaration = RegExp(
    r'(?:Future<[^;{}]*>|void|bool|String\??|int|double)'
    '\\s+${RegExp.escape(method)}\\s*\\(',
  );
  for (final match in declaration.allMatches(source)) {
    // Match the parameter list first.
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

    // Skip modifiers (`async`, `=>` is rejected) up to the body brace.
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

/// Removes `//` line comments (including `///` docs) and `/* ... */` block
/// comments while leaving string literals untouched.
///
/// Without this, commenting a guard out would still satisfy a substring check.
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

/// Recursively lists `.dart` sources under [dir].
List<File> _dartFiles(Directory dir) {
  final files = <File>[];
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) files.add(entity);
  }
  return files;
}

void main() {
  setUp(() {
    LegacyWriteGuard.resetForTest();
  });

  tearDown(() {
    LegacyWriteGuard.resetForTest();
    CoreFlags.resetBackend();
  });

  group('source coverage', () {
    test('legacy_write_guard_covers_every_writer', () {
      final failures = <String>[];
      final sources = <String, String>{};

      for (final writer in _writers) {
        final source =
            sources[writer.file] ??= File(writer.file).readAsStringSync();
        final body = _extractMethodBody(source, writer.method);
        if (body == null) {
          failures.add('${writer.file}: declaration of ${writer.method} '
              'not found');
          continue;
        }
        final expected = "assertAllowed('${writer.domain}')";
        final found = RegExp(RegExp.escape(expected))
            .allMatches(_stripComments(body))
            .length;
        if (found < writer.occurrences) {
          failures.add('${writer.file}::${writer.method} has $found of '
              '${writer.occurrences} expected $expected call(s)');
        }
      }

      expect(failures, isEmpty,
          reason: 'every legacy writer must call '
              'LegacyWriteGuard.assertAllowed(<domain>) before writing:\n'
              '${failures.join('\n')}');
      expect(_writers.length, greaterThanOrEqualTo(40),
          reason: 'the writer inventory must stay exhaustive');
    });

    test('js_channel domain is reserved and has no writer call site', () {
      final offenders = <String>[];
      for (final file in _dartFiles(Directory('lib'))) {
        final source = file.readAsStringSync();
        if (source.contains("assertAllowed('js_channel')")) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'js_channel is RESERVED until Wave 5: $offenders');
    });

    test('guard binds at bootstrap through the CoreApi facade', () {
      final facade =
          File('lib/core/rust/CoreApiFacade.dart').readAsStringSync();
      expect(facade, contains('LegacyWriteGuard.bind(api)'),
          reason: 'the guard must receive the live CoreApi handle or it is '
              'dead code');
    });
  });

  group('runtime blocking', () {
    test('legacy_write_guard_blocks_by_marker_without_global_flag', () async {
      // Global mirror explicitly false: the marker alone must block.
      CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(coreWrites: false)),
      );
      await CoreFlags.refresh();
      expect(CoreFlags.coreWrites, isFalse);

      final seen = <String>[];
      LegacyWriteGuard.probeOverride = (domain) async {
        seen.add(domain);
        return true;
      };

      Object? thrown;
      try {
        await LegacyWriteGuard.assertAllowed('channel');
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<LegacyWriteBlocked>());
      expect(thrown.toString(), contains('CORE_E_WRITE_BLOCKED'));
      expect(seen, <String>['channel'],
          reason:
              'the probe must run even while CoreFlags.coreWrites is false');
    });

    test('marker absent allows the legacy write', () async {
      CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(coreWrites: false)),
      );
      await CoreFlags.refresh();
      LegacyWriteGuard.probeOverride = (domain) async => false;

      await LegacyWriteGuard.assertAllowed('channel');
    });

    test('unbound guard allows (no core to defer to)', () async {
      LegacyWriteGuard.resetForTest();
      await LegacyWriteGuard.assertAllowed('channel');
      expect(LegacyWriteGuard.probeOverride, isNull);
    });

    test('probe error fails open (a broken core must not brick writes)',
        () async {
      LegacyWriteGuard.probeOverride =
          (domain) async => throw StateError('core unavailable');

      await LegacyWriteGuard.assertAllowed('channel');
    });
  });

  group('domain fidelity', () {
    test('guard probes the exact domain of every writer', () async {
      final seen = <String>[];
      LegacyWriteGuard.probeOverride = (domain) async {
        seen.add(domain);
        return false;
      };

      final expected = <String>[];
      for (final writer in _writers) {
        expected.add(writer.domain);
        await LegacyWriteGuard.assertAllowed(writer.domain);
      }

      expect(seen, expected);
      expect(expected.toSet(),
          <String>{'channel', 'catalog', 'update', 'download'});
    });
  });

  group('adversarial invariants', () {
    test('no client cache: marker flip between calls blocks the second',
        () async {
      var armed = false;
      final seen = <String>[];
      LegacyWriteGuard.probeOverride = (domain) async {
        seen.add(domain);
        return armed;
      };

      await LegacyWriteGuard.assertAllowed('catalog');
      armed = true;
      await expectLater(
        LegacyWriteGuard.assertAllowed('catalog'),
        throwsA(isA<LegacyWriteBlocked>()),
      );
      expect(seen, <String>['catalog', 'catalog']);
    });

    test('concurrent calls for one domain all observe the marker', () async {
      LegacyWriteGuard.probeOverride = (domain) async => true;

      final results = await Future.wait<bool>(
        List<Future<bool>>.generate(8, (_) async {
          try {
            await LegacyWriteGuard.assertAllowed('download');
            return false;
          } on LegacyWriteBlocked {
            return true;
          }
        }),
      );

      expect(results.every((blocked) => blocked), isTrue);
    });
  });
}
