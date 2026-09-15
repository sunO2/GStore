import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/page/apk_browser/directory_view.dart';
import 'package:gstore/page/apk_browser/preview.dart';

/// APK 内容浏览器（**一个页面 = 一个容器**）
///
/// 导航模型（对应三个诉求）：
/// 1. **目录层 = 栈内的目录组件**：每进一层目录就把一个 [ApkDirectoryView] 压进栈，
///    并用 `IndexedStack` 保活 → 返回上一层时滚动位置、搜索词、已加载清单都还在，
///    不会"回到顶部"、也不会重新列举。
/// 2. **手势/系统返回 = 回上一层**：`PopScope` 拦下返回，只在栈深度 > 1 时回退一层；
///    已是本容器根层时才真正退出本页。
/// 3. **标题栏返回按钮 = 直接退出本页**：`BackButton` 显式走 `Navigator.pop`，
///    绕过 `PopScope`，语义与手势区分开。
///
/// 压缩包（zip/apk/jar/aar）**另开一个页面**：每个容器一个页面，
/// 面包屑只表达"本容器内的目录路径"，不会把当前页重置成另一个容器。
///
/// 架构：目录列举与解压全在 Rust（唯一出口），本页只负责导航与渲染。
class ApkBrowserPage extends StatefulWidget {
  const ApkBrowserPage({
    super.key,
    required this.apkPath,
    required this.appLabel,
    this.packageName = '',
    this.initialChain = '',
    this.listingLoader,
  });

  /// 目标 APK（base APK 路径）
  final String apkPath;
  final String appLabel;
  final String packageName;

  /// 起始容器链（空 = APK 根；非空 = 直接打开某个压缩包，用于"另开页"进入）
  final String initialChain;

  /// 目录加载函数（可注入，便于测试；默认走 [defaultApkListingLoader]）
  final ApkListingLoader? listingLoader;

  @override
  State<ApkBrowserPage> createState() => _ApkBrowserPageState();
}

class _ApkBrowserPageState extends State<ApkBrowserPage> {
  /// 目录层栈：栈底是容器根（''），每进一层目录压一项
  List<String> _dirs = const [''];

  ApkListingLoader get _loader =>
      widget.listingLoader ?? defaultApkListingLoader;

  /// 容器显示名（APK 或压缩包文件名）
  String get _containerLabel => widget.initialChain.isEmpty
      ? 'APK'
      : widget.initialChain
          .split(AnalyzerRustDecoder.chainSep)
          .last
          .split('/')
          .last;

  String get _title =>
      widget.initialChain.isEmpty ? 'APK 文件浏览' : _containerLabel;

  void _goUp() {
    if (_dirs.length <= 1) return;
    setState(() => _dirs = _dirs.sublist(0, _dirs.length - 1));
  }

  /// 面包屑跳转：祖先目录已在栈中 → 截断；新目录 → 压栈
  void _jumpTo(String dir) {
    final at = _dirs.indexOf(dir);
    setState(() {
      _dirs = at >= 0 ? _dirs.sublist(0, at + 1) : [..._dirs, dir];
    });
  }

  /// 把容器链与本容器内的条目路径拼成新的容器链
  String _joinChain(String entryPath) => widget.initialChain.isEmpty
      ? entryPath
      : '${widget.initialChain}${AnalyzerRustDecoder.chainSep}$entryPath';

  /// 压缩包：另开一个页面浏览（不重置当前页）
  Future<void> _openZip(ApkBrowsableEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApkBrowserPage(
          apkPath: widget.apkPath,
          appLabel: widget.appLabel,
          packageName: widget.packageName,
          initialChain: _joinChain(entry.path),
          listingLoader: widget.listingLoader,
        ),
      ),
    );
  }

  Future<void> _openFile(ApkBrowsableEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApkEntryPreviewPage(
          apkPath: widget.apkPath,
          entry: entry,
          containerChain: widget.initialChain,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 还有上层目录时：手势返回只回退一层（canPop=false 时由回调处理）
      canPop: _dirs.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title, overflow: TextOverflow.ellipsis),
          // 标题栏返回按钮：直接退出本页（不逐层回退），与手势返回区分
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        ),
        body: Column(
          children: [
            _headerCard(),
            Expanded(
              child: IndexedStack(
                index: _dirs.length - 1,
                children: [
                  for (final dir in _dirs)
                    ApkDirectoryView(
                      // 按「容器 + 目录」做 key：栈内各层各自保活
                      key: ValueKey('${widget.initialChain}#$dir'),
                      apkPath: widget.apkPath,
                      containerChain: widget.initialChain,
                      containerLabel: _containerLabel,
                      dir: dir,
                      loader: _loader,
                      onUp: _goUp,
                      onJumpTo: _jumpTo,
                      onOpenZip: _openZip,
                      onOpenFile: _openFile,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerCard() {
    final theme = Theme.of(context);
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.appLabel.isEmpty ? widget.packageName : widget.appLabel,
            style:
                theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '容器：${widget.initialChain.isEmpty ? 'APK 根' : widget.initialChain}',
            style: AppTypography.code,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(widget.apkPath, style: AppTypography.code),
        ],
      ),
    );
  }
}
