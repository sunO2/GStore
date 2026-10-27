import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';
import 'package:gstore/core/channel/script_ui_request_router.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// Returns the app id of the page currently bound to the registry.
typedef ScriptUiAppIdProvider = String Function();

/// Returns the channel key of the page currently bound to the registry.
typedef ScriptUiChannelKeyProvider = String Function();

/// Opaque handle returned by [ScriptUiHandlerRegistry.bind].
///
/// [ScriptUiHandlerRegistry.unbind] only clears the registry when the handle is
/// still the active binding, so a slow page teardown cannot unbind a newer page.
class ScriptUiBinding {
  ScriptUiBinding._();
}

/// Process-wide indirection for the eight `ui.*` script handlers.
///
/// `DetailCallbacks` is per-detail-page, while [ScriptUiRequestRouter] is a
/// process-wide singleton. Registering a page's callbacks at channel-init time
/// would therefore pin the first (or a dead) page. Instead the router always
/// holds handlers that read *this* registry, and the detail page binds/unbinds
/// its callbacks here for the lifetime of the page.
///
/// With no active page every handler answers the typed
/// [noActiveDetailCode] envelope; it never falls through to the router's silent
/// `ui.<kind> 未注册` response.
class ScriptUiHandlerRegistry {
  ScriptUiHandlerRegistry._();

  /// Process-wide registry.
  static final ScriptUiHandlerRegistry instance = ScriptUiHandlerRegistry._();

  /// Stable typed error code for "there is no active detail page".
  static const String noActiveDetailCode = 'CORE_E_SCRIPT_UI_NO_ACTIVE_DETAIL';

  DetailCallbacks? _callbacks;
  ScriptUiAppIdProvider? _appId;
  ScriptUiChannelKeyProvider? _channelKey;
  ScriptUiBinding? _binding;

  /// Whether a detail page is currently bound.
  bool get hasActivePage => _callbacks != null && _binding != null;

  /// Channel key of the active page, or null when no page is bound.
  String? get activeChannelKey => _channelKey?.call();

  /// Binds the active detail page. A newer bind replaces the previous page.
  ScriptUiBinding bind({
    required DetailCallbacks callbacks,
    required ScriptUiAppIdProvider appId,
    required ScriptUiChannelKeyProvider channelKey,
  }) {
    final binding = ScriptUiBinding._();
    _binding = binding;
    _callbacks = callbacks;
    _appId = appId;
    _channelKey = channelKey;
    return binding;
  }

  /// Unbinds [binding] when it is still the active page (stale teardown is a
  /// no-op). Never throws.
  void unbind(ScriptUiBinding binding) {
    if (!identical(_binding, binding)) return;
    _clear();
  }

  /// Clears the active page unconditionally (module teardown/tests).
  void detach() => _clear();

  /// Test seam: equivalent to [detach].
  void resetForTest() => _clear();

  void _clear() {
    _binding = null;
    _callbacks = null;
    _appId = null;
    _channelKey = null;
  }

  /// Builds the full `kind -> handler` map. Rebuilding is cheap and every
  /// handler resolves the active page at call time.
  Map<String, ScriptUiHandler> buildHandlers() => <String, ScriptUiHandler>{
        for (final kind in ScriptUiRequestRouter.uiKinds)
          kind: (payload) => _dispatch(kind, payload),
      };

  /// Registers all eight `ui.*` kinds on [router].
  ///
  /// Idempotent: [ScriptUiRequestRouter.registerAll] overwrites the same map
  /// entries, so repeated initialization leaves exactly eight live handlers and
  /// never stacks callbacks.
  void registerOn(ScriptUiRequestRouter router) {
    router.registerAll(buildHandlers());
  }

  Future<Object?> _dispatch(String kind, Map<String, dynamic> payload) async {
    final callbacks = _callbacks;
    final appId = _appId?.call();
    if (callbacks == null || appId == null) {
      return <String, Object?>{
        'ok': false,
        'error': noActiveDetailCode,
        'message': 'ui.$kind requires an active detail page',
      };
    }
    switch (kind) {
      case 'showVersionPicker':
        await callbacks.showVersionPicker(
          options: Map<String, dynamic>.from(payload),
          appId: appId,
        );
        return null;
      case 'showBuildHistory':
        final builds = ((payload['builds'] as List?) ?? <Object?>[])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        await callbacks.showBuildHistory(
          builds: builds,
          appId: appId,
          version: payload['version']?.toString() ?? '',
          env: payload['env']?.toString() ?? '',
        );
        return null;
      case 'refreshDetail':
        await callbacks.refreshDetail(
          detailData: Map<String, dynamic>.from(payload),
        );
        return null;
      case 'updateDownloadList':
        final downloads = (payload['downloads'] as List?) ?? <Object?>[];
        final parsed = JsChannelDetailProxy(<String, dynamic>{
          'downloads': downloads,
        }).downloads;
        await callbacks.updateDownloadList(downloads: parsed);
        return null;
      case 'showUAPicker':
        final options = ((payload['options'] as List?) ?? <Object?>[])
            .map((entry) => (entry as Map)['ua']?.toString() ?? '')
            .where((ua) => ua.isNotEmpty)
            .toList();
        final current = (payload['current'] as String?)?.isNotEmpty == true
            ? payload['current'] as String
            : null;
        return callbacks.showUAPicker(
          uaOptions: options,
          appId: appId,
          current: current,
        );
      case 'updateDetail':
        await callbacks.updateDetail(
          partial: Map<String, dynamic>.from(payload),
        );
        return null;
      case 'setBusy':
        await callbacks.setActionBusy(
          visible: payload['visible'] == true,
          label: payload['label']?.toString() ?? '',
        );
        return null;
      case 'download':
        final url = payload['url']?.toString() ?? '';
        if (url.isEmpty) {
          return <String, Object?>{'ok': false, 'error': '下载地址为空'};
        }
        final size = (payload['size'] as num?)?.toInt();
        final downloadInfo = DownloadInfo(
          url: url,
          name: payload['name']?.toString() ?? '',
          size: size,
          version: payload['version']?.toString() ?? 'unknown',
        );
        await callbacks.startDownload(
          downloadInfo,
          downloadSize: size,
          fromScript: true,
        );
        return <String, Object?>{'ok': true};
      default:
        // ScriptUiRequestRouter.uiKinds is the single source of truth; this
        // branch is unreachable unless a kind is added without a handler.
        return <String, Object?>{
          'ok': false,
          'error': noActiveDetailCode,
          'message': 'ui.$kind is not handled by ScriptUiHandlerRegistry',
        };
    }
  }
}
