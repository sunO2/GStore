/// Offline minimal legacy → grouped config migration (plan Todo 22, C28).
///
/// The real migration runs on-device through the generated FRB bridge (Todo 21).
/// That opaque API needs a Flutter engine, so it must **not** be instantiated
/// here. This CLI is instead a pure, offline JSON transformer:
///
/// ```text
/// dart run tool/migrate_config.dart --dry-run test/fixtures/legacy_cli_export.json
/// dart run tool/migrate_config.dart test/fixtures/legacy_cli_export.json \
///     --out /tmp/grouped_config.json
/// ```
///
/// Input is a legacy export of the two real stores:
///
/// ```json
/// {"prefs": {"config_download_max_concurrent": 5}, "secure": {"webdav_url": "..."}}
/// ```
///
/// A flat object (no `prefs` / `secure` wrapper) is also accepted as prefs.
/// Mapping and decoding come from `legacy_config_mapping.dart`, the same pure
/// helper `ConfigMigrationTool` uses, so the table cannot drift.
///
/// Output:
/// * `--dry-run` prints the grouped config plus a per-key report and writes
///   **nothing** to disk,
/// * real mode writes `module -> key -> value` JSON to `--out` (required).
///
/// The per-key report contains `storageKey` / `wireKey` / `status` / `code`
/// only — never a config value. Exit code is `1` for invalid JSON, an invalid
/// export shape, bad values (per-key failures) or a missing `--out`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gstore/core/config/migration/legacy_config_mapping.dart';

const String _usage = '''
Offline legacy → grouped config migration.

Usage:
  dart run tool/migrate_config.dart [--dry-run] [--out <file>] <legacy-export.json>

Options:
  --dry-run      Print the grouped config + per-key report; write nothing.
  --out <file>   Write the grouped config JSON here (required without --dry-run).
  -h, --help     Show this help.

Exit codes:
  0  every present key mapped
  1  invalid input, invalid arguments, or at least one per-key mapping failure
''';

/// Typed CLI failure: stable `code` + human `message`, printed as JSON.
class _CliError implements Exception {
  const _CliError(this.code, this.message);

  final String code;
  final String message;
}

class _Options {
  const _Options({
    required this.input,
    required this.dryRun,
    this.out,
  });

  final String input;
  final bool dryRun;
  final String? out;
}

void main(List<String> args) {
  exitCode = _run(args);
}

int _run(List<String> args) {
  try {
    if (args.contains('-h') || args.contains('--help')) {
      stdout.write(_usage);
      return 0;
    }
    final options = _parseArgs(args);

    String raw;
    try {
      raw = File(options.input).readAsStringSync();
    } on FileSystemException {
      throw _CliError(
        'input_not_found',
        'cannot read input file: ${options.input}',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw _CliError(
        'invalid_json',
        'input is not valid JSON: ${error.message}',
      );
    }

    final export = _readExport(decoded);
    final mapping = mapLegacyConfig(
      prefs: export.prefs,
      secure: export.secure,
    );

    final keys = <Map<String, Object?>>[
      for (final entry in mapping.pending)
        <String, Object?>{
          'storageKey': entry.storageKey,
          'wireKey': entry.wireKey,
          'status': 'applied',
        },
      for (final report in mapping.reports)
        <String, Object?>{
          'storageKey': report.storageKey,
          'wireKey': report.wireKey,
          'status': report.status,
          if (report.code != null) 'code': report.code,
        },
    ];
    final superseded = mapping.reports
        .where((report) => report.status == 'superseded')
        .length;
    final grouped = mapping.groupedConfig;
    final failed = mapping.failedCount;

    if (options.dryRun) {
      final envelope = <String, Object?>{
        'mode': 'dry-run',
        'input': options.input,
        'summary': <String, Object?>{
          'totalStorageKeys': mapping.totalStorageKeys,
          'mappedEntries': mapping.pending.length,
          'groups': grouped.length,
          'failed': failed,
          'superseded': superseded,
        },
        'config': grouped,
        'keys': keys,
      };
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(envelope));
      return failed > 0 ? 1 : 0;
    }

    if (options.out == null || options.out!.isEmpty) {
      throw const _CliError(
        'missing_out',
        'real mode requires --out <file> (or use --dry-run)',
      );
    }

    if (failed > 0) {
      // Never leave a partial artifact that looks like a successful migration.
      final envelope = <String, Object?>{
        'mode': 'write',
        'input': options.input,
        'output': options.out,
        'written': false,
        'error': <String, Object?>{
          'code': 'mapping_failed',
          'message': '$failed key(s) failed to map; nothing was written',
        },
        'summary': <String, Object?>{
          'totalStorageKeys': mapping.totalStorageKeys,
          'mappedEntries': mapping.pending.length,
          'groups': grouped.length,
          'failed': failed,
          'superseded': superseded,
        },
        'keys': keys,
      };
      stderr.writeln(const JsonEncoder.withIndent('  ').convert(envelope));
      return 1;
    }

    final output = File(options.out!);
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(grouped),
      flush: true,
    );

    final envelope = <String, Object?>{
      'mode': 'write',
      'input': options.input,
      'output': options.out,
      'written': true,
      'summary': <String, Object?>{
        'totalStorageKeys': mapping.totalStorageKeys,
        'mappedEntries': mapping.pending.length,
        'groups': grouped.length,
        'failed': failed,
        'superseded': superseded,
      },
      'keys': keys,
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(envelope));
    return 0;
  } on _CliError catch (error) {
    _printError(error);
    return 1;
  } catch (error) {
    _printError(_CliError('internal_error', '$error'));
    return 1;
  }
}

