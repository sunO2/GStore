/// 全屏抓包详情页（`proxy-http-capture` Todo 23，纯展示 / 触发层）。
///
/// 入口按 `recordId` 拉取 `captures.detail`（Todo 12 冻结契约，见
/// `API.md` §2.18），把一条抓包记录铺成 5 个分段：概览 / 请求 / 响应 /
/// 时间线 / 元数据。
///
/// **本页只做展示**：解析 / 抓包 / 存储全部在 Rust 侧 `gstore_mod_proxy`。
/// Dart 只把 `CaptureDetail` 的字段与字节渲染出来，并对 Body 做纯本地的
/// 「原始 / 格式化 / 复制 / 作为改写响应」视图操作。
///
/// ## 动作桥接（可注入接缝，Todo 24 接线）
/// AppBar 动作菜单（复制 cURL / 保存到请求调试 / 创建改写规则）与 Body 的
/// 「作为改写响应」都通过**可空回调**暴露：
/// * [onCopyCurl] / [onSaveToDebug] / [onCreateRewriteRule]：`(CaptureDetail)`
/// * [onUseAsRewriteResponse]：`(String body)`
///
/// 默认为 `null` = 空实现（本页**不**实现任何桥接 / 写库 / 建规则行为）。
/// 页面之间经此接缝解耦，**不** import 对方页面 State。
///
/// ## 未解密（无 HTTP 详情）
/// `mitmFailed == true`（或 `captures.detail` 返回 `PROXY_CAPTURE_NOT_FOUND`）
/// 时，页面显示流级信息 + 「未解密」提示，绝不崩溃。
///
/// ## 版本 / 大小边界
/// * Body 区**限高 + 内部滚动**，超长内容不溢出；
/// * 二进制 / 非文本 Body 走安全预览（base64），不崩；
/// * 分段横向可滚，窄屏 5 段不溢出。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_har_export.dart';

/// 详情页所需的模块能力：按 `recordId` 拉一条完整抓包。
///
/// 窄接口（不改动冻结契约）：生产用 [ProxyModuleCaptureDetailFacade] 适配
/// [ProxyModule]；测试注入假实现即可，无需原生模块。
abstract class ProxyCaptureDetailFacade {
  /// `captures.detail`：环内摘要 + SQLite 读取的完整 body / url / 头 / wsFrames。
  Future<CaptureDetail> detail(int recordId);
}

/// 生产适配器：[ProxyModule] → [ProxyCaptureDetailFacade] 的薄转发。
class ProxyModuleCaptureDetailFacade implements ProxyCaptureDetailFacade {
  ProxyModuleCaptureDetailFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<CaptureDetail> detail(int recordId) => _module.invoke(
        ProxyMethods.capturesDetail,
        CaptureDetail.fromJson,
        payload: CaptureDetailRequest(recordId).toJson(),
      );
}

/// 详情页删除能力：按 `recordId` 删除一条抓包记录（窄接口）。
///
/// 与 [ProxyCaptureDetailFacade] 分离，便于测试单独注入假删除实现而无需
/// 原生模块；生产用 [ProxyModuleCaptureDeleteFacade] 薄转发
/// [ProxyModule.capturesDelete]（`captures.delete`，幂等）。
abstract class ProxyCaptureDeleteFacade {
  /// `captures.delete`：删除一条记录；缺席时返回 `removed:false`（不报错）。
  Future<CaptureDeleteResult> delete(int recordId);
}

/// 生产适配器：[ProxyModule] → [ProxyCaptureDeleteFacade] 的薄转发。
class ProxyModuleCaptureDeleteFacade implements ProxyCaptureDeleteFacade {
  ProxyModuleCaptureDeleteFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<CaptureDeleteResult> delete(int recordId) =>
      _module.capturesDelete(recordId);
}

/// 动作接缝：以整条详情为参数（Todo 24 桥接）。
typedef CaptureDetailAction = void Function(CaptureDetail detail);

/// Body 级动作接缝：以待操作文本为参数（Todo 24 桥接「作为改写响应」）。
typedef CaptureBodyAction = void Function(String body);

/// Body 存盘接缝：`(id, 原始字节, contentType) → 落地路径（取消 → null）`。
typedef CaptureBodySaver = Future<String?> Function(
  String id,
  List<int> bytes,
  String contentType,
);

/// 另存接缝：调用系统保存对话框并返回落地路径（取消 → `null`）。
///
/// 生产默认走 [FilePicker.platform.saveFile]；测试注入假实现断言「写入字节
/// 与原字节逐字节一致」。
typedef CaptureSaveFile = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
});

/// 分段。
enum CaptureDetailSegment {
  overview('概览'),
  request('请求'),
  response('响应'),
  timeline('时间线'),
  metadata('元数据');

  const CaptureDetailSegment(this.label);

  final String label;
}

/// `captures.detail` 未命中（记录已被淘汰 / 不存在）的错误码。
const String _kCaptureNotFound = 'PROXY_CAPTURE_NOT_FOUND';

/// 全屏抓包详情页。
class ProxyCaptureDetailPage extends StatefulWidget {
  const ProxyCaptureDetailPage({
    super.key,
    required this.recordId,
    this.flow,
    this.facade,
    this.deleteFacade,
    this.onCopyCurl,
    this.onSaveToDebug,
    this.onCreateRewriteRule,
    this.onUseAsRewriteResponse,
    this.onResendToDebug,
    this.saveFile,
  });

