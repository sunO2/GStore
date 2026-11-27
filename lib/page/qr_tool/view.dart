import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/QrRustDecoder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 二维码工具模式：生成二维码 / 识别二维码
enum QrToolMode { generate, scan }

/// `qr` 原生模块自举阶段流 Provider（仅 `qr` 一个模块）。
///
/// 桥接 [ModuleBootstrap.watch]('qr')，供识别模式的「准备中 / 已就绪」指示 chip
/// 订阅。页面内指示（非顶部横幅——顶部横幅就绪即隐藏）。测试可经 `overrideWith`
/// 注入受控阶段流，无需 FFI / 网络即可验证 chip 各状态。
final qrModulePhaseProvider = StreamProvider<ModuleBootstrapPhase>(
    (ref) => ModuleBootstrap.instance.watch('qr').map((state) => state.phase));

/// 二维码工具页：输入文本/链接 → 实时生成二维码；支持长按保存图片（应用目录 + 系统相册）；
/// 历史生成记录防抖持久化（shared_preferences），点击历史可回填输入。
/// 「识别二维码」模式复用同一预览区显示相机实时预览，识别结果自动回填输入框，
/// 识别历史独立持久化（qr_tool_scan_history）。
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key, this.initialMode = QrToolMode.generate});

  /// 页面打开时的初始模式（默认「生成」）。
  ///
  /// 供「扫码」直达入口以识别模式打开页面；初始为识别时会在 [initState] 提前预热
  /// `qr` 模块（与相机初始化并行），而页面以默认生成模式打开时**绝不**预热。
  final QrToolMode initialMode;

  /// 测试注入：系统相册写入结果（null = 走真实 gal；true/false = 模拟结果，不触发真实相册）。
  @visibleForTesting
  static bool? debugGallerySucceeds;

  /// 测试注入：枚举可用相机（null = 走真实 availableCameras()）。
  /// 测试环境平台通道未注册会挂起，注入后可确定性走「相机不可用」失败路径。
  @visibleForTesting
  static Future<List<CameraDescription>> Function()? debugAvailableCameras;

  /// 将紧凑像素帧按【顺时针 quarterTurns 次 90°】旋转，再可选水平镜像——
  /// 把 CameraImage（传感器方向）转成与 CameraPreview 一致的预览方向。
  /// 纯函数（无状态依赖），供解码/码眼/定格统一复用，且可直接单测。
  /// [w]/[h] 为输入宽高、[bytesPerPixel] 每像素字节数（灰度 1 / RGBA 4），
  /// 返回 <像素数据, 旋转后宽, 旋转后高>。
  @visibleForTesting
  static (Uint8List, int, int) rotateLumaToPreview(
    Uint8List luma,
    int w,
    int h, {
    required int quarterTurns,
    bool mirrorX = false,
    int bytesPerPixel = 1,
  }) {
    return QrFrameTransform.rotateToPreview(
      luma,
      w,
      h,
      quarterTurns: quarterTurns,
      mirrorX: mirrorX,
      bytesPerPixel: bytesPerPixel,
    );
  }

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  /// 历史记录存储键
  static const String _historyKey = 'qr_tool_history';

  /// 识别历史存储键
  static const String _scanHistoryKey = 'qr_tool_scan_history';

  /// 历史记录上限
  static const int _historyLimit = 20;

  /// 当前模式：生成二维码 / 识别二维码
  QrToolMode _mode = QrToolMode.generate;

  /// 输入控制器（「清除」时清空并复位 [_text]）
  final TextEditingController _controller = TextEditingController();

  /// 输入框焦点节点（保存完成后保持失焦，用户主动点击才重新聚焦）
  final FocusNode _focusNode = FocusNode();

  /// 当前要生成二维码的内容（空 → 显示占位）
  String _text = '';

  /// 历史生成记录（去重置顶，最近的在最前，上限 [_historyLimit]）
  List<String> _history = [];

  /// 识别历史记录（同样去重置顶 + 上限 + 持久化；chips 点击回填输入框）
  List<String> _scanHistory = [];

  /// 整页滑动手势跟踪：
  /// 手势累计位移（起手指针原始事件累计；用于方向锁定 + 上滑/下滑/左右滑判定）。
  double _gestureDx = 0, _gestureDy = 0;

  /// 当前手势锁定的方向：'h' 水平 / 'v' 垂直 / null 未锁定。
  /// 首 2~3 帧按「|dx| > |dy|×1.2 锁定水平，|dy| > |dx|×1.2 锁定垂直」，
  /// 锁定后忽略另一方向位移，避免斜滑/抖动误触发。
  String? _gestureAxis;

  /// 手势起点的全局 Y（用于向下滑清空时排除输入区——起点落在 TextField 范围内不认领）
  bool _gestureStartedInInput = false;

  /// 下一次 [TextField] 构建时用于标记其局部坐标（供手势命中判定）
  final GlobalKey _inputFieldKey = GlobalKey();

  /// 保存中标志（防重复触发长按保存）
  bool _saving = false;

  /// 历史写入防抖计时器（输入停顿 [_historyDebounceDuration] 后才落历史）
  Timer? _historyDebounce;

  /// 历史写入防抖时长：输入停顿 800ms 后才写入历史（避免逐字符记录）
  static const Duration _historyDebounceDuration = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _loadHistory();
    _loadScanHistory();
    // 「按需」= 扫码意图，而非页面打开：仅当页面以识别模式进入时预热；以默认
    // 生成模式打开（只生成二维码）绝不预热，避免让这类用户被动下载模块。
    if (_mode == QrToolMode.scan) {
      _prewarmQrModule();
    }
  }

  @override
  void dispose() {
    _historyDebounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 从 shared_preferences 加载历史记录（失败不阻塞 UI）
  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_historyKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _history = stored.where((e) => e.trim().isNotEmpty).toList();
      });
    } catch (e) {
      appLog.error('QrToolPage: 加载历史记录失败 - $e');
    }
  }

  /// 从 shared_preferences 加载识别历史（失败不阻塞 UI）
  Future<void> _loadScanHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_scanHistoryKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _scanHistory = stored.where((e) => e.trim().isNotEmpty).toList();
      });
    } catch (e) {
      appLog.error('QrToolPage: 加载识别历史失败 - $e');
    }
  }

  /// 输入变化：即时更新二维码内容；历史写入改为防抖（停顿 800ms 后 [_commitHistory]）。
  /// 防抖只在生成模式生效（识别模式的回填走 [_onScanSuccess]/[_applyHistory]，不走防抖）。
  void _onTextChanged(String value) {
    final text = value.trim();
    setState(() => _text = text);
    if (_mode != QrToolMode.generate) return;
    _historyDebounce?.cancel();
    _historyDebounce = Timer(_historyDebounceDuration, _commitHistory);
  }

  /// 防抖到期：把当前非空内容去重置顶写入历史（与首条相同则跳过），异步持久化
  void _commitHistory() {
    final text = _text.trim();
    if (text.isEmpty || (_history.isNotEmpty && _history.first == text)) return;
    setState(() {
      _history = [text, ..._history.where((e) => e != text)]
          .take(_historyLimit)
          .toList();
    });
    unawaited(_persistHistory());
  }

  /// 将当前历史写回 shared_preferences（fire-and-forget，失败仅记录日志）
  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, _history);
    } catch (e) {
      appLog.error('QrToolPage: 写入历史记录失败 - $e');
    }
  }

  /// 将当前识别历史写回 shared_preferences（fire-and-forget，失败仅记录日志）
  Future<void> _persistScanHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_scanHistoryKey, _scanHistory);
    } catch (e) {
      appLog.error('QrToolPage: 写入识别历史失败 - $e');
    }
  }

  /// 点击历史 chip：回填输入框并重新生成二维码（识别模式回填后不再自动重新扫描）
  void _applyHistory(String item) {
    _historyDebounce?.cancel();
    _controller.text = item;
    _controller.selection = TextSelection.collapsed(offset: item.length);
    setState(() => _text = item);
  }

  /// 清空当前模式对应的历史记录
  void _clearHistory() {
    setState(() {
      if (_mode == QrToolMode.scan) {
        _scanHistory = [];
      } else {
        _history = [];
      }
    });
    unawaited(
        _mode == QrToolMode.scan ? _persistScanHistory() : _persistHistory());
  }

  /// 当前模式对应的历史记录（生成历史 / 识别历史）
  List<String> get _activeHistory =>
      _mode == QrToolMode.scan ? _scanHistory : _history;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // 无标题；分段切换放右侧 actions（与返回按钮不挤；短标签「生成|识别」，去图标）
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: AppSegmentedButton<QrToolMode>(
              value: _mode,
              segments: const [
                AppSegment(value: QrToolMode.generate, label: '生成'),
                AppSegment(value: QrToolMode.scan, label: '识别'),
              ],
              onChanged: _onModeChanged,
              density: VisualDensity.compact,
            ),
          ),
        ],
      ),
      // 悬浮清除按钮已移除：清空输入由「下滑」手势承担（见 _onGestureUp），
      // 避免与手势系统重复、也减少页面冗余控件。
      body: Listener(
        // 整页滑动手势：上滑=历史 / 下滑=清空(起点非输入区) / 左右滑=切模式。
        // 必须放在 Stack 最外层：Stack hitTest 逆序、命中即停——若 Listener 作为
        // Stack 的兄弟层，会被上层 TextField 拦截而收不到任何指针事件。
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onGestureDown,
        onPointerMove: _onGestureMove,
        onPointerUp: _onGestureUp,
        child: Stack(
          children: [
            // 主体内容：预览区 + 输入区（历史记录已移入底部弹窗）
            Padding(
              padding: AppSpacing.allLG,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 预览区 / 输入区 5:4：预览(取景/生成)与输入框区域接近均衡，
                  // 视觉比例协调；键盘弹出时输入区先收缩、预览等比缩小。
                  Expanded(flex: 5, child: _buildQrArea(context)),
                  const SizedBox(height: AppSpacing.sm),

                  // 输入区（flex 4 ≈ 剩余空间，撑开多行输入；识别模式下只读展示识别结果）
                  // 底部留白避免输入框贴地（视觉上浮起，与页面留白协调）
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: TextField(
                        key: _inputFieldKey,
                        controller: _controller,
                        focusNode: _focusNode,
                        // 识别模式结果只读；生成模式可编辑
                        readOnly: _mode == QrToolMode.scan,
                        // 识别结果长按可选择/复制（系统选择菜单）
                        enableInteractiveSelection: true,
                        // 长按输入框：
                        // - 识别/只读模式：只提供「复制全文」；
                        // - 生成/可编辑模式：使用 EditableText 的系统默认按钮
                        //   （剪切 / 复制 / 粘贴 / 全选）。
                        // 注意：不能直接传 null——显式 null 会覆盖 TextField
                        // 构造函数的默认 contextMenuBuilder，导致系统菜单消失。
                        contextMenuBuilder: (context, editableTextState) {
                          if (_mode == QrToolMode.scan) {
                            return AdaptiveTextSelectionToolbar.buttonItems(
                              anchors: editableTextState.contextMenuAnchors,
                              buttonItems: [
                                ContextMenuButtonItem(
                                  label: '复制',
                                  onPressed: () {
                                    // 点击后收起工具栏（自定义按钮不会自动隐藏）
                                    editableTextState.hideToolbar();
                                    _copyResult();
                                  },
                                ),
                              ],
                            );
                          }
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems:
                                editableTextState.contextMenuButtonItems,
                          );
                        },
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: _mode == QrToolMode.scan
                              ? '将二维码对准相机，识别结果自动填入此处'
                              : '输入文本或链接生成二维码',
                          hintStyle:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.outline,
                                  ),
                          border: const OutlineInputBorder(
                            borderRadius: AppRadius.allLG,
                          ),
                        ),
                        onChanged: _onTextChanged,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 右上角手势规则说明入口
            Positioned(
              top: AppSpacing.sm,
              right: AppSpacing.sm,
              child: IconButton(
                tooltip: '手势操作说明',
                icon: const Icon(TablerIcons.info_circle,
                    size: AppTypography.iconSM),
                onPressed: _showGestureHelp,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ===== 整页滑动手势系统 =====

  /// 手势方向锁定比例：|dx| > |dy|×1.2 → 水平；|dy| > |dx|×1.2 → 垂直。
  static const double _gestureLockRatio = 1.2;

  /// 触发阈值（逻辑像素）：上滑弹历史 / 下滑清空 / 左右滑切模式。
  static const double _swipeUpHistory = 80;
  static const double _swipeDownClear = 120;
  static const double _swipeHorizontalSwitch = 80;

  /// 重置手势跟踪状态（起手指针时）
  void _onGestureDown(PointerDownEvent e) {
    _gestureDx = 0;
    _gestureDy = 0;
    _gestureAxis = null;
    _gestureStartedInInput = _isPointInsideInput(e.position);
  }

  /// 手势移动：方向锁定（首帧按比例定轴，锁定后只累计该轴位移）
  void _onGestureMove(PointerMoveEvent e) {
    _gestureDx += e.delta.dx;
    _gestureDy += e.delta.dy;
    if (_gestureAxis == null) {
      if (_gestureDx.abs() > _gestureDy.abs() * _gestureLockRatio) {
        _gestureAxis = 'h';
      } else if (_gestureDy.abs() > _gestureDx.abs() * _gestureLockRatio) {
        _gestureAxis = 'v';
      }
    }
  }

  /// 手势结束：按锁定方向分派动作
  void _onGestureUp(PointerUpEvent e) {
    final axis = _gestureAxis;
    _gestureAxis = null;
    if (axis == null) return;
    final horizontal = _gestureDx;
    final vertical = _gestureDy;

    if (axis == 'h' && horizontal.abs() >= _swipeHorizontalSwitch) {
      // 左右滑切换模式：右滑=生成（预览区），左滑=识别（扫码）
      final target = horizontal > 0 ? QrToolMode.generate : QrToolMode.scan;
      if (target != _mode) {
        HapticFeedback.mediumImpact();
        _onModeChanged(target);
      }
      return;
    }

    if (axis != 'v') return;

    if (vertical <= -_swipeUpHistory) {
      // 上滑 → 弹出历史记录 sheet
      HapticFeedback.mediumImpact();
      _showHistorySheet();
    } else if (vertical >= _swipeDownClear && !_gestureStartedInInput) {
      // 下滑 → 清空输入框（起点在输入框内除外——避免编辑时误触发）
      HapticFeedback.mediumImpact();
      _clear();
    }
  }

  /// 判断指针是否落在输入框内（起点在输入区时不认领“下滑清空”，尊重编辑手势）
  bool _isPointInsideInput(Offset globalPos) {
    final box = _inputFieldKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return false;
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    return globalPos.dx >= topLeft.dx &&
        globalPos.dx <= topLeft.dx + size.width &&
        globalPos.dy >= topLeft.dy &&
        globalPos.dy <= topLeft.dy + size.height;
  }

  /// 上滑手势：弹出当前模式的历史记录底部弹窗（复用 AppDialogs.showBottomSheet）。
  /// 样式与「导入渠道包」sheet 保持一致：内容整体左右 padding 不贴边，
  /// 底部操作按钮右下角（取消 + 确认风格清空）。
  void _showHistorySheet() {
    final history = _activeHistory;
    final title = _mode == QrToolMode.scan ? '识别历史' : '历史记录';
    if (history.isEmpty) {
      AppDialogs.showInfo('暂无$title');
      return;
    }
    // 弹窗打开前收起键盘/失焦，避免关闭后焦点自动归还输入框、键盘重新弹出
    _focusNode.unfocus();
    AppDialogs.showBottomSheet(
      title: title,
      children: [
        // children 无水平 padding（标题才带），内容整体补左右边距避免贴边（对齐渠道包 sheet）
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '点击历史项回填输入框',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 历史列表（点击回填输入框并关闭弹窗）
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: Theme.of(context).colorScheme.borderLight,
                  ),
                  itemBuilder: (context, index) {
                    final item = history[index];
                    return InkWell(
                      onTap: () {
                        _applyHistory(item);
                        AppDialogs.popSheet<void>(null);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                        child: Text(
                          item,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // 操作按钮（右下角，对齐渠道包 sheet：取消 + 确认风格清空）
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => AppDialogs.popSheet<void>(null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: () {
                      _clearHistory();
                      AppDialogs.popSheet<void>(null);
                    },
                    icon: const Icon(TablerIcons.trash,
                        size: AppTypography.iconSM),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 右上角「手势操作说明」弹窗（打开前收起键盘/失焦，避免关闭后焦点归还输入框）
  Future<void> _showGestureHelp() async {
    const rules = [
      ('已启用手势', '就像在聊天软件里滑动一样，在页面内滑动即可快捷操作'),
      ('上滑', '查看历史记录'),
      ('下滑', '清空输入框（在输入框内下滑除外）'),
      ('左滑 / 右滑', '切换「识别」/「生成」模式'),
      ('长按输入框', '复制识别结果（识别模式）'),
    ];
    // 弹窗打开前收起键盘/失焦，避免关闭后焦点自动归还输入框、键盘重新弹出
    _focusNode.unfocus();
    await AppDialogs.showDialog(
      title: '手势操作说明',
      icon: const Icon(TablerIcons.swipe),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (action, desc) in rules)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      action,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  Expanded(child: Text(desc)),
                ],
              ),
            ),
        ],
      ),
      confirmText: '知道了',
    );
    // 弹窗关闭后再确保失焦（不归还输入框焦点）
    _focusNode.unfocus();
  }

  /// 长按输入框复制当前内容（识别/只读模式；内容为空时不动作）。
  /// 以 controller 实际文本为准（与识别回填 / 手输路径均一致）。
  void _copyResult() {
    final content = _controller.text;
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    AppDialogs.showSuccess('已复制');
  }

  /// 二维码预览区：生成模式显示占位/二维码；识别模式显示相机实时预览 + 识别框。
  /// 统一包一层与输入框同款的圆角描边容器（宽度一致、视觉成组），
  /// 内部内容居中；扫码相机 240 取景居中，生成内容等比放大填满可用空间。
  Widget _buildQrArea(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: AppRadius.allLG,
        border: Border.all(color: colorScheme.borderLight),
      ),
      clipBehavior: Clip.antiAlias,
      child: _mode == QrToolMode.scan
          ? Stack(
              fit: StackFit.expand,
              children: [
                _buildScanArea(context),
                // `qr` 模块自举指示：页面内（非顶部横幅，顶部横幅就绪即隐藏），
                // 贴在预览区底部中央；不拦截相机预览的点击对焦。
                const Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: AppSpacing.onlyBottomSM,
                      child: IgnorePointer(child: _QrModulePhaseChip()),
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
              ),
            ),
    );
  }

  /// 识别模式预览区：复用独立扫码组件。
  Widget _buildScanArea(BuildContext context) {
    return Center(
      child: QrScannerView(
        dimension: 240,
        availableCameras: QrToolPage.debugAvailableCameras,
        onResult: _handleScanResult,
      ),
    );
  }

  /// 扫码组件识别成功：回填输入框 + 写识别历史（组件不写历史）。
  void _handleScanResult(String text) {
    _historyDebounce?.cancel();
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() {
      _text = text;
      _scanHistory = [text, ..._scanHistory.where((e) => e != text)]
          .take(_historyLimit)
          .toList();
    });
    unawaited(_persistScanHistory());
    AppDialogs.showSuccess('已识别二维码');
  }

  /// 空输入占位提示
  Widget _buildPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allLG,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            TablerIcons.qrcode,
            size: AppTypography.iconMassive,
            color: colorScheme.outline,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '输入内容后生成二维码',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  /// 二维码预览（白底保证可扫描；圆角容器；长按弹确认框保存图片）
  Widget _buildQr() {
    return GestureDetector(
      onLongPress: _confirmSaveImage,
      child: Container(
        padding: AppSpacing.allLG,
        decoration: const BoxDecoration(
          // 二维码需要浅色底才能被识别扫描：功能必需，非主题配色
          color: Colors.white,
          borderRadius: AppRadius.allLG,
        ),
        child: QrImageView(
          data: _text,
          version: QrVersions.auto,
          size: 240,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }

  /// 长按确认后保存图片（确认框 → 真保存）
  Future<void> _confirmSaveImage() async {
    if (_saving) return;
    // 长按先收起键盘
    _focusNode.unfocus();
    final confirmed = await AppDialogs.showDialog(
      title: '保存二维码',
      content: '将二维码图片保存到系统相册?',
      confirmText: '保存',
      cancelText: '取消',
    );
    if (confirmed != true || !mounted) return;
    await _saveImage();
    // 抵消确认框关闭时的焦点恢复：保存后输入框保持失焦，用户主动点击才重新聚焦
    _focusNode.unfocus();
  }

  /// 保存二维码：PNG 写应用文档目录 qr_codes/<时间戳>.png（保留落盘），
  /// 并同步写入系统相册（gal）；提示以相册结果为准。
  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final byteData = await _renderQrImage();
      if (byteData == null) {
        throw const FileSystemException('生成二维码图片失败');
      }
      // 应用目录落盘保留（不再作为主提示）
      await _writePng(byteData);
      // 系统相册写入（gal）：成功为主提示；失败仅提示，不影响已落盘文件
      final galleryOk = await _saveToGallery(byteData.buffer.asUint8List());
      if (!mounted) return;
      if (galleryOk) {
        AppDialogs.showSuccess('已保存到相册');
      } else {
        AppDialogs.showError('保存到相册失败');
      }
    } catch (e) {
      if (mounted) AppDialogs.showError('保存二维码失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存用画布边长（px）
  static const double _qrSaveSize = 512;

  /// 保存用 QR 与白底之间留白（px）
  static const double _qrSavePadding = 48;

  /// 保存用白底圆角半径（px）
  static const double _qrSaveRadius = 32;

  /// 合成保存用二维码 PNG：512×512 白色圆角背景 + 居中 QR（padding 留白），
  /// 替代 QrPainter.toImageData 的透明背景输出；失败返回 null。
  Future<ByteData?> _renderQrImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const rect = Rect.fromLTWH(0, 0, _qrSaveSize, _qrSaveSize);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_qrSaveRadius)),
      Paint()..color = Colors.white,
    );
    canvas.translate(_qrSavePadding, _qrSavePadding);
    QrPainter(
      data: _text,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    ).paint(
      canvas,
      const Size(
          _qrSaveSize - 2 * _qrSavePadding, _qrSaveSize - 2 * _qrSavePadding),
    );
    final picture = recorder.endRecording();
    final image =
        await picture.toImage(_qrSaveSize.round(), _qrSaveSize.round());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData;
  }

  /// 将 PNG 字节写入系统相册（gal）。返回是否成功；失败仅记录日志不抛出。
  /// 测试通过 [QrToolPage.debugGallerySucceeds] 注入结果，避免依赖真实相册。
  Future<bool> _saveToGallery(Uint8List bytes) async {
    final injected = QrToolPage.debugGallerySucceeds;
    if (injected != null) return injected;
    try {
      await Gal.putImageBytes(
        bytes,
        name: 'qr_${DateTime.now().millisecondsSinceEpoch}',
      );
      return true;
    } catch (e) {
      appLog.error('QrToolPage: 写入系统相册失败 - $e');
      return false;
    }
  }

  /// 将 PNG 字节写入文档目录 qr_codes/（参照 apk_info_service._saveIconBytes）
  Future<String> _writePng(ByteData byteData) async {
    final dir = await getApplicationDocumentsDirectory();
    final qrDir = Directory('${dir.path}/qr_codes');
    await qrDir.create(recursive: true);
    final file =
        File('${qrDir.path}/${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData.buffer.asUint8List());
    debugPrint('QrToolPage: 二维码已保存 - ${file.path}');
    return file.path;
  }

  /// 提前点火 `qr` 原生模块的下载与挂载，使其与相机初始化**并行**（而非等首帧
  /// 解码才触发）。「按需」按的是**扫码意图**（进页面即识别 / 切到识别），不是
  /// 页面打开：仅生成二维码的用户不调用本方法，避免被动下载。
  void _prewarmQrModule() {
    QrRustDecoder.prewarm();
  }

  /// 模式切换：切到识别 → 预热 qr 模块 + 初始化并启动相机；切回生成 → 释放相机
  /// （切回识别再重新初始化）。
  void _onModeChanged(QrToolMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == QrToolMode.scan) {
      _prewarmQrModule();
    }
  }

  void _clear() {
    _historyDebounce?.cancel();
    _controller.clear();
    setState(() {
      _text = '';
    });
  }
}

/// 识别模式的 `qr` 模块自举指示 chip（页面内，非顶部横幅——顶部横幅就绪即隐藏）。
///
/// * `absent`/`downloading`/`initializing` → 「准备中」（进行中状态带 [AppLoading]）；
/// * `ready` → 短暂显示「已就绪」后自动隐藏（自消失，不长期占用预览）；
/// * `failed` → 弱化的「模块加载失败」，不崩溃、不遮挡/不阻塞相机预览。
///
/// 订阅 [qrModulePhaseProvider]；测试可 `overrideWith` 注入受控阶段流。
class _QrModulePhaseChip extends ConsumerStatefulWidget {
  const _QrModulePhaseChip();

  @override
  ConsumerState<_QrModulePhaseChip> createState() => _QrModulePhaseChipState();
}

class _QrModulePhaseChipState extends ConsumerState<_QrModulePhaseChip> {
  /// 「已就绪」保留时长：短暂反馈后自动消失，避免长期遮挡预览。
  static const Duration _readyVisibleDuration = Duration(milliseconds: 1500);

  Timer? _readyTimer;
  bool _readyVisible = false;
  ModuleBootstrapPhase? _observedPhase;

  @override
  void dispose() {
    _readyTimer?.cancel();
    super.dispose();
  }

  /// 阶段跃迁副作用：`ready` 时启动「短暂显示后隐藏」计时；其它阶段取消隐藏。
  /// 由 [build] 在订阅值变化时驱动（[_observedPhase] 去重，计时器只建一次）。
  void _onPhaseChanged(ModuleBootstrapPhase phase) {
    if (phase == _observedPhase) return;
    _observedPhase = phase;
    _readyTimer?.cancel();
    if (phase == ModuleBootstrapPhase.ready) {
      _readyVisible = true;
      _readyTimer = Timer(_readyVisibleDuration, () {
        if (mounted) setState(() => _readyVisible = false);
      });
    } else {
      _readyVisible = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(qrModulePhaseProvider).valueOrNull ??
        ModuleBootstrapPhase.absent;
    _onPhaseChanged(phase);

    // 就绪提示是「一次性」反馈：短暂显示后自行消失，不长期占用预览。
    if (phase == ModuleBootstrapPhase.ready && !_readyVisible) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    switch (phase) {
      case ModuleBootstrapPhase.ready:
        return _buildChip(
          context,
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
          leading: Icon(
            TablerIcons.circle_check,
            size: AppTypography.iconSM,
            color: scheme.onSecondaryContainer,
          ),
          label: '已就绪',
        );
      case ModuleBootstrapPhase.failed:
        return _buildChip(
          context,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.outline,
          leading: Icon(
            TablerIcons.alert_circle,
            size: AppTypography.iconSM,
            color: scheme.outline,
          ),
          label: '模块加载失败',
        );
      case ModuleBootstrapPhase.absent:
      case ModuleBootstrapPhase.downloading:
      case ModuleBootstrapPhase.initializing:
        return _buildChip(
          context,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
          leading: const AppLoading(size: AppLoadingSize.small),
          label: '准备中',
        );
    }
  }

  /// 统一 chip 外观：圆角胶囊 + [leading]（图标/Loading）+ 文案（颜色取自主题）。
  Widget _buildChip(
    BuildContext context, {
    required Color background,
    required Color foreground,
    required Widget leading,
    required String label,
  }) {
    return Container(
      padding: AppSpacing.chipPadding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.allCircle,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

/// 码眼预览绘制：在 240×240 预览窗上绘制码眼映射点（实心小圆点 + 描边提高可见性）。
/// 坐标由 [_QrToolPageState._mappedEyePoints] 提供（帧坐标 → 预览窗 cover 近似映射）。
