// Todo 17: ConfigInitializer initializes the Rust config client.
//
// Covers:
//  * initialize() awaits ConfigStore.initialize() then ConfigService.ensureReady()
//  * idempotence: a second call is a no-op (no re-run of either step)
//  * a missing native bridge surfaces as a typed StateError and leaves the
//    initializer retryable (no half-initialized state)

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

/// Simulates the production failure when the native bridge cannot be loaded:
/// `ConfigApi.init()/list()` fails before any metadata is hydrated.
class _MissingBridgeClient implements ConfigApiClient {
  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    throw Exception('Failed to load dynamic library: native bridge missing');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Simulates a programming bug: an [Error] (not an [Exception]) must never be
/// relabeled as a bridge `StateError`.
class _ProgrammingBugClient implements ConfigApiClient {
  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    throw ArgumentError('BUG');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
  });

  tearDown(() {
    ConfigInitializer.debugReset();
    ConfigStore.instance.resetForTest();
  });

  test('initialize awaits ConfigStore then ConfigService once (idempotent)',
      () async {
    final calls = <String>[];
    ConfigInitializer.debugSetSteps(
      initializeStore: () async => calls.add('store.initialize'),
      ensureServiceReady: () async => calls.add('service.ensureReady'),
    );

    await ConfigInitializer.initialize();
    expect(calls, ['store.initialize', 'service.ensureReady']);
    expect(ConfigInitializer.debugInitialized, isTrue);

    await ConfigInitializer.initialize();
    expect(
      calls,
      ['store.initialize', 'service.ensureReady'],
      reason: '第二次调用应是 no-op，不得重复 initialize/ensureReady',
    );
    expect(ConfigInitializer.debugInitialized, isTrue);
  });

  test('second call does not re-run ConfigStore.initialize/ensureReady',
      () async {
    var storeCalls = 0;
    var ensureCalls = 0;
    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        storeCalls++;
      },
      ensureServiceReady: () async {
        ensureCalls++;
      },
    );

    await ConfigInitializer.initialize();
    await ConfigInitializer.initialize();
    await ConfigInitializer.initialize();

    expect(storeCalls, 1, reason: 'ConfigStore.initialize 只应执行一次');
    expect(ensureCalls, 1, reason: 'ConfigService.ensureReady 只应执行一次');
  });

  test('bridge Exception is wrapped as typed StateError and stays retryable',
      () async {
    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        // Production-shaped seam: ConfigService points at the Rust API, whose
        // native bridge is unavailable in this test.
        ConfigService.instance
            .debugSetApi(ConfigRustApi(_MissingBridgeClient()));
      },
      // ensureServiceReady uses the production implementation so the FFI
      // failure is normalized into a StateError.
    );

    await expectLater(
      ConfigInitializer.initialize(),
      throwsA(isA<StateError>()),
    );
    expect(
      ConfigInitializer.debugInitialized,
      isFalse,
      reason: '初始化失败不得把幂等标记置为 true（否则重试会被跳过）',
    );

    // Retry still runs both steps: the failed attempt did not corrupt state.
    final calls = <String>[];
    ConfigInitializer.debugSetSteps(
      initializeStore: () async => calls.add('store.initialize'),
      ensureServiceReady: () async => calls.add('service.ensureReady'),
    );
    await ConfigInitializer.initialize();
    expect(calls, ['store.initialize', 'service.ensureReady']);
    expect(ConfigInitializer.debugInitialized, isTrue);
  });

  test('programming Error propagates unchanged (never wrapped as StateError)',
      () async {
    ConfigInitializer.debugSetSteps(
      initializeStore: () async {
        // Same production seam, but the failure is a programming bug (Error).
        ConfigService.instance
            .debugSetApi(ConfigRustApi(_ProgrammingBugClient()));
      },
    );

    await expectLater(
      ConfigInitializer.initialize(),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.message, 'message', 'BUG'),
      ),
    );
    expect(
      ConfigInitializer.debugInitialized,
      isFalse,
      reason: '编程错误同样不得把初始化标记为完成',
    );
  });
}