  /// 抓包记录 ID（`captures.detail` 入参；来自列表行点击接缝）。
  final int recordId;

  /// 可选的**流级**记录（骨架行携带）：
  /// 用于元数据段 `src / dst / uid / packages / closeReason` 及未解密兜底。
  final RequestRecord? flow;

  /// 详情门面（测试可注入；为空时用生产适配器）。
  final ProxyCaptureDetailFacade? facade;

  /// 删除门面（测试可注入；为空时用生产适配器转发 `captures.delete`）。
  final ProxyCaptureDeleteFacade? deleteFacade;

  /// 动作菜单：复制 cURL（`null` = 空实现，Todo 24 接线）。
  final CaptureDetailAction? onCopyCurl;

  /// 动作菜单：保存到请求调试（`null` = 空实现）。
  final CaptureDetailAction? onSaveToDebug;

  /// 动作菜单：创建改写规则（`null` = 空实现）。
  final CaptureDetailAction? onCreateRewriteRule;

  /// Body 区：作为改写响应（`null` = 空实现）。
  final CaptureBodyAction? onUseAsRewriteResponse;

  /// 动作菜单：重发到请求调试（`null` = 空实现）。
  ///
  /// 生产装配应经 T7 的落库桥保存该请求再跳转「请求调试」工作台；本页
  /// 只暴露接缝，不直接触碰请求调试 store / 路由。
  final CaptureDetailAction? onResendToDebug;

  /// Body 存盘接缝（测试可注入；为空时走 [FilePicker.platform.saveFile]）。
  final CaptureSaveFile? saveFile;

  @override
  State<ProxyCaptureDetailPage> createState() => _ProxyCaptureDetailPageState();
}

class _ProxyCaptureDetailPageState extends State<ProxyCaptureDetailPage> {
  late final ProxyCaptureDetailFacade _facade;
  late final ProxyCaptureDeleteFacade _deleteFacade;
  late final CaptureSaveFile _saveFile;

