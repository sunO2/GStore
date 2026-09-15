import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/service/it_tools_service.dart';

import 'tool_list.dart';

/// 可选语言（与 it-tools 仓库的 `locales/` 目录一致）。
const Map<String, String> _availableLocales = {
  'zh': '中文',
  'en': 'English',
  'de': 'Deutsch',
  'es': 'Español',
  'fr': 'Français',
  'no': 'Norwegian',
  'pt': 'Português',
  'uk': 'Українська',
  'vi': 'Tiếng Việt',
};

/// 开发者工具箱（IT Tools 离线内嵌页）。
///
/// 入口：「我的 → 工具 → 开发者工具箱」。
///
/// 首次进入会先把宿主资产里的离线包解压到应用私有目录（见 [ItToolsService]），
/// 再用 WebView 以 `file://` 加载该目录下的 `index.html`。
///
/// **导航头**：页面以 `hostEmbed=1` 加载，it-tools 侧会隐藏自己的页内导航头，
/// 由本页 AppBar 承担导航职责，并通过 `window.ItTools` 反向驱动页面：
///
/// | AppBar | 调用的桥接 API |
/// |---|---|
/// | ☰ 工具列表 | 用本页原生弹层展示（清单由页面推来），选中后 `navigateTo(path)` |
/// | 🔍 搜索 | `window.ItTools.openSearch()` |
/// | 🌐 语言 | `window.ItTools.setLocale(code)` |
///
/// 页面状态经 `itToolsState` handler 回传（当前路径/语言等），
/// 工具清单经 `itToolsTools` handler 推来，主题则由本页主动下发。
class ItToolsPage extends StatefulWidget {
  const ItToolsPage({super.key});

  @override
  State<ItToolsPage> createState() => _ItToolsPageState();
}

class _ItToolsPageState extends State<ItToolsPage> {
  /// 入口文件的本地路径（解压完成后才有值）
  String? _entryPath;
  bool _loading = true;
  String? _error;

  InAppWebViewController? _controller;

  /// 页面桥接已就绪（未就绪时 AppBar 上的动作禁用，避免点了没反应）
  bool _bridgeReady = false;

  /// 页面当前语言（用于语言弹层的选中标记）
  String _pageLocale = 'en';

  /// 页面当前所在路径（用于工具列表里标出当前项）
  String _currentPath = '/';

  /// 页面推来的工具清单：内嵌模式下由本页原生弹层展示、选择
  List<ItToolGroup> _toolGroups = const [];

