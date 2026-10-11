import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_animation.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_app_identity.dart';
import 'proxy_capture_bridge.dart';
import 'proxy_capture_ca_gate.dart';
import 'proxy_capture_debug_bridge.dart';
import 'proxy_capture_detail_page.dart';
import 'proxy_capture_settings_page.dart';
import 'proxy_requests_facade.dart';
import 'proxy_requests_paging.dart';

/// 单次 `requests.get` 拉取上限（游标前向翻页的页大小）。
const int _pageLimit = 200;

/// 单次 `captures.get` 拉取上限；与 [ _pageLimit ] **独立**（两条流各自分页，
/// join 只在展示层，不落盘）。
const int _capturesLimit = 200;

/// 自动前向翻页的页数上限（保护：坏后端重复返回满页时不会死循环）。
/// 单流上限：200 × 64 = 12800 条，覆盖 ring/DB 的保留上限。
const int _maxAutoPages = 64;

/// 分组视图（Top 应用 / 域名 / IP、出站 / 规则分布）展示条数。
const int _groupLimit = 5;

/// 时间线趋势的桶数量与桶宽（按分钟聚合）。
const int _trendBucketCount = 24;
const int _trendBucketMs = 60 * 1000;

/// 单次渲染请求行上限，避免超长列表一次性 build（取最新 N 条）。
const int _maxRendered = 500;

/// 实时兜底轮询周期（脏信号为主、此定时器仅兜底）。
const Duration _fallbackInterval = Duration(seconds: 2);

/// 时间范围选项（`sinceMs` 由当前时间回推）。
class _RangeOption {
  const _RangeOption(this.label, this.rangeMs);

  final String label;
  final int rangeMs;
}

const List<_RangeOption> _rangeOptions = <_RangeOption>[
  _RangeOption('全部', 0),
  _RangeOption('5 分钟', 5 * 60 * 1000),
  _RangeOption('1 小时', 60 * 60 * 1000),
  _RangeOption('24 小时', 24 * 60 * 60 * 1000),
];

/// 网络类型筛选项（`null` = 全部；保留既有能力）。
const List<String?> _networkOptions = <String?>[null, 'tcp', 'udp'];

/// 协议筛选项（`null` = 全部；对应 `CaptureRecord.protocol`）。
const List<String?> _protocolOptions = <String?>[null, 'h1', 'h2', 'ws'];

/// HTTP 状态段筛选项（`null` = 全部；对应 `statusCode ~/ 100`）。
const List<int?> _statusOptions = <int?>[null, 1, 2, 3, 4, 5];

/// 方法筛选项（`null` = 全部；大小写不敏感精确匹配）。
const List<String?> _methodOptions = <String?>[
  null,
  'GET',
  'POST',
  'PUT',
  'DELETE',
  'PATCH',
  'HEAD',
  'OPTIONS',
];

/// 列表排序方式（稳定排序：相等键保持原相对顺序）。
enum _SortMode {
  order('默认', TablerIcons.list),
  newest('最新优先', TablerIcons.arrow_down),
  oldest('最早优先', TablerIcons.arrow_up),
  largest('按大小', TablerIcons.arrows_sort);

  const _SortMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 导出另存的测试接缝：调用系统保存对话框并返回落地路径（取消 → `null`）。
///
/// 生产默认走 [FilePicker.platform.saveFile]，测试注入假实现断言「保存被调用」。
typedef ProxyRequestsSaveFile = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
});

/// 读取 Rust 侧已生成导出文件字节的测试接缝。
typedef ProxyRequestsReadFile = Future<Uint8List> Function(String path);

/// 一次导出的落地目标（Rust 产物路径 → 另存文件名 / 扩展名）。
class _ExportTarget {
  const _ExportTarget({
    required this.path,
    required this.fileName,
    required this.allowedExtensions,
  });

  final String path;
  final String fileName;
  final List<String> allowedExtensions;
}

/// 导出格式选项行（统一弹层内容；避免 [ListTile] 对 Material 祖先的依赖）。
class _ExportOption extends StatelessWidget {
  const _ExportOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconMD,
              color: scheme.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              TablerIcons.chevron_right,
              size: AppTypography.iconMD,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表优先的「请求域名 / IP」页（Todo 22 重做）。
///
/// **数据叠加语义（硬性）**：
/// * 行以 `requests.get` 的**流记录为骨架**，按
///   `CaptureRecord.requestRecordId == RequestRecord.recordId` 叠加
///   `captures.get` 的 HTTP 详情；
/// * 一个流可叠加**多条** capture（keep-alive / h2 mux），行摘要取**最新一条**
///   （`recordId` 最大）；
/// * 无 capture 的流显示「未解密」（仅流级字段）；
/// * 孤儿 capture（`requestRecordId == 0`）与未能匹配到当前骨架窗口的 capture
///   **自成一行（capture 驱动），不得丢弃**；
/// * `captures.get` 与 `requests.get` **各自独立分页**（各自取 `limit`），join
///   只在展示层，**不在 Dart 落盘**。
///
/// 保留既有能力：搜索 / 筛选、分组分析（Top / 趋势 / DNS 质量 / 出站 / 规则）、
/// 导出、清空、实时拉取、行点击详情。
///
/// 门面与事件流均经构造函数注入，测试无需原生模块（[facade] 默认适配
/// [ProxyModule]，[events] 默认取 [ProxyModule.instance] 的事件流）。
class ProxyRequestsPage extends StatefulWidget {
  const ProxyRequestsPage({
    super.key,
    this.facade,
    this.events,
    this.initialLive = true,
    this.saveFile,
    this.readFile,
    this.captureDetailFacade,
    this.captureDeleteFacade,
    this.captureActionBinder,
    this.initialDomain,
  });

  /// 收集页门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyRequestsFacade? facade;

  /// 类型化代理事件流（测试可注入；为空时用 [ProxyModule.instance]）。
  final Stream<ProxyEvent>? events;

  /// 初始是否开启实时（脏信号 + 2s 兜底）。
  final bool initialLive;

  /// 导出另存接缝（测试注入；为空时走 [FilePicker.platform.saveFile]）。
  final ProxyRequestsSaveFile? saveFile;

  /// 导出文件读取接缝（测试注入；为空时读本地文件）。
  final ProxyRequestsReadFile? readFile;

  /// 全屏抓包详情页（[ProxyCaptureDetailPage]）的拉取门面注入缝。
  ///
  /// `null` = 详情页使用生产适配器（[ProxyModuleCaptureDetailFacade]）。
  /// 测试注入假实现即可断言「跳转携带正确 `recordId`」而无需原生模块。
  final ProxyCaptureDetailFacade? captureDetailFacade;

  /// 全屏详情页（[ProxyCaptureDetailPage]）的删除门面注入缝。
  ///
  /// `null` = 详情页使用生产适配器（[ProxyModuleCaptureDeleteFacade]）。
  /// 测试注入假实现即可断言「删除携带正确 `recordId`」而无需原生模块。
  final ProxyCaptureDeleteFacade? captureDeleteFacade;

  /// 全屏详情页动作桥注入缝（复制 cURL / 保存到请求调试 / 创建改写规则）。
  ///
  /// `null` = 使用生产装配 [productionCaptureActionBinder]（仅在首次点击抓包行
  /// 时惰性构建，避免页面初始化即触碰请求调试 store）。
  final CaptureDetailActionBinder? captureActionBinder;

  /// 初始域名筛选（下钻接缝）：非空时预填搜索框并按该域名本地过滤。
  final String? initialDomain;

