/// 抓包详情动作桥的**生产适配器**（plan todo 35）。
///
/// 把 [CaptureBridge]（todo 24 定义的窄接口）接到真实能力：
///
/// * `保存到请求调试`：[saveToCollection] 用 [debugRequestFromCapture] 把
///   [CaptureDetail] 映射为 [DebugRequest]，再经 [RequestDebugFacade]（**不**
///   直接触碰 store）写入约定的「抓包」集合并落盘。
/// * `创建改写规则`：[openRewriteRuleEditor] 跳转「请求调试」工作台（改写规则
///   编辑器所在分区），预填值经路由 extra 传递。
///
/// 装配：`CaptureDetailActionBinder(bridge: RequestDebugCaptureBridge())`，或直接用
/// [productionCaptureActionBinder]。失败时由 [CaptureDetailActionBinder] 边界
/// 转 `AppDialogs.showError`，绝不把异常抛给页面。
library;

import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';

import '../request_debug/request_debug_facade_provider.dart';
import 'proxy_capture_bridge.dart';

/// 抓包保存的默认集合名（集合不存在时自动创建）。
const String kCaptureDebugCollectionName = '抓包';

/// 打开改写规则编辑器的导航接缝（默认经全局路由；测试可注入断言载荷）。
typedef RewriteRuleEditorOpener = void Function(CaptureRulePrefill prefill);

/// 生产抓包动作桥：映射 + 经请求调试门面落库。
///
/// 门面默认取共享 [RequestDebugFacadeProvider.instance]（与请求调试页同一
/// store，消除双门面覆盖）；测试可注入假门面。
class RequestDebugCaptureBridge implements CaptureBridge {
  RequestDebugCaptureBridge({
    RequestDebugFacade? facade,
    RewriteRuleEditorOpener? openRuleEditor,
  })  : _facade = facade ?? RequestDebugFacadeProvider.instance,
        _openRuleEditor = openRuleEditor ?? _openViaRouter;

  final RequestDebugFacade _facade;

  /// 打开改写规则编辑器的导航接缝（默认 `appRouter.go`，测试可注入）。
  final RewriteRuleEditorOpener _openRuleEditor;

  /// 注入的门面（测试可断言调用）。
  RequestDebugFacade get facade => _facade;

  /// 默认导航：把预填经路由 extra 交给「请求调试」工作台（落到改写规则分区）。
  static void _openViaRouter(CaptureRulePrefill prefill) {
    appRouter.go(AppRoute.requestDebug, extra: prefill);
  }

  @override
  Future<void> saveToCollection(CaptureDetail detail) async {
    // store 语义：加载损坏时降级为空，不抛。
    await _facade.load();
    final collectionId = _ensureCaptureCollection();
    final request = debugRequestFromCapture(detail);

    // Seam 1：门面负责把 collectionId 回填并写内存。
    await _facade.saveCaptured(collectionId: collectionId, request: request);
    final saved = await _facade.save();
    if (!saved) {
      throw StateError('请求调试存储落盘失败');
    }
  }

  @override
  Future<void> openRewriteRuleEditor(CaptureRulePrefill prefill) async {
    // 改写规则编辑器在「请求调试」工作台内；预填值经路由 extra 传递。
    _openRuleEditor(prefill);
  }

  /// 取「抓包」集合 id；不存在则创建。
  String _ensureCaptureCollection() {
    final store = _facade.store;
    for (final collection in store.collections) {
      if (collection.name == kCaptureDebugCollectionName) {
        return collection.id;
      }
    }
    return store.addCollection(name: kCaptureDebugCollectionName).id;
  }
}

/// 生产动作绑定：保存 / 建规则经 [RequestDebugCaptureBridge] 真实执行。
CaptureDetailActionBinder productionCaptureActionBinder() =>
    CaptureDetailActionBinder(bridge: RequestDebugCaptureBridge());
