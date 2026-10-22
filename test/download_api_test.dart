import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

rust.DownloadTaskDto _dto({
  int id = 1,
  String status = 'running',
  String? error,
}) =>
    rust.DownloadTaskDto(
      id: id,
      moduleTaskId: '$id',
      dedupKey: 'dedup:$id',
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: 'example.apk',
      kind: 'app',
      resourceId: 'com.example.app',
      resourceVersion: '1.2.3',
      url: 'https://example.test/example.apk',
      destPath: '/tmp/example.apk',
      status: status,
      bytesDone: 10,
      total: 100,
      speedBps: 2,
      etaSec: 5,
      segmentsJson: null,
      retries: 0,
      serverMeta: null,
      priority: 0,
      headersJson: null,
      expectedSha256: null,
      installAfterDownload: true,
      error: error,
      lastStartedAt: 7,
      createdAt: 100,
      updatedAt: 200,
    );

rust.DownloadStartRequest _request() => const rust.DownloadStartRequest(
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: 'example.apk',
      url: 'https://example.test/example.apk',
      destPath: '/tmp/example.apk',
      kind: 'app',
      resourceId: 'com.example.app',
      resourceVersion: '1.2.3',
      dedupKey: 'dedup:example',
      expectedSha256: null,
      installAfterDownload: true,
    );

class _FakeDownloadBackend implements DownloadBackend {
  final List<String> calls = <String>[];
  final List<rust.DownloadTaskDto> streamed = <rust.DownloadTaskDto>[];

  @override
  Future<int> start(rust.DownloadStartRequest request) async {
    calls.add('start:${request.appId}:${request.dedupKey}:'
        '${request.expectedSha256}:${request.installAfterDownload}');
    return 77;
  }

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    calls.add('list');
    return <rust.DownloadTaskDto>[_dto()];
  }

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async {
    calls.add('get:$moduleTaskId');
    return _dto(id: 9);
  }

  @override
  Future<void> pause(String moduleTaskId) async => calls.add('pause:$moduleTaskId');

  @override
  Future<void> resume(String moduleTaskId) async => calls.add('resume:$moduleTaskId');

  @override
  Future<void> cancel(String moduleTaskId) async => calls.add('cancel:$moduleTaskId');

  @override
  Future<void> retry(String moduleTaskId) async => calls.add('retry:$moduleTaskId');

  @override
  Future<void> restart(String moduleTaskId) async => calls.add('restart:$moduleTaskId');

  @override
  Future<void> remove(String moduleTaskId) async => calls.add('remove:$moduleTaskId');

  @override
  Stream<rust.DownloadTaskDto> watchAll() {
    calls.add('watchAll');
    return Stream<rust.DownloadTaskDto>.fromIterable(streamed);
  }
}

void main() {
  test('download_api facade forwards every method', () async {
    final backend = _FakeDownloadBackend();
    final facade = DownloadFacade(backend: backend);

    expect(await facade.start(_request()), 77);
    final list = await facade.list();
    expect(list.single.id, 1);
    final one = await facade.get('9');
    expect(one?.id, 9);
    await facade.pause('1');
    await facade.resume('2');
    await facade.cancel('3');
    await facade.retry('4');
    await facade.restart('5');
    await facade.remove('6');

    final dto = _dto(id: 11);
    backend.streamed.add(dto);
    final streamed = await facade.watchAll().toList();

    expect(streamed.single.id, 11);
    expect(backend.calls, <String>[
      'start:com.example.app:dedup:example:null:true',
      'list',
      'get:9',
      'pause:1',
      'resume:2',
      'cancel:3',
      'retry:4',
      'restart:5',
      'remove:6',
      'watchAll',
    ]);
  });

  test('download_api toDownloadTask maps completed', () {
    final task = toDownloadTask(_dto(status: 'completed'));

    expect(task.status, DownloadStatusEnum.completed);
    expect(task.error, isNull);
    expect(task.received, 10);
    expect(task.total, 100);
    expect(task.speedBps, 2);
    expect(task.etaSec, 5);
    expect(task.installAfterDownload, isTrue);
    expect(task.appId, 'com.example.app');
    expect(task.filePath, '/tmp/example.apk');
    expect(task.createdAt.millisecondsSinceEpoch, 100 * 1000);
  });

  test('download_api toDownloadTask maps needs_restart to paused', () {
    final task = toDownloadTask(_dto(status: 'needs_restart'));

    expect(task.status, DownloadStatusEnum.paused);
    expect(task.error, 'needs_restart');
    expect(task.installAfterDownload, isTrue);
  });

  test('download_api toDownloadTask maps unknown status to paused', () {
    final task = toDownloadTask(_dto(status: 'mystery'));

    expect(task.status, DownloadStatusEnum.paused);
    expect(task.error, 'mystery');
  });
}
