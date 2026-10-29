/// Plan-Todo 11 — Dart 事件常量与模块事件流的类型化映射。
///
/// 断言：
/// 1. `AppEventTypes.channelChanged` / `catalogChanged` **字面等于** Rust 侧线名
///    （`gstore_core::event::EVT_CHANNEL_CHANGED` / `EVT_CATALOG_CHANGED`）。
/// 2. 模块事件流上的 `channel.changed` / `catalog.changed` 映射为**类型化**
///    `AppEvent`，且携带 payload（`key`/`kind`、`key`/`app_id`/`removed`），
///    并**同时**保留通用 `rust.event`（IN ADDITION）。
/// 3. 未知 `eventType` 仍然映射为 `rust.event`（不被丢弃），且不产生类型化事件。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

/// 构造与 Rust `push_core_event` 同形的模块事件正文：
/// `{"event": <wire>, "payload": <payload>}`（serde `tag=event, content=payload`）。
ModuleEvent _coreEvent(String eventType, Map<String, dynamic> payload) =>
    ModuleEvent(
      moduleId: BigInt.zero,
      instanceId: BigInt.zero,
      eventType: eventType,
      data: Uint8List.fromList(
        utf8.encode(jsonEncode({'event': eventType, 'payload': payload})),
      ),
      timestampMs: 0,
    );

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => AppEventBus.instance.resetGuards());

  group('AppEventTypes 常量等于 Rust 线名', () {
    test('channelChanged == "channel.changed"', () {
      expect(AppEventTypes.channelChanged, 'channel.changed');
    });

    test('catalogChanged == "catalog.changed"', () {
      expect(AppEventTypes.catalogChanged, 'catalog.changed');
    });
  });

  group('handleModuleEvent 类型化映射', () {
    test('channel.changed 映射为类型化 AppEvent 且携带 payload', () async {
      final bus = AppEventBus.instance;
      final typed = <AppEvent>[];
      final generic = <AppEvent>[];
      final subTyped = bus.on(AppEventTypes.channelChanged, typed.add);
      final subGeneric = bus.on(AppEventTypes.rustEvent, generic.add);
      addTearDown(() async {
        await subTyped.cancel();
        await subGeneric.cancel();
      });

      RustModuleManager.instance.handleModuleEvent(
        _coreEvent(AppEventTypes.channelChanged, {
          'key': 'js_vivo',
          'kind': 'js_local',
        }),
      );
      await _settle();

      // 类型化事件（source=rust）且 payload 被透传。
      expect(typed, hasLength(1));
      expect(typed.single.type, 'channel.changed');
      expect(typed.single.source, AppEventSource.rust);
      expect(typed.single.data?['key'], 'js_vivo');
      expect(typed.single.data?['kind'], 'js_local');

      // 通用 rust.event 仍在（IN ADDITION）。
      expect(generic, hasLength(1));
      expect(generic.single.data?['eventType'], 'channel.changed');
    });

    test('catalog.changed 映射为类型化 AppEvent 且携带 payload', () async {
      final bus = AppEventBus.instance;
      final typed = <AppEvent>[];
      final generic = <AppEvent>[];
      final subTyped = bus.on(AppEventTypes.catalogChanged, typed.add);
      final subGeneric = bus.on(AppEventTypes.rustEvent, generic.add);
      addTearDown(() async {
        await subTyped.cancel();
        await subGeneric.cancel();
      });

      RustModuleManager.instance.handleModuleEvent(
        _coreEvent(AppEventTypes.catalogChanged, {
          'key': 'local_db',
          'app_id': 'com.example.app',
          'removed': false,
        }),
      );
      await _settle();

      expect(typed, hasLength(1));
      expect(typed.single.type, 'catalog.changed');
      expect(typed.single.source, AppEventSource.rust);
      expect(typed.single.data?['key'], 'local_db');
      expect(typed.single.data?['app_id'], 'com.example.app');
      expect(typed.single.data?['removed'], false);

      expect(generic, hasLength(1));
      expect(generic.single.data?['eventType'], 'catalog.changed');
    });

    test('未知 eventType 仍映射为 rust.event 且不丢事件', () async {
      final bus = AppEventBus.instance;
      final generic = <AppEvent>[];
      final typedChannel = <AppEvent>[];
      final typedCatalog = <AppEvent>[];
      final subGeneric = bus.on(AppEventTypes.rustEvent, generic.add);
      final subChannel = bus.on(AppEventTypes.channelChanged, typedChannel.add);
      final subCatalog = bus.on(AppEventTypes.catalogChanged, typedCatalog.add);
      addTearDown(() async {
        await subGeneric.cancel();
        await subChannel.cancel();
        await subCatalog.cancel();
      });

      RustModuleManager.instance.handleModuleEvent(
        _coreEvent('proxy.stats', {'x': 1}),
      );
      await _settle();

      // 未知事件必须保留为通用 rust.event，不被丢弃。
      expect(generic, hasLength(1));
      expect(generic.single.type, AppEventTypes.rustEvent);
      expect(generic.single.data?['eventType'], 'proxy.stats');
      // 不得产生任何类型化领域事件。
      expect(typedChannel, isEmpty);
      expect(typedCatalog, isEmpty);
    });
  });
}