  CaptureDetailSegment _segment = CaptureDetailSegment.overview;
  bool _loading = true;
  String? _error;
  CaptureDetail? _detail;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleCaptureDetailFacade();
    _deleteFacade = widget.deleteFacade ?? ProxyModuleCaptureDeleteFacade();
    _saveFile = widget.saveFile ?? _defaultSaveFile;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _facade.detail(widget.recordId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ProxyModuleException catch (e) {
      if (!mounted) return;
      if (e.code == _kCaptureNotFound) {
        // 记录未命中（已淘汰 / 不存在）→ 降级为流级「未解密」展示。
        setState(() {
          _detail = null;
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = e.message.isEmpty ? e.code : e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 记录未命中（`captures.detail` `PROXY_CAPTURE_NOT_FOUND`）：纯流级
  /// 「未解密」兜底（无任何 HTTP 详情）。
  bool get _notFound => _detail == null;

  /// MITM 上游失败：capture 已落库且 method / URL / 请求头**已解密**，
  /// 仅上游拨号失败；据此显示提示条并照常渲染分段内容。
  bool get _mitmFailed => _detail != null && _detail!.mitmFailed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const Key('detail_actions_menu'),
            tooltip: '动作',
            icon: const Icon(TablerIcons.dots_vertical),
            onPressed: _detail == null ? null : _openActions,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  String _title() {
    final detail = _detail;
    if (detail != null) {
      final method = detail.method.trim();
      final host = detail.host.trim();
      final pathPart = host.isNotEmpty ? '$host${detail.path}' : detail.url;
      final text = [if (method.isNotEmpty) method, pathPart]
          .where((s) => s.trim().isNotEmpty)
          .join(' ')
          .trim();
      if (text.isNotEmpty) return text;
    }
    final flow = widget.flow;
    if (flow != null && flow.domain.isNotEmpty) return flow.domain;
    return '抓包详情';
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: AppLoading(size: AppLoadingSize.medium),
      );
    }
    if (_error != null) {
      return ErrorState(
        message: _error!,
        retryLabel: '重试',
        onRetryPressed: _load,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSegmented(context),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xxxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_notFound)
                  _UndecryptedNotice(detail: _detail, flow: widget.flow),
                if (_mitmFailed)
                  _MitmFailedNotice(reason: _detail!.failureReason),
                _buildSegment(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSegmented(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: AppSegmentedButton<CaptureDetailSegment>(
        value: _segment,
        segments: CaptureDetailSegment.values
            .map(
              (s) => AppSegment<CaptureDetailSegment>(
                value: s,
                label: s.label,
                key: Key('seg_${s.name}'),
              ),
            )
            .toList(),
        onChanged: (s) => setState(() => _segment = s),
      ),
    );
  }

  Widget _buildSegment(BuildContext context) {
    final detail = _detail;
    switch (_segment) {
      case CaptureDetailSegment.overview:
        return _OverviewSegment(
          key: const Key('detail_segment_overview'),
          detail: detail,
          flow: widget.flow,
        );
      case CaptureDetailSegment.request:
        return _RequestSegment(
          key: const Key('detail_segment_request'),
          detail: detail,
          onUseAsRewriteResponse: widget.onUseAsRewriteResponse,
          onSaveBody: _saveBody,
        );
      case CaptureDetailSegment.response:
        return _ResponseSegment(
          key: const Key('detail_segment_response'),
          detail: detail,
          onUseAsRewriteResponse: widget.onUseAsRewriteResponse,
          onSaveBody: _saveBody,
        );
      case CaptureDetailSegment.timeline:
        return _TimelineSegment(
          key: const Key('detail_segment_timeline'),
          detail: detail,
        );
      case CaptureDetailSegment.metadata:
        return _MetadataSegment(
          key: const Key('detail_segment_metadata'),
          detail: detail,
          flow: widget.flow,
        );
    }
  }

  Future<void> _openActions() async {
    final detail = _detail;
    if (detail == null) return;
    await AppSheet.show<void>(
      context: context,
      title: '动作',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ActionTile(
            key: const Key('action_copy_curl'),
            icon: TablerIcons.copy,
            title: '复制 cURL',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              widget.onCopyCurl?.call(detail);
            },
          ),
          _ActionTile(
            key: const Key('action_save_debug'),
            icon: TablerIcons.bookmark,
            title: '保存到请求调试',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              widget.onSaveToDebug?.call(detail);
            },
          ),
          _ActionTile(
            key: const Key('action_resend_debug'),
            icon: TablerIcons.send,
            title: '重发到请求调试',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              widget.onResendToDebug?.call(detail);
            },
          ),
          _ActionTile(
            key: const Key('action_create_rule'),
            icon: TablerIcons.file_pencil,
            title: '创建改写规则',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              widget.onCreateRewriteRule?.call(detail);
            },
          ),
          _ActionTile(
            key: const Key('action_export_har'),
            icon: TablerIcons.file_download,
            title: '导出为 HAR',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              unawaited(_exportHar());
            },
          ),
          _ActionTile(
            key: const Key('detail_delete_record'),
            icon: TablerIcons.trash,
            title: '删除该记录',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              unawaited(_confirmDelete());
            },
          ),
        ],
      ),
    );
  }

  /// 「删除该记录」：危险确认 → `captures.delete(recordId)`。
  ///
  /// * 确认：下发删除；成功 `Navigator.pop` 返回列表（列表在 `_openRow` 的
  ///   push 返回后 `_load()` 刷新）；
  /// * 取消：不下发、不 pop；
  /// * 失败：统一 [AppDialogs.showError]，留在本页。
  Future<void> _confirmDelete() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除该记录',
      message: '删除该抓包记录？不可撤销',
      confirmText: '删除',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (ok != true || !mounted) return;
    try {
      await _deleteFacade.delete(widget.recordId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(
        error.message.isEmpty ? error.code : error.message,
        title: '删除失败',
      );
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('删除失败：$error');
    }
  }

  /// Body 存盘：以 `capture_<recordId>_<req|resp>.<ext>` 另存**原始字节**。
  ///
  /// 取消（返回 `null` / 空路径）静默；成功 / 失败走统一 [AppDialogs]。
  Future<String?> _saveBody(
    String id,
    List<int> bytes,
    String contentType,
  ) async {
    final ext = _extensionFor(contentType);
    final fileName = 'capture_${widget.recordId}_$id.$ext';
    try {
      final path = await _saveFile(
        fileName: fileName,
        bytes: Uint8List.fromList(bytes),
        allowedExtensions: <String>[ext],
      );
      if (!mounted) return path;
      if (path != null && path.isNotEmpty) {
        AppDialogs.showSuccess('已保存 $fileName');
      }
      return path;
    } catch (error) {
      if (!mounted) return null;
      AppDialogs.showError('保存失败：$error');
      return null;
    }
  }

  /// 「导出为 HAR」：把当前抓包编码为单条 HAR 1.2 并另存。
  ///
  /// 纯 Dart 拼装（[encodeCaptureHar]，不重复请求 Tree），经与 Body 存盘同一
  /// [CaptureSaveFile] 接缝落地；取消（返回 `null` / 空路径）静默，成功 / 失败
  /// 走统一 [AppDialogs]。
  Future<String?> _exportHar() async {
    final detail = _detail;
    if (detail == null) return null;
    final fileName = 'capture_${widget.recordId}.har';
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(encodeCaptureHar(<CaptureDetail>[detail])),
      );
      final path = await _saveFile(
        fileName: fileName,
        bytes: bytes,
        allowedExtensions: const <String>['har'],
      );
      if (!mounted) return path;
      if (path != null && path.isNotEmpty) {
        AppDialogs.showSuccess('已导出 $fileName');
      }
      return path;
    } catch (error) {
      if (!mounted) return null;
      AppDialogs.showError('导出失败：$error');
      return null;
    }
  }

  /// 生产默认另存：系统保存对话框（与列表导出同机制）。
  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存正文',
      fileName: fileName,
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }
}

// ==================== 未解密提示 ====================

/// 未解密（无 HTTP 详情）时的顶部提示条 + 流级信息。
class _UndecryptedNotice extends StatelessWidget {
  const _UndecryptedNotice({required this.detail, required this.flow});

  final CaptureDetail? detail;
  final RequestRecord? flow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('detail_undecrypted'),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                TablerIcons.shield_lock,
                size: AppTypography.iconMD,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '未解密',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '该连接未解密，仅显示流级信息',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _FlowOnlyFields(detail: detail, flow: flow),
        ],
      ),
    );
  }
}

// ==================== 上游失败提示 ====================

/// MITM 上游连接失败时的顶部提示条。
///
/// 与 [_UndecryptedNotice] 区分：这条 flow 的请求**已解密**（method / URL /
/// 请求头均已落库），只是上游拨号失败，因此提示条之后照常渲染分段内容；
/// `reason` 非空时以较小第二行附上失败原因。
class _MitmFailedNotice extends StatelessWidget {
  const _MitmFailedNotice({required this.reason});

