import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/a2ui_payload_normalizer.dart';
import 'package:gstore/core/agent/a2ui_render_validation.dart';

Map<String, Object?> _message(List<Object?> components) => {
      'version': '1.0',
      'createSurface': <String, Object?>{
        'surfaceId': 'products',
        'catalogId': BasicCatalog.v1_0Id,
        'dataModel': <String, Object?>{
          'products': [
            {
              'name': '稳稳盈 A',
              'code': 'A001',
              'acc': '1.23%',
              'yes': '+0.45%',
              'nav': '1.0456',
              'val': '12.3 万',
            },
          ],
        },
        'components': components,
      },
    };

List<Object?> _legacyComponents() => [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['list'],
      },
      {
        'id': 'list',
        'component': 'List',
        'children': {'path': '/products', 'componentId': 'tpl'},
      },
      {'id': 'tpl', 'component': 'Card', 'child': 'col'},
      {
        'id': 'col',
        'component': 'Column',
        'children': ['head', 'name', 'code', 'row', 'status'],
      },
      {
        'id': 'head',
        'component': 'Row',
        'children': ['nameLabel', 'valLabel'],
      },
      {'id': 'nameLabel', 'component': 'Text', 'text': r'$name'},
      {'id': 'valLabel', 'component': 'Text', 'text': r'$val'},
      {'id': 'name', 'component': 'Text', 'text': r'$name'},
      {'id': 'code', 'component': 'Text', 'text': r'$code'},
      {
        'id': 'row',
        'component': 'Row',
        'children': ['acc', 'yes', 'nav'],
      },
      {'id': 'acc', 'component': 'Text', 'text': r'累计 $acc'},
      {'id': 'yes', 'component': 'Text', 'text': r'日 $yes'},
      {'id': 'nav', 'component': 'Text', 'text': r'净值 $nav'},
    ];

