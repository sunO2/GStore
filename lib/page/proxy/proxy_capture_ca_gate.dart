/// 抓包开关的 CA 门控（与代理首页同一 `capture.ca.get` 复核流程）。
///
/// 首页、抓包设置页、请求列表页共用同一份文案与流程，避免三处漂移：
/// 开启抓包前实时复核 MITM 根证书是否存在；缺失时经统一
/// [AppDialogs.showConfirmSheet] 拦截并引导到「抓包设置 › 证书管理」，
/// **绝不默默开启**。仅 HTTP 明文流量无需证书。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 无 CA 时的拦截标题（首页 / 设置页 / 列表页共用同一文案）。
const String kCaptureNeedsCaTitle = '需要先生成根证书';

/// 无 CA 时的拦截正文。
const String kCaptureNeedsCaMessage =
    '抓取 HTTPS 流量需要 MITM 根证书。请先在「抓包设置 › 证书管理」'
    '生成并信任证书，再开启抓包；仅 HTTP 明文流量无需证书。';

/// 拦截弹层确认按钮文案（跳转「证书管理」）。
const String kCaptureNeedsCaConfirmText = '去设置';

/// 拦截弹层取消按钮文案。
const String kCaptureNeedsCaCancelText = '取消';

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

/// 开启抓包前复核 CA：已生成 → `true`；否则弹统一确认（「去设置」）→ `false`。
///
/// 读取失败按「无 CA」处理（与首页 best-effort 行为一致），绝不放行。
Future<bool> ensureCaptureCaGate({
  required Future<CaptureCaInfo> Function() captureCaGet,
  required VoidCallback onOpenCaptureSettings,
}) async {
  CaptureCaInfo? ca;
  try {
    ca = await captureCaGet();
  } catch (_) {
    ca = null;
  }
  if (ca?.generated == true) return true;
  await AppDialogs.showConfirmSheet(
    title: kCaptureNeedsCaTitle,
    message: kCaptureNeedsCaMessage,
    confirmText: kCaptureNeedsCaConfirmText,
    cancelText: kCaptureNeedsCaCancelText,
    onConfirm: onOpenCaptureSettings,
  );
  return false;
}