  @override
  State<ProxyRequestsPage> createState() => _ProxyRequestsPageState();
}

class _ProxyRequestsPageState extends State<ProxyRequestsPage>
    with WidgetsBindingObserver {
  late final ProxyRequestsFacade _facade;
  late final Stream<ProxyEvent> _events;
  late final ProxyRequestsSaveFile _saveFile;
  late final ProxyRequestsReadFile _readFile;

  /// CA 门控接缝：门面实现 [ProxyCaptureCaGate] 时启用（生产恒启用）。
  ProxyCaptureCaGate? _caGate;

  /// 列表单条删除门面（`captures.delete`）：详情页与长按菜单共用。
  late final ProxyCaptureDeleteFacade _deleteFacade;

  /// 详情页动作绑定（首次点击抓包行时构建；优先注入缝，否则生产装配）。
  late final CaptureDetailActionBinder _captureActionBinder =
      widget.captureActionBinder ?? productionCaptureActionBinder();

  StreamSubscription<ProxyEvent>? _eventSub;
  Timer? _fallbackTimer;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _filterAppController = TextEditingController();
  final TextEditingController _filterOutboundController =
      TextEditingController();

  bool _live = true;
  bool _visible = true;
  bool _loading = true;
  bool _pullInFlight = false;
  bool _exporting = false;
  bool _loadingMore = false;

  /// 跨页累计的请求骨架 / 抓包详情（按 `recordId` 去重）。
  List<RequestRecord> _requests = <RequestRecord>[];
  List<CaptureRecord> _captures = <CaptureRecord>[];

  /// 最近一页的元数据（`retained` / `nextCursor` / `firstCursor`）。
  RequestPage? _requestsPage;
  CapturePage? _capturesPage;

  /// 是否仍有更“新”的页可拉（游标前向分页的续页标志）。
  bool _requestsHasMore = false;
  bool _capturesHasMore = false;

  String? _error;

  /// `captures.get` 拉取失败 → 列表降级为仅流级信息（不视为致命错误）。
  bool _capturesDegraded = false;

  /// 抓包总开关（`capture.config`）；`null` = 尚未读取到（best-effort）。
  bool? _captureEnabled;
  CaptureConfig? _captureConfig;
  bool _captureBusy = false;

  // ---- 本地筛选状态 ----
  String _searchQuery = '';
  String _appQuery = '';
  String _outboundQuery = '';
  String? _network;
  String? _protocol;
  int? _statusClass;
  String? _method;
  bool _errorsOnly = false;
  int _rangeMs = 0;

  /// 列表排序方式（默认沿用后端顺序）。
  _SortMode _sortMode = _SortMode.order;

  /// 分析区是否展开（默认折叠）。
  bool _analysisExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _facade = widget.facade ?? ProxyModuleRequestsFacade();
    _caGate = _facade is ProxyCaptureCaGate
        ? _facade as ProxyCaptureCaGate
        : null;
    _deleteFacade =
        widget.captureDeleteFacade ?? ProxyModuleCaptureDeleteFacade();
    _events = widget.events ?? ProxyModule.instance.events;
    _saveFile = widget.saveFile ?? _defaultSaveFile;
    _readFile = widget.readFile ?? _defaultReadFile;
    _live = widget.initialLive;
    final initialDomain = widget.initialDomain?.trim() ?? '';
    if (initialDomain.isNotEmpty) {
      _searchController.text = initialDomain;
      _searchQuery = initialDomain.toLowerCase();
    }
    _eventSub = _events.listen(_onEvent);
    if (_live) _startFallback();
    unawaited(_load());
    unawaited(_ensureAppIdentities());
  }

  @override
  void dispose() {
    _stopFallback();
    _eventSub?.cancel();
    _eventSub = null;
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _filterAppController.dispose();
    _filterOutboundController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 页面不可见（后台 / 暂停）时停表；恢复前台且实时开启时续上。
    final visible = state == AppLifecycleState.resumed;
    if (visible == _visible) return;
    _visible = visible;
    if (!_visible) {
      _stopFallback();
    } else if (_live) {
      _startFallback();
    }
  }

  // ==================== 实时 ====================

  /// 脏信号（`proxy.request`）→ 增量拉取（**拉取为准**）。
  ///
  /// 实时关闭或页面不可见时忽略；[dispose] 取消订阅。
  void _onEvent(ProxyEvent event) {
    if (!mounted || !_visible || !_live) return;
    if (event is ProxyRequestEvent) {
      unawaited(_poll());
    }
  }

