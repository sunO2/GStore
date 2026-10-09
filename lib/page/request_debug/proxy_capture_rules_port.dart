/// 生产改写规则端口：把「请求调试」Seam 2 接到 `ProxyModule`（plan todo 35）。
///
/// [CaptureRulesPort] 定义在纯逻辑层 `lib/core/request_debug/request_debug_facade.dart`，
/// 生产实现落在此处（页面层），复用 [debugRuleToSetRequest] /
/// [parseRuleHeaderLines] 的线缆映射，经 [ProxyModule] 的 typed 绑定
/// `captureRulesGet/Set/Remove`（`invoke` 信封）读写 Rust 规则表。
///
/// 失败时抛异常：门面在端口边界捕获并转为显式失败结果，页面无需 try/catch
/// （见 `RequestDebugFacade` 的 `_guardRules`）。
library;

import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'rules_section.dart';

/// 经 [ProxyModule] 读写 `capture.rules.*` 的生产端口。
class ProxyModuleCaptureRulesPort implements CaptureRulesPort {
  ProxyModuleCaptureRulesPort([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<List<DebugRewriteRule>> getRules() async {
    final rules = await _module.captureRulesGet();
    return rules.map(debugRewriteRuleFromContract).toList();
  }

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async {
    final saved = await _module.captureRulesSet(debugRuleToSetRequest(rule));
    return debugRewriteRuleFromContract(saved);
  }

  @override
  Future<bool> removeRule(String id) async {
    final result = await _module.captureRulesRemove(id);
    return result.removed;
  }
}

/// Rust [CaptureRule] → UI [DebugRewriteRule] 的字段翻译（纯函数）。
///
/// `kind` 线缆值为 `replace` / `local`（`API.md` §2.19）；未知值降级为
/// [DebugRewriteKind.replaceResponse]（绝不抛错）。
DebugRewriteRule debugRewriteRuleFromContract(CaptureRule rule) {
  final headers = rule.respHeaders;
  return DebugRewriteRule(
    id: rule.id,
    enabled: rule.enabled,
    method: rule.method,
    url: rule.url,
    kind: _debugRewriteKindFromWire(rule.kind),
    remark: rule.remark,
    statusCode: rule.statusCode,
    respHeaders: (headers == null || headers.trim().isEmpty)
        ? null
        : parseRuleHeaderLines(headers),
    respBody: rule.respBody,
    delayMs: rule.delayMs,
    hitCount: rule.hitCount,
    matchType: DebugRewriteMatch.fromWire(rule.matchType),
  );
}

DebugRewriteKind _debugRewriteKindFromWire(String wire) =>
    wire == 'local'
        ? DebugRewriteKind.localResponse
        : DebugRewriteKind.replaceResponse;
