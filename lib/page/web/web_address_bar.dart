// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_suggestions.dart';

/// 搜索建议加载器（测试可注入）。
typedef WebSuggestionLoader = Future<List<String>> Function(String query);

/// 键盘上方的地址/搜索栏。
///
/// 点击导航头时插入到页面底部（Scaffold 会随键盘缩小，所以它自动贴在键盘
/// 顶部）：输入框 + 向右箭头；输入过程中建议列表出现在输入框**上方**。
class WebAddressBar extends StatefulWidget {
  const WebAddressBar({
    super.key,
    required this.initialText,
    required this.onSubmit,
    this.suggestionLoader,
  });

  final String initialText;
  final ValueChanged<String> onSubmit;
  final WebSuggestionLoader? suggestionLoader;

  @override
  State<WebAddressBar> createState() => _WebAddressBarState();
}

class _WebAddressBarState extends State<WebAddressBar> {
  static const Duration _debounce = Duration(milliseconds: 260);

  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  )..selection = TextSelection(
      baseOffset: widget.initialText.length,
      extentOffset: widget.initialText.length,
    );
  final FocusNode _focus = FocusNode();

  Timer? _timer;
  List<String> _suggestions = const [];
  int _requestId = 0;
  late bool _showClear = widget.initialText.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _looksLikeUrl(String text) => text.contains('.') && !text.contains(' ');

  void _onChanged() {
    _timer?.cancel();
    final showClear = _controller.text.isNotEmpty;
    if (showClear != _showClear) {
      setState(() => _showClear = showClear);
    }
    final text = _controller.text.trim();
    if (text.isEmpty || text.contains(' ') || _looksLikeUrl(text)) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _timer = Timer(_debounce, () => _fetch(text));
  }

  Future<void> _fetch(String text) async {
    final id = ++_requestId;
    final loader = widget.suggestionLoader ?? fetchBingSuggestions;
    final items = await loader(text);
    if (!mounted || id != _requestId) return;
    setState(() => _suggestions = items);
  }

  void _submit([String? value]) {
    final text = (value ?? _controller.text).trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_suggestions.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
                  final item = _suggestions[index];
                  return InkWell(
                    onTap: () => _submit(item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            TablerIcons.search,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              item,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium,
                            ),
                          ),
                          Icon(
                            TablerIcons.arrow_up_left,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ],
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.xs,
              // 键盘弹出时不再叠加导航栏安全区，否则会多出一截空白。
              AppSpacing.xs +
                  (MediaQuery.of(context).viewInsets.bottom > 0
                      ? 0
                      : MediaQuery.of(context).viewPadding.bottom),
            ),
            child: Row(
              children: [
                Icon(
                  TablerIcons.world,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    textInputAction: TextInputAction.go,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _submit(),
                    style: textTheme.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '输入网址或搜索',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintStyle: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                if (_showClear)
                  IconButton(
                    tooltip: '清除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(TablerIcons.x, size: 18),
                    onPressed: () {
                      _controller.clear();
                      _focus.requestFocus();
                    },
                  ),
                IconButton(
                  tooltip: '打开',
                  icon: const Icon(TablerIcons.arrow_right),
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