  /// `CaptureDetail.failureReason`（未失败 / 缺省为空串）。
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trimmed = reason.trim();
    return Container(
      key: const Key('detail_mitm_failed'),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      padding: AppSpacing.horizontalMD_verticalSM,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                TablerIcons.shield_lock,
                size: AppTypography.iconMD,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '已拦截·上游连接失败',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
            ],
          ),
          if (trimmed.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              trimmed,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 未解密兜底展示：优先流级记录，缺省回退详情里尚存的字段。
class _FlowOnlyFields extends StatelessWidget {
  const _FlowOnlyFields({required this.detail, required this.flow});

  final CaptureDetail? detail;
  final RequestRecord? flow;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final f = flow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(
          label: '连接 ID',
          value: d?.connId ?? f?.connId ?? '',
        ),
        _FieldRow(
          label: '主机',
          value: (d?.host.isNotEmpty ?? false) ? d!.host : (f?.domain ?? ''),
        ),
        _FieldRow(
          label: '源',
          value: f?.src ?? '',
        ),
        _FieldRow(
          label: '目标',
          value: f == null ? '' : '${f.dstIp}:${f.dstPort}',
        ),
        _FieldRow(
          label: '应用',
          value: _flowAppLabel(f),
        ),
        if (d != null) ...[
          _FieldRow(label: '协议', value: d.protocol),
          _FieldRow(label: '上传大小', value: byteSize(d.reqBytes)),
          _FieldRow(label: '下载大小', value: byteSize(d.respBytes)),
        ],
      ],
    );
  }
}

/// 流级应用标签（包名优先，其次 UID）。
String _flowAppLabel(RequestRecord? flow) {
  if (flow == null) return '';
  if (flow.packages.isNotEmpty) return flow.packages.first;
  if (flow.uid != null) return 'UID ${flow.uid}';
  return '';
}

// ==================== 概览 ====================

class _OverviewSegment extends StatelessWidget {
  const _OverviewSegment({super.key, required this.detail, required this.flow});

  final CaptureDetail? detail;
  final RequestRecord? flow;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(label: '方法', value: d?.method ?? ''),
        _FieldRow(label: 'URL', value: d?.url ?? ''),
        _FieldRow(
          label: '状态',
          value: d == null || d.statusCode == 0 ? '' : '${d.statusCode}',
        ),
        _FieldRow(label: '协议', value: d?.protocol ?? ''),
        _FieldRow(label: '主机', value: d?.host ?? ''),
        _FieldRow(label: '路径', value: d?.path ?? ''),
        _FieldRow(label: '内容类型', value: d?.contentType ?? ''),
        _FieldRow(
          label: '请求大小',
          value: d == null ? '' : byteSize(d.reqBytes),
        ),
        _FieldRow(
          label: '响应大小',
          value: d == null ? '' : byteSize(d.respBytes),
        ),
        _FieldRow(
          label: '耗时',
          value: d == null ? '' : _formatMs(d.durationMs),
        ),
        _FieldRow(
          label: '开始',
          value: d == null ? '' : _formatDateTime(d.startedAtMs),
        ),
        _FieldRow(
          label: '结束',
          value: d == null ? '' : _formatDateTime(d.finishedAtMs),
        ),
        if (d != null && d.truncated)
          const _FieldRow(label: '截断', value: '内容已截断'),
        _FieldRow(label: '流记录 ID', value: flow?.recordId.toString() ?? ''),
      ],
    );
  }
}

// ==================== 请求 ====================

class _RequestSegment extends StatelessWidget {
  const _RequestSegment({
    super.key,
    required this.detail,
    required this.onUseAsRewriteResponse,
    required this.onSaveBody,
  });

  final CaptureDetail? detail;
  final CaptureBodyAction? onUseAsRewriteResponse;
  final CaptureBodySaver? onSaveBody;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final url = d?.url ?? '';
    final query = Uri.tryParse(url)?.queryParametersAll ?? const {};
    final reqHeaders = d?.reqHeaders ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(label: '方法', value: d?.method ?? ''),
        _FieldRow(label: 'URL', value: url),
        _CollapsibleSection(
          sectionKey: 'req_query',
          title: 'Query',
          initiallyExpanded: true,
          child: query.isEmpty
              ? const _EmptyHint(text: '（无 Query）')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: query.entries
                      .map(
                        (e) => _FieldRow(
                          label: e.key,
                          value: e.value.join(', '),
                        ),
                      )
                      .toList(),
                ),
        ),
        _CollapsibleSection(
          sectionKey: 'req_headers',
          title: '请求头',
          child: _HeaderList(raw: reqHeaders),
        ),
        _CollapsibleSection(
          sectionKey: 'req_body',
          title: '请求体',
          initiallyExpanded: true,
          child: _BodyBlock(
            id: 'req',
            bytes: d?.reqBody ?? const <int>[],
            contentType: d?.contentType ?? '',
            contentEncoding: _headerValue(reqHeaders, 'content-encoding'),
            onUseAsRewriteResponse: onUseAsRewriteResponse,
            onSaveBody: onSaveBody,
          ),
        ),
      ],
    );
  }
}

// ==================== 响应 ====================

class _ResponseSegment extends StatelessWidget {
  const _ResponseSegment({
    super.key,
    required this.detail,
    required this.onUseAsRewriteResponse,
    required this.onSaveBody,
  });

