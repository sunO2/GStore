/// OpenAI 兼容服务的模型发现：GET `{baseUrl}/models`
///
/// 复用 `openai_dart` 的 `OpenAIClient`，请求地址拼接与鉴权头（Bearer apiKey）
/// 和实际推理调用走同一套实现 —— 手工拼 URL 容易出现 `/v1` 有无、尾斜杠等
/// 与聊天请求不一致的问题，导致"列表能拉到但对话 404"。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/agent/agent_http_client.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:http/http.dart' as http;
import 'package:openai_dart/openai_dart.dart' as sdk;

/// Base URL 留空时使用的默认地址（与 AgentModel.defaultBaseUrl 一致）
const String kDefaultOpenAiBaseUrl = 'https://api.openai.com/v1';

/// 模型列表缓存的 key：Base URL 留空时按默认地址归并。
///
/// 缓存按**接口地址**而不是按模型配置存储：同一端点被多个配置复用时共享一份列表，
/// 换了地址也不会误用别的端点上的模型。
String modelCatalogKey(String baseUrl) =>
    baseUrl.isEmpty ? kDefaultOpenAiBaseUrl : baseUrl;

/// 拉取可用模型 ID 列表（去重后按名称升序）。
///
/// [baseUrl] 为空时按 [kDefaultOpenAiBaseUrl] 拉取，与模型配置里
/// "Base URL 留空即用默认值"的语义一致。
///
/// [httpClient] 仅供测试注入；传入时由调用方负责关闭。
///
/// 失败（网络不通 / 401 / 404 / 响应结构非预期）不吞异常，直接抛给调用方提示。
Future<List<String>> fetchOpenAiModelIds({
  required String baseUrl,
  required String apiKey,
  http.Client? httpClient,
}) async {
  // 默认用 rhttp（curl 栈）客户端；测试可注入 MockClient
  final client = sdk.OpenAIClient.withApiKey(
    apiKey,
    baseUrl: modelCatalogKey(baseUrl),
    httpClient: httpClient ?? await buildAgentHttpClient(),
  );
  try {
    final list = await client.models.list();
    final ids = list.data
        .map((model) => model.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    debugPrint('模型列表: 拉取成功 baseUrl=$baseUrl count=${ids.length}');
    return ids;
  } catch (e) {
    debugPrint('模型列表: 拉取失败 baseUrl=$baseUrl error=$e');
    rethrow;
  } finally {
    client.close();
  }
}

/// 把（可能是历史字符串编码的）原始缓存值展开成 JSON 结构。
///
/// `agent.model_catalog` 注册为 `json` 类型（C6）：当前格式是已解码的 `Map`；
/// 旧数据是 `writeString(jsonEncode(...))` 落盘的字符串（可能双重编码）。
Object? _decodeCatalogJson(Object? raw) {
  var value = raw;
  for (var depth = 0; depth < 2 && value is String; depth++) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final looksJson = text.startsWith('{') ||
        text.startsWith('[') ||
        text.startsWith('"');
    if (!looksJson) return null;
    try {
      value = jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
  return value;
}

/// 归一化缓存值：`{baseUrl: [modelId, ...]}`。
({Map<String, List<String>> cache, bool fromLegacyString})
_decodeCatalogValue(Object? raw) {
  final decoded = _decodeCatalogJson(raw);
  // 仅当历史字符串成功解出 map 时才迁移；畸形数据保持原样。
  final fromLegacyString = raw is String && decoded is Map;
  if (decoded is! Map) {
    return (cache: <String, List<String>>{}, fromLegacyString: false);
  }
  final result = <String, List<String>>{};
  decoded.forEach((key, value) {
    if (value is List) {
      result[key.toString()] =
          value.map((e) => e.toString()).toList(growable: false);
    }
  });
  return (cache: result, fromLegacyString: fromLegacyString);
}

/// 读取全部已缓存的模型列表（key = [modelCatalogKey] 的结果）。
///
/// 存储不可用（测试环境未初始化等）或内容损坏时返回空 map，不影响表单使用预设。
Future<Map<String, List<String>>> loadModelCatalogCache() async {
  try {
    final store = ConfigStore.instance;
    await store.initialize();
    Object? raw = await store.readValue(ConfigKeys.agentModelCatalog);
    if (raw == null || (raw is String && raw.trim().isEmpty)) {
      // 旧数据兼容：历史版本以 JSON 字符串存于普通存储。
      raw = await store.readString(ConfigKeys.agentModelCatalog);
    }
    final decoded = _decodeCatalogValue(raw);
    if (decoded.fromLegacyString) {
      await _writeCatalog(store, decoded.cache);
    }
    return decoded.cache;
  } catch (e) {
    debugPrint('模型列表: 读取缓存失败 error=$e');
    return {};
  }
}

/// 以 typed JSON（`Map<String, List<String>>`）写入缓存。
Future<bool> _writeCatalog(
  ConfigStore store,
  Map<String, List<String>> cache,
) {
  return store.write(ConfigKeys.agentModelCatalog, cache);
}

/// 缓存某个端点拉取到的模型列表（覆盖该端点旧值）。
Future<void> cacheModelIds(String baseUrl, List<String> modelIds) async {
  try {
    final store = ConfigStore.instance;
    await store.initialize();
    final cache = await loadModelCatalogCache();
    cache[modelCatalogKey(baseUrl)] = modelIds;
    await _writeCatalog(store, cache);
    debugPrint('模型列表: 已缓存 baseUrl=$baseUrl count=${modelIds.length}');
  } catch (e) {
    debugPrint('模型列表: 写入缓存失败 error=$e');
  }
}
