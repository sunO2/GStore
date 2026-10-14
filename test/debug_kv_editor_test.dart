/// `DebugKvEditor` / `DebugKvRow` 组件测试（plan todo 2 + 11 + 12 + 16）。
///
/// Wave 6：行是**只读键 / 值文字预览**（点击不编辑），唯一交互是**长按整行**；
/// 键值编辑面（键 + 值表单弹层、插入变量 / 建议 chips / 上一个·下一个字段）属于
/// 页面私有弹层，由页面级测试覆盖，不在本组件测试范围。
///
/// 覆盖验收：
/// - 3 行渲染：name/value 键齐全；非排序模式无 drag/delete/expand 常驻键；
/// - 排序模式开启后行尾出现 drag 手柄，关闭后隐藏；
/// - 重复非空键显示 dup 提示，唯一键不显示；
/// - 每行后有浅分隔线；
/// - 长按行触发 onRowLongPress → 移除一行且不抛 disposed-controller；
/// - 点击键 / 值预览不打开任何编辑面（只读预览）；
/// - 窄屏 360x640 / 320x568 无 overflow，行仍可长按。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/page/request_debug/debug_kv_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<DebugKvRow> seed(List<(String, String)> pairs) => <DebugKvRow>[
        for (var i = 0; i < pairs.length; i++)
          DebugKvRow(id: 'row-$i', name: pairs[i].$1, value: pairs[i].$2),
      ];

  /// 以 StatefulBuilder 托管 [rows]，把组件回调接到真实的列表变更上。
  ///
  /// [removeOnLongPress] 为 true 时组件级模拟页面「长按 → 删除弹层确认」后的
  /// 移除；需要仅断言「长按命中该行」时置 false，避免行被移除干扰后续断言。
  Widget harness({
    required List<DebugKvRow> rows,
    bool allowDisable = false,
    bool sortMode = false,
    ValueChanged<DebugKvRow>? onRowLongPress,
    bool removeOnLongPress = true,
  }) {
    // 本地可变排序状态：`onToggleSort` 切换后 setState 重建。
    var sort = sortMode;
    return MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => DebugKvEditor(
            rows: rows,
            keyPrefix: 'kv',
            nameHint: '名称',
            addLabel: '添加',
            addKey: const Key('kv-add'),
            allowDisable: allowDisable,
            onChanged: () => setState(() {}),
            onRemove: (row) => setState(() => rows.remove(row)),
            onReordered: (oldIndex, newIndex) => setState(() {
              final row = rows.removeAt(oldIndex);
              rows.insert(newIndex, row);
            }),
            onAdd: () =>
                setState(() => rows.add(DebugKvRow(id: 'new-${rows.length}'))),
            onBulkEdit: () {},
            sortMode: sort,
            onToggleSort: () => setState(() => sort = !sort),
            // 组件级模拟页面「长按 → 删除弹层确认」后的移除：回调后出列表。
            onRowLongPress: (row) {
              onRowLongPress?.call(row);
              if (removeOnLongPress) setState(() => rows.remove(row));
            },
          ),
        ),
      ),
    );
  }

  group('DebugKvEditor · 行渲染', () {
    testWidgets('3 行渲染：name/value 键齐全、非常驻动作键', (tester) async {
      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('kv-name-$i')), findsOneWidget);
        expect(find.byKey(Key('kv-value-$i')), findsOneWidget);
        // Wave 6：非排序模式不得有常驻拖拽手柄；行内无删除常驻按钮。
        expect(find.byKey(Key('kv-drag-$i')), findsNothing);
        expect(find.byKey(Key('kv-delete-$i')), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('排序模式：行尾出现拖拽手柄，关闭后隐藏', (tester) async {
      final rows = seed([('a', '1'), ('b', '2')]);
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kv-drag-0')), findsNothing);

      await tester.tap(find.byKey(const Key('request-editor-kv-sort')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('kv-drag-0')), findsOneWidget);
      expect(find.byKey(const Key('kv-drag-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-editor-kv-sort')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('kv-drag-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重复键显示 dup 提示，唯一键无提示', (tester) async {
      final rows = seed([('dup', '1'), ('dup', '2'), ('unique', '3')]);
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kv-dup-0')), findsOneWidget);
      expect(find.byKey(const Key('kv-dup-1')), findsOneWidget);
      expect(find.byKey(const Key('kv-dup-2')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('每行后有浅分隔线', (tester) async {
      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      expect(find.byType(Divider), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表仅页脚仍在', (tester) async {
      final rows = <DebugKvRow>[];
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kv-add')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-kv-bulk')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-kv-sort')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('allowDisable 渲染复选框', (tester) async {
      final rows = seed([('a', '1')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: true));
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('allowDisable 切换复选框翻转 row.enabled', (tester) async {
      final rows = seed([('a', '1')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: true));
      await tester.pumpAndSettle();

      expect(rows.first.enabled, isTrue);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(
        rows.first.enabled,
        isFalse,
        reason: '点击复选框应翻转该行的 enabled',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('DebugKvEditor · 删除', () {
    testWidgets('长按行触发 onRowLongPress 并移除该行且不抛 disposed-controller',
        (tester) async {
      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      final target = rows.first;
      DebugKvRow? pressed;
      await tester.pumpWidget(harness(
        rows: rows,
        onRowLongPress: (row) => pressed = row,
      ));
      await tester.pumpAndSettle();

      // 长按整行（以名称预览为落点）→ 组件回调删除。
      await tester.longPress(find.byKey(const Key('kv-name-0')));
      await tester.pumpAndSettle();

      expect(pressed, same(target), reason: '长按须回调被长按的那一行');
      expect(rows.length, 2);
      expect(rows.contains(target), isFalse);
      expect(find.byKey(const Key('kv-name-2')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('DebugKvEditor · 只读预览 / 长按', () {
    testWidgets('点击键 / 值预览不打开任何编辑面（只读）', (tester) async {
      final rows = seed([('a', '1')]);
      await tester.pumpWidget(harness(rows: rows));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('kv-name-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('kv-value-0')));
      await tester.pumpAndSettle();

      // Wave 6：行内预览无 sheet，点击不产生任何编辑面 / 工具栏。
      expect(find.byKey(const Key('request-editor-field-sheet')), findsNothing);
      expect(find.byKey(const Key('request-editor-kv-row-editor')), findsNothing);
      expect(find.byKey(const Key('editor-toolbar-paste')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按键 / 值预览均命中该行回调（不下沉为点击）', (tester) async {
      final rows = seed([('a', '1'), ('b', '2')]);
      final pressed = <DebugKvRow>[];
      await tester.pumpWidget(harness(
        rows: rows,
        removeOnLongPress: false,
        onRowLongPress: pressed.add,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const Key('kv-name-0')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('kv-value-1')));
      await tester.pumpAndSettle();

      expect(pressed, <DebugKvRow>[rows[0], rows[1]]);
      // 只读预览：长按不改变行集合。
      expect(rows.length, 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('DebugKvEditor · 窄屏', () {
    void setViewport(WidgetTester tester, double w, double h) {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('360x640 渲染无 overflow（allowDisable true）', (tester) async {
      setViewport(tester, 360, 640);

      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: true));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kv-name-0')), findsOneWidget);
      expect(find.byKey(const Key('kv-value-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360x640 渲染无 overflow（allowDisable false）', (tester) async {
      setViewport(tester, 360, 640);

      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kv-name-0')), findsOneWidget);
      expect(find.byKey(const Key('kv-value-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320x568 极窄屏渲染不抛异常', (tester) async {
      setViewport(tester, 320, 568);

      final rows = seed([('a', '1'), ('b', '2'), ('c', '3')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: true));
      await tester.pumpAndSettle();

      // 极窄屏不得抛 overflow / 布局异常；键值仍可渲染。
      expect(find.byKey(const Key('kv-name-0')), findsOneWidget);
      expect(find.byKey(const Key('kv-value-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320x568 极窄屏（allowDisable=true，含空行）无 overflow 且行可长按',
        (tester) async {
      setViewport(tester, 320, 568);

      // 中间为一行空键空值：预览呈现 hint，不得触发布局异常。
      final rows = seed([('a', '1'), ('', ''), ('b', '2')]);
      final target = rows[1];
      DebugKvRow? pressed;
      await tester.pumpWidget(harness(
        rows: rows,
        allowDisable: true,
        removeOnLongPress: false,
        onRowLongPress: (row) => pressed = row,
      ));
      await tester.pumpAndSettle();

      // 三行（含空行）键 / 值预览均渲染，且无 overflow / 异常。
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('kv-name-$i')), findsOneWidget);
        expect(find.byKey(Key('kv-value-$i')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      // 行本身仍可长按：长按空行预览命中该行（只读，不打开编辑面）。
      await tester.longPress(find.byKey(const Key('kv-value-1')));
      await tester.pumpAndSettle();
      expect(
        pressed,
        same(target),
        reason: '极窄屏下长按仍须命中被长按的那一行',
      );
      expect(find.byKey(const Key('request-editor-field-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320x568 极窄屏（allowDisable=false，含空行）无 overflow 且行可长按',
        (tester) async {
      setViewport(tester, 320, 568);

      final rows = seed([('a', '1'), ('', ''), ('b', '2')]);
      final target = rows.first;
      DebugKvRow? pressed;
      await tester.pumpWidget(harness(
        rows: rows,
        allowDisable: false,
        onRowLongPress: (row) => pressed = row,
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // 行本身仍可长按：长按预览命中该行并触发移除。
      await tester.longPress(find.byKey(const Key('kv-name-0')));
      await tester.pumpAndSettle();

      expect(
        pressed,
        same(target),
        reason: '极窄屏下长按仍须命中被长按的那一行',
      );
      expect(rows.length, 2);
      expect(rows.contains(target), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '320x568 极窄屏（排序模式 + allowDisable=true，含空行）无 overflow 且行可长按',
        (tester) async {
      setViewport(tester, 320, 568);

      // 最紧横向预算：复选框槽(40) + 拖拽槽(40) + 间距(8) 同时存在，
      // 键 / 值两列被压到最小；中间为空键空值行。
      final rows = seed([('a', '1'), ('', ''), ('b', '2')]);
      final target = rows[1];
      DebugKvRow? pressed;
      await tester.pumpWidget(harness(
        rows: rows,
        allowDisable: true,
        sortMode: true,
        removeOnLongPress: false,
        onRowLongPress: (row) => pressed = row,
      ));
      await tester.pumpAndSettle();

      // 键 / 值预览与拖拽手柄均渲染，无 overflow / 异常。
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('kv-name-$i')), findsOneWidget);
        expect(find.byKey(Key('kv-value-$i')), findsOneWidget);
        expect(find.byKey(Key('kv-drag-$i')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      // 行本身仍可长按：长按空行值预览命中该行（只读，不打开编辑面）。
      await tester.longPress(find.byKey(const Key('kv-value-1')));
      await tester.pumpAndSettle();
      expect(
        pressed,
        same(target),
        reason: '极窄屏 + 排序模式下长按仍须命中被长按的那一行',
      );
      expect(find.byKey(const Key('request-editor-field-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('DebugKvEditor · 触控尺寸', () {
    testWidgets('排序模式下拖拽手柄动作槽宽 == AppSpacing.huge(40)', (tester) async {
      final rows = seed([('a', '1'), ('b', '2')]);
      await tester.pumpWidget(harness(rows: rows, sortMode: true));
      await tester.pumpAndSettle();

      for (var i = 0; i < 2; i++) {
        expect(
          tester.getSize(find.byKey(Key('kv-drag-$i'))).width,
          AppSpacing.huge,
          reason: '拖拽手柄动作槽宽度必须 == AppSpacing.huge(40)',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('每行 ≥ 48dp（AppSpacing.massive）', (tester) async {
      final rows = seed([('a', '1'), ('b', '2')]);
      await tester.pumpWidget(harness(rows: rows, allowDisable: true));
      await tester.pumpAndSettle();

      for (var i = 0; i < 2; i++) {
        expect(
          tester.getSize(find.byKey(Key('kv-row-${rows[i].id}'))).height,
          greaterThanOrEqualTo(AppSpacing.massive),
          reason: '行最小高必须 ≥ AppSpacing.massive(48)',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}