  final CaptureDetail? detail;
  final CaptureBodyAction? onUseAsRewriteResponse;
  final CaptureBodySaver? onSaveBody;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final cookies = _parseCookies(d?.respHeaders ?? '');
    final frames = d?.wsFrames ?? const <CaptureWsFrame>[];
    final respHeaders = d?.respHeaders ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(
          label: '状态',
          value: d == null || d.statusCode == 0 ? '' : '${d.statusCode}',
        ),
        _CollapsibleSection(
          sectionKey: 'resp_headers',
          title: '响应头',
          child: _HeaderList(raw: respHeaders),
        ),
        _CollapsibleSection(
          sectionKey: 'resp_body',
          title: '响应体',
          initiallyExpanded: true,
          child: _BodyBlock(
            id: 'resp',
            bytes: d?.respBody ?? const <int>[],
            contentType: d?.contentType ?? '',
            contentEncoding: _headerValue(respHeaders, 'content-encoding'),
            onUseAsRewriteResponse: onUseAsRewriteResponse,
            onSaveBody: onSaveBody,
          ),
        ),
        _CollapsibleSection(
          sectionKey: 'resp_cookies',
          title: 'Cookie 表',
          initiallyExpanded: true,
          child: _CookieTable(cookies: cookies),
        ),
        if (frames.isNotEmpty)
          _CollapsibleSection(
            sectionKey: 'resp_ws',
            title: 'WebSocket 帧',
            child: _WsFrameList(frames: frames),
          ),
      ],
    );
  }
}

// ==================== 时间线 ====================

class _TimelineSegment extends StatelessWidget {
  const _TimelineSegment({super.key, required this.detail});

  final CaptureDetail? detail;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(label: '连接', value: d?.connId ?? ''),
        _CollapsibleSection(
          sectionKey: 'timeline_waterfall',
          title: '时间线瀑布',
          initiallyExpanded: true,
          child: _TimelineWaterfall(detail: d),
        ),
        _FieldRow(
          label: '首字节',
          value: d == null ? '' : _formatDateTime(d.startedAtMs),
        ),
        _FieldRow(
          label: '耗时',
          value: d == null ? '' : _formatMs(d.durationMs),
        ),
        _FieldRow(
          label: '开始',
          value: d == null ? '' : _formatDateTime(d.startedAtMs),
        ),
        _FieldRow(
          label: '结束',
          value: d == null ? '' : _formatDateTime(d.finishedAtMs),
        ),
      ],
    );
  }
}

/// 时间线瀑布：用可用字段（startedAt/finishedAt/durationMs）画一条占比条。
class _TimelineWaterfall extends StatelessWidget {
  const _TimelineWaterfall({required this.detail});

  final CaptureDetail? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = detail;
    final span = d == null ? 0 : d.finishedAtMs - d.startedAtMs;
    final total = span > 0 ? span : (d?.durationMs ?? 0);
    final duration = d?.durationMs ?? 0;
    final factor = (total <= 0 || duration <= 0)
        ? 0.0
        : (duration / total).clamp(0.0, 1.0).toDouble();
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      key: const Key('timeline_waterfall'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: AppRadius.allSM,
                  ),
                ),
                if (factor > 0)
                  FractionallySizedBox(
                    widthFactor: factor,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: AppRadius.allSM,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                _formatDateTime(d?.startedAtMs ?? 0),
                style: labelStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(_formatMs(duration), style: labelStyle),
            Expanded(
              child: Text(
                _formatDateTime(d?.finishedAtMs ?? 0),
                style: labelStyle,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ==================== 元数据 ====================

class _MetadataSegment extends StatelessWidget {
  const _MetadataSegment({
    super.key,
    required this.detail,
    required this.flow,
  });

  final CaptureDetail? detail;
  final RequestRecord? flow;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final f = flow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldRow(label: '记录 ID', value: d?.recordId.toString() ?? ''),
        _FieldRow(
          label: '流记录 ID',
          value: d?.requestRecordId.toString() ?? '',
        ),
        _FieldRow(label: '连接 ID', value: d?.connId ?? f?.connId ?? ''),
        _FieldRow(label: '源', value: f?.src ?? ''),
        _FieldRow(
          label: '目标',
          value: f == null ? '' : '${f.dstIp}:${f.dstPort}',
        ),
        _FieldRow(label: 'UID', value: f?.uid?.toString() ?? ''),
        _FieldRow(
          label: '应用包',
          value: (f == null || f.packages.isEmpty) ? '' : f.packages.join(', '),
        ),
        _FieldRow(label: '结束原因', value: f?.closeReason ?? ''),
        _FieldRow(label: '协议', value: d?.protocol ?? ''),
        _FieldRow(label: '方案', value: d?.scheme ?? ''),
        _FieldRow(
          label: '截断',
          value: d == null ? '' : (d.truncated ? '是' : '否'),
        ),
        _FieldRow(
          label: '解密失败',
          value: d == null ? '' : (d.mitmFailed ? '是' : '否'),
        ),
      ],
    );
  }
}

// ==================== 通用展示件 ====================

