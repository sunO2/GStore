import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';

/// A2UI payload 的本地校验与限额（阶段 A：工具式 renderA2ui）。
///
/// 模型输出一律视为不可信输入：
/// - 只接受协议 v1.0 的 createSurface/updateComponents/updateDataModel/deleteSurface
/// - 只允许 GStore 白名单内的 basic catalog 组件
/// - 只允许 agent action（event），拒绝 functionCall / openUrl 等本地执行
/// - 限制 surface 数、组件数、文本长度和 payload 大小
class A2uiRenderValidation {
  A2uiRenderValidation._();

  static const String catalogId = BasicCatalog.v1_0Id;
  static const int maxPayloadChars = 32000;
  static const int maxComponents = 60;
  static const int maxSurfaces = 1;
  static const int maxStringChars = 2000;

  /// 阶段 A 允许的组件。刻意排除 Image/Video/AudioPlayer（网络/体积）
  /// 以及 Tabs/Modal/Slider/DateTimeInput（交互复杂度）。
  static const Set<String> allowedComponents = {
    'Column',
    'Row',
    'Card',
    'Text',
    'Button',
    'Divider',
    'TextField',
    'CheckBox',
    'ChoicePicker',
    'List',
  };

  /// 校验并返回规范化结果；失败抛 [A2uiError]（code 供模型修正）。
  static A2uiRenderResult validate(Object? rawPayload) {
    final String payload;
    if (rawPayload is String) {
      payload = rawPayload.trim();
    } else if (rawPayload is Map || rawPayload is List) {
      payload = jsonEncode(rawPayload);
    } else {
      throw A2uiError('payload 必须是 JSON 字符串/对象/数组', code: 'INVALID_PAYLOAD');
    }
    if (payload.isEmpty) {
      throw A2uiError('payload 为空', code: 'EMPTY_PAYLOAD');
    }
    if (payload.length > maxPayloadChars) {
      throw A2uiError(
        'payload 过大（${payload.length} > $maxPayloadChars 字符），请精简',
        code: 'PAYLOAD_TOO_LARGE',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (e) {
      throw A2uiError('payload 不是合法 JSON：$e', code: 'INVALID_JSON');
    }

    final List<Object?> messages;
    if (decoded is List) {
      messages = decoded;
    } else if (decoded is Map) {
      messages = <Object?>[decoded];
    } else {
      throw A2uiError('payload 必须是消息数组或单个消息对象', code: 'INVALID_PAYLOAD');
    }
    if (messages.isEmpty) {
      throw A2uiError('payload 消息数组为空', code: 'EMPTY_PAYLOAD');
    }
    if (messages.length > 8) {
      throw A2uiError('消息条数过多（${messages.length} > 8）', code: 'TOO_MANY_MESSAGES');
    }

    var componentCount = 0;
    final surfaceIds = <String>{};
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message is! Map) {
        throw A2uiError('第 ${i + 1} 条消息不是 JSON 对象', code: 'INVALID_ENVELOPE');
      }
      componentCount += _validateMessage(message, surfaceIds, i);
    }
    if (surfaceIds.length > maxSurfaces) {
      throw A2uiError(
        '阶段 A 只允许 $maxSurfaces 个 surface，当前 ${surfaceIds.length} 个',
        code: 'TOO_MANY_SURFACES',
      );
    }

    // 交给 a2ui_core 做完整协议校验（组件引用、数据绑定、函数签名等）。
    final processor = MessageProcessor(catalogs: [BasicCatalog.v1_0()]);
    try {
      processor.processMessages(messages);
    } on A2uiError catch (e) {
      throw A2uiError(e.message, code: 'VALIDATION_FAILED');
    } finally {
      processor.dispose();
    }

    return A2uiRenderResult(
      normalizedPayload: payload,
      surfaceId: surfaceIds.isEmpty ? '' : surfaceIds.first,
      componentCount: componentCount,
    );
  }

