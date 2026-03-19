import 'dart:convert';

/// JSON Merge Patch (RFC 7386) 实现
/// 用于合并 F-Droid index-v2 的增量更新
///
/// 合并规则：
/// 1. 如果 patch 不是对象，替换 target
/// 2. 如果 patch 中的值是 null，删除 target 中对应的 key
/// 3. 如果 patch 中的值是对象，递归合并
/// 4. 否则，用 patch 的值替换 target 的值
class JsonMergePatch {
  /// 应用 JSON Merge Patch 到目标 JSON
  static Map<String, dynamic> apply(
    Map<String, dynamic> target,
    Map<String, dynamic> patch,
  ) {
    // 如果 patch 不是对象，直接替换
    if (!_isObject(patch)) {
      return patch as Map<String, dynamic>;
    }

    final result = Map<String, dynamic>.from(target);

    patch.forEach((key, value) {
      if (value == null) {
        // null 表示删除
        result.remove(key);
      } else if (_isObject(value)) {
        // 对象递归合并
        final targetValue = result[key];
        if (_isObject(targetValue)) {
          result[key] = apply(
            targetValue as Map<String, dynamic>,
            value as Map<String, dynamic>,
          );
        } else {
          // target 不是对象，直接使用 patch 值
          result[key] = value;
        }
      } else {
        // 基本类型，直接替换
        result[key] = value;
      }
    });

    return result;
  }

  /// 检查值是否为对象类型
  static bool _isObject(dynamic value) {
    return value is Map<String, dynamic>;
  }

  /// 检查是否有实际变化
  static bool hasChanges(
    Map<String, dynamic> target,
    Map<String, dynamic> patch,
  ) {
    // 快速检查：如果 patch 为空，无变化
    if (patch.isEmpty) return false;

    // 检查是否有任何字段变化
    for (final key in patch.keys) {
      final patchValue = patch[key];
      final targetValue = target[key];

      if (patchValue == null && target.containsKey(key)) {
        // 删除操作，算作变化
        return true;
      }

      if (!_isEqual(patchValue, targetValue)) {
        return true;
      }
    }

    return false;
  }

  /// 简单的相等比较
  static bool _isEqual(dynamic a, dynamic b) {
    if (a == b) return true;

    // 深度比较 Map
    if (a is Map && b is Map) {
      final aMap = a as Map;
      final bMap = b as Map;
      if (aMap.length != bMap.length) return false;

      for (final key in aMap.keys) {
        if (!_isEqual(aMap[key], bMap[key])) {
          return false;
        }
      }
      return true;
    }

    // 深度比较 List
    if (a is List && b is List) {
      final aList = a as List;
      final bList = b as List;
      if (aList.length != bList.length) return false;

      for (int i = 0; i < aList.length; i++) {
        if (!_isEqual(aList[i], bList[i])) {
          return false;
        }
      }
      return true;
    }

    return false;
  }
}