  void _startFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(
      _fallbackInterval,
      (_) => unawaited(_poll()),
    );
  }

  void _stopFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }

  void _toggleLive() {
    setState(() => _live = !_live);
    if (_live) {
      _startFallback();
      unawaited(_poll());
    } else {
      _stopFallback();
    }
  }

  // ==================== 加载 ====================

  /// 手动 / 首屏加载：整页 loading。
  Future<void> _load() => _reload(silent: false);

  /// 预加载已安装应用身份（惰性、缓存、失败静默）。
  ///
  /// 完成后刷新一次，使列表 / 详情用人类可读的应用名 + 图标替换包名；
  /// 加载失败（非 Android / 插件缺失 / 测试环境）时不改变任何现有展示。
  Future<void> _ensureAppIdentities() async {
    await ProxyAppIdentityResolver.instance.ensureLoaded();
    if (mounted) setState(() {});
  }

  /// 全量重载：清空累计、从 `cursor = 0` 起前向翻页到耗尽（有界），
  /// 按 `recordId` 去重后落地。筛选变化 / 刷新 / 首屏走此路径。
  Future<void> _reload({required bool silent}) async {
    if (_pullInFlight) return;
    _pullInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final loaded = <RequestRecord>[];
      RequestPage? last;
      int? cursor;
      var hasMore = false;
      var pages = 0;
      do {
        final page = await _facade.requestsGet(_buildRequest(cursor: cursor));
        last = page;
        loaded.addAll(page.records);
        if (page.records.isNotEmpty) {
          cursor = page.records.last.recordId;
        }
        hasMore = page.records.length >= _pageLimit &&
            cursor != null &&
            cursor < page.nextCursor;
      } while (hasMore && ++pages < _maxAutoPages);

      final records = mergeById<RequestRecord>(
        const <RequestRecord>[],
        loaded,
        (record) => record.recordId,
      );
      if (!mounted) return;
      setState(() {
        _requests = records;
        _requestsPage = last;
        _requestsHasMore = hasMore;
        _loading = false;
        _error = null;
      });
      await _fetchAux();
    } on ProxyModuleException catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = '请求列表加载失败：$error';
        _loading = false;
      });
    } finally {
      _pullInFlight = false;
    }
  }

  /// 增量拉取：以当前累计的最后一条 `recordId` 为游标，只取更新的页并合并去重。
  /// 实时脏信号 / 兜底轮询 / 「加载更多」走此路径。
  Future<void> _poll() async {
    if (_pullInFlight) return;
    _pullInFlight = true;
    try {
      final reqCursor = _requests.isEmpty ? null : _requests.last.recordId;
      final page = await _facade.requestsGet(_buildRequest(cursor: reqCursor));
      if (!mounted) return;
      final merged = mergeById(
        _requests,
        page.records,
        (record) => record.recordId,
      );
      final mergedCursor = merged.isEmpty ? null : merged.last.recordId;
      setState(() {
        _requests = merged;
        _requestsPage = page;
        _requestsHasMore = page.records.length >= _pageLimit &&
            mergedCursor != null &&
            mergedCursor < page.nextCursor;
        // 首次整页加载失败后，若后续实时 / 兜底拉取成功，必须清除错误态，
        // 否则列表永久冻结在「请求列表不可用」。
        _error = null;
      });
      await _pollCaptures();
    } on ProxyModuleException catch (_) {
      // 静默：保留现有数据。
    } catch (_) {
      // 静默：保留现有数据。
    } finally {
      _pullInFlight = false;
    }
  }

  Future<void> _pollCaptures() async {
    final capCursor = _captures.isEmpty ? null : _captures.last.recordId;
    try {
      final page =
          await _facade.capturesGet(_buildCapturesRequest(cursor: capCursor));
      if (!mounted) return;
      setState(() {
        _captures = mergeById(
          _captures,
          page.records,
          (capture) => capture.recordId,
        );
        _capturesPage = page;
        _capturesDegraded = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _capturesDegraded = true);
    }
  }

  /// 手动加载下一页（仅在前向游标仍有更“新”记录时出现）。
  Future<void> _loadMore() async {
    if (_loadingMore || _pullInFlight) return;
    setState(() => _loadingMore = true);
    try {
      await _poll();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// `captures.get` + `capture.config.get` 的 best-effort 叠加（失败静默降级）。
  Future<void> _fetchAux() async {
    try {
      final loaded = <CaptureRecord>[];
      CapturePage? last;
      int? cursor;
      var hasMore = false;
      var pages = 0;
      do {
        final page =
            await _facade.capturesGet(_buildCapturesRequest(cursor: cursor));
        last = page;
        loaded.addAll(page.records);
        if (page.records.isNotEmpty) {
          cursor = page.records.last.recordId;
        }
        hasMore = page.records.length >= _capturesLimit &&
            cursor != null &&
            cursor < page.nextCursor;
      } while (hasMore && ++pages < _maxAutoPages);

      if (!mounted) return;
      setState(() {
        _captures = mergeById<CaptureRecord>(
          const <CaptureRecord>[],
          loaded,
          (capture) => capture.recordId,
        );
        _capturesPage = last;
        _capturesHasMore = hasMore;
        _capturesDegraded = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _capturesDegraded = true);
    }
    await _fetchCaptureConfig();
  }

  Future<void> _fetchCaptureConfig() async {
    try {
      final config = await _facade.captureConfigGet();
      if (!mounted) return;
      setState(() {
        _captureConfig = config;
        _captureEnabled = config.enabled;
      });
    } catch (_) {
      // 忽略：开关展示为未知/关闭。
    }
  }

  RequestGetRequest _buildRequest({int? cursor}) {
    return RequestGetRequest(
      cursor: cursor,
      limit: _pageLimit,
      filter: _buildRequestsFilter(),
    );
  }

  RequestsFilter? _buildRequestsFilter() {
    final sinceMs = _rangeMs > 0
        ? DateTime.now().millisecondsSinceEpoch - _rangeMs
        : null;
    if (_outboundQuery.isEmpty && sinceMs == null && _network == null) {
      return null;
    }
    return RequestsFilter(
      network: _network,
      outbound: _outboundQuery.isEmpty ? null : _outboundQuery,
      sinceMs: sinceMs,
    );
  }

  CapturesGetRequest _buildCapturesRequest({int? cursor}) {
    return CapturesGetRequest(
      cursor: cursor,
      limit: _capturesLimit,
      filter: _buildCapturesFilter(),
    );
  }

  CapturesFilter? _buildCapturesFilter() {
    if (_protocol == null && _method == null && _statusClass == null) {
      return null;
    }
    return CapturesFilter(
      protocol: _protocol,
      method: _method,
      statusClass: _statusClass,
    );
  }

  Future<void> _confirmReset() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空请求记录',
      message: '将清空全部请求记录与抓包内容（含已解密内容），且无法撤销。确定继续吗？',
      confirmText: '清空',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (ok != true || !mounted) return;
    try {
      // 先清抓包（含已解密行），再清请求骨架；两者都成功后才提示并刷新。
      await _facade.capturesReset();
      await _facade.requestsReset();
      if (!mounted) return;
      AppDialogs.showSuccess('已清空请求记录');
      await _load();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '清空失败');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('清空失败：$error');
    }
  }

  // ==================== 抓包开关（迷你） ====================

  /// CA 拦截弹层「去设置」：打开抓包设置页（可进入「证书管理」）。
  void _openCaptureSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProxyCaptureSettingsPage(),
      ),
    );
  }

  /// 列表页「抓包」迷你开关：开启前复用首页 CA 门控（无根证书则拦截并引导）。
  Future<void> _toggleCapture() async {
    if (_captureBusy) return;
    final current = _captureEnabled ?? false;
    final next = !current;
    if (next) {
      final gate = _caGate;
      if (gate != null) {
        final result = await ensureCaptureCaGate(
          captureCaGet: gate.captureCaGet,
          onOpenCaptureSettings: _openCaptureSettings,
        );
        if (!mounted || !result.allowed) return;
      }
    }
    setState(() {
      _captureBusy = true;
      _captureEnabled = next;
    });
    try {
      final config = (_captureConfig ?? const CaptureConfig())
          .copyWith(enabled: next);
      final applied = await _facade.captureConfigSet(config);
      if (!mounted) return;
      setState(() {
        _captureConfig = applied;
        _captureEnabled = applied.enabled;
        _captureBusy = false;
      });
      AppDialogs.showSuccess(next ? '已开启抓包' : '已关闭抓包');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _captureEnabled = current;
        _captureBusy = false;
      });
      AppDialogs.showError(
        error is ProxyModuleException ? error.message : '抓包开关下发失败：$error',
        title: '操作失败',
      );
    }
  }

  // ==================== 导出 ====================

  /// 「导出」入口：统一 [AppSheet] 选择 CSV / JSON / 两者。
  ///
  /// 选择后调用 `requests.export` 拿到 Rust 侧生成的文件路径与字节，再经
  /// [ProxyRequestsSaveFile] 另存。用户取消（弹层返回 `null` 或 `saveFile`
  /// 返回 `null`）**不报错、不提示失败**；成功提示包含行数；失败走
  /// [AppDialogs.showError] 且不崩溃。
  Future<void> _export() async {
    if (_exporting) return;
    final format = await AppDialogs.showContentSheet<String>(
      title: '导出请求记录',
      icon: const Icon(TablerIcons.file_download),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExportOption(
            key: const Key('requests_export_csv'),
            icon: TablerIcons.file_description,
            title: 'CSV',
            subtitle: '适合电子表格 / 数据分析',
            onTap: () => AppDialogs.popSheet<String>('csv'),
          ),
          _ExportOption(
            key: const Key('requests_export_json'),
            icon: TablerIcons.braces,
            title: 'JSON',
            subtitle: '适合程序化处理',
            onTap: () => AppDialogs.popSheet<String>('json'),
          ),
          _ExportOption(
            key: const Key('requests_export_both'),
            icon: TablerIcons.files,
            title: 'CSV + JSON',
            subtitle: '同时导出两种格式',
            onTap: () => AppDialogs.popSheet<String>('both'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<String>(null),
          child: const Text('取消'),
        ),
      ],
    );
    if (format == null || !mounted) return;
    await _runExport(format);
  }

  /// 执行导出：`requestsExport` → 读字节 → 另存。
  Future<void> _runExport(String format) async {
    setState(() => _exporting = true);
    RequestExportResult result;
    try {
      result = await _facade.requestsExport(
        RequestExportRequest(format: format, filter: _buildRequestsFilter()),
      );
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError(error.message, title: '导出失败');
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError('导出失败：$error', title: '导出失败');
      return;
    }
    if (!mounted) return;

    final timestamp = _exportTimestamp();
    final targets = <_ExportTarget>[
      if (result.csvPath != null && result.csvPath!.isNotEmpty)
        _ExportTarget(
          path: result.csvPath!,
          fileName: 'gstore_requests_$timestamp.csv',
          allowedExtensions: const <String>['csv'],
        ),
      if (result.jsonPath != null && result.jsonPath!.isNotEmpty)
        _ExportTarget(
          path: result.jsonPath!,
          fileName: 'gstore_requests_$timestamp.json',
          allowedExtensions: const <String>['json'],
        ),
    ];
    if (targets.isEmpty) {
      setState(() => _exporting = false);
      AppDialogs.showError('未生成可导出的文件', title: '导出失败');
      return;
    }

    try {
      var saved = 0;
      for (final target in targets) {
        final bytes = await _readFile(target.path);
        final outputPath = await _saveFile(
          fileName: target.fileName,
          bytes: bytes,
          allowedExtensions: target.allowedExtensions,
        );
        // 取消（返回 null / 空路径）：静默停止，不报错、不提示失败。
        if (outputPath == null || outputPath.isEmpty) {
          if (mounted) setState(() => _exporting = false);
          return;
        }
        saved++;
      }
      if (!mounted) return;
      setState(() => _exporting = false);
      final suffix = saved > 1 ? '（CSV + JSON）' : '';
      AppDialogs.showSuccess(
        '已导出 ${result.rows} 条请求记录$suffix',
        title: '导出成功',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError('导出失败：$error', title: '导出失败');
    }
  }

  /// 生产默认另存：系统保存对话框（与日志 / 备份导出同机制）。
  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存请求记录',
      fileName: fileName,
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }

  /// 生产默认读取：读 Rust 侧生成的导出文件字节。
  static Future<Uint8List> _defaultReadFile(String path) =>
      File(path).readAsBytes();

  /// 导出文件名时间戳（`yyyyMMdd_HHmmss`）。
  String _exportTimestamp() {
    final now = DateTime.now();
    return '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  }

  // ==================== 数据叠加（展示层 join，不落盘） ====================

  /// 骨架行 + 孤儿 capture 行（未套用筛选、未截断）。
  List<_UnifiedRow> _allRows() {
    final requests = _requests;
    final captures = _captures;

    // `requestRecordId -> 最新 capture`（recordId 单调，取最大者作摘要）。
    final byRequestId = <int, CaptureRecord>{};
    for (final capture in captures) {
      if (capture.requestRecordId == 0) continue;
      final existing = byRequestId[capture.requestRecordId];
      if (existing == null || capture.recordId > existing.recordId) {
        byRequestId[capture.requestRecordId] = capture;
      }
    }

    final skeletonIds = requests.map((record) => record.recordId).toSet();
    final rows = <_UnifiedRow>[
      for (final record in requests)
        _UnifiedRow(request: record, capture: byRequestId[record.recordId]),
    ];
    // 未被骨架匹配的 capture（含孤儿 `requestRecordId == 0`）自成一行，绝不丢弃。
    for (final capture in captures) {
      if (capture.requestRecordId != 0 &&
          skeletonIds.contains(capture.requestRecordId)) {
        continue;
      }
      rows.add(_UnifiedRow(capture: capture));
    }
    return rows;
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 当前窗口经本地筛选后的行（同时转发后端可支持的过滤字段）。
  List<_UnifiedRow> get _visibleRows {
    final nowMs = _nowMs();
    final matched = _allRows().where((row) {
      if (!_matchesSearch(row)) return false;
      if (!_matchesFilters(row, nowMs)) return false;
      return true;
    }).toList();
    final sorted = _sortRows(matched);
    return sorted.length <= _maxRendered
        ? sorted
        : sorted.sublist(0, _maxRendered);
  }

  /// 稳定排序（相等键保持原相对顺序）。
  List<_UnifiedRow> _sortRows(List<_UnifiedRow> rows) {
    switch (_sortMode) {
      case _SortMode.order:
        return rows;
      case _SortMode.newest:
        return stableSortBy(rows, (a, b) => b.timeMs.compareTo(a.timeMs));
      case _SortMode.oldest:
        return stableSortBy(rows, (a, b) => a.timeMs.compareTo(b.timeMs));
      case _SortMode.largest:
        return stableSortBy(rows, (a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    }
  }

  bool _matchesSearch(_UnifiedRow row) {
    if (_searchQuery.isEmpty) return true;
    final haystack = <String>[
      row.host,
      row.path,
      row.method,
      row.request?.domain ?? '',
      row.request?.dstIp ?? '',
    ].join(' ').toLowerCase();
    return haystack.contains(_searchQuery);
  }

  bool _matchesFilters(_UnifiedRow row, int nowMs) {
    final capture = row.capture;
    final request = row.request;
    if (_protocol != null) {
      if (capture == null ||
          capture.protocol.toLowerCase() != _protocol!.toLowerCase()) {
        return false;
      }
    }
    if (_statusClass != null) {
      if (capture == null || capture.statusCode ~/ 100 != _statusClass) {
        return false;
      }
    }
    if (_method != null) {
      if (capture == null ||
          capture.method.toUpperCase() != _method!.toUpperCase()) {
        return false;
      }
    }
    if (_errorsOnly) {
      final isError = capture != null &&
          (capture.mitmFailed || capture.statusCode >= 400);
      if (!isError) return false;
    }
    if (_network != null) {
      if (request == null || request.network != _network) return false;
    }
    if (_appQuery.isNotEmpty) {
      if (request == null) return false;
      final labels = request.packages
          .map((pkg) => ProxyAppIdentityResolver.instance.lookup(pkg)?.label)
          .whereType<String>();
      final haystack =
          '${request.packages.join(' ')} ${labels.join(' ')} ${request.uid ?? ''}'
              .toLowerCase();
      if (!haystack.contains(_appQuery)) return false;
    }
    if (_outboundQuery.isNotEmpty) {
      if (request == null ||
          !request.outbound.toLowerCase().contains(_outboundQuery)) {
        return false;
      }
    }
    if (_rangeMs > 0) {
      final ts = row.timeMs;
      if (ts > 0 && ts < nowMs - _rangeMs) return false;
    }
    return true;
  }

  bool get _hasActiveFilters =>
      _network != null ||
      _protocol != null ||
      _statusClass != null ||
      _method != null ||
      _errorsOnly ||
      _appQuery.isNotEmpty ||
      _outboundQuery.isNotEmpty ||
      _rangeMs > 0;

  /// 任一筛选变化：本地重算 + best-effort 后端重拉（转发可支持的字段）。
  void _onFilterChanged() {
    setState(() {});
    unawaited(_reload(silent: true));
  }

  void _applySearch() => setState(() {});

  void _resetFilters() {
    _filterAppController.clear();
    _filterOutboundController.clear();
    setState(() {
      _network = null;
      _protocol = null;
      _statusClass = null;
      _method = null;
      _errorsOnly = false;
      _appQuery = '';
      _outboundQuery = '';
      _rangeMs = 0;
    });
  }

  // ==================== 排序 / 长按操作 ====================

  Future<void> _openSort() async {
    final selected = await AppDialogs.showContentSheet<_SortMode>(
      title: '排序方式',
      icon: const Icon(TablerIcons.arrows_sort),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final mode in _SortMode.values)
            _ExportOption(
              key: Key('requests_sort_${mode.name}'),
              icon: mode.icon,
              title: mode.label,
              subtitle: mode == _sortMode ? '当前' : '',
              onTap: () => AppDialogs.popSheet<_SortMode>(mode),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<_SortMode>(null),
          child: const Text('取消'),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    setState(() => _sortMode = selected);
  }

  /// 长按行：复制域名 / URL、分享文本、删除该抓包记录。
  Future<void> _onRowLongPress(_UnifiedRow row) async {
    final capture = row.capture;
    final action = await AppDialogs.showContentSheet<String>(
      title: row.host.isEmpty ? '记录操作' : row.host,
      icon: const Icon(TablerIcons.dots_vertical),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExportOption(
            key: const Key('row_action_copy_host'),
            icon: TablerIcons.copy,
            title: '复制域名',
            subtitle: row.host.isEmpty ? '（无域名）' : row.host,
            onTap: () => AppDialogs.popSheet<String>('copy_host'),
          ),
          if (capture != null && capture.url.isNotEmpty)
            _ExportOption(
              key: const Key('row_action_copy_url'),
              icon: TablerIcons.link,
              title: '复制 URL',
              subtitle: capture.url,
              onTap: () => AppDialogs.popSheet<String>('copy_url'),
            ),
          _ExportOption(
            key: const Key('row_action_share'),
            icon: TablerIcons.share,
            title: '分享',
            subtitle: '复制可分享的文本摘要',
            onTap: () => AppDialogs.popSheet<String>('share'),
          ),
          if (capture != null)
            _ExportOption(
              key: const Key('row_action_delete'),
              icon: TablerIcons.trash,
              title: '删除该记录',
              subtitle: '仅删除这一条抓包记录',
              onTap: () => AppDialogs.popSheet<String>('delete'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<String>(null),
          child: const Text('关闭'),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy_host':
        await _copyToClipboard(row.host, '已复制域名');
      case 'copy_url':
        await _copyToClipboard(capture?.url ?? '', '已复制 URL');
      case 'share':
        await _copyToClipboard(_shareText(row), '已复制分享文本');
      case 'delete':
        if (capture != null) await _deleteCapture(capture);
    }
  }

  Future<void> _copyToClipboard(String text, String successMessage) async {
    if (text.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      AppDialogs.showSuccess(successMessage);
    } catch (_) {
      if (!mounted) return;
      AppDialogs.showError('复制失败');
    }
  }

  String _shareText(_UnifiedRow row) {
    final buffer = StringBuffer()
      ..writeln('${row.method.isEmpty ? '—' : row.method} ${row.host}')
      ..write(row.path.isEmpty ? '' : row.path);
    final capture = row.capture;
    if (capture != null && capture.url.isNotEmpty) {
      buffer
        ..writeln()
        ..write(capture.url);
    }
    return buffer.toString().trim();
  }

  /// 单条删除（`captures.delete`）：危险确认 → 乐观移除 → 重载刷新计数。
  Future<void> _deleteCapture(CaptureRecord capture) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除该记录',
      message: '将删除这一条抓包记录，无法撤销。确定继续吗？',
      confirmText: '删除',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (ok != true || !mounted) return;
    try {
      await _deleteFacade.delete(capture.recordId);
      if (!mounted) return;
      setState(() {
        _captures = _captures
            .where((item) => item.recordId != capture.recordId)
            .toList();
      });
      AppDialogs.showSuccess('已删除该记录');
      await _reload(silent: true);
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '删除失败');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('删除失败：$error', title: '删除失败');
    }
  }

  // ==================== 筛选弹层 ====================

  Future<void> _openFilters() async {
    await AppSheet.show<void>(
      context: context,
      title: '筛选',
      icon: const Icon(TablerIcons.filter),
      content: StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void sync(VoidCallback change) {
            setState(change);
            setSheetState(() {});
            unawaited(_reload(silent: true));
          }

          void reset() {
            _resetFilters();
            setSheetState(() {});
            unawaited(_reload(silent: true));
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('requests_filter_reset'),
                  onPressed: reset,
                  child: const Text('重置'),
                ),
              ),
              _FilterSection(
                title: '协议',
                child: _FilterChips<String?>(
                  keyPrefix: 'requests_filter_protocol',
                  options: _protocolOptions,
                  selected: _protocol,
                  labelOf: (value) => value ?? '全部',
                  onSelected: (value) => sync(() => _protocol = value),
                ),
              ),
              _FilterSection(
                title: '状态段',
                child: _FilterChips<int?>(
                  keyPrefix: 'requests_filter_status',
                  options: _statusOptions,
                  selected: _statusClass,
                  labelOf: (value) => value == null ? '全部' : '${value}xx',
                  onSelected: (value) => sync(() => _statusClass = value),
                ),
              ),
              _FilterSection(
                title: '方法',
                child: _FilterChips<String?>(
                  keyPrefix: 'requests_filter_method',
                  options: _methodOptions,
                  selected: _method,
                  labelOf: (value) => value ?? '全部',
                  onSelected: (value) => sync(() => _method = value),
                ),
              ),
              _FilterSection(
                title: '网络',
                child: _FilterChips<String?>(
                  keyPrefix: 'requests_filter_network',
                  options: _networkOptions,
                  selected: _network,
                  labelOf: (value) => value ?? '全部',
                  onSelected: (value) => sync(() => _network = value),
                ),
              ),
              _FilterSection(
                title: '应用',
                child: TextField(
                  key: const Key('requests_filter_app'),
                  controller: _filterAppController,
                  onChanged: (value) {
                    setState(() {
                      _appQuery = value.trim().toLowerCase();
                    });
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '包名 / 应用名 / UID 子串',
                    prefixIcon: Icon(TablerIcons.apps),
                  ),
                ),
              ),
              _FilterSection(
                title: '出站',
                child: TextField(
                  key: const Key('requests_filter_outbound'),
                  controller: _filterOutboundController,
                  onChanged: (value) {
                    _outboundQuery = value.trim().toLowerCase();
                    _onFilterChanged();
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '出站子串',
                    prefixIcon: Icon(TablerIcons.arrows_split),
                  ),
                ),
              ),
              _FilterSection(
                title: '时间范围',
                child: _FilterChips<int>(
                  keyPrefix: 'requests_filter_range',
                  options: _rangeOptions.map((option) => option.rangeMs).toList(),
                  selected: _rangeMs,
                  labelOf: (value) => _rangeOptions
                      .firstWhere((option) => option.rangeMs == value)
                      .label,
                  onSelected: (value) => sync(() => _rangeMs = value),
                ),
              ),
              FilterChip(
                key: const Key('requests_filter_errors_only'),
                label: const Text('仅错误'),
                avatar: const Icon(TablerIcons.alert_triangle),
                selected: _errorsOnly,
                onSelected: (value) =>
                    sync(() => _errorsOnly = value),
              ),
            ],
          );
        },
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  // ==================== 渲染 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('请求域名 / IP'),
        actions: [
          IconButton(
            key: const Key('requests_sort'),
            tooltip: '排序',
            icon: const Icon(TablerIcons.arrows_sort),
            onPressed: _openSort,
          ),
          IconButton(
            key: const Key('requests_export'),
            tooltip: '导出',
            icon: const Icon(TablerIcons.file_download),
            onPressed: _exporting ? null : _export,
          ),
          IconButton(
            key: const Key('requests_refresh'),
            tooltip: '刷新',
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loading ? null : () => _load(),
          ),
          IconButton(
            key: const Key('requests_reset'),
            tooltip: '清空记录',
            icon: const Icon(TablerIcons.trash),
            onPressed: _requestsPage == null ? null : _confirmReset,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _requestsPage == null) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildTopChips(context)),
          SliverToBoxAdapter(child: _buildSearchBar(context)),
          SliverToBoxAdapter(child: _buildAnalysis(context)),
          ..._buildContentSlivers(context),
        ],
      ),
    );
  }

  /// 顶部一行 chips：抓包开关迷你 / 实时 / `共 N 条`。
  Widget _buildTopChips(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = _captureEnabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilterChip(
            key: const Key('requests_capture_toggle'),
            avatar: Icon(
              TablerIcons.shield_lock,
              size: AppTypography.iconSM,
              color: enabled == true ? scheme.primary : scheme.onSurfaceVariant,
            ),
            label: Text(enabled == true ? '抓包中' : '抓包'),
            selected: enabled == true,
            onSelected: _captureBusy ? null : (_) => _toggleCapture(),
          ),
          FilterChip(
            key: const Key('requests_live_toggle'),
            avatar: Icon(
              TablerIcons.bolt,
              size: AppTypography.iconSM,
              color: _live ? scheme.primary : scheme.onSurfaceVariant,
            ),
            label: const Text('实时'),
            selected: _live,
            onSelected: (_) => _toggleLive(),
          ),
          Container(
            key: const Key('requests_count_chip'),
            padding: AppSpacing.horizontalSM_verticalXS,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: AppRadius.allMD,
            ),
            child: Text(
              '共 ${_allRows().length} 条',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            key: const Key('requests_retained_chip'),
            padding: AppSpacing.horizontalSM_verticalXS,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: AppRadius.allMD,
            ),
            child: Text(
              '保留 请求 ${_requestsPage?.retained ?? 0} · '
              '抓包 ${_capturesPage?.retained ?? 0}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框（域名 / IP / 方法 / 路径）+ 筛选入口。
  Widget _buildSearchBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('requests_search'),
              controller: _searchController,
              onChanged: (value) {
                _searchQuery = value.trim().toLowerCase();
                _applySearch();
              },
              decoration: const InputDecoration(
                isDense: true,
                hintText: '域名 / IP / 方法 / 路径',
                prefixIcon: Icon(TablerIcons.search),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            key: const Key('requests_filter_open'),
            tooltip: '筛选',
            icon: const Icon(TablerIcons.filter),
            color: _hasActiveFilters ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: _openFilters,
          ),
        ],
      ),
    );
  }

  /// 分析区：折叠到列表上方「分析」可展开区（Top / 趋势 / DNS 质量 + 概览）。
  Widget _buildAnalysis(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final records = _requests;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const Key('requests_analysis_toggle'),
              onTap: () =>
                  setState(() => _analysisExpanded = !_analysisExpanded),
              child: Padding(
                padding: AppSpacing.horizontalMD_verticalSM,
                child: Row(
                  children: [
                    Icon(
                      TablerIcons.chart_line,
                      size: AppTypography.iconMD,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text('分析', style: theme.textTheme.titleSmall),
                    ),
                    AnimatedRotation(
                      turns: _analysisExpanded ? 0.5 : 0.0,
                      duration: AppAnimation.fast,
                      curve: AppAnimation.curve,
                      child: Icon(
                        _analysisExpanded
                            ? TablerIcons.chevron_up
                            : TablerIcons.chevron_down,
                        size: AppTypography.iconLG,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: AppAnimation.medium,
              curve: AppAnimation.curve,
              alignment: Alignment.topCenter,
              child: _analysisExpanded
                  ? Padding(
                      padding: AppSpacing.allMD,
                      child: _buildAnalysisCards(records),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysisCards(List<RequestRecord> records) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final page = _requestsPage;
    final totalBytes = records.fold<int>(
      0,
      (sum, record) => sum + record.uploadBytes + record.downloadBytes,
    );
    final active =
        records.where((record) => record.closeReason == 'open').length;
    final unknownDomains =
        records.where((record) => !record.domainKnown).length;
    final unknownRatio = records.isEmpty
        ? 0
        : ((unknownDomains / records.length) * 100).round();
    final known = records.where((record) => record.domainKnown).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          children: [
            _OverviewMetric(
              icon: TablerIcons.arrow_up,
              label: '总量',
              value: byteSize(totalBytes),
            ),
            _OverviewMetric(
              icon: TablerIcons.arrows_up_down,
              label: '请求数',
              value: '${records.length}',
            ),
            _OverviewMetric(
              icon: TablerIcons.bolt,
              label: '活跃',
              value: '$active',
            ),
            _OverviewMetric(
              icon: TablerIcons.server,
              label: '未知域名',
              value: '$unknownRatio%',
              sub: '$unknownDomains / ${records.length}',
            ),
          ],
        ),
        if (page != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '保留 ${page.retained}/${page.capacity} · '
            '淘汰 ${page.evicted} · 丢弃 ${page.dropped}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        _GroupCard(
          key: const Key('requests_group_apps'),
          title: 'Top 应用',
          icon: TablerIcons.apps,
          rows: _groupTop(records, _appLabel),
        ),
        _GroupCard(
          key: const Key('requests_group_domains'),
          title: 'Top 域名',
          icon: TablerIcons.server,
          rows: _groupTop(
            records,
            (record) => record.domain.isEmpty ? '(未知域名)' : record.domain,
          ),
        ),
        _GroupCard(
          key: const Key('requests_group_ips'),
          title: 'Top IP',
          icon: TablerIcons.network,
          rows: _groupTop(
            records,
            (record) => record.dstIp.isEmpty ? '(未知 IP)' : record.dstIp,
          ),
        ),
        _TrendCard(
          key: const Key('requests_group_trend'),
          counts: _trendBuckets(records),
        ),
        _DnsQualityCard(
          key: const Key('requests_group_dns'),
          known: known,
          total: records.length,
        ),
        _GroupCard(
          key: const Key('requests_group_outbound'),
          title: '出站分布',
          icon: TablerIcons.arrows_split,
          rows: _groupTop(
            records,
            (record) => record.outbound.isEmpty ? '未匹配' : record.outbound,
          ),
        ),
        _GroupCard(
          key: const Key('requests_group_rules'),
          title: '规则分布',
          icon: TablerIcons.list_check,
          rows: _groupTop(
            records,
            (record) => record.rule.isEmpty ? '未匹配规则' : record.rule,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildContentSlivers(BuildContext context) {
    final error = _error;
    if (error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: TablerIcons.alert_circle,
            title: '请求列表不可用',
            message: error,
            actionLabel: '重试',
            onAction: _load,
          ),
        ),
      ];
    }
    final rows = _visibleRows;
    if (rows.isEmpty) {
      final hasAny = _allRows().isNotEmpty;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: hasAny ? TablerIcons.filter_off : TablerIcons.history_off,
            title: hasAny ? '无匹配请求' : '暂无请求记录',
            message: hasAny
                ? '当前筛选条件没有匹配的请求。'
                : '调试引擎尚未采集到请求。',
          ),
        ),
      ];
    }
    return [
      if (_capturesDegraded)
        const SliverToBoxAdapter(child: _DegradedNotice()),
      SliverToBoxAdapter(child: _buildListHeader(context, rows.length)),
      SliverPadding(
        padding: AppSpacing.onlyHorizontalLG,
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            return _UnifiedRowCard(
              key: ValueKey(row.rowKey),
              row: row,
              onTap: () => _openRow(row),
              onLongPress: () => _onRowLongPress(row),
            );
          },
        ),
      ),
      if (_requestsHasMore || _capturesHasMore)
        SliverToBoxAdapter(child: _buildLoadMore(context)),
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
    ];
  }

  Widget _buildLoadMore(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Center(
        child: OutlinedButton.icon(
          key: const Key('requests_load_more'),
          onPressed: _loadingMore ? null : _loadMore,
          icon: _loadingMore
              ? const AppLoading(size: AppLoadingSize.small)
              : const Icon(TablerIcons.chevron_down),
          label: const Text('加载更多'),
        ),
      ),
    );
  }

  Widget _buildListHeader(BuildContext context, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          ColoredAliIcon(
            icon: TablerIcons.history,
            size: AppTypography.iconLG,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text('实时请求', style: theme.textTheme.titleSmall),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openRow(_UnifiedRow row) async {
    // 有 HTTP 详情（capture）→ 进入独立全屏详情页（「逐条 HTTP 请求详情」）。
    final capture = row.capture;
    if (capture != null) {
      await _openCaptureDetail(capture, row.request);
      // 详情页可能删除/修改了记录：push 返回（含删除成功后的 pop）即刷新列表。
      if (mounted) await _load();
      return;
    }
    // 无 capture（未解密）→ 保留既有流级 AppSheet 详情。
    final request = row.request;
    if (request == null) return;
    await _showDetail(request);
  }

  /// 打开全屏抓包详情页 [ProxyCaptureDetailPage]。
  ///
  /// `recordId` 取该行摘要 capture 的 `recordId`；骨架行把对应 [RequestRecord]
  /// 作为 `flow` 传入（元数据段 / 未解密兜底）。动作回调经
  /// [CaptureDetailActionBinder] 绑定；注入缝为空时惰性构建生产装配，避免页面
  /// 初始化即触碰请求调试 store。
  Future<void> _openCaptureDetail(
    CaptureRecord capture,
    RequestRecord? flow,
  ) async {
    final binder = _captureActionBinder;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProxyCaptureDetailPage(
          recordId: capture.recordId,
          flow: flow,
          facade: widget.captureDetailFacade,
          deleteFacade: _deleteFacade,
          onCopyCurl: binder.onCopyCurl,
          onSaveToDebug: binder.onSaveToDebug,
          onCreateRewriteRule: binder.onCreateRewriteRule,
          onUseAsRewriteResponse: binder.onUseAsRewriteResponse,
          onResendToDebug: (detail) =>
              unawaited(_resendToRequestDebug(detail)),
        ),
      ),
    );
  }

  /// 「重发到请求调试」：复用抓包落库桥保存请求，再跳转「请求调试」工作台。
  ///
  /// 保存为尽力而为（失败已由 [CaptureDetailActionBinder] 经 `showError`
  /// 提示，不抛异常）；随后经 [appRouter] 落到默认「集合」分区，便于用户查看 /
  /// 重发。
  Future<void> _resendToRequestDebug(CaptureDetail detail) async {
    await _captureActionBinder.saveToDebug(detail);
    if (!mounted) return;
    appRouter.go(AppRoute.requestDebug);
  }

  Future<void> _showDetail(RequestRecord record) async {
    await AppDialogs.showContentSheet<void>(
      title: record.domain.isEmpty ? '请求详情' : record.domain,
      subtitle: _formatDateTime(record.openTsMs),
      icon: const Icon(TablerIcons.arrows_up_down),
      content: _RequestDetail(record: record),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<void>(null),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// App 归属展示：可解析时优先人类可读应用名，其次包名，再次 `UID <n>`，
/// 无包名且 `uid == null` 时显式「未知应用」。
String _appLabel(RequestRecord record) {
  if (record.packages.isNotEmpty) {
    final packageName = record.packages.first;
    final identity = ProxyAppIdentityResolver.instance.lookup(packageName);
    if (identity != null && identity.label.isNotEmpty) return identity.label;
    return packageName;
  }
  if (record.uid != null) return 'UID ${record.uid}';
  return '未知应用';
}

/// 记录归属应用的图标路径；无包名 / 未解析 / 无图标 → `null`（不渲染前导图标）。
String? _appIconPath(RequestRecord record) {
  if (record.packages.isEmpty) return null;
  return ProxyAppIdentityResolver.instance
      .lookup(record.packages.first)
      ?.iconPath;
}

/// 列表统一行：`requests` 骨架 + 可选的 `captures` HTTP 详情。
///
/// [request] 为 `null` 时是 capture 驱动行（孤儿 capture）。
class _UnifiedRow {
  const _UnifiedRow({this.request, this.capture});

  final RequestRecord? request;
  final CaptureRecord? capture;

  bool get isOrphan => request == null;

  /// 稳定 key：骨架行沿用 `request_row_<recordId>`，孤儿行用
  /// `capture_row_<recordId>`（两者不会同 id 冲突）。
  String get rowKey =>
      isOrphan ? 'capture_row_${capture!.recordId}' : 'request_row_${request!.recordId}';

  String get method => capture?.method ?? '';

  String get host {
    final captureHost = capture?.host ?? '';
    if (captureHost.isNotEmpty) return captureHost;
    final domain = request?.domain ?? '';
    if (domain.isNotEmpty) return domain;
    return request?.dstIp ?? '';
  }

  String get path => capture?.path ?? '';

  int get statusCode => capture?.statusCode ?? 0;

  bool get isError =>
      capture != null && (capture!.mitmFailed || capture!.statusCode >= 400);

  bool get decrypted => capture != null;

  int get sizeBytes => capture != null
      ? capture!.reqBytes + capture!.respBytes
      : (request?.uploadBytes ?? 0) + (request?.downloadBytes ?? 0);

  int? get durationMs => capture != null ? capture!.durationMs : request?.durationMs;

  int get timeMs {
    final started = capture?.startedAtMs ?? 0;
    if (started > 0) return started;
    return request?.openTsMs ?? 0;
  }
}

/// 统一列表行：`方法徽标 · 域名/路径 · 状态 · 大小 · 耗时 · 时间`。
class _UnifiedRowCard extends StatelessWidget {
  const _UnifiedRowCard({
    super.key,
    required this.row,
    required this.onTap,
    this.onLongPress,
  });

  final _UnifiedRow row;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final capture = row.capture;
    final request = row.request;

    final method = row.method.isEmpty ? '—' : row.method;
    final host = row.host.isEmpty ? '(未知)' : row.host;
    final path = row.path;
    final statusText =
        capture == null ? '未解密' : (capture.statusCode == 0 ? '—' : '${capture.statusCode}');
    final durationText =
        row.durationMs == null ? '进行中' : '${row.durationMs} ms';
    final meta = capture == null
        ? '流级信息'
        : '${capture.protocol.isEmpty ? 'http' : capture.protocol} · ${capture.scheme}';
    final appLine = request != null
        ? '${_appLabel(request)} · ${request.outbound.isEmpty ? '未匹配' : request.outbound}'
        : '孤儿记录（无流骨架）';
    final appIconPath = request == null ? null : _appIconPath(request);

    return Card(
      margin: AppSpacing.onlyVerticalXS,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (appIconPath != null) ...[
                AppIcon(
                  url: appIconPath,
                  width: AppTypography.iconXXL,
                  height: AppTypography.iconXXL,
                  borderRadius: AppRadius.circle,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              _MethodBadge(method: method, orphan: request == null),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (path.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Flexible(
                            child: Text(
                              path,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Text(
                          statusText,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: row.isError ? scheme.error : scheme.onSurface,
                          ),
                        ),
                        if (capture != null && capture.mitmFailed) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const _UpstreamFailedBadge(),
                        ],
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            '$meta · ${byteSize(row.sizeBytes)} · $durationText',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      appLine,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                _formatTime(row.timeMs),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「上游失败」角标：已拦截但上游拨号失败的 capture，区别于从未解密的流。
class _UpstreamFailedBadge extends StatelessWidget {
  const _UpstreamFailedBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('capture_upstream_failed_badge'),
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: AppRadius.allSM,
      ),
      alignment: Alignment.center,
      child: Text(
        '上游失败',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onErrorContainer,
          fontWeight: AppTypography.weightBold,
        ),
      ),
    );
  }
}

/// 方法徽标（等宽、固定最小宽度；未解密流显示 `—`）。
class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method, required this.orphan});

  final String method;
  final bool orphan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: AppSpacing.huge),
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: orphan
            ? scheme.tertiaryContainer
            : scheme.primaryContainer,
        borderRadius: AppRadius.allSM,
      ),
      alignment: Alignment.center,
      child: Text(
        method,
        style: theme.textTheme.labelMedium?.copyWith(
          color: orphan ? scheme.onTertiaryContainer : scheme.onPrimaryContainer,
          fontWeight: AppTypography.weightBold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// `captures.get` 失败时的降级提示条（requests 列表仍然可用）。
class _DegradedNotice extends StatelessWidget {
  const _DegradedNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('requests_captures_degraded'),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      padding: AppSpacing.horizontalMD_verticalSM,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allMD,
      ),
      child: Row(
        children: [
          Icon(
            TablerIcons.alert_triangle,
            size: AppTypography.iconMD,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'HTTP 详情不可用，仅显示流级信息',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 筛选弹层的一个小节（标题 + 内容）。
class _FilterSection extends StatelessWidget {
  const _FilterSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyBottomMD,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          child,
        ],
      ),
    );
  }
}

/// 一组可单选筛选项（`null` = 全部）。key 形如 `<prefix>_<value>`。
class _FilterChips<T> extends StatelessWidget {
  const _FilterChips({
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String keyPrefix;
  final List<T> options;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final option in options)
          ChoiceChip(
            key: Key('${keyPrefix}_${option ?? 'all'}'),
            label: Text(labelOf(option)),
            selected: option == selected,
            onSelected: (_) => onSelected(option),
          ),
      ],
    );
  }
}