void _printError(_CliError error) {
  stderr.writeln(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'error': <String, Object?>{
        'code': error.code,
        'message': error.message,
      },
    }),
  );
}

class _LegacyExport {
  const _LegacyExport({required this.prefs, required this.secure});

  final Map<String, Object?> prefs;
  final Map<String, String?> secure;
}

_LegacyExport _readExport(Object? decoded) {
  if (decoded is! Map) {
    throw const _CliError(
      'invalid_export_shape',
      'root JSON must be an object',
    );
  }

  final hasWrappers = decoded.containsKey('prefs') || decoded.containsKey('secure');
  final prefsNode = hasWrappers ? decoded['prefs'] : decoded;
  final secureNode = hasWrappers ? decoded['secure'] : null;

  final prefs = _asPrefs(prefsNode);
  final secure = _asSecure(secureNode);
  if (prefs.isEmpty && secure.isEmpty) {
    throw const _CliError(
      'empty_export',
      'export contains no prefs or secure values',
    );
  }
  return _LegacyExport(prefs: prefs, secure: secure);
}

Map<String, Object?> _asPrefs(Object? node) {
  if (node == null) return <String, Object?>{};
  if (node is! Map) {
    throw const _CliError(
      'invalid_export_shape',
      '"prefs" must be an object',
    );
  }
  return <String, Object?>{
    for (final entry in node.entries) entry.key.toString(): entry.value,
  };
}

Map<String, String?> _asSecure(Object? node) {
  if (node == null) return <String, String?>{};
  if (node is! Map) {
    throw const _CliError(
      'invalid_export_shape',
      '"secure" must be an object',
    );
  }
  return <String, String?>{
    for (final entry in node.entries)
      entry.key.toString(): switch (entry.value) {
        null => null,
        final String value => value,
        final Object value => jsonEncode(value),
      },
  };
}

_Options _parseArgs(List<String> args) {
  var dryRun = false;
  String? out;
  final positional = <String>[];

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg == '--out') {
      if (index + 1 >= args.length) {
        throw const _CliError(
          'invalid_arguments',
          '--out requires a file path',
        );
      }
      out = args[++index];
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg.startsWith('-')) {
      throw _CliError('invalid_arguments', 'unknown option: $arg');
    } else {
      positional.add(arg);
    }
  }

  if (positional.isEmpty) {
    throw const _CliError(
      'missing_input',
      'provide a legacy export JSON file (see --help)',
    );
  }
  if (positional.length > 1) {
    throw _CliError(
      'invalid_arguments',
      'expected exactly one input file, got ${positional.length}',
    );
  }
  return _Options(input: positional.single, dryRun: dryRun, out: out);
}
