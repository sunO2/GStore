import 'dart:convert';
import 'dart:io';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/a2ui_render_validation.dart';

String _sample(String name) =>
    File('assets/a2ui/$name.json').readAsStringSync();

List<Object?> _decode(String name) =>
    jsonDecode(_sample(name)) as List<Object?>;

void main() {
  test('accepts the app card sample', () {
    final result = A2uiRenderValidation.validate(_sample('app_card'));
    expect(result.surfaceId, 'app-card');
    expect(result.componentCount, 10);
    expect(result.normalizedPayload, contains('createSurface'));
  });

  test('accepts payload as a decoded map/list', () {
    final result = A2uiRenderValidation.validate(_decode('filter_form'));
    expect(result.surfaceId, 'filter-form');
    expect(result.componentCount, greaterThan(0));
  });

  test('rejects invalid JSON', () {
    expect(
      () => A2uiRenderValidation.validate('{not json'),
      throwsA(
        isA<A2uiError>().having((e) => e.code, 'code', 'INVALID_JSON'),
      ),
    );
  });

  test('rejects unsupported components', () {
    final messages = _decode('app_card');
    final surface = messages.first as Map;
    final components =
        (surface['createSurface'] as Map)['components'] as List;
    (components.first as Map)['component'] = 'Video';
    expect(
      () => A2uiRenderValidation.validate(messages),
      throwsA(
        isA<A2uiError>().having(
          (e) => e.code,
          'code',
          'UNSUPPORTED_COMPONENT',
        ),
      ),
    );
  });

  test('accepts richer components in the whitelist', () {
    for (final name in ['Tabs', 'Icon', 'Image', 'Slider', 'DateTimeInput']) {
      expect(A2uiRenderValidation.allowedComponents, contains(name));
    }
    // 仍排除大体积媒体与弹层。
    expect(A2uiRenderValidation.allowedComponents, isNot(contains('Video')));
    expect(A2uiRenderValidation.allowedComponents, isNot(contains('AudioPlayer')));
    expect(A2uiRenderValidation.allowedComponents, isNot(contains('Modal')));
  });

  test('rejects local functionCall actions', () {
    final messages = _decode('app_card');
    final surface = messages.first as Map;
    final components =
        (surface['createSurface'] as Map)['components'] as List;
    final install = components.firstWhere(
      (c) => (c as Map)['id'] == 'install',
    ) as Map;
    install['action'] = {
      'functionCall': {
        '@call': 'openUrl',
        'args': {'url': 'https://example.com'},
      },
    };
    expect(
      () => A2uiRenderValidation.validate(messages),
      throwsA(
        isA<A2uiError>().having((e) => e.code, 'code', 'UNSUPPORTED_ACTION'),
      ),
    );
  });

  test('rejects a different catalog', () {
    final messages = _decode('app_card');
    final surface = messages.first as Map;
    (surface['createSurface'] as Map)['catalogId'] = 'https://example.com/c.json';
    expect(
      () => A2uiRenderValidation.validate(messages),
      throwsA(
        isA<A2uiError>().having((e) => e.code, 'code', 'UNSUPPORTED_CATALOG'),
      ),
    );
  });

  test('rejects sendDataModel=true', () {
    final messages = _decode('app_card');
    final surface = messages.first as Map;
    (surface['createSurface'] as Map)['sendDataModel'] = true;
    expect(
      () => A2uiRenderValidation.validate(messages),
      throwsA(
        isA<A2uiError>().having((e) => e.code, 'code', 'UNSUPPORTED_PRIVACY'),
      ),
    );
  });

  test('rejects too many components', () {
    final components = <Map<String, Object?>>[
      {
        'id': 'root',
        'component': 'Column',
        'children': [
          for (var i = 0; i < 60; i++) 't$i',
        ],
      },
      for (var i = 0; i < 60; i++)
        {'id': 't$i', 'component': 'Text', 'text': 'item $i'},
    ];
    final messages = [
      {
        'version': '1.0',
        'createSurface': {
          'surfaceId': 'too-many',
          'catalogId': A2uiRenderValidation.catalogId,
          'components': components,
        },
      },
    ];
    expect(
      () => A2uiRenderValidation.validate(messages),
      throwsA(
        isA<A2uiError>().having(
          (e) => e.code,
          'code',
          'TOO_MANY_COMPONENTS',
        ),
      ),
    );
  });
}
