/// 抓包详情 → 请求调试 / 改写规则的动作桥（plan todo 24）。
///
/// 详情页（[ProxyCaptureDetailPage]，todo 23）只暴露**可空回调接缝**，本文件
/// 把这些接缝绑定到窄接口 [CaptureBridge]——跨 feature 桥接**只**经此接口，
/// 页面之间不互相 import 对方 State，也**不** import 请求调试的 store。
///
/// * `复制 cURL`：纯本地拼装（[buildCaptureCurl]），本 todo 只做**最小**等价
///   拼装，todo 27 的完整 codec 后续收敛复用（本文件**不**依赖它）。
/// * `保存到请求调试`：[CaptureBridge.saveToCollection] 写出；生产适配器
///   （抓包字节 → `DebugRequest` 映射 + 落库）在 todo 35 接线，本 todo 仅以
///   假实现测试。
/// * `创建改写规则`：[captureRulePrefill] 预填 method/url + 当前响应作为
///   `replace` 初值，再经 [CaptureBridge.openRewriteRuleEditor] 跳编辑器。
///
/// 失败一律在 [CaptureDetailActionBinder] 边界转 `AppDialogs.showError`，
/// 绝不把异常抛给页面。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';

// ==================== 窄接口 ====================

/// 抓包详情动作桥（窄接口，跨 feature 边界）。
///
/// 生产适配器在 todo 35 接线（复用「抓包记录 → DebugRequest」映射）；本 todo
/// 只能用假实现注入。实现方法失败时抛异常，由 [CaptureDetailActionBinder]
/// 捕获并转 `showError`。
abstract class CaptureBridge {
  /// `保存到请求调试`：把一条抓包详情写入请求调试集合。
  ///
  /// 由适配器负责 `CaptureDetail` → `DebugRequest` 的字段映射与落库；
  /// 调用方不需要（也不允许）触碰请求调试 store。
  Future<void> saveToCollection(CaptureDetail detail);

  /// `创建改写规则`：打开改写规则编辑器并预填 [prefill]。
  Future<void> openRewriteRuleEditor(CaptureRulePrefill prefill);
}

/// 未接线的生产桥：生产适配器在 todo 35 提供前使用。
///
/// **显式失败**：避免「静默成功」误导；调用方必须注入假实现或等待 todo 35。
class UnavailableCaptureBridge implements CaptureBridge {
  const UnavailableCaptureBridge();

  /// 未接线提示（测试据此断言）。
  static const String message = '抓包动作桥尚未接线（生产适配器在 todo 35 提供）';

  @override
  Future<void> saveToCollection(CaptureDetail detail) =>
      Future<void>.error(UnimplementedError(message));

  @override
  Future<void> openRewriteRuleEditor(CaptureRulePrefill prefill) =>
      Future<void>.error(UnimplementedError(message));
}

// ==================== 改写规则预填 ====================

/// 改写规则编辑器预填值（由抓包详情派生）。
class CaptureRulePrefill {
  const CaptureRulePrefill({
    required this.method,
    required this.url,
    required this.replaceBody,
    this.statusCode,
    this.responseHeaders,
  });

  /// 匹配方法（空 = 任意方法）。
  final String method;

  /// 匹配精确 URL。
  final String url;

  /// `replace` 初值：当前响应体文本。
  final String replaceBody;

  /// 当前响应状态码（缺省 = 不覆盖）。
  final int? statusCode;

  /// 当前响应头文本（缺省 = 不覆盖）。
  final String? responseHeaders;
}

/// 由抓包详情派生改写规则预填（纯函数）。
CaptureRulePrefill captureRulePrefill(CaptureDetail detail) {
  return CaptureRulePrefill(
    method: detail.method,
    url: captureUrl(detail),
    replaceBody: _decodeBody(detail.respBody),
    statusCode: detail.statusCode == 0 ? null : detail.statusCode,
    responseHeaders: detail.respHeaders.isEmpty ? null : detail.respHeaders,
  );
}

// ==================== cURL 最小拼装 ====================

/// 抓包详情的最终 URL：优先 `url`，缺省按 `scheme://host` 回退。
String captureUrl(CaptureDetail detail) {
  final url = detail.url.trim();
  if (url.isNotEmpty) return url;
  final host = detail.host.trim();
  if (host.isEmpty) return '';
  final scheme = detail.scheme.trim().isEmpty ? 'https' : detail.scheme.trim();
  return '$scheme://$host${detail.path}';
}

