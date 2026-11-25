import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/page/agent/inline_card_registry.dart';

/// 构造一条工具消息；默认是已完成的 `showConfigSwitch` 调用。
AgentMessage _msg({
  bool isToolResult = true,
  String? toolName = AgentService.showConfigSwitchToolName,
  AgentToolStatus? toolStatus = AgentToolStatus.done,
  Map<String, dynamic>? toolArgs,
  String? toolResult,
}) {
  return AgentMessage(
    isUser: false,
    text: '',
    isToolResult: isToolResult,
    toolName: toolName,
    toolStatus: toolStatus,
    toolArgs: toolArgs,
    toolResult: toolResult,
  );
}

Map<String, dynamic> _args(String key) {
  return <String, dynamic>{'key': key};
}

void main() {
  group('switchForInlineCard（仅显式 showConfigSwitch）', () {
    test('done + canonical key returns the matching spec', () {
      final spec = switchForInlineCard(
        _msg(toolArgs: _args(ConfigKeys.downloadWifiOnly)),
      );

      expect(spec, isNotNull);
      expect(spec!.configKey, ConfigKeys.downloadWifiOnly);
      expect(spec.title, '仅 Wi-Fi 下载');
    });

    test('done + alias 分段下载 resolves to the multi-segment spec', () {
      final spec = switchForInlineCard(
        _msg(toolArgs: _args('分段下载')),
      );

      expect(spec, isNotNull);
      expect(spec!.configKey, ConfigKeys.downloadMultiSegmentEnabled);
    });

    test('done + alias 仅wifi resolves to the wifi-only spec', () {
      final spec = switchForInlineCard(
        _msg(toolArgs: _args('仅wifi')),
      );

      expect(spec, isNotNull);
      expect(spec!.configKey, ConfigKeys.downloadWifiOnly);
    });

    test('configManager messages never derive implicit cards', () {
      for (final action in <String>['get', 'set', 'list', 'clear']) {
        final spec = switchForInlineCard(
          _msg(
            toolName: AgentService.configManagerToolName,
            toolArgs: <String, dynamic>{
              'action': action,
              'key': ConfigKeys.downloadWifiOnly,
            },
            toolResult: '{"key":"${ConfigKeys.downloadWifiOnly}"}',
          ),
        );
        expect(spec, isNull, reason: 'configManager $action should not derive');
      }
    });

    test('running or error status returns null', () {
      for (final status in <AgentToolStatus>[
        AgentToolStatus.running,
        AgentToolStatus.error,
      ]) {
        final spec = switchForInlineCard(
          _msg(
            toolStatus: status,
            toolArgs: _args(ConfigKeys.downloadWifiOnly),
          ),
        );
        expect(spec, isNull, reason: 'status=$status should be rejected');
      }
    });

    test('non tool-result message returns null', () {
      final spec = switchForInlineCard(
        _msg(
          isToolResult: false,
          toolArgs: _args(ConfigKeys.downloadWifiOnly),
        ),
      );

      expect(spec, isNull);
    });

    test('other tools return null', () {
      for (final name in <String>['downloadApp', 'confirmAction', 'loadProtocol']) {
        final spec = switchForInlineCard(
          _msg(
            toolName: name,
            toolArgs: _args(ConfigKeys.downloadWifiOnly),
          ),
        );
        expect(spec, isNull, reason: 'tool=$name should be rejected');
      }
    });

    test('null, empty or unknown key returns null', () {
      expect(switchForInlineCard(_msg()), isNull);
      expect(
        switchForInlineCard(_msg(toolArgs: <String, dynamic>{})),
        isNull,
      );
      expect(switchForInlineCard(_msg(toolArgs: _args(''))), isNull);
      expect(
        switchForInlineCard(
          _msg(toolArgs: _args(ConfigKeys.downloadMaxConcurrent)),
        ),
        isNull,
      );
      expect(
        switchForInlineCard(_msg(toolArgs: _args('unknown.key'))),
        isNull,
      );
    });
  });

  group('AgentInlineCards.switchForKey', () {
    test('returns null for null or unknown key', () {
      expect(AgentInlineCards.switchForKey(null), isNull);
      expect(AgentInlineCards.switchForKey('unknown.key'), isNull);
      expect(AgentInlineCards.switchForKey(''), isNull);
    });

    test('returns spec for every whitelisted key', () {
      for (final spec in AgentInlineCards.switchSpecs) {
        expect(AgentInlineCards.switchForKey(spec.configKey), same(spec));
      }
    });

    test('never returns non-switch kinds', () {
      expect(AgentInlineCards.switchForKey(ConfigKeys.downloadMaxConcurrent),
          isNull);
      expect(AgentInlineCards.switchForKey(ConfigKeys.themeMode), isNull);
    });
  });

  group('AgentInlineCards.controlForKey', () {
    test('bool key resolves to switchControl', () {
      final spec = AgentInlineCards.controlForKey(ConfigKeys.downloadWifiOnly);
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.switchControl);
      expect(spec.valueType, 'bool');
    });

    test('download.max_concurrent resolves to a 1-10 integer slider', () {
      final spec =
          AgentInlineCards.controlForKey(ConfigKeys.downloadMaxConcurrent);
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.slider);
      expect(spec.min, 1);
      expect(spec.max, 10);
      expect(spec.step, 1);
      expect(spec.valueType, 'int');
    });

    test('download.max_retries resolves to a 0-5 slider', () {
      final spec = AgentInlineCards.controlForKey(ConfigKeys.downloadMaxRetries);
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.slider);
      expect(spec.min, 0);
      expect(spec.max, 5);
    });

    test('update.auto_update_policy resolves to segmented with labels', () {
      final spec =
          AgentInlineCards.controlForKey(ConfigKeys.updateAutoUpdatePolicy);
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.segmented);
      expect(spec.enumValues, ['never', 'wifi_only', 'always']);
      expect(spec.enumLabels!['wifi_only'], '仅 Wi-Fi');
      expect(spec.valueType, 'string');
    });

    test('theme.mode resolves to int segmented', () {
      final spec = AgentInlineCards.controlForKey(ConfigKeys.themeMode);
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.segmented);
      expect(spec.enumValues, ['0', '1', '2']);
      expect(spec.valueType, 'int');
    });

    test('alias 并发下载 resolves to max-concurrent spec', () {
      final spec = AgentInlineCards.controlForKey('并发下载');
      expect(spec, isNotNull);
      expect(spec!.configKey, ConfigKeys.downloadMaxConcurrent);
    });

    test('kind mismatch returns null', () {
      expect(
        AgentInlineCards.controlForKey(
          ConfigKeys.downloadMaxConcurrent,
          kind: 'switch',
        ),
        isNull,
      );
      expect(
        AgentInlineCards.controlForKey(
          ConfigKeys.downloadMultiSegmentEnabled,
          kind: 'slider',
        ),
        isNull,
      );
      expect(
        AgentInlineCards.controlForKey(
          ConfigKeys.downloadWifiOnly,
          kind: 'segmented',
        ),
        isNull,
      );
    });

    test('unknown kind returns null', () {
      expect(
        AgentInlineCards.controlForKey(
          ConfigKeys.downloadWifiOnly,
          kind: 'unknown',
        ),
        isNull,
      );
    });

    test('unknown key returns null', () {
      expect(AgentInlineCards.controlForKey(null), isNull);
      expect(AgentInlineCards.controlForKey(''), isNull);
      expect(AgentInlineCards.controlForKey('unknown.key'), isNull);
    });
  });

  group('controlForInlineCard', () {
    test('showConfigControl slider key without type derives slider', () {
      final spec = controlForInlineCard(
        _msg(
          toolName: AgentService.showConfigControlToolName,
          toolArgs: _args(ConfigKeys.downloadMaxConcurrent),
        ),
      );

      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.slider);
      expect(spec.configKey, ConfigKeys.downloadMaxConcurrent);
    });

    test('showConfigControl with mismatched type returns null', () {
      final spec = controlForInlineCard(
        _msg(
          toolName: AgentService.showConfigControlToolName,
          toolArgs: <String, dynamic>{
            'key': ConfigKeys.downloadMaxConcurrent,
            'type': 'switch',
          },
        ),
      );

      expect(spec, isNull);
    });

    test('showConfigSwitch still derives switch specs only', () {
      final spec = controlForInlineCard(
        _msg(toolArgs: _args(ConfigKeys.downloadWifiOnly)),
      );
      expect(spec, isNotNull);
      expect(spec!.kind, AgentInlineControlKind.switchControl);
    });
  });

  group('AgentInlineCards.controlsInText', () {
    test('分段下载开关状态 resolves to the multi-segment switch', () {
      final specs = AgentInlineCards.controlsInText('查询分段下载开关状态');
      expect(specs, hasLength(1));
      expect(specs.single.configKey, ConfigKeys.downloadMultiSegmentEnabled);
      expect(specs.single.kind, AgentInlineControlKind.switchControl);
    });

    test('把最大并发调到 5 resolves to the max-concurrent slider', () {
      final specs = AgentInlineCards.controlsInText('把最大并发调到 5');
      expect(specs, hasLength(1));
      expect(specs.single.configKey, ConfigKeys.downloadMaxConcurrent);
      expect(specs.single.kind, AgentInlineControlKind.slider);
    });

    test('自动更新策略改成仅 Wi-Fi resolves to the auto-update policy', () {
      final specs = AgentInlineCards.controlsInText('自动更新策略改成仅 Wi-Fi');
      expect(specs, hasLength(1));
      expect(specs.single.configKey, ConfigKeys.updateAutoUpdatePolicy);
      expect(specs.single.kind, AgentInlineControlKind.segmented);
    });

    test('主题模式改成深色 resolves to the theme.mode segmented', () {
      final specs = AgentInlineCards.controlsInText('主题模式改成深色');
      expect(specs, hasLength(1));
      expect(specs.single.configKey, ConfigKeys.themeMode);
      expect(specs.single.kind, AgentInlineControlKind.segmented);
    });

    test('深浅色主题设置 also resolves to the theme.mode segmented', () {
      final specs = AgentInlineCards.controlsInText('深浅色主题设置');
      expect(specs, hasLength(1));
      expect(specs.single.configKey, ConfigKeys.themeMode);
      expect(specs.single.kind, AgentInlineControlKind.segmented);
    });

    test('unrelated text returns empty', () {
      expect(AgentInlineCards.controlsInText('帮我下载一个笔记应用'), isEmpty);
      expect(AgentInlineCards.controlsInText(''), isEmpty);
      expect(AgentInlineCards.controlsInText('   '), isEmpty);
    });

    test('two mentioned controls are returned in whitelist order', () {
      // 文本顺序反过来，结果仍应按白名单顺序（分段下载在前，主题模式在后）。
      final specs = AgentInlineCards.controlsInText('主题模式改成深色，顺便看看分段下载开关');
      expect(specs.map((s) => s.configKey).toList(), <String>[
        ConfigKeys.downloadMultiSegmentEnabled,
        ConfigKeys.themeMode,
      ]);
    });
  });

  group('whitelist hygiene', () {
    test('every spec maps to a bool, agent-accessible, non-sensitive entry', () {
      for (final spec in AgentInlineCards.switchSpecs) {
        final matches = ConfigRegistry.entries
            .where((entry) => entry.key == spec.configKey)
            .toList();

        expect(
          matches,
          hasLength(1),
          reason: 'missing registry entry for ${spec.configKey}',
        );

        final entry = matches.single;
        expect(entry.type, ConfigValueType.bool);
        expect(entry.agentAccessible, isTrue);
        expect(entry.sensitive, isFalse);
      }
    });

    test('specs have non-empty copy and unique keys', () {
      final keys = <String>{};
      for (final spec in AgentInlineCards.controlSpecs) {
        expect(spec.title.trim(), isNotEmpty);
        expect(spec.subtitle.trim(), isNotEmpty);
        expect(keys.add(spec.configKey), isTrue,
            reason: 'duplicate key ${spec.configKey}');
      }
    });

    test('aliases are non-empty and unique within each spec', () {
      for (final spec in AgentInlineCards.controlSpecs) {
        final aliases = <String>{};
        for (final alias in spec.aliases) {
          expect(alias.trim(), isNotEmpty);
          expect(aliases.add(alias), isTrue,
              reason: 'duplicate alias $alias for ${spec.configKey}');
        }
      }
    });
  });
}
