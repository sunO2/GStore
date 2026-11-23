/// MCP 服务器配置持久化（SharedPreferences，小数据量）
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mcp_models.dart';

class McpServerStore {
  McpServerStore._(this._prefs, this._servers);

  static const String storageKey = 'agent_mcp_servers_v1';

  final SharedPreferences _prefs;
  final List<McpServerConfig> _servers;

  List<McpServerConfig> get all => List<McpServerConfig>.unmodifiable(_servers);
  List<McpServerConfig> get enabled =>
      _servers.where((s) => s.enabled && s.url.trim().isNotEmpty).toList();

  static Future<McpServerStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final servers = <McpServerConfig>[];
    final raw = prefs.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final config = McpServerConfig.fromJson(
                item.map((k, v) => MapEntry(k.toString(), v)),
              );
              if (config.id.isNotEmpty) servers.add(config);
            }
          }
        }
      } catch (error) {
        debugPrint('McpServerStore: 解析配置失败（按空处理） - $error');
      }
    }
    return McpServerStore._(prefs, servers);
  }

  Future<McpServerConfig> add({
    required String name,
    required String url,
    Map<String, String> headers = const {},
  }) async {
    final config = McpServerConfig(
      id: 'mcp-${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'MCP' : name.trim(),
      url: url.trim(),
      headers: headers,
    );
    _servers.add(config);
    await _save();
    return config;
  }

  Future<void> update(McpServerConfig config) async {
    final index = _servers.indexWhere((s) => s.id == config.id);
    if (index >= 0) {
      _servers[index] = config;
    } else {
      _servers.add(config);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    _servers.removeWhere((s) => s.id == id);
    await _save();
  }

  Future<void> clear() async {
    _servers.clear();
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(
      storageKey,
      jsonEncode([for (final s in _servers) s.toJson()]),
    );
  }
}
