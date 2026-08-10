import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/JsonMergePatch.dart';

void main() {
  group('JsonMergePatch.apply（RFC 7386）', () {
    test('空 patch 保持目标不变', () {
      final target = {'a': 1, 'b': 2};
      final result = JsonMergePatch.apply(target, {});
      expect(result, {'a': 1, 'b': 2});
    });

    test('新增键', () {
      final target = {'a': 1};
      final result = JsonMergePatch.apply(target, {'b': 2});
      expect(result, {'a': 1, 'b': 2});
    });

    test('null 值删除键', () {
      final target = {'a': 1, 'b': 2};
      final result = JsonMergePatch.apply(target, {'a': null});
      expect(result, {'b': 2});
    });

    test('标量替换', () {
      final target = {'a': 1};
      final result = JsonMergePatch.apply(target, {'a': 'x'});
      expect(result, {'a': 'x'});
    });

    test('对象递归合并', () {
      final target = {'a': {'x': 1, 'y': 2}, 'b': 3};
      final result = JsonMergePatch.apply(target, {
        'a': {'y': 20, 'z': 30},
      });
      expect(result, {
        'a': {'x': 1, 'y': 20, 'z': 30},
        'b': 3,
      });
    });

    test('递归删除嵌套键', () {
      final target = {'a': {'x': 1, 'y': 2}};
      final result = JsonMergePatch.apply(target, {
        'a': {'y': null},
      });
      expect(result, {'a': {'x': 1}});
    });

    test('目标键非对象时，patch 对象整体替换', () {
      final target = {'a': 5};
      final result = JsonMergePatch.apply(target, {
        'a': {'x': 1},
      });
      expect(result, {'a': {'x': 1}});
    });

    test('数组整体替换', () {
      final target = {'list': [1, 2, 3]};
      final result = JsonMergePatch.apply(target, {'list': [4, 5]});
      expect(result, {'list': [4, 5]});
    });

    test('不修改原始对象', () {
      final target = {'a': 1};
      JsonMergePatch.apply(target, {'b': 2});
      expect(target, {'a': 1});
    });

    test('多层嵌套合并', () {
      final target = {
        'level1': {
          'level2': {'keep': 1, 'change': 2},
          'other': 'x',
        },
      };
      final result = JsonMergePatch.apply(target, {
        'level1': {
          'level2': {'change': 3, 'add': 4},
          'new': 'y',
        },
      });
      expect(result, {
        'level1': {
          'level2': {'keep': 1, 'change': 3, 'add': 4},
          'other': 'x',
          'new': 'y',
        },
      });
    });

    test('F-Droid index-v2 风格：repo 元数据增量更新', () {
      final target = {
        'repo': {'name': 'MyRepo', 'timestamp': 1000},
        'packages': {'com.a': {'versions': ['1.0']}},
      };
      final patch = {
        'repo': {'timestamp': 2000, 'newField': 'v'},
      };
      final result = JsonMergePatch.apply(target, patch);
      expect(result['repo'], {'name': 'MyRepo', 'timestamp': 2000, 'newField': 'v'});
      expect(result['packages'], {'com.a': {'versions': ['1.0']}});
    });

    test('jsonDecode 场景：从 JSON 字符串应用 patch', () {
      final target = jsonDecode('{"a": {"x": 1}, "b": [1,2]}') as Map<String, dynamic>;
      final patch = jsonDecode('{"a": {"x": null, "y": 2}}') as Map<String, dynamic>;
      final result = JsonMergePatch.apply(target, patch);
      expect(result, {'a': {'y': 2}, 'b': [1, 2]});
    });
  });
}
