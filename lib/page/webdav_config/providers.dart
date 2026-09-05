import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/webdav/webdav_config.dart';

/// WebDAV 配置页 UI 状态（不含输入框 controller——由页面持有）。
class WebDavConfigUiState {
  final bool enableHttps;
  final bool obscurePassword;
  final bool isTesting;
  final bool isSaving;
  final bool hasConfig;

  const WebDavConfigUiState({
    this.enableHttps = true,
    this.obscurePassword = true,
    this.isTesting = false,
    this.isSaving = false,
    this.hasConfig = false,
  });

  WebDavConfigUiState copyWith({
    bool? enableHttps,
    bool? obscurePassword,
    bool? isTesting,
    bool? isSaving,
    bool? hasConfig,
  }) {
    return WebDavConfigUiState(
      enableHttps: enableHttps ?? this.enableHttps,
      obscurePassword: obscurePassword ?? this.obscurePassword,
      isTesting: isTesting ?? this.isTesting,
      isSaving: isSaving ?? this.isSaving,
      hasConfig: hasConfig ?? this.hasConfig,
    );
  }
}

/// WebDAV 配置管理（Riverpod 版，替代原 GetxController）。
///
/// 输入框文本由页面持有（TextEditingController 属 UI 层），
/// 操作时组装 [WebDavConfig] 传入。持久化走纯单例 [WebDavConfigManager]。
class WebDavConfigNotifier extends Notifier<WebDavConfigUiState> {
  final WebDavConfigManager _configManager = WebDavConfigManager.instance;

  @override
  WebDavConfigUiState build() => const WebDavConfigUiState();

  /// 加载配置是否存在（页面 initState 调用，回填 hasConfig 驱动删除按钮显隐）。
  Future<void> loadHasConfig() async {
    final config = await _configManager.loadConfig();
    state = state.copyWith(hasConfig: config != null && config.isValid);
  }

  /// 测试连接（webdav 模块下线时降级提示，不抛）。
  Future<void> testConnection(WebDavConfig config) async {
    final service = ModuleManager.instance.get<IWebDavService>();
    if (service == null) {
      AppDialogs.showWarning('WebDAV 模块未启用，无法测试连接');
      return;
    }
    if (!config.isValid) {
      AppDialogs.showWarning('请填写完整的 WebDAV 配置信息（服务器地址、用户名、密码）');
      return;
    }

    state = state.copyWith(isTesting: true);
    try {
      appLog.info('WebDavConfigNotifier: 开始测试连接 - ${config.baseUrl}');
      final success = await service.testWebDavConnection(config);
      if (success) {
        AppDialogs.showSuccess('WebDAV 服务器连接正常');
      } else {
        AppDialogs.showError('无法连接到 WebDAV 服务器，请检查地址、账号密码或网络');
      }
    } catch (e) {
      appLog.error('WebDavConfigNotifier: 测试连接失败 - $e');
      AppDialogs.showError('连接错误：$e');
    } finally {
      state = state.copyWith(isTesting: false);
    }
  }

  /// 保存配置；成功返回 true（页面据此 pop）。
  Future<bool> save(WebDavConfig config) async {
    if (!config.isValid) {
      AppDialogs.showWarning('请填写完整的 WebDAV 配置信息');
      return false;
    }
    state = state.copyWith(isSaving: true);
    try {
      await _configManager.saveConfig(config);
      state = state.copyWith(hasConfig: true);
      AppDialogs.showSuccess('WebDAV 配置已保存');
      return true;
    } catch (e) {
      appLog.error('WebDavConfigNotifier: 保存配置失败 - $e');
      AppDialogs.showError('保存配置失败：$e');
      return false;
    } finally {
      state = state.copyWith(isSaving: false);
    }
  }

  /// 删除配置。
  Future<void> delete() async {
    try {
      await _configManager.clearConfig();
      state = const WebDavConfigUiState(hasConfig: false);
      AppDialogs.showSuccess('WebDAV 配置已删除');
    } catch (e) {
      appLog.error('WebDavConfigNotifier: 删除配置失败 - $e');
      AppDialogs.showError('删除配置失败：$e');
    }
  }

  void setEnableHttps(bool value) => state = state.copyWith(enableHttps: value);

  void toggleObscurePassword() =>
      state = state.copyWith(obscurePassword: !state.obscurePassword);
}

final webDavConfigProvider =
    NotifierProvider<WebDavConfigNotifier, WebDavConfigUiState>(
  WebDavConfigNotifier.new,
);
