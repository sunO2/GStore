/// 抓包开关的 CA 门控（与代理首页同一 `capture.ca.get` 复核流程）。
///
/// 首页、抓包设置页、请求列表页共用同一份文案与流程，避免三处漂移：
/// 开启抓包前实时复核 MITM 根证书是否存在；缺失时经统一
/// [AppDialogs.showConfirmSheet] 提示（HTTPS 不解密、仅明文 HTTP 会被抓取）
/// 并给出「继续开启 / 去设置」两个动作——选「继续开启」可在无证书时开启
/// 抓包（此时只有明文 HTTP 会被抓取），**绝不默默开启**。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 无 CA 时的拦截标题（首页 / 设置页 / 列表页共用同一文案）。
const String kCaptureNeedsCaTitle = '需要先生成根证书';

/// 无 CA 时的提示正文。
const String kCaptureNeedsCaMessage =
    '未安装 MITM 根证书：HTTPS 流量不会被解密，仅明文 HTTP 流量会被抓取。'
    '如需抓取 HTTPS，请先在「抓包设置 › 证书管理」生成并信任证书。';

/// 提示弹层确认按钮文案（无证书也继续开启抓包）。
const String kCaptureNeedsCaConfirmText = '继续开启';

/// 提示弹层取消按钮文案（跳转「证书管理」）。
const String kCaptureNeedsCaCancelText = '去设置';

/// CA 门控结果：是否放行开启抓包，以及当前是否已生成 MITM 根证书。
///
/// [caGenerated] 供首页**如实**渲染状态标签（无证书时显示「仅 HTTP」，
/// 绝不谎报 `HTTP+HTTPS`）。
class CaptureCaGateResult {
  const CaptureCaGateResult({required this.allowed, required this.caGenerated});

  /// 是否允许继续开启抓包（有证书，或用户在无证书提示中选「继续开启」）。
  final bool allowed;

  /// 复核时刻 MITM 根证书是否已生成。
  final bool caGenerated;
}

/// CA 复核接缝（`capture.ca.get`）。
///
/// 页面门面若实现本接口，则开启抓包前强制复核；否则跳过（供既有密闭测试
/// 保留原行为）。生产适配器均实现本接口。
abstract class ProxyCaptureCaGate {
  Future<CaptureCaInfo> captureCaGet();
}

/// 生产适配器：[ProxyModule] → [ProxyCaptureCaGate] 的薄转发。
class ProxyModuleCaptureCaGate implements ProxyCaptureCaGate {
  ProxyModuleCaptureCaGate([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<CaptureCaInfo> captureCaGet() => _module.captureCaGet();
}

/// 开启抓包前复核 CA。
///
/// 已生成 → `(allowed:true, caGenerated:true)`。缺失时弹统一提示（标题
/// [kCaptureNeedsCaTitle]，正文 [kCaptureNeedsCaMessage]）：
/// * 确认「继续开启」→ `(allowed:true, caGenerated:false)`（无证书也放行，
///   此时仅明文 HTTP 会被抓取）；
/// * 取消「去设置」→ 触发 [onOpenCaptureSettings] 并 `(allowed:false, ...)`。
///
/// 读取失败按「无 CA」处理（与首页 best-effort 行为一致），经提示后由用户
/// 决定是否继续。
Future<CaptureCaGateResult> ensureCaptureCaGate({
  required Future<CaptureCaInfo> Function() captureCaGet,
  required VoidCallback onOpenCaptureSettings,
}) async {
  CaptureCaInfo? ca;
  try {
    ca = await captureCaGet();
  } catch (_) {
    ca = null;
  }
  if (ca?.generated == true) {
    return const CaptureCaGateResult(allowed: true, caGenerated: true);
  }
  final result = await AppDialogs.showConfirmSheet(
    title: kCaptureNeedsCaTitle,
    message: kCaptureNeedsCaMessage,
    confirmText: kCaptureNeedsCaConfirmText,
    cancelText: kCaptureNeedsCaCancelText,
    onCancel: onOpenCaptureSettings,
  );
  return CaptureCaGateResult(allowed: result == true, caGenerated: false);
}
