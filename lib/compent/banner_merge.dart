// 顶部横幅的**纯逻辑层**：把两条独立进度来源归并成一组可直接渲染的卡片，
// 并提供体积与文案格式化。
//
// 两条来源：
// * 原生模块自举（`ModuleBootstrapState`，qr/analyzer/repo/download/llm）；
// * 通用任务中枢（`TaskProgressState`，例如 `fdroid-sync` 仓库索引同步）。
//
// 本文件**不依赖 Flutter widget**（不 import material/widgets），因此归并规则、
// 去重优先级与文案格式化都能在纯 Dart 测试中穷举验证；颜色、排版与图标全部
// 留在 `module_install_banner.dart` 的 UI 层。

import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

/// 模块名 → 中文展示名（与模块管理页的原生插件清单保持一致；未收录时原样返回）。
const Map<String, String> moduleInstallLabels = <String, String>{
  'qr': '二维码解码',
  'analyzer': 'APK 分析',
  'repo': 'F-Droid 仓库',
  'download': '下载内核',
  'llm': '本地大模型',
};

/// 返回模块的中文展示名；未收录的模块回退为原始模块名。
String moduleInstallLabel(String module) =>
    moduleInstallLabels[module] ?? module;

/// 模块名 → 一句功能说明（横幅卡片的详情行，回答「这东西是干嘛的」）。
///
/// 与 [moduleInstallLabels] 并列维护；未收录的模块返回 `null`，
/// 调用方应**省略**该行而不是显示占位文案（优雅降级）。
const Map<String, String> modulePurposeLabels = <String, String>{
  'qr': '用于扫描识别二维码',
  'analyzer': '用于解析 APK 信息',
  'repo': '用于 F-Droid 仓库搜索',
  'download': '用于接管下载任务',
  'llm': '用于本地模型推理',
};

/// 返回模块的功能说明；未收录时为 `null`。
String? modulePurposeLabel(String module) => modulePurposeLabels[module];

/// 把字节数格式化为紧凑的人类可读体积。
///
/// * `null` / `<= 0` → `null`（调用方省略体积行）；
/// * `< 1 KiB` → `'N B'`（不显示小数，避免「1.0 KB 却说不足 1KB」）；
/// * 其余按 KB / MB / GB 保留 **1 位小数**。
String? formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return null;
  }
  const int unitKB = 1024;
  const int unitMB = unitKB * 1024;
  const int unitGB = unitMB * 1024;
  if (bytes < unitKB) {
    return '$bytes B';
  }
  if (bytes < unitMB) {
    return '${(bytes / unitKB).toStringAsFixed(1)} KB';
  }
  if (bytes < unitGB) {
    return '${(bytes / unitMB).toStringAsFixed(1)} MB';
  }
  return '${(bytes / unitGB).toStringAsFixed(1)} GB';
}

/// 一张可直接渲染的横幅卡片（已与来源解耦）。
///
/// 字段语义见各成员文档；只承载展示数据，不含任何 widget / 颜色。
class BannerCard {
  /// 构造一张卡片。
  const BannerCard({
    required this.cardKey,
    required this.label,
    this.stage,
    this.progress,
    this.sizeBytes,
    this.fromModule = false,
    this.detail,
    this.error,
  });

  /// 归并/去重键：同一个 [cardKey] 在横幅里**只出现一次**。
  ///
  /// 模块卡片为 `'module:<module>'`（与仓库任务 `fdroid-sync` 的 `groupKey`
  /// 一致），因此「安装 .so → 索引同步」会落在同一张卡片上。
  final String cardKey;

  /// 标题（模块为中文名；任务为任务自带的 label）。
  final String label;

  /// 阶段文案——面向用户的**动作句**（如 `'正在下载模块 42%'` /
  /// `'下载完成，正在准备使用'` / `'解析入库…'`）。
  ///
  /// 任务来源未上报阶段时，归并层补一句通用兜底（见 [_taskFallbackStage]），
  /// 因此正常情况下非空；仅当来源确实无阶段且兜底也不适用时为 `null`。
  final String? stage;

  /// 完成比例 `[0,1]`；`null` → UI 显示不定量进度条。
  final double? progress;

  /// 期望/实际字节数（用于「约 X MB」文案）；未知为 `null`。
  final int? sizeBytes;

  /// 是否来自原生模块自举（`true`）还是通用任务中枢（`false`）。
  final bool fromModule;

  /// 详情行——回答「为什么下载 / 要下多大」。
  ///
  /// 模块为 `'首次使用需下载，用途 · 约 X MB · 仅需一次'`；任务为任务自带
  /// detail，缺省且已知体积时补 `'约 X MB · 仅需一次'`。
  final String? detail;

  /// 失败来源的原始错误。
  ///
  /// **当前策略：隐藏失败来源**——横幅覆盖层是 `IgnorePointer`（不可交互），
  /// 展示一个既不能关闭也不能重试的错误只会制造噪音，且与既有「`failed` 时
  /// 自动隐藏」的行为保持一致。因此 [mergeBannerCards] 不会为失败来源生成卡片，
  /// 本字段恒为 `null`；保留它是为将来可交互的提示层预留透传位（签名兼容）。
  final Object? error;
}