Future<void> _pump(WidgetTester tester, List<Map<String, Object?>> messages) async {
  final processor = MessageProcessor<ComponentImplementation>(
    catalogs: [basicCatalog(locale: 'zh-CN')],
  );
  final surfaces = <SurfaceModel<ComponentImplementation>>[];
  processor.model.onSurfaceCreated.subscribe(surfaces.add);
  processor.processMessages(messages);
  addTearDown(processor.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: A2uiSurface(surface: surfaces.single),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('normalizeA2uiBindings', () {
    test('整串绑定改成 @path', () {
      final messages = normalizeA2uiBindings([
        _message([
          {'id': 'a', 'component': 'Text', 'text': r'$name'},
          {'id': 'b', 'component': 'Text', 'text': r'$/products/0/nav'},
          {'id': 'c', 'component': 'Text', 'text': r'${acc}'},
        ]),
      ]);
      final components =
          ((messages.single['createSurface'] as Map)['components'] as List);
      expect((components[0] as Map)['text'], {'@path': 'name'});
      expect((components[1] as Map)['text'], {'@path': '/products/0/nav'});
      expect((components[2] as Map)['text'], {'@path': 'acc'});
    });

    test('旧版 {"path": ...} 绑定也转换成 @path', () {
      final messages = normalizeA2uiBindings([
        _message([
          {'id': 'a', 'component': 'Text', 'text': {'path': 'name'}},
          {
            'id': 'b',
            'component': 'TextField',
            'label': '关键词',
            'value': {'path': '/form/keyword'},
          },
          {
            'id': 'list',
            'component': 'List',
            'children': {'path': '/products', 'componentId': 'tpl'},
          },
        ]),
      ]);
      final components =
          ((messages.single['createSurface'] as Map)['components'] as List);
      expect((components[0] as Map)['text'], {'@path': 'name'});
      expect((components[1] as Map)['value'], {'@path': '/form/keyword'});
      // 列表模板（带 componentId）必须保持原样
      expect((components[2] as Map)['children'], {
        'path': '/products',
        'componentId': 'tpl',
      });
    });

    test('混合文本拆成 Row + Text 片段', () {
      final messages = normalizeA2uiBindings([
        _message([
          {'id': 'acc', 'component': 'Text', 'text': r'累计 $acc', 'variant': 'caption'},
        ]),
      ]);
      final components =
          ((messages.single['createSurface'] as Map)['components'] as List);
      expect(components, hasLength(3));
      final row = components.first as Map;
      expect(row['component'], 'Row');
      expect(row['id'], 'acc');
      final children = (row['children'] as List).cast<String>();
      expect(children, hasLength(2));
      expect((components[1] as Map)['text'], '累计');
      expect((components[2] as Map)['text'], {'@path': 'acc'});
      expect((components[2] as Map)['variant'], 'caption');
    });

    test('不改动普通文本、结构字段与无法解析的表达式', () {
      final messages = normalizeA2uiBindings([
        _message([
          {'id': 'a', 'component': 'Text', 'text': r'普通文本 \$9.99'},
          {'id': 'b', 'component': 'Text', 'text': r'合计 ${formatNumber(x)}'},
          {'id': 'c', 'component': 'Row', 'children': [r'$name']},
        ]),
      ]);
      final components =
          ((messages.single['createSurface'] as Map)['components'] as List);
      expect((components[0] as Map)['text'], r'普通文本 \$9.99');
      expect((components[1] as Map)['text'], r'合计 ${formatNumber(x)}');
      expect((components[2] as Map)['children'], [r'$name']);
    });

    test('action context 里的整串绑定也会转换', () {
      final messages = normalizeA2uiBindings([
        _message([
          {
            'id': 'btn',
            'component': 'Button',
            'child': 'label',
            'action': {
              'event': {
                'name': 'install',
                'context': {'pkg': r'$code'},
              },
            },
          },
          {'id': 'label', 'component': 'Text', 'text': '安装'},
        ]),
      ]);
      final button =
          ((messages.single['createSurface'] as Map)['components'] as List)[0]
              as Map;
      final context = (((button['action'] as Map)['event'] as Map)['context']
          as Map);
      expect(context['pkg'], {'@path': 'code'});
    });

    test('生成的子组件 id 不与已有 id 冲突', () {
      final messages = normalizeA2uiBindings([
        _message([
          {'id': 't', 'component': 'Text', 'text': r'$a / $b'},
          {'id': 't__s0', 'component': 'Text', 'text': '占位'},
        ]),
      ]);
      final components =
          ((messages.single['createSurface'] as Map)['components'] as List);
      final ids = components.map((c) => (c as Map)['id']).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('legacy payload renders', () {
    testWidgets(r'列表模板里的 $name / 累计 $acc 能解析成真实数据', (tester) async {
      final messages = normalizeA2uiBindings([_message(_legacyComponents())]);
      await _pump(tester, messages);

      expect(tester.takeException(), isNull);
      expect(find.text('稳稳盈 A'), findsNWidgets(2));
      expect(find.text('A001'), findsOneWidget);
      expect(find.text('12.3 万'), findsOneWidget);
      expect(find.text('累计'), findsOneWidget);
      expect(find.text('1.23%'), findsOneWidget);
      expect(find.text('日'), findsOneWidget);
      expect(find.text('+0.45%'), findsOneWidget);
      expect(find.text('净值'), findsOneWidget);
      expect(find.text('1.0456'), findsOneWidget);
      // 不应再出现占位符
      expect(find.textContaining(r'$name'), findsNothing);
      expect(find.textContaining(r'$acc'), findsNothing);
    });

    testWidgets('归一化后的 payload 仍通过协议校验', (tester) async {
      final messages = normalizeA2uiBindings([_message(_legacyComponents())]);
      final result = A2uiRenderValidation.validate(messages);
      expect(result.surfaceId, 'products');
    });
  });
}