/// 分组统计行（标签 + 计数 + 字节）。
class _GroupRow {
  const _GroupRow({
    required this.label,
    required this.count,
    required this.bytes,
  });

  final String label;
  final int count;
  final int bytes;
}

/// 按 [keyOf] 聚合为 Top [limit] 行（计数降序，字节次序）。
List<_GroupRow> _groupTop(
  List<RequestRecord> records,
  String Function(RequestRecord record) keyOf, {
  int limit = _groupLimit,
}) {
  final counts = <String, int>{};
  final bytes = <String, int>{};
  for (final record in records) {
    final key = keyOf(record);
    counts[key] = (counts[key] ?? 0) + 1;
    bytes[key] =
        (bytes[key] ?? 0) + record.uploadBytes + record.downloadBytes;
  }
  final rows = counts.keys
      .map((key) => _GroupRow(
            label: key,
            count: counts[key]!,
            bytes: bytes[key]!,
          ))
      .toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : b.bytes.compareTo(a.bytes);
    });
  return rows.take(limit).toList();
}

/// 时间线趋势：按分钟分桶计数，取最近 [_trendBucketCount] 个桶。
List<int> _trendBuckets(List<RequestRecord> records) {
  final buckets = <int, int>{};
  for (final record in records) {
    if (record.openTsMs <= 0) continue;
    final bucket = record.openTsMs ~/ _trendBucketMs;
    buckets[bucket] = (buckets[bucket] ?? 0) + 1;
  }
  if (buckets.isEmpty) return const <int>[];
  final keys = buckets.keys.toList()..sort();
  final recent = keys.length <= _trendBucketCount
      ? keys
      : keys.sublist(keys.length - _trendBucketCount);
  return recent.map((key) => buckets[key]!).toList();
}

