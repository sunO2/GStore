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

  @override
  State<ProxyCaptureDetailPage> createState() => _ProxyCaptureDetailPageState();
}

class _ProxyCaptureDetailPageState extends State<ProxyCaptureDetailPage> {
  late final ProxyCaptureDetailFacade _facade;
  late final ProxyCaptureDeleteFacade _deleteFacade;

  CaptureDetailSegment _segment = CaptureDetailSegment.overview;
  bool _loading = true;
  String? _error;
  CaptureDetail? _detail;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleCaptureDetailFacade();
    _deleteFacade = widget.deleteFacade ?? ProxyModuleCaptureDeleteFacade();
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

  /// 无 HTTP 详情（未解密）判定：记录未命中，或 MITM 失败。
  bool get _flowOnly => _detail == null || _detail!.mitmFailed;

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
                if (_flowOnly)
                  _UndecryptedNotice(detail: _detail, flow: widget.flow),
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
        );
      case CaptureDetailSegment.response:
        return _ResponseSegment(
          key: const Key('detail_segment_response'),
          detail: detail,
          onUseAsRewriteResponse: widget.onUseAsRewriteResponse,
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
            key: const Key('action_create_rule'),
            icon: TablerIcons.file_pencil,
            title: '创建改写规则',
            onTap: () {
              AppDialogs.popSheet<void>(null);
              widget.onCreateRewriteRule?.call(detail);
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
  });

  final CaptureDetail? detail;
  final CaptureBodyAction? onUseAsRewriteResponse;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final url = d?.url ?? '';
    final query = Uri.tryParse(url)?.queryParametersAll ?? const {};
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
          child: _HeaderList(raw: d?.reqHeaders ?? ''),
        ),
        _CollapsibleSection(
          sectionKey: 'req_body',
          title: '请求体',
          initiallyExpanded: true,
          child: _BodyBlock(
            id: 'req',
            bytes: d?.reqBody ?? const <int>[],
            contentType: d?.contentType ?? '',
            onUseAsRewriteResponse: onUseAsRewriteResponse,
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
  });

  final CaptureDetail? detail;
  final CaptureBodyAction? onUseAsRewriteResponse;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final cookies = _parseCookies(d?.respHeaders ?? '');
    final frames = d?.wsFrames ?? const <CaptureWsFrame>[];
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
          child: _HeaderList(raw: d?.respHeaders ?? ''),
        ),
        _CollapsibleSection(
          sectionKey: 'resp_body',
          title: '响应体',
          initiallyExpanded: true,
          child: _BodyBlock(
            id: 'resp',
            bytes: d?.respBody ?? const <int>[],
            contentType: d?.contentType ?? '',
            onUseAsRewriteResponse: onUseAsRewriteResponse,
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

/// Body 区：`原始 / 格式化 / 复制 / 作为改写响应`，限高内部滚动。
class _BodyBlock extends StatefulWidget {
  const _BodyBlock({
    required this.id,
    required this.bytes,
    required this.contentType,
    required this.onUseAsRewriteResponse,
  });

  /// `req` / `resp`（用于测试定位 key）。
  final String id;
  final List<int> bytes;
  final String contentType;
  final CaptureBodyAction? onUseAsRewriteResponse;

  @override
  State<_BodyBlock> createState() => _BodyBlockState();
}

class _BodyBlockState extends State<_BodyBlock> {
  bool _formatted = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bytes = widget.bytes;
    final isBinary = _looksBinary(bytes);
    final raw = _decodeBody(bytes);
    final display = (isBinary || !_formatted)
        ? raw
        : _formatBody(bytes, widget.contentType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _BodyActionChip(
              actionKey: 'body_raw_${widget.id}',
              label: '原始',
              selected: !_formatted,
              onTap: () => setState(() => _formatted = false),
            ),
            const SizedBox(width: AppSpacing.xs),
            _BodyActionChip(
              actionKey: 'body_format_${widget.id}',
              label: '格式化',
              selected: _formatted,
              onTap: () => setState(() => _formatted = true),
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
              onPressed: () => _copy(context, raw),
            ),
          ],
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
            child: bytes.isEmpty
                ? const _EmptyHint(text: '（空）')
                : Text(
                    isBinary
                        ? '${base64Encode(bytes)}\n\n（二进制内容，base64 预览）'
                        : display,
                    style: AppTypography.code.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: Key('body_rewrite_${widget.id}'),
            onPressed: () => widget.onUseAsRewriteResponse?.call(raw),
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
