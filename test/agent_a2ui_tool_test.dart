import 'dart:io';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

String _sample(String name) =>
    File('assets/a2ui/$name.json').readAsStringSync();

void main() {
  test('renderA2ui is registered with a loadable protocol', () {
    final spec = AgentToolCatalog.byName(AgentService.renderA2uiToolName);
    expect(spec, isNotNull);
    expect(spec!.group, AgentToolGroup.interact);
    expect(spec.protocol, contains('createSurface'));
    expect(spec.protocol, contains('loadProtocol'));
  });

  test('renderA2ui tool accepts a valid payload', () async {
    final service = AgentService();
    final result = await service.runTool(
      AgentService.renderA2uiToolName,
      {'payload': _sample('filter_form')},
    );
    expect(result, contains('UI 已渲染'));
    expect(result, contains('filter-form'));
  });

  test('renderA2ui tool rejects an invalid payload', () async {
    final service = AgentService();
    await expectLater(
      service.runTool(
        AgentService.renderA2uiToolName,
        {'payload': '{"version":"1.0"}'},
      ),
      throwsA(isA<A2uiError>()),
    );
  });
}
