import 'package:flutter/material.dart';
import '../../../core/workflow/services/sqlite_database_service.dart';

/// 表选择器组件
/// 支持从现有表选择或输入新表名
class TableSelector extends StatefulWidget {
  final String? selectedTable;
  final String? selectedAlias;
  final ValueChanged<String> onTableChanged;
  final ValueChanged<String> onAliasChanged;

  const TableSelector({
    super.key,
    this.selectedTable,
    this.selectedAlias,
    required this.onTableChanged,
    required this.onAliasChanged,
  });

  @override
  State<TableSelector> createState() => _TableSelectorState();
}

class _TableSelectorState extends State<TableSelector> {
  final _tableController = TextEditingController();
  final _aliasController = TextEditingController();
  final _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  final _dbService = SqliteDatabaseService();
  List<String> _tableNames = [];
  List<String> _filteredTables = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _tableController.text = widget.selectedTable ?? '';
    _aliasController.text = widget.selectedAlias ?? '';
    _loadTables();
  }

  @override
  void dispose() {
    _tableController.dispose();
    _aliasController.dispose();
    _removeOverlay();
    super.dispose();
  }

  Future<void> _loadTables() async {
    setState(() => _isLoading = true);
    try {
      _tableNames = await _dbService.getTableNames();
      _filteredTables = _tableNames.take(10).toList();
    } catch (e) {
      _tableNames = [];
      _filteredTables = [];
    }
    setState(() => _isLoading = false);
  }

  void _filterTables(String query) {
    if (query.isEmpty) {
      _filteredTables = _tableNames.take(10).toList();
    } else {
      _filteredTables = _tableNames
          .where((t) => t.toLowerCase().contains(query.toLowerCase()))
          .take(10)
          .toList();
    }
    _overlayEntry?.markNeedsBuild();
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    _filterTables(_tableController.text);

    _overlayEntry = _createOverlayEntry();
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
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
            child: _buildTableList(overlayContext),
          ),
        );
      },
    );
  }

  Widget _buildTableList(BuildContext overlayContext) {
    final theme = Theme.of(overlayContext);

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 250),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _filteredTables.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _isLoading ? '加载中...' : '无匹配表',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _filteredTables.length + 1,
                itemBuilder: (listContext, index) {
                  if (index == 0) {
                    return _buildTableHeader(listContext, theme);
                  }
                  final tableName = _filteredTables[index - 1];
                  return _buildTableItem(listContext, tableName, theme);
                },
              ),
      ),
    );
  }

  Widget _buildTableHeader(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.table_chart, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '选择表或输入新表名',
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh, size: 14),
            onPressed: _loadTables,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: '刷新表列表',
          ),
        ],
      ),
    );
  }

  Widget _buildTableItem(BuildContext context, String tableName, ThemeData theme) {
    return InkWell(
      onTap: () => _selectTable(tableName),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.table_rows,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tableName,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTable(String tableName) {
    _tableController.text = tableName;
    widget.onTableChanged(tableName);
    _removeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          link: _layerLink,
          child: TextFormField(
            controller: _tableController,
            decoration: InputDecoration(
              labelText: '表名',
              isDense: true,
              hintText: '输入或选择表名',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isLoading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.arrow_drop_down, size: 18),
                      onPressed: () {
                        if (_overlayEntry != null) {
                          _removeOverlay();
                        } else {
                          _showOverlay();
                        }
                      },
                    ),
                ],
              ),
            ),
            onChanged: (value) {
              widget.onTableChanged(value);
              _filterTables(value);
            },
            onTap: () {
              if (_overlayEntry == null) {
                _showOverlay();
              }
            },
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _aliasController,
          decoration: const InputDecoration(
            labelText: '表别名（用于数据流引用）',
            isDense: true,
            hintText: '如: users, orders',
          ),
          onChanged: widget.onAliasChanged,
        ),
      ],
    );
  }
}

/// 字段选择器组件
/// 支持从表中现有字段选择
class ColumnSelector extends StatefulWidget {
  final String tableName;
  final List<String> selectedColumns;
  final ValueChanged<List<String>> onColumnsChanged;

  const ColumnSelector({
    super.key,
    required this.tableName,
    required this.selectedColumns,
    required this.onColumnsChanged,
  });

  @override
  State<ColumnSelector> createState() => _ColumnSelectorState();
}

class _ColumnSelectorState extends State<ColumnSelector> {
  final _dbService = SqliteDatabaseService();
  List<ColumnInfo> _columns = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadColumns();
  }

  @override
  void didUpdateWidget(ColumnSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tableName != widget.tableName) {
      _loadColumns();
    }
  }

  Future<void> _loadColumns() async {
    if (widget.tableName.isEmpty) {
      setState(() => _columns = []);
      return;
    }

    setState(() => _isLoading = true);
    try {
      _columns = await _dbService.getTableColumns(widget.tableName);
    } catch (e) {
      _columns = [];
    }
    setState(() => _isLoading = false);
  }

  void _toggleColumn(String columnName) {
    final newSelection = List<String>.from(widget.selectedColumns);
    if (newSelection.contains(columnName)) {
      newSelection.remove(columnName);
    } else {
      newSelection.add(columnName);
    }
    widget.onColumnsChanged(newSelection);
  }

  void _selectAll() {
    widget.onColumnsChanged(_columns.map((c) => c.name).toList());
  }

  void _clearAll() {
    widget.onColumnsChanged([]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '字段选择',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            if (_columns.isNotEmpty) ...[
              TextButton(
                onPressed: _selectAll,
                child: const Text('全选', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _clearAll,
                child: const Text('清空', style: TextStyle(fontSize: 11)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        if (_isLoading)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else if (_columns.isEmpty)
          Text(
            widget.tableName.isEmpty ? '请先选择表' : '该表无字段信息',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _columns.map((column) {
              final isSelected = widget.selectedColumns.contains(column.name);
              return FilterChip(
                label: Text(
                  column.name,
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                selected: isSelected,
                onSelected: (_) => _toggleColumn(column.name),
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                selectedColor: Theme.of(context).colorScheme.primary,
                checkmarkColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        if (widget.selectedColumns.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '已选: ${widget.selectedColumns.join(", ")}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