/// 由 method / url / headers / body 生成**等价** cURL 字符串（最小拼装）。
///
/// * `GET` / `HEAD` / 无方法不额外发 `-X`；
/// * 请求头按 `-H 'Name: value'` 逐条展开；
/// * 非空请求体用 `--data-raw`，单引号按 shell 安全序列转义。
///
/// 这是 todo 27 完整 codec 之前的**最小**实现；后续收敛复用，本文件先保持
/// 独立以解耦依赖。
String buildCaptureCurl(CaptureDetail detail) {
  final method = detail.method.trim().toUpperCase();
  final url = captureUrl(detail);
  final lines = <String>[];

  final head = StringBuffer('curl');
  if (method.isNotEmpty && method != 'GET' && method != 'HEAD') {
    head.write(' -X $method');
  }
  head.write(' ${_singleQuote(url)}');
  lines.add(head.toString());

  for (final header in _parseHeaderLines(detail.reqHeaders)) {
    lines.add('-H ${_singleQuote(header)}');
  }

  if (detail.reqBody.isNotEmpty) {
    lines.add('--data-raw ${_singleQuote(_decodeBody(detail.reqBody))}');
  }

  return lines.join(' \\\n  ');
}

/// 解析 `Name: value` 头文本为原始行（续行并入上一行）。
List<String> _parseHeaderLines(String raw) {
  final result = <String>[];
  final buffer = StringBuffer();
  var started = false;

  void flush() {
    if (started) result.add(buffer.toString().trim());
    buffer.clear();
    started = false;
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && started) {
      buffer.write(' ${line.trim()}');
      continue;
    }
    flush();
    buffer.write(line.trim());
    started = true;
  }
  flush();
  return result;
}

/// 单个 shell 参数的 POSIX 单引号包裹（内嵌单引号转义）。
String _singleQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// UTF-8 解码（容错：非法字节不抛）。
String _decodeBody(List<int> bytes) {
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes, allowMalformed: true);
}

// ==================== 接缝绑定 ====================

/// 把详情页的可注入回调接缝绑定到 [CaptureBridge]。
///
/// 用法（宿主 / 生产装配在 todo 35）：
/// ```dart
/// final binder = CaptureDetailActionBinder(bridge: bridge);
/// ProxyCaptureDetailPage(
///   recordId: id,
///   facade: facade,
///   onCopyCurl: binder.onCopyCurl,
///   onSaveToDebug: binder.onSaveToDebug,
///   onCreateRewriteRule: binder.onCreateRewriteRule,
///   onUseAsRewriteResponse: binder.onUseAsRewriteResponse,
/// );
/// ```
///
/// 提示信息走 [AppDialogs]（全局通道，无需 BuildContext）；失败只提示不抛。
class CaptureDetailActionBinder {
  const CaptureDetailActionBinder({required this.bridge});

  /// 注入的窄桥（生产在 todo 35 接线；测试注入假实现）。
  final CaptureBridge bridge;

  /// `复制 cURL` 回调（详情页接缝）。
  CaptureDetailAction get onCopyCurl => (d) => unawaited(copyCurl(d));

  /// `保存到请求调试` 回调（详情页接缝）。
  CaptureDetailAction get onSaveToDebug => (d) => unawaited(saveToDebug(d));

  /// `创建改写规则` 回调（详情页接缝）。
  CaptureDetailAction get onCreateRewriteRule =>
      (d) => unawaited(createRewriteRule(d));

  /// Body 区`作为改写响应` 回调（详情页接缝）。
  CaptureBodyAction get onUseAsRewriteResponse =>
      (body) => unawaited(createRewriteRuleFromBody(body));

  /// 生成等价 cURL 并写入剪贴板。
  Future<void> copyCurl(CaptureDetail detail) async {
    try {
      await Clipboard.setData(ClipboardData(text: buildCaptureCurl(detail)));
      AppDialogs.showSuccess('已复制 cURL');
    } catch (_) {
      AppDialogs.showError('复制 cURL 失败');
    }
  }

  /// 经 [CaptureBridge.saveToCollection] 保存到请求调试。
  Future<void> saveToDebug(CaptureDetail detail) async {
    try {
      await bridge.saveToCollection(detail);
      AppDialogs.showSuccess('已保存到请求调试');
    } catch (error) {
      AppDialogs.showError('保存失败：${_describe(error)}');
    }
  }

  /// 预填改写规则并跳编辑器（method/url + 当前响应）。
  Future<void> createRewriteRule(CaptureDetail detail) =>
      _openRuleEditor(captureRulePrefill(detail));

  /// 以指定响应体为 `replace` 初值跳改写规则编辑器。
  Future<void> createRewriteRuleFromBody(String body) => _openRuleEditor(
        CaptureRulePrefill(method: '', url: '', replaceBody: body),
      );

  Future<void> _openRuleEditor(CaptureRulePrefill prefill) async {
    try {
      await bridge.openRewriteRuleEditor(prefill);
    } catch (error) {
      AppDialogs.showError('创建改写规则失败：${_describe(error)}');
    }
  }

  static String _describe(Object error) => error.toString();
}
