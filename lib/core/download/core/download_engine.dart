import 'package:dio/dio.dart';
import 'download_event.dart';
import 'download_request.dart';

/// Engine is a swappable pure-transfer core; it does NOT do
/// queue/concurrency/retry/persistence (that is DownloadManager's job);
/// new engines = new DownloadEngine impl injected into DownloadManager.
abstract class DownloadEngine {
  Stream<DownloadEvent> execute(
    DownloadRequest request, {
    CancelToken? cancelToken,
  });
}
