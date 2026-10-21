import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// Pure-Dart half of the LocalDb parity harness.
///
/// `libsqlite3.so` is unavailable on the QA host, so this test never opens
/// SQLite: it maps the committed raw-row fixture through the same pure mapping
/// the app uses (`db.AppInfo` -> `AppSummary.fromDbAppInfo`). Search mirrors the
/// DAO LIKE fallback (`name LIKE %q% OR des LIKE %q%`, ASCII case-insensitive);
/// FTS5 is out of scope for this harness.
void main() {
  test('writes canonical Dart parity JSON from raw fixture rows', () {
    final rawRows = jsonDecode(
      File('test/fixtures/parity/localdb_rows.json').readAsStringSync(),
    ) as List<dynamic>;

    final apps = rawRows
        .map((raw) => _toDbAppInfo(raw as Map<String, dynamic>))
        .map(AppSummary.fromDbAppInfo)
        .toList(growable: false);

    const query = 'demo';
    final search = apps
        .where(
          (app) =>
              app.name.toLowerCase().contains(query) ||
              app.des.toLowerCase().contains(query),
        )
        .toList(growable: false);

    final document = <String, dynamic>{
      'getAllApps': apps.map(_summaryToJson).toList(growable: false),
      'searchApps': search.map(_summaryToJson).toList(growable: false),
      'getAppInfo': apps.isEmpty ? null : _summaryToJson(apps.first),
      'getAppInfoMissing': null,
      'downloadLifecycle': _downloadLifecycle(),
    };

    final output = File('target/spike-evidence/parity-dart.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(document),
    );

    expect(output.existsSync(), isTrue);
    for (final key in const [
      'getAllApps',
      'searchApps',
      'getAppInfo',
      'getAppInfoMissing',
      'downloadLifecycle',
    ]) {
      expect(document.containsKey(key), isTrue, reason: 'missing $key');
    }
    expect((document['getAllApps'] as List<dynamic>).length, 3);
    expect((document['searchApps'] as List<dynamic>).length, 2);
    expect(document['getAppInfoMissing'], isNull);
    expect(document['downloadLifecycle'], ['running', 'running', 'completed']);
  });
}

db.AppInfo _toDbAppInfo(Map<String, dynamic> raw) {
  final categoryText = raw['category'] as String?;
  final category = categoryText == null
      ? null
      : (jsonDecode(categoryText) as List<dynamic>).cast<String>();
  final readme = raw['readme'] as String?;
  final extra = raw['extra'] as String?;

  // `db.AppInfo` has no constructor carrying both readme and extra, so a row
  // with a readme uses `withReadme` (extra stays null in the fixture), while
  // every other row uses `withExtra` as required by the harness contract.
  if (readme != null) {
    return db.AppInfo.withReadme(
      raw['appId'] as String,
      raw['name'] as String,
      raw['user'] as String,
      raw['repositories'] as String,
      raw['icon'] as String,
      raw['des'] as String,
      readme,
      category,
    );
  }
  return db.AppInfo.withExtra(
    raw['appId'] as String,
    raw['name'] as String,
    raw['user'] as String,
    raw['repositories'] as String,
    raw['icon'] as String,
    raw['des'] as String,
    category,
    extra,
  );
}

Map<String, dynamic> _summaryToJson(AppSummary app) => {
  'appId': app.appId,
  'packageName': app.packageName,
  'name': app.name,
  'user': app.user,
  'repositories': app.repositories,
  'icon': app.icon,
  'des': app.des,
  'readme': app.readme,
  'category': app.category,
  'extra': app.extra,
};

/// Test-local mapping from the Dart enum to the core status labels.
///
/// The production Dart `DownloadStatusEnum` is a separate representation from
/// the core i64 status codes, so the harness pins the observable lifecycle
/// (`queued`/`downloading` -> running, `completed` -> completed) here instead of
/// adding a production mapping used only by tests.
List<String> _downloadLifecycle() {
  const phases = [
    DownloadStatusEnum.queued,
    DownloadStatusEnum.downloading,
    DownloadStatusEnum.completed,
  ];
  return phases.map((phase) {
    return switch (phase) {
      DownloadStatusEnum.queued ||
      DownloadStatusEnum.connecting ||
      DownloadStatusEnum.downloading => 'running',
      DownloadStatusEnum.paused => 'paused',
      DownloadStatusEnum.completed => 'completed',
      DownloadStatusEnum.failed => 'failed',
      DownloadStatusEnum.cancelled => 'cancelled',
    };
  }).toList(growable: false);
}