/// 总览指标（图标 + 标签 + 值 + 可选副值）。
class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconXS, color: scheme.primary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(value, style: theme.textTheme.titleSmall),
        if (sub != null)
          Text(
            sub!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 通用分组卡（Top 列表：标签 + 计数 + 字节）。
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    super.key,
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_GroupRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: icon,
                  size: AppTypography.iconSM,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (rows.isEmpty)
              Text(
                '暂无数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final row in rows) _GroupRowTile(row: row),
          ],
        ),
      ),
    );
  }
}

class _GroupRowTile extends StatelessWidget {
  const _GroupRowTile({required this.row});

  final _GroupRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.label,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '${row.count} · ${byteSize(row.bytes)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间线趋势卡（自绘等高柱状，纯展示）。
class _TrendCard extends StatelessWidget {
  const _TrendCard({super.key, required this.counts});

  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxCount = counts.isEmpty
        ? 0
        : counts.reduce((a, b) => a > b ? a : b);
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: TablerIcons.chart_line,
                  size: AppTypography.iconSM,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('时间线趋势', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (counts.isEmpty)
              Text(
                '暂无数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              SizedBox(
                height: AppSpacing.huge,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final count in counts)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 1,
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.bottomCenter,
                            heightFactor: maxCount == 0
                                ? 0.0
                                : (count / maxCount).clamp(0.02, 1.0).toDouble(),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: AppRadius.allXS,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// DNS 质量卡（`domainKnown` 命中率）。
class _DnsQualityCard extends StatelessWidget {
  const _DnsQualityCard({
    super.key,
    required this.known,
    required this.total,
  });

  final int known;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unknown = total - known;
    final ratio = total == 0 ? 0 : ((known / total) * 100).round();
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: TablerIcons.shield_check,
                  size: AppTypography.iconSM,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('DNS 质量', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '域名可解析 $ratio% · 已解析 $known · 未知 $unknown / 共 $total',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 请求详情（统一弹层内容，完整字段）。
class _RequestDetail extends StatelessWidget {
  const _RequestDetail({required this.record});

  final RequestRecord record;

  @override
  Widget build(BuildContext context) {
    final appIconPath = _appIconPath(record);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailField(label: '记录 ID', value: '${record.recordId}'),
        _DetailField(label: '连接 ID', value: record.connId),
        _DetailField(label: '域名', value: record.domain),
        _DetailField(
          label: '域名状态',
          value: record.domainKnown ? '已解析' : '未知（显示目标 IP）',
        ),
        _DetailField(label: '目标地址', value: '${record.dstIp}:${record.dstPort}'),
        _DetailField(label: '入站（源）', value: record.src),
        _DetailField(label: '网络', value: record.network),
        _DetailField(
          label: '应用',
          value: _appLabel(record),
          leading: appIconPath == null
              ? null
              : AppIcon(
                  url: appIconPath,
                  width: AppTypography.iconXL,
                  height: AppTypography.iconXL,
                  borderRadius: AppRadius.circle,
                ),
        ),
        _DetailField(label: 'UID', value: record.uid?.toString() ?? '—'),
        _DetailField(
          label: 'UID 状态',
          value: record.uidState.wire,
        ),
        if (record.packages.isNotEmpty)
          _DetailField(label: '包名', value: record.packages.join(', ')),
        _DetailField(label: '出站', value: record.outbound),
        _DetailField(label: '规则', value: record.rule),
        _DetailField(label: '规则载荷', value: record.rulePayload),
        _DetailField(label: '上传', value: byteSize(record.uploadBytes)),
        _DetailField(label: '下载', value: byteSize(record.downloadBytes)),
        _DetailField(
          label: '总计',
          value: byteSize(record.uploadBytes + record.downloadBytes),
        ),
        _DetailField(
          label: '耗时',
          value: record.durationMs == null ? '进行中' : '${record.durationMs} ms',
        ),
        _DetailField(label: '开始', value: _formatDateTime(record.openTsMs)),
        if (record.closeTsMs != null)
          _DetailField(label: '结束', value: _formatDateTime(record.closeTsMs!)),
        _DetailField(label: '结束原因', value: record.closeReason),
      ],
    );
  }
}

/// 详情字段：标签 + 值（值用等宽字体）。
class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    required this.value,
    this.leading,
  });

  final String label;
  final String value;

  /// 可选的字段前置元素（如应用图标）；为 `null` 时布局与原来完全一致。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = value.trim().isEmpty ? '—' : value;
    return Padding(
      padding: AppSpacing.onlyBottomMD,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (leading == null)
            Text(
              display,
              style: AppTypography.code.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            )
          else
            Row(
              children: [
                leading!,
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    display,
                    style: AppTypography.code.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 两位补零。
String _two(int value) => value.toString().padLeft(2, '0');

/// 毫秒时间戳 → `HH:mm:ss`（0 = 空）。
String _formatTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}

/// 毫秒时间戳 → `yyyy-MM-dd HH:mm:ss`（0 = 空）。
String _formatDateTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}
