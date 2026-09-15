import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/it_tools/tool_list.dart';

/// 工具清单的解析与展示回归测试。
///
/// - `parseItToolsToolGroups`：页面 → App 的数据边界，各平台解码不一致，
///   结构不符必须降级（少几个工具）而不是让整页崩掉；
/// - `ItToolListSheet`：80+ 项的面板，打开时必须定位到当前工具。
void main() {
  group('parseItToolsToolGroups', () {
    test('接受已解码的 List<Map> 结构（Android 常见形态）', () {
      final groups = parseItToolsToolGroups([
        {
          'category': '加密',
          'tools': [
            {'path': '/bcrypt', 'name': 'bcrypt', 'description': '哈希'},
            {'path': '/hash-text', 'name': '文本哈希', 'description': ''},
          ],
        },
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.category, '加密');
      expect(
        groups.single.tools.map((t) => t.path).toList(),
        ['/bcrypt', '/hash-text'],
      );
      expect(groups.single.tools.first.name, 'bcrypt');
      expect(groups.single.tools.first.description, '哈希');
    });

    test('也接受 JSON 字符串（部分平台按原样传递）', () {
      final payload = jsonEncode([
        {
          'category': '网络',
          'tools': [
            {'path': '/ipv4', 'name': 'IPv4', 'description': 'd'},
          ],
        },
      ]);

      final groups = parseItToolsToolGroups(payload);

      expect(groups, hasLength(1));
      expect(groups.single.tools.single.path, '/ipv4');
    });

    test('结构不符的条目被跳过，不影响其余有效条目', () {
      final groups = parseItToolsToolGroups([
        'not-a-map',
        {'category': '缺少 tools'},
        {'category': 'tools 不是列表', 'tools': 'oops'},
        {'category': '', 'tools': <Object>[]},
        {
          'category': '有效',
          'tools': [
            'bad',
            {'path': '', 'name': '空路径'},
            {'name': '缺路径'},
            {'path': '/ok', 'name': 'OK', 'description': 123},
          ],
        },
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.category, '有效');
      expect(groups.single.tools, hasLength(1));
      expect(groups.single.tools.single.path, '/ok');
      // description 非字符串时退化为空串，而不是抛出
      expect(groups.single.tools.single.description, '');
    });

    test('非清单输入返回空列表', () {
      expect(parseItToolsToolGroups(null), isEmpty);
      expect(parseItToolsToolGroups('not json'), isEmpty);
      expect(parseItToolsToolGroups(42), isEmpty);
      expect(parseItToolsToolGroups(<Object>[]), isEmpty);
    });
  });

  group('ItToolListSheet', () {
    List<ItToolGroup> buildGroups(int count) => [
          ItToolGroup(
            category: '全部工具',
            tools: [
              for (var i = 0; i < count; i++)
                ItToolItem(
                  path: '/tool-$i',
                  name: '工具 $i',
                  description: '说明 $i',
                ),
            ],
          ),
        ];

    Finder tileOf(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(ListTile));

    testWidgets('打开时自动把当前工具滚到可视区', (tester) async {
      // 当前工具排在很靠后的位置：不定位的话必然在首屏之外
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ItToolListSheet(
            groups: buildGroups(80),
            currentPath: '/tool-70',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final tileRect = tester.getRect(tileOf('工具 70').first);
      final sheetRect = tester.getRect(find.byType(ItToolListSheet));

      expect(
        tileRect.top,
        greaterThanOrEqualTo(sheetRect.top - 1),
        reason: '当前工具应在可视区内（上边界）',
      );
      expect(
        tileRect.bottom,
        lessThanOrEqualTo(sheetRect.bottom + 1),
        reason: '当前工具应在可视区内（下边界）',
      );
    });

    testWidgets('当前工具不在清单里（如停在工具首页）时不报错', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ItToolListSheet(
            groups: buildGroups(80),
            currentPath: '/',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ListTile), findsWidgets);
    });

    testWidgets('按关键字过滤后只剩匹配项', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ItToolListSheet(
            groups: buildGroups(80),
            currentPath: '/',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '工具 7');
      await tester.pumpAndSettle();

      // 命中「工具 7」「工具 70..79」共 11 项；用 ListTile 限定，
      // 否则 find.text 还会匹配到输入框自身的 EditableText
      expect(find.widgetWithText(ListTile, '工具 8'), findsNothing);
      expect(find.widgetWithText(ListTile, '工具 7'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(11));
    });
  });
}