  static int _validateMessage(
    Map<Object?, Object?> message,
    Set<String> surfaceIds,
    int index,
  ) {
    final version = message['version'];
    if (version != '1.0') {
      throw A2uiError(
        '第 ${index + 1} 条消息 version 必须是 "1.0"',
        code: 'INVALID_VERSION',
      );
    }
    final types = message.keys.where((key) => key != 'version').toList();
    if (types.length != 1) {
      throw A2uiError(
        '第 ${index + 1} 条消息必须且只能包含一种消息类型',
        code: 'INVALID_ENVELOPE',
      );
    }
    final type = types.single.toString();
    const allowedTypes = {
      'createSurface',
      'updateComponents',
      'updateDataModel',
      'deleteSurface',
    };
    if (!allowedTypes.contains(type)) {
      throw A2uiError(
        '不支持的消息类型：$type（阶段 A 只允许 $allowedTypes）',
        code: 'UNSUPPORTED_MESSAGE',
      );
    }
    final body = message[types.single];
    if (body is! Map) {
      throw A2uiError('$type 的消息体必须是 JSON 对象', code: 'INVALID_ENVELOPE');
    }
    _checkStrings(body, 'payload.$type');

    switch (type) {
      case 'createSurface':
        final surfaceId = body['surfaceId']?.toString() ?? '';
        if (surfaceId.isEmpty) {
          throw A2uiError('createSurface.surfaceId 不能为空', code: 'INVALID_SURFACE');
        }
        surfaceIds.add(surfaceId);
        final declaredCatalog = body['catalogId']?.toString();
        if (declaredCatalog != catalogId) {
          throw A2uiError(
            'catalogId 必须是 $catalogId',
            code: 'UNSUPPORTED_CATALOG',
          );
        }
        if (body['sendDataModel'] == true) {
          throw A2uiError(
            '阶段 A 不允许 sendDataModel=true（避免数据模型回传）',
            code: 'UNSUPPORTED_PRIVACY',
          );
        }
        return _countComponents(body['components'], 'createSurface.components');
      case 'updateComponents':
        final surfaceId = body['surfaceId']?.toString() ?? '';
        if (surfaceId.isEmpty) {
          throw A2uiError('updateComponents.surfaceId 不能为空', code: 'INVALID_SURFACE');
        }
        surfaceIds.add(surfaceId);
        return _countComponents(body['components'], 'updateComponents.components');
      case 'updateDataModel':
        final surfaceId = body['surfaceId']?.toString() ?? '';
        if (surfaceId.isEmpty) {
          throw A2uiError('updateDataModel.surfaceId 不能为空', code: 'INVALID_SURFACE');
        }
        surfaceIds.add(surfaceId);
        return 0;
      case 'deleteSurface':
        final surfaceId = body['surfaceId']?.toString() ?? '';
        if (surfaceId.isEmpty) {
          throw A2uiError('deleteSurface.surfaceId 不能为空', code: 'INVALID_SURFACE');
        }
        return 0;
    }
    return 0;
  }

  static int _countComponents(Object? value, String path) {
    if (value == null) return 0;
    if (value is! List) {
      throw A2uiError('$path 必须是数组', code: 'INVALID_COMPONENTS');
    }
    if (value.length > maxComponents) {
      throw A2uiError(
        '$path 组件数过多（${value.length} > $maxComponents）',
        code: 'TOO_MANY_COMPONENTS',
      );
    }
    for (var i = 0; i < value.length; i++) {
      final component = value[i];
      if (component is! Map) {
        throw A2uiError('$path[$i] 不是 JSON 对象', code: 'INVALID_COMPONENT');
      }
      final name = component['component']?.toString() ?? '';
      if (!allowedComponents.contains(name)) {
        throw A2uiError(
          '不支持的组件 "$name"（阶段 A 允许：${allowedComponents.join(', ')}）',
          code: 'UNSUPPORTED_COMPONENT',
        );
      }
      final catalog = component['@catalogId']?.toString();
      if (catalog != null && catalog != catalogId) {
        throw A2uiError('组件不允许指定其他 catalog：$catalog', code: 'UNSUPPORTED_CATALOG');
      }
      final action = component['action'];
      if (action is Map) {
        if (action['functionCall'] != null) {
          throw A2uiError(
            '阶段 A 不允许 local functionCall（只支持 action.event）',
            code: 'UNSUPPORTED_ACTION',
          );
        }
        final event = action['event'];
        if (event is! Map || (event['name']?.toString().isEmpty ?? true)) {
          throw A2uiError('$path[$i].action 必须包含 event.name', code: 'INVALID_ACTION');
        }
      }
    }
    return value.length;
  }

  static void _checkStrings(Object? value, String path) {
    if (value is String) {
      if (value.length > maxStringChars) {
        throw A2uiError(
          '$path 的字符串过长（${value.length} > $maxStringChars）',
          code: 'TEXT_TOO_LONG',
        );
      }
      return;
    }
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _checkStrings(value[i], '$path[$i]');
      }
      return;
    }
    if (value is Map) {
      value.forEach((key, child) => _checkStrings(child, '$path.$key'));
    }
  }
}

class A2uiRenderResult {
  const A2uiRenderResult({
    required this.normalizedPayload,
    required this.surfaceId,
    required this.componentCount,
  });

  final String normalizedPayload;
  final String surfaceId;
  final int componentCount;
}
