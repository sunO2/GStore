import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 路径联想输入框组件
/// 使用弹出框方式显示建议列表
class PathAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final List<String> suggestions;
  final String labelText;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSelected;
  final bool autofocus;

  const PathAutocompleteField({
    super.key,
    required this.controller,
    required this.suggestions,
    required this.labelText,
    this.hintText,
    this.onChanged,
    this.onSelected,
    this.autofocus = false,
  });

  @override
  State<PathAutocompleteField> createState() => _PathAutocompleteFieldState();
}

class _PathAutocompleteFieldState extends State<PathAutocompleteField> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  final FocusNode _focusNode = FocusNode();
  List<String> _filteredSuggestions = [];
  int _selectedIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    _filterSuggestions();
    _updateOverlay();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (!_focusNode.hasFocus) {
      _removeOverlay();
    } else if (widget.suggestions.isNotEmpty) {
      _showOverlay();
    }
  }

  void _filterSuggestions() {
    final text = widget.controller.text;
    if (text.isEmpty) {
      _filteredSuggestions = widget.suggestions.take(10).toList();
    } else {
      _filteredSuggestions = widget.suggestions
          .where((s) => s.toLowerCase().contains(text.toLowerCase()))
          .take(10)
          .toList();
    }
    _selectedIndex = _filteredSuggestions.isNotEmpty ? 0 : -1;
  }

  void _updateOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    _filterSuggestions();
    if (_filteredSuggestions.isEmpty) return;

    final overlay = Overlay.of(context);
    _overlayEntry = _createOverlayEntry();
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() {
        _selectedIndex = -1;
      });
    }
  }

  OverlayEntry _createOverlayEntry() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return OverlayEntry(builder: (_) => const SizedBox.shrink());
    }
    final size = renderBox.size;

    return OverlayEntry(
      builder: (overlayContext) {
        return Positioned(
          width: size.width,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, size.height + 4),
            child: _buildSuggestionsPopup(overlayContext),
          ),
        );
      },
    );
  }

  Widget _buildSuggestionsPopup(BuildContext overlayContext) {
    final theme = Theme.of(overlayContext);

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _filteredSuggestions.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '无匹配建议',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _filteredSuggestions.length,
                itemBuilder: (listContext, index) {
                  final suggestion = _filteredSuggestions[index];
                  final isSelected = index == _selectedIndex;
                  return InkWell(
                    onTap: () => _selectSuggestion(suggestion),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      color: isSelected
                          ? theme.colorScheme.primary.withValues(alpha: 0.1)
                          : null,
                      child: Row(
                        children: [
                          Icon(
                            Icons.data_object,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              suggestion,
                              style: TextStyle(
                                fontSize: 13,
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isSelected)
                            Icon(
                              Icons.keyboard_arrow_right,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  void _selectSuggestion(String suggestion) {
    widget.controller.text = suggestion;
    widget.controller.selection = TextSelection.fromPosition(
      TextPosition(offset: suggestion.length),
    );
    widget.onSelected?.call(suggestion);
    widget.onChanged?.call(suggestion);
    _removeOverlay();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (_overlayEntry == null) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.arrowDown ||
              event.logicalKey == LogicalKeyboardKey.arrowUp)) {
        _showOverlay();
      }
      return;
    }

    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          if (_filteredSuggestions.isNotEmpty) {
            _selectedIndex = (_selectedIndex + 1) % _filteredSuggestions.length;
          }
        });
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          if (_filteredSuggestions.isNotEmpty) {
            _selectedIndex = (_selectedIndex - 1 + _filteredSuggestions.length) %
                _filteredSuggestions.length;
          }
        });
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (_selectedIndex >= 0 && _selectedIndex < _filteredSuggestions.length) {
          _selectSuggestion(_filteredSuggestions[_selectedIndex]);
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        _removeOverlay();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: _handleKeyEvent,
        child: TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          decoration: InputDecoration(
            labelText: widget.labelText,
            isDense: true,
            hintText: widget.hintText,
            suffixIcon: widget.suggestions.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.arrow_drop_down, size: 18),
                    onPressed: () {
                      if (_overlayEntry != null) {
                        _removeOverlay();
                      } else {
                        _showOverlay();
                      }
                    },
                  )
                : null,
          ),
          style: const TextStyle(fontSize: 13),
          onChanged: (value) {
            widget.onChanged?.call(value);
          },
          onTap: () {
            if (widget.suggestions.isNotEmpty && _overlayEntry == null) {
              _showOverlay();
            }
          },
        ),
      ),
    );
  }
}
