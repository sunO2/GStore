// Behavioural tests for [DownloadNotificationService] after the download
// cutover: the Dart service is the only notification poster, so every entry
// point must reach the platform channels — but only after `init()`.
//
// The plugin method channels are mocked (no real Android channels): the
// assertions are about observable behaviour — post counts, channel creation
// arguments, and foreground-service start/stop calls.
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel, MethodCall;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/service/download_notification_service.dart';

const MethodChannel _notificationsChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const MethodChannel _foregroundChannel = MethodChannel(
  'flutter_foreground_task/methods',
);

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

class _ChannelLog {
  final List<MethodCall> calls = <MethodCall>[];

  List<String> get methods => calls.map((c) => c.method).toList();

  MethodCall? callOf(String method) {
    for (final call in calls) {
      if (call.method == method) return call;
    }
    return null;
  }
}

late _ChannelLog _notifications;
late _ChannelLog _foreground;
bool _foregroundRunning = false;

Future<void> _setFlags({bool download = true}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(download: download)),
  );
  await CoreFlags.refresh();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // `flutter test` never runs the generated plugin registrant, so the
    // platform-interface instance is unset (`static late`). Register the
    // Android implementation explicitly; the method channel itself is mocked.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    _foregroundRunning = false;
    FlutterForegroundTask.resetStatic();
    // Do not poll `isRunningService` for five seconds; the channel mock below
    // reports the state change immediately.
    FlutterForegroundTask.skipServiceResponseCheck = true;

    _notifications = _ChannelLog();
    _foreground = _ChannelLog();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notificationsChannel, (call) async {
      _notifications.calls.add(call);
      switch (call.method) {
        case 'initialize':
        case 'requestNotificationsPermission':
          return true;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(_foregroundChannel, (call) async {
      _foreground.calls.add(call);
      switch (call.method) {
        case 'isRunningService':
          return _foregroundRunning;
        case 'startService':
          _foregroundRunning = true;
          return null;
        case 'stopService':
          _foregroundRunning = false;
          return null;
        default:
          return null;
      }
    });

    await _setFlags(download: true);
    // No cross-test bleed: the singleton's `_initialized`/`_activeDownloads`/
    // throttle table *and* the spies are reset for every test.
    DownloadNotificationService.instance.debugResetForTest();
    expect(DownloadNotificationService.debugPostCount, 0);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notificationsChannel, null);
    messenger.setMockMethodCallHandler(_foregroundChannel, null);
    FlutterForegroundTask.resetStatic();
    debugDefaultTargetPlatformOverride = null;
  });

  // Declared first: `init()` is idempotent, so this test must observe the
  // first (and only) channel-creation call of the process.
  test('init creates the download channel even when CoreFlags.download is true',
      () async {
    expect(CoreFlags.download, isTrue,
        reason:
            'the suppression flag is on, which used to disable the service');

    final service = DownloadNotificationService.instance;
    await service.init();

    expect(_notifications.methods, contains('initialize'));
    final channelCall = _notifications.callOf('createNotificationChannel');
    expect(channelCall, isNotNull,
        reason: 'init must always create the notification channel');
    final args = channelCall!.arguments as Map<Object?, Object?>;
    expect(args['id'], 'download_progress');
  });

  test('on* before init is dropped, on* after init posts', () async {
    final service = DownloadNotificationService.instance;

    service.onDownloadStart(101, 'Example', 'example.apk');
    expect(DownloadNotificationService.debugPostCount, 0,
        reason: 'posting before init must be dropped (init-before-on* order)');

    await service.init();
    service.onDownloadStart(101, 'Example', 'example.apk');
    expect(DownloadNotificationService.debugPostCount, greaterThan(0),
        reason: 'init() must unblock the posting path');

    service.onDownloadComplete(101);
  });

  test('the five download callbacks each post after init', () async {
    final service = DownloadNotificationService.instance;
    await service.init();

    var posts = DownloadNotificationService.debugPostCount;
    expect(posts, 0, reason: 'init itself posts nothing');

    service.onDownloadStart(201, 'Example', 'example.apk');
    expect(DownloadNotificationService.debugPostCount, posts + 1,
        reason: 'start posts a progress notification');

    posts = DownloadNotificationService.debugPostCount;
    service.onDownloadProgress(201, 'Example', 'example.apk', 40, 100);
    expect(DownloadNotificationService.debugPostCount, posts + 1,
        reason: 'progress posts a progress notification');

    posts = DownloadNotificationService.debugPostCount;
    service.onDownloadComplete(201);
    expect(DownloadNotificationService.debugPostCount, posts + 1,
        reason: 'complete cancels/posts');

    posts = DownloadNotificationService.debugPostCount;
    service.onDownloadError(202, 'Example');
    expect(DownloadNotificationService.debugPostCount, posts + 1,
        reason: 'error posts a failure notification');

    posts = DownloadNotificationService.debugPostCount;
    service.onDownloadCancel(203);
    expect(DownloadNotificationService.debugPostCount, posts + 1,
        reason: 'cancel posts a removal');

    expect(_notifications.methods, contains('show'));
    expect(_notifications.methods, contains('cancel'));
    MethodCall? progressCall;
    for (final call in _notifications.calls) {
      if (call.method != 'show') continue;
      final args = call.arguments as Map<Object?, Object?>;
      final body = args['body'];
      if (body is String && body.contains('40%')) {
        progressCall = call;
        break;
      }
    }
    expect(progressCall, isNotNull,
        reason: 'the progress callback must publish 40%');
  });

  test('foreground service starts on start and stops when idle', () async {
    final service = DownloadNotificationService.instance;
    await service.init();

    service.onDownloadStart(401, 'Example', 'example.apk');
    await pumpEventQueue();
    expect(_foreground.methods, contains('startService'),
        reason: 'a download must start the foreground service');
    final startCall = _foreground.callOf('startService')!;
    final startArgs = startCall.arguments as Map<Object?, Object?>;
    expect(startArgs['serviceId'], 997);
    expect(startArgs['notificationContentTitle'], '后台下载中');

    service.onDownloadComplete(401);
    await pumpEventQueue();
    expect(_foreground.methods, contains('stopService'),
        reason: 'the last completed download must stop the foreground service');
  });

  test('requestPermission reaches the platform after init', () async {
    final service = DownloadNotificationService.instance;
    await service.init();

    await service.requestPermission();

    expect(_notifications.methods, contains('requestNotificationsPermission'));
  });
}
