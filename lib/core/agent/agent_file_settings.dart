import 'package:shared_preferences/shared_preferences.dart';

/// AI 文件访问设置（默认关闭）。
///
/// 工作区本身始终可查看/导入导出，但只有开启后才会向模型下发文件工具。
class AgentFileSettings {
  AgentFileSettings._();

  static const String _keyEnabled = 'agent_file_access_enabled';

  /// 是否允许 AI 读写工作区文件。
  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? false;
  }

  static Future<void> saveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
  }
}