  /// 上次下发给页面的主题指纹，用于只在主题变化时重新下发
  String? _appliedTheme;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTheme();
  }

  /// 确保离线包已解压（首次/升级后才会真正解压）
  Future<void> _prepare() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final dir = await ItToolsService.ensureExtracted();
      final entryPath = p.join(dir.path, ItToolsService.entryFile);

      if (!mounted) return;
      setState(() {
        _entryPath = entryPath;
        _loading = false;
      });
      debugPrint('ItToolsPage: 入口 $entryPath');
    } catch (e) {
      debugPrint('ItToolsPage: 准备离线资源失败 - $e');
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 当前 App 主题的主色（#rrggbb）
  String _primaryHex() {
    final primary = Theme.of(context).colorScheme.primary;
    return '#${(primary.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  bool _isDark() => Theme.of(context).brightness == Brightness.dark;

  /// App 主题（明暗/主色）变化时同步给页面，让内嵌页始终跟随 App
  void _syncTheme() {
    final key = '${_primaryHex()}-${_isDark()}';
    if (key == _appliedTheme) return;
    _appliedTheme = key;
    _pushTheme();
  }

  Future<void> _pushTheme() async {
    final controller = _controller;
    if (controller == null) return;

    await _call(
      "window.ItTools && window.ItTools.setTheme({ "
      "primaryColor: '${_primaryHex()}', isDark: ${_isDark()} });",
    );
  }

  /// 调用页面桥接 API（页面未接桥时静默失败）
  Future<void> _call(String expression) async {
    try {
      await _controller?.evaluateJavascript(source: expression);
    } catch (e) {
      debugPrint('ItToolsPage: 调用页面失败 - $e');
    }
  }

  /// 弹出原生工具列表；选中后驱动页面跳转。
  Future<void> _showToolList() async {
    final picked = await AppSheet.showCustom<String>(
      context: context,
      builder: (sheetContext) => ItToolListSheet(
        groups: _toolGroups,
        currentPath: _currentPath,
      ),
    );

    if (picked == null || !mounted || picked == _currentPath) return;
    await _call("window.ItTools && window.ItTools.navigateTo('$picked')");
  }

  /// file:// 入口地址，带上宿主主题与内嵌模式
  Uri _entryUri() {
    return Uri.file(_entryPath!).replace(queryParameters: {
      'hostTheme': _primaryHex(),
      'hostDark': _isDark() ? '1' : '0',
      // 内嵌模式：隐藏页内导航头，改由本页 AppBar 承担
      'hostEmbed': '1',
    });
  }

  Future<void> _pickLocale() async {
    final picked = await AppSheet.showCustom<String>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '语言',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in _availableLocales.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == _pageLocale
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(entry.key),
              ),
          ],
        ),
      ),
    );

    if (picked == null || !mounted) return;
    await _call("window.ItTools && window.ItTools.setLocale('$picked')");
    if (mounted) {
      setState(() => _pageLocale = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('开发者工具箱'),
        actions: [
          IconButton(
            tooltip: '工具列表',
            icon: const Icon(Icons.menu_open),
            // 清单未就绪时不弹空列表
            onPressed: _toolGroups.isEmpty ? null : _showToolList,
          ),
          IconButton(
            tooltip: '搜索工具',
            icon: const Icon(Icons.search),
            onPressed: _bridgeReady
                ? () => _call('window.ItTools && window.ItTools.openSearch()')
                : null,
          ),
          IconButton(
            tooltip: '语言',
            icon: const Icon(Icons.translate),
            onPressed: _pickLocale,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLoading(size: AppLoadingSize.medium),
            const SizedBox(height: AppSpacing.md),
            Text(
              '正在准备离线资源…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return _buildError(context);
    }

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_entryUri().toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        // file 源加载所需：不开 universal，页面会白屏且无报错
        // （入口是 type="module" 脚本，被跨源策略拦截）。
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        // 页面通过 itToolsState 回传自身状态（导航头据此同步）
        controller.addJavaScriptHandler(
          handlerName: 'itToolsState',
          callback: (args) {
            final raw = args.isNotEmpty ? args.first : null;
            if (raw is! Map) return null;
            final locale = raw['locale'];
            final path = raw['path'];
            if (!mounted) return null;
            setState(() {
              _bridgeReady = true;
              if (locale is String && locale.isNotEmpty) {
                _pageLocale = locale;
              }
              if (path is String && path.isNotEmpty) {
                _currentPath = path;
              }
            });
            return null;
          },
        );
        // 工具清单：内嵌模式下抽屉由本页原生弹层替代，清单必须来自页面
        controller.addJavaScriptHandler(
          handlerName: 'itToolsTools',
          callback: (args) {
            final groups = parseItToolsToolGroups(
              args.isNotEmpty ? args.first : null,
            );
            if (!mounted) return null;
            setState(() => _toolGroups = groups);
            debugPrint(
              'ItToolsPage: 收到工具清单 ${groups.length} 类 / '
              '${groups.fold(0, (s, g) => s + g.tools.length)} 个',
            );
            return null;
          },
        );
      },
      onLoadStop: (controller, url) {
        // 页面脚本就绪后补一次主题（首帧前的主题已随 URL query 下发）
        _pushTheme();
      },
    );
  }

  Widget _buildError(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: scheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              '离线资源准备失败',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _prepare,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
