import 'package:gstore/core/core.dart' show getProxy;
import 'package:gstore/core/utils/unit.dart' show applyProxyIfNeeded;

/// 下载服务入口的统一 URL 解析。
///
/// 渠道 / 策略层可能已经套过代理（URL 以代理前缀开头），也可能完全没处理
/// （例如 GStore catalog 从 Rust 原样映射的下载地址）。这里做最后一层兜底：
/// GitHub 相关域名统一复用 [applyProxyIfNeeded] 套代理；非 GitHub URL 原样返回。
///
/// 幂等：已带当前代理前缀的 URL 不会二次拼接。代理值会补齐尾部 `/`，避免
/// 用户配置 `https://gh-proxy.org`（无斜杠）时拼出非法 URL。
String resolveDownloadUrl(
  String url, {
  String? proxy,
  bool autoProxy = true,
}) {
  if (!autoProxy) return url;
  final value = (proxy ?? getProxy()).trim();
  if (value.isEmpty) return url;
  final normalized = value.endsWith('/') ? value : '$value/';
  return applyProxyIfNeeded(url, normalized);
}