/// 归并模块与任务两条来源，返回**有序、按键去重**的卡片列表。
///
/// 规则（精确）：
/// * 只有进行中的来源进入结果：模块的 `downloading`/`initializing`、任务的
///   `running`。`ready`/`failed`/`absent` 一律隐藏（终态不渲染卡片）。
/// * 模块优先级更高：模块键为 `'module:<module>'`。若某任务的 [BannerCard.cardKey]
///   与之相同，该任务被**抑制（合并）**而非重复渲染；模块不再活动后，同键任务
///   自然接管同一张卡片（键不变 → 视觉连续）。
/// * 顺序：模块在前、任务在后；同一 [BannerCard.cardKey] 只保留首次出现者。
List<BannerCard> mergeBannerCards(
  List<ModuleBootstrapState> modules,
  List<TaskProgressState> tasks,
) {
  final List<BannerCard> cards = <BannerCard>[];
  final Set<String> seenKeys = <String>{};

  // 1) 活动中的原生模块优先占键。
  for (final ModuleBootstrapState module in modules) {
    if (!_isActiveModule(module.phase)) {
      continue;
    }
    final String key = 'module:${module.module}';
    if (!seenKeys.add(key)) {
      continue;
    }
    cards.add(BannerCard(
      cardKey: key,
      label: moduleInstallLabel(module.module),
      stage: _moduleStage(module.phase, module.progress),
      progress: module.progress,
      sizeBytes: module.sizeBytes,
      fromModule: true,
      detail: _moduleDetail(module.module, module.sizeBytes),
    ));
  }

  // 2) 任务其次；与已有键（模块或先前任务）冲突者被抑制。
  for (final TaskProgressState task in tasks) {
    if (task.phase != TaskPhase.running) {
      continue;
    }
    if (!seenKeys.add(task.cardKey)) {
      continue;
    }
    cards.add(BannerCard(
      cardKey: task.cardKey,
      label: task.label,
      // 具体阶段（如 `'正在下载仓库索引 42%'`）由生产者上报；未上报时补一句
      // 通用动作句，避免卡片只剩标题+进度条、读不出「在干嘛」。
      stage: task.stage ?? _taskFallbackStage,
      progress: task.progress,
      sizeBytes: task.sizeBytes,
      fromModule: false,
      detail: task.detail ?? _taskDetailFallback(task.sizeBytes),
    ));
  }

  return cards;
}

/// 模块是否处于「进行中」（`downloading` / `initializing`）。
bool _isActiveModule(ModuleBootstrapPhase phase) =>
    phase == ModuleBootstrapPhase.downloading ||
    phase == ModuleBootstrapPhase.initializing;

/// 模块阶段文案——写成一句「正在做什么」，而非一个名词化状态：
/// * 下载中 → `正在下载模块 42%`（百分比可见；无进度则省略百分比）；
/// * 初始化 → `下载完成，正在准备使用`（告诉用户下一步会发生什么）；
/// * 终态（ready/failed/absent 不产生卡片）→ 空串。
String _moduleStage(ModuleBootstrapPhase phase, double? progress) {
  switch (phase) {
    case ModuleBootstrapPhase.downloading:
      return progress == null
          ? '正在下载模块'
          : '正在下载模块 ${(progress * 100).round()}%';
    case ModuleBootstrapPhase.initializing:
      return '下载完成，正在准备使用';
    case ModuleBootstrapPhase.ready:
    case ModuleBootstrapPhase.failed:
    case ModuleBootstrapPhase.absent:
      return '';
  }
}

/// 模块详情行——一句人话解释「为什么下载 / 要下多大 / 是不是一次性的」：
/// `'首次使用需下载，用途 · 约 X MB · 仅需一次'`。
///
/// 用途与体积各自可缺省（缺哪段省略哪段）；两者皆缺时返回 `null`，调用方
/// **省略整行**而不是留下半句「首次使用需下载，」。
String? _moduleDetail(String module, int? sizeBytes) {
  final String? purpose = modulePurposeLabel(module);
  final String? size = formatBytes(sizeBytes);
  final List<String> parts = <String>[
    if (purpose != null) purpose,
    if (size != null) '约 $size · 仅需一次',
  ];
  return parts.isEmpty ? null : '首次使用需下载，${parts.join(' · ')}';
}

/// 任务阶段兜底：任务源未上报 [TaskProgressState.stage] 时使用的通用动作句。
///
/// 具体阶段（如 `'正在下载仓库索引 42%'`）由生产者上报，归并层**不臆造**业务
/// 细节；兜底只保证卡片始终有一句「后台在工作」的说明，避免只剩标题+进度条。
const String _taskFallbackStage = '正在后台处理…';

/// 任务详情兜底：任务未提供 detail 且已知 [sizeBytes] 时，补一句
/// `'约 X MB · 仅需一次'`；体积未知则保持 `null`（不臆造来源信息）。
String? _taskDetailFallback(int? sizeBytes) {
  final String? size = formatBytes(sizeBytes);
  return size == null ? null : '约 $size · 仅需一次';
}