/// 详情字段：标签 + 值（值可选中、等宽、自动换行）。
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.value});

  final String label;
  final String value;

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
          SelectableText(
            display,
            style: AppTypography.code.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 可折叠小节（标题 + 展开内容）。
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection({
    required this.sectionKey,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  final String sectionKey;
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: Key('section_${widget.sectionKey}'),
      margin: AppSpacing.onlyBottomMD,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('section_toggle_${widget.sectionKey}'),
            borderRadius: AppRadius.allMD,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: AppSpacing.horizontalMD_verticalSM,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? TablerIcons.chevron_up
                        : TablerIcons.chevron_down,
                    size: AppTypography.iconMD,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: AppSpacing.horizontalMD_verticalSM,
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// 空内容提示。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 头部键值列表（解析 `Name: value` 行；续行以空白开头时并入上一值）。
class _HeaderList extends StatelessWidget {
  const _HeaderList({required this.raw});

  final String raw;

  @override
  Widget build(BuildContext context) {
    final headers = _parseHeaders(raw);
    if (headers.isEmpty) return const _EmptyHint(text: '（无请求头）');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: headers
          .map((h) => _FieldRow(label: '${h.$1}:', value: h.$2))
          .toList(),
    );
  }
}

/// Cookie 表（响应 `Set-Cookie`，缺省回退请求 `Cookie`）。
class _CookieTable extends StatelessWidget {
  const _CookieTable({required this.cookies});

  final List<_Cookie> cookies;

  @override
  Widget build(BuildContext context) {
    if (cookies.isEmpty) return const _EmptyHint(text: '（无 Cookie）');
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(flex: 3, child: Text('名称', style: headerStyle)),
            Expanded(flex: 5, child: Text('值', style: headerStyle)),
            Expanded(flex: 4, child: Text('属性', style: headerStyle)),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ...cookies.map(
          (c) => Padding(
            padding: AppSpacing.onlyBottomSM,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Text(c.name, style: AppTypography.code),
                ),
                Expanded(
                  flex: 5,
                  child: Text(c.value, style: AppTypography.code),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    c.attributes.isEmpty ? '—' : c.attributes,
                    style: AppTypography.code.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// WebSocket 帧列表。
class _WsFrameList extends StatelessWidget {
  const _WsFrameList({required this.frames});

  final List<CaptureWsFrame> frames;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: frames
          .map(
            (f) => _FieldRow(
              label: '${f.direction.isEmpty ? '—' : f.direction} · '
                  '${f.opcode.isEmpty ? '—' : f.opcode} · ${f.payloadLen} B',
              value: f.preview.isEmpty
                  ? '（空）'
                  : utf8.decode(f.preview, allowMalformed: true),
            ),
          )
          .toList(),
    );
  }
}

/// Body 展示模式。
enum _BodyView { raw, formatted, hex }

/// Body 区：`原始 / 格式化 / 十六进制 / 图片预览 / 搜索 / 复制 / 存盘 /
/// 作为改写响应`，限高内部滚动。
///
/// * 按 [contentEncoding] 解码展示（gzip / deflate；未知编码回退原始字节）；
/// * 图片（`image/*`）额外渲染预览（解码失败降级为占位，不崩）；
/// * 存盘写**原始抓包字节**（byte-identical），不做任何重编码。
class _BodyBlock extends StatefulWidget {
  const _BodyBlock({
    required this.id,
    required this.bytes,
    required this.contentType,
    required this.contentEncoding,
    required this.onUseAsRewriteResponse,
    required this.onSaveBody,
  });

  /// `req` / `resp`（用于测试定位 key）。
  final String id;
  final List<int> bytes;
  final String contentType;

  /// 该侧 `Content-Encoding` 头值（空 = 未声明）。
  final String contentEncoding;
  final CaptureBodyAction? onUseAsRewriteResponse;
  final CaptureBodySaver? onSaveBody;

  @override
  State<_BodyBlock> createState() => _BodyBlockState();
}

class _BodyBlockState extends State<_BodyBlock> {
  _BodyView _view = _BodyView.raw;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final decoded = _decodeContentEncoding(widget.bytes, widget.contentEncoding);
    final viewBytes = decoded.bytes;
    final decodedText = _decodeBody(viewBytes);
    final isBinary = _looksBinary(viewBytes);
    final isImage = widget.contentType.toLowerCase().startsWith('image/') &&
        viewBytes.isNotEmpty;
    final display = isBinary
        ? '${base64Encode(viewBytes)}\n\n（二进制内容，base64 预览）'
        : (_view == _BodyView.formatted
            ? _formatBody(viewBytes, widget.contentType)
            : decodedText);
    final hits = _countOccurrences(decodedText, _searchQuery.trim());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _BodyActionChip(
              actionKey: 'body_raw_${widget.id}',
              label: '原始',
              selected: _view == _BodyView.raw,
              onTap: () => setState(() => _view = _BodyView.raw),
            ),
            const SizedBox(width: AppSpacing.xs),
            _BodyActionChip(
              actionKey: 'body_format_${widget.id}',
              label: '格式化',
              selected: _view == _BodyView.formatted,
              onTap: () => setState(() => _view = _BodyView.formatted),
            ),
            const SizedBox(width: AppSpacing.xs),
            _BodyActionChip(
              actionKey: 'body_hex_${widget.id}',
              label: '十六进制',
              selected: _view == _BodyView.hex,
              onTap: () => setState(() => _view = _BodyView.hex),
            ),
            const Spacer(),
            IconButton(
              key: Key('body_copy_${widget.id}'),
              tooltip: '复制',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                TablerIcons.copy,
                size: AppTypography.iconMD,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: () => _copy(context, decodedText),
            ),
            IconButton(
              key: Key('body_save_${widget.id}'),
              tooltip: '保存到文件',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                TablerIcons.download,
                size: AppTypography.iconMD,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: () => widget.onSaveBody?.call(
                widget.id,
                widget.bytes,
                widget.contentType,
              ),
            ),
          ],
        ),
        if (decoded.encoding.isNotEmpty)
          Padding(
            padding: AppSpacing.onlyBottomXS,
            child: Text(
              '解码后 ${viewBytes.length} B · ${decoded.encoding}',
              key: Key('body_decoded_size_${widget.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        Padding(
          padding: AppSpacing.onlyBottomXS,
          child: TextField(
            key: Key('body_search_${widget.id}'),
            controller: _searchController,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索正文',
              prefixIcon: Icon(
                TablerIcons.search,
                size: AppTypography.iconMD,
                color: scheme.onSurfaceVariant,
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
        ),
        if (_searchQuery.trim().isNotEmpty)
          Padding(
            padding: AppSpacing.onlyBottomXS,
            child: Text(
              hits == 0 ? '无匹配' : '命中 $hits 处',
              key: Key('body_search_hit_${widget.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: hits == 0 ? scheme.error : scheme.primary,
              ),
            ),
          ),
        if (isImage)
          Container(
            key: Key('body_image_${widget.id}'),
            constraints: const BoxConstraints(maxHeight: 240),
            alignment: Alignment.center,
            padding: AppSpacing.allSM,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: AppRadius.allSM,
            ),
            child: Image.memory(
              Uint8List.fromList(viewBytes),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const _EmptyHint(text: '（图片无法预览）'),
            ),
          ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          key: Key('body_scroll_${widget.id}'),
          constraints: const BoxConstraints(maxHeight: 320),
          width: double.infinity,
          padding: AppSpacing.allSM,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: AppRadius.allSM,
          ),
          child: SingleChildScrollView(
            child: viewBytes.isEmpty
                ? const _EmptyHint(text: '（空）')
                : (_view == _BodyView.hex
                    ? Text(
                        _toHexDump(viewBytes),
                        key: Key('body_hex_view_${widget.id}'),
                        style: AppTypography.code.copyWith(
                          color: scheme.onSurface,
                        ),
                      )
                    : Text(
                        display,
                        style: AppTypography.code.copyWith(
                          color: scheme.onSurface,
                        ),
                      )),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: Key('body_rewrite_${widget.id}'),
            onPressed: () =>
                widget.onUseAsRewriteResponse?.call(decodedText),
            icon: const Icon(TablerIcons.file_pencil, size: AppTypography.iconMD),
            label: const Text('作为改写响应'),
          ),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      AppDialogs.showSuccess('已复制');
    } catch (_) {
      if (!context.mounted) return;
      AppDialogs.showError('复制失败');
    }
  }
}

/// Body 区的原始 / 格式化切换药丸。
class _BodyActionChip extends StatelessWidget {
  const _BodyActionChip({
    required this.actionKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String actionKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: Key(actionKey),
      borderRadius: AppRadius.allSM,
      onTap: onTap,
      child: Container(
        padding: AppSpacing.horizontalSM_verticalXS,
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: AppRadius.allSM,
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 动作菜单项。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: AppRadius.allMD,
      onTap: onTap,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          children: [
            Icon(icon, size: AppTypography.iconMD, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(title, style: theme.textTheme.bodyLarge),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 纯函数（解析 / 格式化） ====================

/// Cookie 行。
class _Cookie {
  const _Cookie(this.name, this.value, this.attributes);

  final String name;
  final String value;
  final String attributes;
}

/// 解析头部文本 → `(name, value)` 列表（支持续行）。
List<(String, String)> _parseHeaders(String raw) {
  final result = <(String, String)>[];
  String? currentName;
  final buffer = StringBuffer();
  void flush() {
    if (currentName != null) {
      result.add((currentName!, buffer.toString().trim()));
    }
    currentName = null;
    buffer.clear();
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && currentName != null) {
      buffer.write(' ${line.trim()}');
      continue;
    }
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    flush();
    currentName = line.substring(0, idx).trim();
    buffer.write(line.substring(idx + 1).trim());
  }
  flush();
  return result;
}

/// 解析 `Set-Cookie`（缺省回退请求 `Cookie`）。
List<_Cookie> _parseCookies(String respHeaders) {
  final cookies = <_Cookie>[];
  for (final entry in _parseHeaders(respHeaders)) {
    if (entry.$1.toLowerCase() != 'set-cookie') continue;
    final parts = entry.$2.split(';');
    if (parts.isEmpty) continue;
    final nameValue = parts.first.trim();
    final eq = nameValue.indexOf('=');
    if (eq <= 0) continue;
    cookies.add(
      _Cookie(
        nameValue.substring(0, eq).trim(),
        nameValue.substring(eq + 1).trim(),
        parts.skip(1).map((p) => p.trim()).where((p) => p.isNotEmpty).join('; '),
      ),
    );
  }
  return cookies;
}

/// UTF-8 解码（容错：非法字节不抛，替换为 U+FFFD）。
String _decodeBody(List<int> bytes) {
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

/// 按 `Content-Encoding` 解码后的结果。
///
/// [encoding] 为**实际成功应用**的编码名（`''` = 未解码 / 未知编码回退原文）。
class _DecodedBody {
  const _DecodedBody(this.bytes, this.encoding);

  final List<int> bytes;
  final String encoding;
}

/// 按 `Content-Encoding` 解码（`gzip` / `deflate`）。
///
/// * 空 / `identity` → 原字节；
/// * `gzip` / `x-gzip` → [gzip].decode；
/// * `deflate` → 先试 zlib 包裹，失败再试 gzip 包裹；
/// * 未知编码（`br` / `zstd` / …）或解压失败 → **原字节回退**（绝不抛）。
_DecodedBody _decodeContentEncoding(List<int> bytes, String rawEncoding) {
  if (bytes.isEmpty) return _DecodedBody(bytes, '');
  final encoding = rawEncoding.trim().toLowerCase();
  if (encoding.isEmpty || encoding == 'identity') {
    return _DecodedBody(bytes, '');
  }
  try {
    if (encoding == 'gzip' || encoding == 'x-gzip') {
      return _DecodedBody(gzip.decode(bytes), encoding);
    }
    if (encoding == 'deflate') {
      try {
        return _DecodedBody(zlib.decode(bytes), encoding);
      } catch (_) {
        return _DecodedBody(gzip.decode(bytes), encoding);
      }
    }
  } catch (_) {
    // 未知 / 损坏编码 → 原文回退。
  }
  return _DecodedBody(bytes, '');
}

/// 从头部原文取某个（大小写不敏感）头的值；缺省返回 `''`。
String _headerValue(String raw, String lowerName) {
  for (final entry in _parseHeaders(raw)) {
    if (entry.$1.toLowerCase() == lowerName) return entry.$2;
  }
  return '';
}

/// 按内容类型给出存盘扩展名（缺省 `bin`）。
String _extensionFor(String contentType) {
  final ct = contentType.toLowerCase();
  if (ct.contains('json')) return 'json';
  if (ct.contains('xml')) return 'xml';
  if (ct.contains('html')) return 'html';
  if (ct.contains('css')) return 'css';
  if (ct.contains('javascript')) return 'js';
  if (ct.contains('plain') || ct.startsWith('text/')) return 'txt';
  if (ct.contains('png')) return 'png';
  if (ct.contains('jpeg') || ct.contains('jpg')) return 'jpg';
  if (ct.contains('gif')) return 'gif';
  if (ct.contains('webp')) return 'webp';
  if (ct.contains('svg')) return 'svg';
  if (ct.contains('pdf')) return 'pdf';
  return 'bin';
}

/// 子串出现次数（大小写不敏感；空串 → 0）。
int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty || haystack.isEmpty) return 0;
  final lowerHaystack = haystack.toLowerCase();
  final lowerNeedle = needle.toLowerCase();
  var count = 0;
  var index = lowerHaystack.indexOf(lowerNeedle);
  while (index != -1) {
    count++;
    index = lowerHaystack.indexOf(lowerNeedle, index + lowerNeedle.length);
  }
  return count;
}

/// 生成 `offset  hex…  ascii` 的十六进制转储（每行 16 字节）。
String _toHexDump(List<int> bytes) {
  const perLine = 16;
  final buffer = StringBuffer();
  for (var offset = 0; offset < bytes.length; offset += perLine) {
    final end =
        (offset + perLine < bytes.length) ? offset + perLine : bytes.length;
    final hex = StringBuffer();
    final ascii = StringBuffer();
    for (var i = offset; i < end; i++) {
      final b = bytes[i];
      hex.write(b.toRadixString(16).padLeft(2, '0'));
      if (i != end - 1) hex.write(' ');
      ascii.write(b >= 32 && b < 127 ? String.fromCharCode(b) : '.');
    }
    buffer.writeln(
      '${offset.toRadixString(16).padLeft(8, '0')}  '
      '${hex.toString().padRight(perLine * 3 - 1)}  $ascii',
    );
  }
  return buffer.toString().trimRight();
}

/// 是否疑似二进制（含 NUL，或控制字符占比 > 10%）。
bool _looksBinary(List<int> bytes) {
  if (bytes.isEmpty) return false;
  const int sample = 1024;
  final n = bytes.length > sample ? sample : bytes.length;
  var controls = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) return true;
    final isText = b == 9 || b == 10 || b == 13 || (b >= 32 && b != 127);
    if (!isText) controls++;
  }
  return controls * 10 > n;
}

/// 按内容类型格式化 Body（JSON / XML / 文本；失败回退原文）。
String _formatBody(List<int> bytes, String contentType) {
  final text = _decodeBody(bytes);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;
  final ct = contentType.toLowerCase();
  if (ct.contains('json') || trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      // 非法 JSON → 回退原文
    }
  }
  if (ct.contains('xml') || trimmed.startsWith('<')) {
    return _prettyXml(text);
  }
  return text;
}

/// 轻量 XML 缩进（失败/异常结构不抛，仅做 best-effort）。
String _prettyXml(String xml) {
  try {
    final buffer = StringBuffer();
    var depth = 0;
    final tokens = xml.split(RegExp(r'(?=<)'));
    for (final token in tokens) {
      final t = token.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('</')) {
        depth = depth > 0 ? depth - 1 : 0;
      }
      buffer.writeln('${'  ' * depth}$t');
      final isOpen = t.startsWith('<') &&
          !t.startsWith('</') &&
          !t.startsWith('<?') &&
          !t.startsWith('<!') &&
          !t.endsWith('/>') &&
          !t.contains('</');
      if (isOpen) depth++;
    }
    return buffer.toString().trimRight();
  } catch (_) {
    return xml;
  }
}

/// 毫秒耗时 → 人类可读。
String _formatMs(int ms) {
  if (ms <= 0) return '—';
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(2)} s';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 毫秒时间戳 → `yyyy-MM-dd HH:mm:ss`（0 = 空）。
String _formatDateTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}
