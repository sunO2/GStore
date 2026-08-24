import 'package:flutter/material.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// 详情页操作项。
/// 由 [IDetailChannel.getActions] 返回，UI 点击调 [onTap]。
/// 支持三种图标：Material 图标（[icon]）、zip 内置图标（[iconImage]）、默认图标。
///
/// [icon] 与 [iconImage] 非必须同时提供（至少一个为 null，均 null 时用默认图标）。
class DetailAction {
  final String label;
  final IconData? icon;
  final MemoryImage? iconImage;
  final Future<void> Function() onTap;

  const DetailAction({
    required this.label,
    this.icon,
    this.iconImage,
    required this.onTap,
  });
}

/// 详情页 UI 交互回调接口。
/// 由 [DetailLogic] 实现，注入到 [IDetailChannel.bind]。
/// channel 不直接依赖 Flutter UI（BuildContext/showModalBottomSheet 等），
/// 通过此接口间接触发 UI 交互。
abstract class DetailCallbacks {
  /// 显示版本选择器
  /// [options] 来自 channel.versionOptions(appId)
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  });

  /// 显示历史构建列表
  /// [builds] 来自 channel.buildHistory(appId, version, env)
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  });

  /// 显示 UA 选择器，返回用户选中的 UA（取消返回 null）
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current, // 新增：当前选中的 UA，用于回显
  });

  /// 刷新详情信息（switchVersion 后调用）
  Future<void> refreshDetail({
    required Map<String, dynamic> detailData,
  });

  /// 粒度推送详情数据（渐进加载原语，可多次调用）。
  ///
  /// [partial] 是详情数据的任意键子集，合并语义为「展开合并」：
  /// - `extra` 键：因 `ChannelDetailProxy.extra` 是原始数据 `_data` 的别名
  ///   （见 ChannelDetailProxy.dart），其值若为 Map 则**逐键展开写入顶层**，
  ///   禁止嵌套存储（嵌套键无任何 getter 消费，等于丢数据）；
  /// - 其余顶层键：浅覆盖（`{...old, ...new}`），数组整体替换不做 diff；
  /// - 当前无详情时以 partial 创建新详情。
  Future<void> updateDetail({required Map<String, dynamic> partial});

  /// 更多按钮忙碌态（慢操作如切版本/切 UA 进行中）。
  /// visible=true 开启（可选 label 描述当前操作），false 结束；
  /// 实现方需带超时兜底防脚本异常挂死状态。
  Future<void> setActionBusy({required bool visible, String? label});

  /// 更新下载列表（脚本调用后）
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  });

  /// 显示成功提示
  void showSuccess(String message, {String? title});

  /// 显示错误提示
  void showError(String message, {String? title});

  /// 显示警告对话框
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  });

  /// 启动已安装应用
  void startApp(String packageName);

  /// 打开浏览器
  void openBrowser(String url);

  /// 打开项目主页
  void openProjectBrowser();

  /// 提交应用元数据提取请求
  Future<void> submitAppMetadata();

  /// 显示更多标签编辑面板
  /// [actions] 是 DetailAction 列表（来自 channel.getActions()）
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  });
}