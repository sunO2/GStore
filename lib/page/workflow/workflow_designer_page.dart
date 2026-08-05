import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import '../../../core/channel/channel.dart';
import '../../../core/workflow/workflow.dart';
import '../../../core/workflow/models/step_position.dart';
import '../../../core/workflow/models/step_model.dart';
import 'logic/workflow_designer_logic.dart';
import 'mixins/mixins.dart';
import 'widgets/path_autocomplete_field.dart';
import 'widgets/table_selector.dart';

/// 工作流设计器页面
class WorkflowDesignerPage extends StatefulWidget {
  const WorkflowDesignerPage({super.key});

  @override
  State<WorkflowDesignerPage> createState() => _WorkflowDesignerPageState();
}

class _WorkflowDesignerPageState extends State<WorkflowDesignerPage>
    with
        StepNodeMixin,
        StepConnectionMixin,
        StepInputOutputMixin,
        StepDataPathMixin,
        StepDebugMixin,
        StepConfigMixin {
  final logic = Get.put(WorkflowDesignerLogic());

  bool _paletteExpanded = true;
  bool _propertyPanelExpanded = true;
  bool _isConnectingMode = false;
  String? _connectingFromId;

  final TransformationController _viewportController = TransformationController();
  final GlobalKey _canvasKey = GlobalKey();
  Offset? _mouseCanvasPosition;

  @override
  void initState() {
    super.initState();
    _viewportController.addListener(_onViewportChanged);
  }

  @override
  void dispose() {
    _viewportController.removeListener(_onViewportChanged);
    _viewportController.dispose();
    super.dispose();
  }

  void _onViewportChanged() {
    final matrix = _viewportController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    logic.updateViewportState(
      scale: scale,
      offsetX: translation.x,
      offsetY: translation.y,
    );
  }

  @override
  Map<String, TextEditingController> get inputPathControllers =>
      _inputPathControllers;
  final Map<String, TextEditingController> _inputPathControllers = {};

  // 提取字段控制器映射: stepId -> fieldIndex -> fieldProperty -> controller
  final Map<String, Map<int, Map<String, TextEditingController>>> _extractFieldControllers = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作流设计器'),
        elevation: 0,
        actions: [
          Obx(() => IconButton(
                icon: const Icon(Icons.undo),
                tooltip: '撤销',
                onPressed: logic.state.undoStack.isEmpty ? null : logic.undo,
              )),
          Obx(() => IconButton(
                icon: const Icon(Icons.redo),
                tooltip: '重做',
                onPressed: logic.state.redoStack.isEmpty ? null : logic.redo,
              )),
          IconButton(
            icon: const Icon(Icons.file_open),
            tooltip: '导入',
            onPressed: () => _showImportDialog(context, logic),
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: '导出',
            onPressed: () => _showExportDialog(context, logic),
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _handleMenuAction(context, value, logic),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'new',
                child: Row(
                  children: [
                    Icon(Icons.add, size: AppTypography.iconSM),
                    SizedBox(width: AppSpacing.sm),
                    Text('新建工作流'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete, size: AppTypography.iconSM, color: AppColors.error),
                    SizedBox(width: AppSpacing.sm),
                    Text('删除工作流', style: TextStyle(color: AppColors.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildWorkflowInfoBar(context),
          Expanded(
            child: Row(
              children: [
                _buildCollapsiblePalette(context),
                Expanded(child: _buildCanvas(context, logic)),
                _buildCollapsiblePropertyPanel(context, logic),
              ],
            ),
          ),
          _buildBottomBar(context, logic),
        ],
      ),
    );
  }

  Widget _buildWorkflowInfoBar(BuildContext context) {
    return Container(
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Obx(() {
            final workflows = logic.state.workflows;
            final selected = logic.state.selectedWorkflow.value;

            return DropdownButton<String>(
              value: selected?.id,
              hint: const Text('选择工作流'),
              underline: const SizedBox(),
              items: workflows.map((w) {
                return DropdownMenuItem(
                  value: w.id,
                  child: Text(w.name),
                );
              }).toList(),
              onChanged: (id) {
                if (id != null) {
                  final workflow = workflows.firstWhere((w) => w.id == id);
                  logic.selectWorkflow(workflow);
                  setState(() {});
                }
              },
            );
          }),
          const SizedBox(width: AppSpacing.md),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '新建工作流',
            onPressed: logic.createWorkflow,
          ),
          const SizedBox(width: AppSpacing.md),
          _buildChannelBinding(context),
          const Spacer(),
          Obx(() {
            final stepCount = logic.state.selectedWorkflow.value?.steps.length ?? 0;
            return Text(
              '$stepCount 个步骤',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildChannelBinding(BuildContext context) {
    return Obx(() {
      final workflow = logic.state.selectedWorkflow.value;
      if (workflow == null) return const SizedBox.shrink();

      final isBound = workflow.isBound;

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<ChannelType>(
            value: workflow.channelType,
            hint: const Text('选择渠道', style: TextStyle(fontSize: 12)),
            underline: const SizedBox(),
            items: ChannelType.values.map((type) {
              return DropdownMenuItem(
                value: type,
                child: Text(type.description, style: const TextStyle(fontSize: 12)),
              );
            }).toList(),
            onChanged: isBound
                ? null
                : (type) {
                    if (type != null) {
                      _showFunctionSelectionDialog(context, type);
                    }
                  },
          ),
          if (isBound) ...[
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: AppRadius.allSM,
              ),
              child: Text(
                workflow.functionName ?? '',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton(
              icon: const Icon(Icons.link_off, size: 18),
              tooltip: '解除绑定',
              onPressed: logic.unbindChannelFunction,
            ),
          ],
        ],
      );
    });
  }

  void _showFunctionSelectionDialog(BuildContext context, ChannelType channelType) {
    final functions = _getChannelFunctions(channelType);

    Get.dialog(
      AlertDialog(
        title: Text('绑定 ${channelType.description} 函数'),
        content: SizedBox(
          width: 250,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: functions.map((func) {
              return ListTile(
                title: Text(func, style: const TextStyle(fontSize: 13)),
                dense: true,
                onTap: () {
                  Get.back();
                  logic.bindToChannelFunction(channelType, func);
                },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  List<String> _getChannelFunctions(ChannelType channelType) {
    return [
      'getAllApps',
      'getAppInfo',
      'getAppDetail',
      'searchApps',
      'searchByCategory',
      'getAllCategories',
      'checkUpdate',
      'doUpdate',
      'getConfig',
    ];
  }

  Widget _buildCollapsiblePalette(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _paletteExpanded ? 220 : 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _paletteExpanded = !_paletteExpanded),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: _paletteExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  if (!_paletteExpanded) ...[
                    Icon(
                      Icons.apps,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ] else ...[
                    const Icon(Icons.chevron_left, size: 20),
                    const SizedBox(width: 8),
                    const Text('步骤', style: TextStyle(fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _paletteExpanded
                ? _buildCategorizedPalette(context)
                : _buildCollapsedPalette(context),
          ),
        ],
      ),
    );
  }

  /// 收起状态下的步骤图标列表
  Widget _buildCollapsedPalette(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: StepType.values.map((type) {
        final color = getStepColor(type);
        final icon = getStepIcon(type);
        return Tooltip(
          message: type.label,
          preferBelow: false,
          child: InkWell(
            onTap: () => logic.addStep(type),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Icon(
                icon,
                color: color,
                size: 22,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCategorizedPalette(BuildContext context) {
    // Group step types by category
    final categoryGroups = <StepCategory, List<StepType>>{};
    for (final type in StepType.values) {
      categoryGroups.putIfAbsent(type.category, () => []).add(type);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: categoryGroups.entries.map((entry) {
        return _buildCategorySection(context, entry.key, entry.value);
      }).toList(),
    );
  }

  Widget _buildCategorySection(BuildContext context, StepCategory category, List<StepType> types) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            category.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        ...types.map((type) => _buildPaletteItem(context, type)),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPaletteItem(BuildContext context, StepType type) {
    final color = getStepColor(type);
    final icon = getStepIcon(type);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: AppRadius.allSM,
        child: InkWell(
          onTap: () => logic.addStep(type),
          borderRadius: AppRadius.allSM,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    type.label,
                    style: TextStyle(fontSize: 12, color: color),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(BuildContext context, WorkflowDesignerLogic logic) {
    return GetBuilder<WorkflowDesignerLogic>(
      init: logic,
      builder: (logic) {
        final workflow = logic.state.selectedWorkflow.value;
        final steps = workflow?.steps ?? [];
        final positions = logic.state.stepPositions;

        if (workflow == null) {
          return _buildEmptyCanvas(context, '选择一个工作流或创建新工作流');
        }

        if (steps.isEmpty) {
          return _buildEmptyCanvas(context, '点击左侧的步骤类型添加到工作流');
        }

        return _buildWorkflowCanvas(context, logic, workflow, steps, positions);
      },
    );
  }

  Widget _buildEmptyCanvas(BuildContext context, String message) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflowCanvas(
    BuildContext context,
    WorkflowDesignerLogic logic,
    WorkflowModel workflow,
    List<StepConfig> steps,
    Map<String, StepPosition> positions,
  ) {
    // 计算画布大小（基于节点位置动态扩展）
    final canvasSize = _calculateCanvasSize(positions, steps);

    // 计算节点中心点，用于视口居中
    final centerOffset = _calculateNodesCenter(positions, steps, canvasSize);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 如果有保存的视口状态，使用它
      if (workflow.viewportScale != 1.0 ||
          workflow.viewportOffsetX != 0 ||
          workflow.viewportOffsetY != 0) {
        final matrix = Matrix4.identity()
          ..translate(workflow.viewportOffsetX, workflow.viewportOffsetY)
          ..scale(workflow.viewportScale);
        _viewportController.value = matrix;
      } else if (centerOffset != null) {
        // 否则，将视口居中到节点中心
        final screenSize = MediaQuery.of(context).size;
        final offsetX = screenSize.width / 2 - centerOffset.dx * workflow.viewportScale;
        final offsetY = screenSize.height / 2 - centerOffset.dy * workflow.viewportScale;
        final matrix = Matrix4.identity()
          ..translate(offsetX, offsetY)
          ..scale(workflow.viewportScale);
        _viewportController.value = matrix;
      }
    });

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: InteractiveViewer(
        transformationController: _viewportController,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        minScale: 0.2,
        maxScale: 2.5,
        constrained: false,
        child: SizedBox(
          width: canvasSize.width,
          height: canvasSize.height,
          child: Listener(
            onPointerMove: (event) {
              // 将屏幕坐标转换为画布坐标
              final matrix = _viewportController.value;
              final inverse = Matrix4.inverted(matrix);
              final point = MatrixUtils.transformPoint(inverse, event.localPosition);
              setState(() {
                _mouseCanvasPosition = point;
              });
            },
            child: Stack(
              children: [
                // 网格背景
                CustomPaint(
                  size: Size(canvasSize.width, canvasSize.height),
                  painter: _GridPainter(),
                ),
                // 连接线
                Obx(() {
                  final currentPositions = logic.state.stepPositions;
                  final currentWorkflow = logic.state.selectedWorkflow.value;

                  return CustomPaint(
                    size: Size(canvasSize.width, canvasSize.height),
                    painter: ConnectionLinePainter(
                      steps: currentWorkflow?.steps ?? steps,
                      positions: currentPositions,
                      connectingFromId: _connectingFromId,
                      mousePosition: _mouseCanvasPosition,
                    ),
                  );
                }),
                // 节点
                Obx(() {
                  final currentPositions = logic.state.stepPositions;
                  final currentWorkflow = logic.state.selectedWorkflow.value;

                  return Stack(
                    children: (currentWorkflow?.steps ?? steps).asMap().entries.map((entry) {
                      final index = entry.key;
                      final step = entry.value;
                      final position = currentPositions[step.id];

                      double x;
                      double y;
                      if (position != null) {
                        x = position.x;
                        y = position.y;
                      } else {
                        x = canvasSize.width / 2 - 90 + (index % 3) * 220 - 220;
                        y = canvasSize.height / 2 - 50 + (index ~/ 3) * 150 - 75;
                      }

                      return Positioned(
                        left: x,
                        top: y,
                        child: _buildStepNode(context, logic, step, currentWorkflow ?? workflow),
                      );
                    }).toList(),
                  );
                }),
                // 连接模式提示
                if (_isConnectingMode)
                  Positioned(
                    bottom: 20,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '点击输入端口完成连接',
                              style: TextStyle(color: Colors.white, fontSize: 12),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: _cancelConnection,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Text(
                                  '取消',
                                  style: TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 计算画布大小（基于节点位置动态扩展）
  Size _calculateCanvasSize(Map<String, StepPosition> positions, List<StepConfig> steps) {
    const minSize = 2000.0;
    const padding = 200.0;

    if (positions.isEmpty) {
      return const Size(minSize, minSize);
    }

    double maxX = minSize;
    double maxY = minSize;

    for (final pos in positions.values) {
      if (pos.x + 180 + padding > maxX) {
        maxX = pos.x + 380;
      }
      if (pos.y + 100 + padding > maxY) {
        maxY = pos.y + 300;
      }
    }

    return Size(maxX, maxY);
  }

  /// 计算节点中心点
  Offset? _calculateNodesCenter(Map<String, StepPosition> positions, List<StepConfig> steps, Size canvasSize) {
    if (positions.isEmpty || steps.isEmpty) {
      // 返回画布中心
      return Offset(canvasSize.width / 2, canvasSize.height / 2);
    }

    double sumX = 0;
    double sumY = 0;
    int count = 0;

    for (final step in steps) {
      final pos = positions[step.id];
      if (pos != null) {
        sumX += pos.x + 90; // 加上节点宽度的一半，使中心在节点中央
        sumY += pos.y + 50; // 加上节点高度的一半
        count++;
      }
    }

    if (count == 0) {
      return Offset(canvasSize.width / 2, canvasSize.height / 2);
    }

    return Offset(sumX / count, sumY / count);
  }

  Widget _buildStepNode(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    WorkflowModel workflow,
  ) {
    final isSelected = logic.state.selectedStep.value?.id == step.id;
    final color = getStepColor(step.type);
    final icon = getStepIcon(step.type);

    final executionResult = logic.state.executionResult.value;
    StepOutput? stepOutput;
    if (executionResult != null) {
      try {
        stepOutput = executionResult.stepOutputs.firstWhere((o) => o.stepId == step.id);
      } catch (_) {}
    }

    final steps = workflow.steps;
    final previousStepNames = <String, String>{};
    for (final s in steps) {
      if (s.id == step.id) break;
      previousStepNames[s.id] = s.name;
    }

    const nodeWidth = 180.0;
    const nodeHeight = 100.0;

    // 记录拖拽开始时手指相对于节点的偏移
    Offset? _dragStartOffset;

    return GestureDetector(
      onTap: () => logic.selectStep(step),
      onLongPress: () => _showStepContextMenu(context, logic, step, workflow),
      onPanStart: (details) {
        final position = logic.state.stepPositions[step.id];
        final currentX = position?.x ?? 100.0;
        final currentY = position?.y ?? 100.0;
        // 记录手指相对于节点左上角的偏移
        _dragStartOffset = Offset(
          details.localPosition.dx,
          details.localPosition.dy,
        );
        // 同时更新位置到手指接触点（不改变显示位置）
        logic.updateStepPosition(
          step.id,
          currentX,
          currentY,
        );
      },
      onPanUpdate: (details) {
        final position = logic.state.stepPositions[step.id];
        final currentX = position?.x ?? 100.0;
        final currentY = position?.y ?? 100.0;
        // 用手指位置减去初始偏移，得到节点左上角的新位置
        final newX = currentX + details.delta.dx;
        final newY = currentY + details.delta.dy;
        logic.updateStepPosition(
          step.id,
          newX,
          newY,
        );
      },
      onPanEnd: (details) {
        _dragStartOffset = null;
      },
      child: Container(
        width: nodeWidth,
        height: nodeHeight,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: AppRadius.allMD,
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(6),
                      topRight: Radius.circular(6),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          step.name,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        onTap: () => _showStepDebugDialog(context, step, stepOutput),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.bug_report,
                            size: 14,
                            color: stepOutput != null
                                ? (stepOutput.success ? AppColors.success : AppColors.error)
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.type.label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: AppColors.textSecondary,
                              fontSize: 9,
                            ),
                      ),
                      const SizedBox(height: 2),
                      _buildInputSourceTag(context, step, previousStepNames),
                      if (step.options['outputVar'] != null &&
                          (step.options['outputVar'] as String).isNotEmpty)
                        buildPortTag(
                          context,
                          '→ ${step.options['outputVar']}',
                          Colors.green,
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(6),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (!step.enabled)
                        const Icon(
                          Icons.disabled_visible,
                          size: 10,
                          color: AppColors.textSecondary,
                        ),
                      const Spacer(),
                      if (stepOutput != null)
                        Icon(
                          stepOutput.success ? Icons.check_circle : Icons.error,
                          size: 10,
                          color: stepOutput.success ? AppColors.success : AppColors.error,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              left: -10,
              top: nodeHeight / 2 - 10,
              child: GestureDetector(
                onTap: () {
                  if (_isConnectingMode && _connectingFromId != null) {
                    _completeConnection(step.id);
                  }
                },
                onLongPress: () {
                  if (_hasInputConnection(step.id, workflow)) {
                    _showDeleteConnectionDialog(context, logic, step.id, workflow);
                  }
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: _hasInputConnection(step.id, workflow) ? Colors.blue : Colors.white,
                      border: Border.all(
                        color: _isConnectingMode ? Colors.blue.shade700 : Colors.blue.shade300,
                        width: 2,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                    child: _hasInputConnection(step.id, workflow)
                        ? const Icon(Icons.arrow_back, size: 10, color: Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
            Positioned(
              right: -10,
              top: nodeHeight / 2 - 10,
              child: GestureDetector(
                onTap: () {
                  // 获取输出端口位置
                  final position = logic.state.stepPositions[step.id];
                  final portX = (position?.x ?? 100) + nodeWidth;
                  final portY = (position?.y ?? 100) + nodeHeight / 2;

                  setState(() {
                    _isConnectingMode = true;
                    _connectingFromId = step.id;
                    // 初始化鼠标位置为输出端口位置，避免出现长线
                    _mouseCanvasPosition = Offset(portX, portY);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: _isConnectingMode && _connectingFromId == step.id
                          ? Colors.blue
                          : (step.nextStepIds.isNotEmpty ? Colors.green : Colors.white),
                      border: Border.all(
                        color: _isConnectingMode && _connectingFromId == step.id
                            ? Colors.blue.shade700
                            : Colors.green.shade300,
                        width: 2,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                    child: _isConnectingMode && _connectingFromId == step.id
                        ? const Icon(Icons.arrow_forward, size: 10, color: Colors.white)
                        : (step.nextStepIds.isNotEmpty
                            ? const Icon(Icons.arrow_forward, size: 10, color: Colors.white)
                            : null),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputSourceTag(
    BuildContext context,
    StepConfig step,
    Map<String, String> previousStepNames,
  ) {
    final inputFrom = step.options['inputFrom'] as String?;
    final inputVar = step.options['inputVar'] as String?;

    if ((inputFrom == null || inputFrom.isEmpty) && (inputVar == null || inputVar.isEmpty)) {
      return buildPortTag(context, '← 未连接', Colors.grey);
    }

    final label = inputVar != null && inputVar.isNotEmpty
        ? '← $inputVar'
        : '← ${previousStepNames[inputFrom] ?? inputFrom ?? '未知'}';

    return buildPortTag(context, label, Colors.orange);
  }

  bool _hasInputConnection(String stepId, WorkflowModel workflow) {
    for (final step in workflow.steps) {
      if (step.nextStepIds.contains(stepId)) {
        return true;
      }
    }
    return false;
  }

  void _completeConnection(String toStepId) {
    if (_connectingFromId == null || _connectingFromId == toStepId) {
      _cancelConnection();
      return;
    }

    final workflow = logic.state.selectedWorkflow.value;
    if (workflow == null) {
      _cancelConnection();
      return;
    }

    final fromStep = workflow.steps.firstWhere(
      (s) => s.id == _connectingFromId,
      orElse: () => workflow.steps.first,
    );

    final updatedStep = fromStep.copyWith(
      nextStepIds: [...fromStep.nextStepIds, toStepId],
    );
    logic.updateStep(updatedStep);

    _cancelConnection();
  }

  void _cancelConnection() {
    setState(() {
      _isConnectingMode = false;
      _connectingFromId = null;
      // 保持 _mouseCanvasPosition 不变，方便下次连接时使用
    });
  }

  void _showDeleteConnectionDialog(
    BuildContext context,
    WorkflowDesignerLogic logic,
    String toStepId,
    WorkflowModel workflow,
  ) {
    final fromSteps = <StepConfig>[];
    for (final step in workflow.steps) {
      if (step.nextStepIds.contains(toStepId)) {
        fromSteps.add(step);
      }
    }

    if (fromSteps.isEmpty) return;

    Get.dialog(
      AlertDialog(
        title: const Text('删除连接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: fromSteps.map((fromStep) => ListTile(
            dense: true,
            leading: const Icon(Icons.link_off, size: 20),
            title: Text(fromStep.name),
            onTap: () {
              logic.removeConnection(fromStep.id, toStepId);
              Get.back();
            },
          )).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _showStepContextMenu(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    WorkflowModel workflow,
  ) {
    // 查找这个步骤的输入连接来源
    String? inputFromName;
    for (final s in workflow.steps) {
      if (s.nextStepIds.contains(step.id)) {
        inputFromName = s.name;
        break;
      }
    }

    Get.bottomSheet(
      Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Icon(getStepIcon(step.type), color: getStepColor(step.type), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      step.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            // 如果有输入连接，显示断开连接选项
            if (inputFromName != null)
              ListTile(
                leading: const Icon(Icons.link_off, color: Colors.orange),
                title: Text('断开来自 "$inputFromName" 的连接'),
                onTap: () {
                  Get.back();
                  logic.removeConnection(
                    workflow.steps.firstWhere((s) => s.name == inputFromName).id,
                    step.id,
                  );
                },
              ),
            // 如果有输出连接，显示断开所有输出连接选项
            if (step.nextStepIds.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.link_off, color: Colors.red),
                title: Text('断开 ${step.nextStepIds.length} 个输出连接'),
                onTap: () {
                  Get.back();
                  for (final nextId in step.nextStepIds.toList()) {
                    logic.removeConnection(step.id, nextId);
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.error),
              title: const Text('删除步骤', style: TextStyle(color: AppColors.error)),
              onTap: () {
                Get.back();
                logic.removeStep(step.id);
              },
            ),
            ListTile(
              leading: Icon(step.enabled ? Icons.disabled_visible : Icons.check_circle),
              title: Text(step.enabled ? '禁用步骤' : '启用步骤'),
              onTap: () {
                Get.back();
                logic.updateStep(step.copyWith(enabled: !step.enabled));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制步骤'),
              onTap: () {
                Get.back();
                logic.addStep(step.type);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, WorkflowDesignerLogic logic) {
    return Container(
      height: 48,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Obx(() {
            final isExecuting = logic.state.isExecuting.value;
            return ElevatedButton.icon(
              onPressed: isExecuting ? null : logic.executeWorkflow,
              icon: isExecuting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(isExecuting ? '执行中...' : '执行工作流'),
            );
          }),
          const SizedBox(width: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: logic.saveWorkflow,
            icon: const Icon(Icons.save, size: 18),
            label: const Text('保存'),
          ),
          const Spacer(),
          Obx(() {
            final result = logic.state.executionResult.value;
            if (result == null) return const SizedBox.shrink();

            return Row(
              children: [
                Icon(
                  result.success ? Icons.check_circle : Icons.error,
                  size: 16,
                  color: result.success ? AppColors.success : AppColors.error,
                ),
                const SizedBox(width: 4),
                Text(
                  result.success
                      ? '完成 (${result.duration.inMilliseconds}ms)'
                      : '失败: ${result.error}',
                  style: TextStyle(
                    fontSize: 12,
                    color: result.success ? AppColors.success : AppColors.error,
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCollapsiblePropertyPanel(BuildContext context, WorkflowDesignerLogic logic) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _propertyPanelExpanded ? 320 : 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _propertyPanelExpanded = !_propertyPanelExpanded),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: _propertyPanelExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  if (!_propertyPanelExpanded) ...[
                    Icon(
                      Icons.chevron_left,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ] else ...[
                    const Text('属性', style: TextStyle(fontWeight: FontWeight.w500)),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.chevron_right, size: 20),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _propertyPanelExpanded
                ? _buildPropertyPanel(context, logic)
                : _buildCollapsedPropertyPanel(context, logic),
          ),
        ],
      ),
    );
  }

  /// 收起状态下的属性面板图标
  Widget _buildCollapsedPropertyPanel(BuildContext context, WorkflowDesignerLogic logic) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Tooltip(
          message: '展开属性面板',
          preferBelow: false,
          child: InkWell(
            onTap: () => setState(() => _propertyPanelExpanded = !_propertyPanelExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Icon(
                Icons.chevron_left,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPropertyPanel(BuildContext context, WorkflowDesignerLogic logic) {
    return Obx(() {
      final step = logic.state.selectedStep.value;

      if (step == null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.touch_app,
                size: 32,
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              Text(
                '选择步骤以编辑属性',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      }

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _buildStepConfigForm(context, logic, step),
      );
    });
  }

  Widget _buildStepConfigForm(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(getStepIcon(step.type), color: getStepColor(step.type), size: 20),
            const SizedBox(width: 8),
            Text(
              step.type.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Switch(
              value: step.enabled,
              onChanged: (value) => logic.updateStep(step.copyWith(enabled: value)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        _buildTextField(
          label: '名称',
          initialValue: step.name,
          onChanged: (value) => logic.updateStep(step.copyWith(name: value)),
        ),
        const SizedBox(height: 12),
        _buildTextField(
          label: '描述',
          initialValue: step.description ?? '',
          onChanged: (value) => logic.updateStep(step.copyWith(description: value)),
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        ..._buildTypeSpecificConfig(context, logic, step),
      ],
    );
  }

  List<Widget> _buildTypeSpecificConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    switch (step.type) {
      case StepType.http_request:
        return _buildHttpRequestConfig(context, logic, step);
      case StepType.data_extract:
        return _buildDataExtractConfig(context, logic, step);
      case StepType.data_filter:
        return _buildDataFilterConfig(context, logic, step);
      case StepType.condition:
        return _buildConditionConfig(context, logic, step);
      case StepType.var_get:
        return _buildVarGetConfig(context, logic, step);
      case StepType.var_set:
        return _buildVarSetConfig(context, logic, step);
      case StepType.log:
        return _buildLogConfig(context, logic, step);
      case StepType.delay:
        return _buildDelayConfig(context, logic, step);
      case StepType.database_read:
        return _buildDatabaseReadConfig(context, logic, step);
      case StepType.database_write:
        return _buildDatabaseWriteConfig(context, logic, step);
      case StepType.database_create:
        return _buildDatabaseCreateConfig(context, logic, step);
      case StepType.database_query:
        return _buildDatabaseQueryConfig(context, logic, step);
      case StepType.comment:
        return _buildCommentConfig(context, logic, step);
      default:
        return [
          Center(
            child: Text(
              '该类型暂无特定配置',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
        ];
    }
  }

  List<Widget> _buildHttpRequestConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final httpOpts = step.httpOptions;
    final url = httpOpts.url;
    final method = httpOpts.method;
    final body = httpOpts.body;
    final timeout = httpOpts.connectTimeout;

    return [
      DropdownButtonFormField<String>(
        value: method,
        decoration: const InputDecoration(
          labelText: '方法',
          isDense: true,
        ),
        items: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'].map((m) {
          return DropdownMenuItem(value: m, child: Text(m));
        }).toList(),
        onChanged: (value) {
          if (value != null) {
            logic.updateStep(step.withHttpOptions(httpOpts.copyWith(method: value)));
          }
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: 'URL',
        initialValue: url,
        onChanged: (value) {
          logic.updateStep(step.withHttpOptions(httpOpts.copyWith(url: value)));
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: 'Body',
        initialValue: body,
        maxLines: 3,
        onChanged: (value) {
          logic.updateStep(step.withHttpOptions(httpOpts.copyWith(body: value)));
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '超时（秒）',
        initialValue: timeout.toString(),
        keyboardType: TextInputType.number,
        onChanged: (value) {
          logic.updateStep(step.withHttpOptions(
            httpOpts.copyWith(connectTimeout: int.tryParse(value) ?? 30),
          ));
        },
      ),
    ];
  }

  List<Widget> _buildDataExtractConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final fieldsData = step.options['fields'] as List<dynamic>? ?? [];
    final fields = fieldsData.map((f) => Map<String, dynamic>.from(f as Map)).toList();

    // 获取输入数据用于路径联想
    final inputData = _getInputDataForStep(logic, step);
    final suggestions = _extractPathSuggestions(inputData);

    // 确保该步骤的控制器映射存在
    _extractFieldControllers[step.id] ??= {};

    return [
      _buildDataPathPicker(context, logic, step),
      const SizedBox(height: 16),
      Row(
        children: [
          Text(
            '提取字段',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${fields.length} 个字段',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      // 字段列表
      ...fields.asMap().entries.map((entry) {
        final index = entry.key;
        final field = entry.value;
        return _buildExtractFieldCard(
          context: context,
          logic: logic,
          step: step,
          fieldIndex: index,
          field: field,
          suggestions: suggestions,
        );
      }),
      const SizedBox(height: 8),
      // 添加字段按钮
      OutlinedButton.icon(
        onPressed: () => _addExtractField(logic, step, fields),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('添加字段'),
      ),
    ];
  }

  /// 从输入数据中提取路径建议
  List<String> _extractPathSuggestions(dynamic data, [String prefix = '']) {
    if (data == null) return [];
    final suggestions = <String>[];

    if (data is Map) {
      data.forEach((key, value) {
        final path = prefix.isEmpty ? key.toString() : '$prefix.$key';
        suggestions.add(path);
        suggestions.addAll(_extractPathSuggestions(value, path));
      });
    } else if (data is List) {
      for (var i = 0; i < data.length; i++) {
        final path = '$prefix[$i]';
        suggestions.add(path);
        if (i < 5) {
          // 只取前5个元素避免过多
          suggestions.addAll(_extractPathSuggestions(data[i], path));
        }
      }
    }
    return suggestions;
  }

  /// 构建单个提取字段卡片
  Widget _buildExtractFieldCard({
    required BuildContext context,
    required WorkflowDesignerLogic logic,
    required StepConfig step,
    required int fieldIndex,
    required Map<String, dynamic> field,
    required List<String> suggestions,
  }) {
    // 获取或创建该字段的控制器映射
    final fieldControllers = _extractFieldControllers[step.id]![fieldIndex] ??= {
      'name': TextEditingController(text: field['name'] as String? ?? ''),
      'path': TextEditingController(text: field['path'] as String? ?? ''),
      'description': TextEditingController(text: field['description'] as String? ?? ''),
      'regex': TextEditingController(text: field['regex'] as String? ?? ''),
      'defaultValue': TextEditingController(text: field['defaultValue'] as String? ?? ''),
    };

    // 如果字段数据有变化但控制器文本没变，同步控制器
    final nameCtrl = fieldControllers['name']!;
    final pathCtrl = fieldControllers['path']!;
    final descCtrl = fieldControllers['description']!;
    final regexCtrl = fieldControllers['regex']!;
    final defaultCtrl = fieldControllers['defaultValue']!;

    if (nameCtrl.text != (field['name'] as String? ?? '') && !nameCtrl.text.contains('\uFFFC')) {
      nameCtrl.text = field['name'] as String? ?? '';
    }
    if (pathCtrl.text != (field['path'] as String? ?? '') && !pathCtrl.text.contains('\uFFFC')) {
      pathCtrl.text = field['path'] as String? ?? '';
    }
    if (descCtrl.text != (field['description'] as String? ?? '') && !descCtrl.text.contains('\uFFFC')) {
      descCtrl.text = field['description'] as String? ?? '';
    }
    if (regexCtrl.text != (field['regex'] as String? ?? '') && !regexCtrl.text.contains('\uFFFC')) {
      regexCtrl.text = field['regex'] as String? ?? '';
    }
    if (defaultCtrl.text != (field['defaultValue'] as String? ?? '') && !defaultCtrl.text.contains('\uFFFC')) {
      defaultCtrl.text = field['defaultValue'] as String? ?? '';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '字段名称',
                      isDense: true,
                      hintText: '输出变量名',
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (value) {
                      field['name'] = value;
                      _updateExtractFields(logic, step, fieldIndex, field);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _removeExtractField(logic, step, fieldIndex),
                  color: AppColors.error,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildPathFieldWithAutocomplete(
              controller: pathCtrl,
              field: field,
              fieldIndex: fieldIndex,
              logic: logic,
              step: step,
              suggestions: suggestions,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: '描述（可选）',
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (value) {
                field['description'] = value;
                _updateExtractFields(logic, step, fieldIndex, field);
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: regexCtrl,
                    decoration: const InputDecoration(
                      labelText: '正则表达式（可选）',
                      isDense: true,
                      hintText: '复杂提取',
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (value) {
                      field['regex'] = value.isEmpty ? null : value;
                      _updateExtractFields(logic, step, fieldIndex, field);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: defaultCtrl,
                    decoration: const InputDecoration(
                      labelText: '默认值（可选）',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (value) {
                      field['defaultValue'] = value.isEmpty ? null : value;
                      _updateExtractFields(logic, step, fieldIndex, field);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建带自动补全的数据路径输入框
  Widget _buildPathFieldWithAutocomplete({
    required TextEditingController controller,
    required Map<String, dynamic> field,
    required int fieldIndex,
    required WorkflowDesignerLogic logic,
    required StepConfig step,
    required List<String> suggestions,
  }) {
    return PathAutocompleteField(
      controller: controller,
      suggestions: suggestions,
      labelText: '数据路径',
      hintText: '如: user.name 或 items[0]',
      onChanged: (value) {
        field['path'] = value;
        _updateExtractFields(logic, step, fieldIndex, field);
      },
    );
  }

  /// 获取步骤的输入数据（用于路径联想）
  dynamic _getInputDataForStep(WorkflowDesignerLogic logic, StepConfig step) {
    final workflow = logic.state.selectedWorkflow.value;
    if (workflow == null) return null;

    // 找到前一个步骤
    StepConfig? prevStep;
    for (final s in workflow.steps) {
      if (s.nextStepIds.contains(step.id)) {
        prevStep = s;
        break;
      }
    }

    if (prevStep == null) return null;

    // 从执行结果中获取前一个步骤的输出
    final result = logic.state.executionResult.value;
    if (result == null) return null;

    try {
      final output = result.stepOutputs.firstWhere((o) => o.stepId == prevStep!.id);
      return output.data;
    } catch (_) {
      return null;
    }
  }

  /// 获取可用的数据源步骤列表
  List<StepConfig> _getAvailableSourceSteps(WorkflowDesignerLogic logic, StepConfig targetStep) {
    final workflow = logic.state.selectedWorkflow.value;
    if (workflow == null) return [];

    // 获取所有前置步骤（在目标步骤之前的步骤）
    final allSteps = workflow.steps;
    final targetIndex = allSteps.indexWhere((s) => s.id == targetStep.id);
    if (targetIndex <= 0) return [];

    // 返回所有在目标步骤之前的步骤
    return allSteps.sublist(0, targetIndex);
  }

  /// 从指定步骤获取输入数据
  dynamic _getInputDataFromStep(WorkflowDesignerLogic logic, StepConfig sourceStep) {
    final result = logic.state.executionResult.value;
    if (result == null) return null;

    try {
      final output = result.stepOutputs.firstWhere((o) => o.stepId == sourceStep.id);
      return output.data;
    } catch (_) {
      return null;
    }
  }

  /// 构建数据源选择器
  Widget _buildDataSourceSelector({
    required BuildContext context,
    required WorkflowDesignerLogic logic,
    required StepConfig step,
    required List<StepConfig> availableSteps,
    required String selectedStepId,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '数据来源',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: selectedStepId,
          decoration: const InputDecoration(
            isDense: true,
            hintText: '选择数据来源步骤',
          ),
          items: [
            const DropdownMenuItem(
              value: '__PREV__',
              child: Row(
                children: [
                  Icon(Icons.arrow_back, size: 16),
                  SizedBox(width: 8),
                  Text('上一步'),
                ],
              ),
            ),
            ...availableSteps.map((s) => DropdownMenuItem(
              value: s.id,
              child: Row(
                children: [
                  Icon(getStepIcon(s.type), size: 16, color: getStepColor(s.type)),
                  const SizedBox(width: 8),
                  Text(s.name.isEmpty ? s.type.label : s.name),
                ],
              ),
            )),
          ],
          onChanged: (v) {
            if (v != null) {
              logic.updateStep(step.copyWith(
                options: Map.from(step.options)..['inputSourceStepId'] = v,
              ));
            }
          },
        ),
      ],
    );
  }

  void _addExtractField(
    WorkflowDesignerLogic logic,
    StepConfig step,
    List<Map<String, dynamic>> fields,
  ) {
    final newField = <String, dynamic>{
      'name': 'field${fields.length + 1}',
      'path': '',
      'description': '',
      'enabled': true,
    };
    final newFields = [...fields, newField];
    logic.updateStep(step.copyWith(
      options: Map.from(step.options)..['fields'] = newFields,
    ));
  }

  void _removeExtractField(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
  ) {
    final fieldsData = step.options['fields'] as List<dynamic>? ?? [];
    final fields = fieldsData.map((f) => Map<String, dynamic>.from(f as Map)).toList();
    if (index >= 0 && index < fields.length) {
      fields.removeAt(index);
      logic.updateStep(step.copyWith(
        options: Map.from(step.options)..['fields'] = fields,
      ));
    }
  }

  void _updateExtractFields(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
    Map<String, dynamic> updatedField,
  ) {
    final fieldsData = step.options['fields'] as List<dynamic>? ?? [];
    final fields = fieldsData.map((f) => Map<String, dynamic>.from(f as Map)).toList();
    if (index >= 0 && index < fields.length) {
      fields[index] = updatedField;
      logic.updateStep(step.copyWith(
        options: Map.from(step.options)..['fields'] = fields,
      ));
    }
  }

  List<Widget> _buildDataFilterConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final field = step.options['field'] as String? ?? '';
    final operator = step.options['operator'] as String? ?? 'eq';
    final value = step.options['value'] as String? ?? '';

    return [
      _buildTextField(
        label: '字段',
        initialValue: field,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['field'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: operator,
        decoration: const InputDecoration(
          labelText: '操作符',
          isDense: true,
        ),
        items: ['eq', 'ne', 'gt', 'lt', 'gte', 'lte', 'contains', 'startsWith', 'endsWith']
            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: (v) {
          if (v != null) {
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['operator'] = v,
            ));
          }
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '值',
        initialValue: value,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['value'] = v,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildConditionConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final field = step.options['field'] as String? ?? '';
    final operator = step.options['operator'] as String? ?? 'eq';
    final value = step.options['value'] as String? ?? '';

    return [
      _buildTextField(
        label: '字段',
        initialValue: field,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['field'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: operator,
        decoration: const InputDecoration(
          labelText: '操作符',
          isDense: true,
        ),
        items: ['eq', 'ne', 'gt', 'lt', 'gte', 'lte', 'contains']
            .map((o) => DropdownMenuItem(value: o, child: Text(o)))
            .toList(),
        onChanged: (v) {
          if (v != null) {
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['operator'] = v,
            ));
          }
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '值',
        initialValue: value,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['value'] = v,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildVarGetConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final varName = step.options['varName'] as String? ?? '';
    final defaultValue = step.options['defaultValue']?.toString() ?? '';

    return [
      _buildTextField(
        label: '变量名',
        initialValue: varName,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['varName'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '默认值',
        initialValue: defaultValue,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['defaultValue'] = v,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildVarSetConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final varName = step.options['varName'] as String? ?? '';
    final value = step.options['value']?.toString() ?? '';
    final isSecret = step.options['isSecret'] as bool? ?? false;

    return [
      _buildTextField(
        label: '变量名',
        initialValue: varName,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['varName'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '值',
        initialValue: value,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['value'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          const Text('敏感数据', style: TextStyle(fontSize: 12)),
          const Spacer(),
          Switch(
            value: isSecret,
            onChanged: (v) {
              logic.updateStep(step.copyWith(
                options: Map.from(step.options)..['isSecret'] = v,
              ));
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildLogConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final level = step.options['level'] as String? ?? 'info';
    final message = step.options['message'] as String? ?? '';

    return [
      DropdownButtonFormField<String>(
        value: level,
        decoration: const InputDecoration(
          labelText: '日志级别',
          isDense: true,
        ),
        items: ['debug', 'info', 'warn', 'error']
            .map((l) => DropdownMenuItem(value: l, child: Text(l)))
            .toList(),
        onChanged: (v) {
          if (v != null) {
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['level'] = v,
            ));
          }
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '消息',
        initialValue: message,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['message'] = v,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildDelayConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final seconds = step.options['seconds'] as int? ?? 1;

    return [
      _buildTextField(
        label: '延迟秒数',
        initialValue: seconds.toString(),
        keyboardType: TextInputType.number,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['seconds'] = int.tryParse(v) ?? 1,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildCommentConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final text = step.options['text'] as String? ?? '';

    return [
      _buildTextField(
        label: '注释',
        initialValue: text,
        maxLines: 3,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['text'] = v,
          ));
        },
      ),
    ];
  }

  // ========== 数据库配置 ==========

  List<Widget> _buildDatabaseReadConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final tableName = step.options['tableName'] as String? ?? '';
    final tableAlias = step.options['tableAlias'] as String? ?? '';
    final whereClause = step.options['whereClause'] as String? ?? '';
    final orderBy = step.options['orderBy'] as String? ?? '';
    final limit = step.options['limit'] as int? ?? 100;
    final columns = step.options['columns'] as List<dynamic>? ?? [];

    return [
      TableSelector(
        selectedTable: tableName,
        selectedAlias: tableAlias,
        onTableChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['tableName'] = v,
          ));
        },
        onAliasChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['tableAlias'] = v,
          ));
        },
      ),
      const SizedBox(height: 16),
      ColumnSelector(
        tableName: tableName,
        selectedColumns: columns.map((c) => c is Map ? c['name'] as String : c.toString()).toList(),
        onColumnsChanged: (selectedColumns) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)
              ..['columns'] = selectedColumns.map((name) => {'name': name}).toList(),
          ));
        },
      ),
      const SizedBox(height: 16),
      _buildTextField(
        label: 'WHERE 条件',
        initialValue: whereClause,
        hintText: '如: status = ? AND age > ?',
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['whereClause'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      _buildTextField(
        label: '排序',
        initialValue: orderBy,
        hintText: '如: created_at DESC',
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['orderBy'] = v,
          ));
        },
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          const Text('限制条数:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: TextFormField(
              initialValue: limit.toString(),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) {
                logic.updateStep(step.copyWith(
                  options: Map.from(step.options)..['limit'] = int.tryParse(v) ?? 100,
                ));
              },
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildDatabaseWriteConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final tableName = step.options['tableName'] as String? ?? '';
    final tableAlias = step.options['tableAlias'] as String? ?? '';
    final operation = step.options['operation'] as String? ?? 'insert';
    final onConflict = step.options['onConflict'] as String? ?? 'abort';
    final conflictTarget = step.options['conflictTarget'] as String? ?? '';
    final columns = step.options['columns'] as List<dynamic>? ?? [];
    final whereClause = step.options['whereClause'] as String? ?? '';
    final inputSourceStepId = step.options['inputSourceStepId'] as String? ?? '__PREV__';

    // 获取数据来源步骤
    final availableSourceSteps = _getAvailableSourceSteps(logic, step);
    final selectedSourceStep = availableSourceSteps.firstWhere(
      (s) => s.id == inputSourceStepId,
      orElse: () => availableSourceSteps.first,
    );

    // 获取输入数据用于路径联想
    final inputData = _getInputDataFromStep(logic, selectedSourceStep);
    final suggestions = _extractPathSuggestions(inputData);

    return [
      // 数据来源选择
      _buildDataSourceSelector(
        context: context,
        logic: logic,
        step: step,
        availableSteps: availableSourceSteps,
        selectedStepId: inputSourceStepId,
      ),
      const SizedBox(height: 16),
      TableSelector(
        selectedTable: tableName,
        selectedAlias: tableAlias,
        onTableChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['tableName'] = v,
          ));
        },
        onAliasChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['tableAlias'] = v,
          ));
        },
      ),
      const SizedBox(height: 16),
      _buildDatabaseWriteFieldMapping(context, logic, step, columns, suggestions),
      const SizedBox(height: 16),
      Row(
        children: [
          const Text('操作:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: operation,
            items: const [
              DropdownMenuItem(value: 'insert', child: Text('插入 INSERT')),
              DropdownMenuItem(value: 'update', child: Text('更新 UPDATE')),
              DropdownMenuItem(value: 'upsert', child: Text('插入或更新 UPSERT')),
            ],
            onChanged: (v) {
              if (v != null) {
                logic.updateStep(step.copyWith(
                  options: Map.from(step.options)..['operation'] = v,
                ));
              }
            },
          ),
        ],
      ),
      if (operation == 'update' || operation == 'upsert') ...[
        const SizedBox(height: 12),
        _buildTextField(
          label: 'WHERE 条件（用于更新定位）',
          initialValue: whereClause,
          hintText: '如: id = ?',
          onChanged: (v) {
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['whereClause'] = v,
            ));
          },
        ),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          const Text('冲突处理:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: onConflict,
            items: const [
              DropdownMenuItem(value: 'abort', child: Text('中止 Abort')),
              DropdownMenuItem(value: 'ignore', child: Text('忽略 Ignore')),
              DropdownMenuItem(value: 'replace', child: Text('替换 Replace')),
            ],
            onChanged: (v) {
              if (v != null) {
                logic.updateStep(step.copyWith(
                  options: Map.from(step.options)..['onConflict'] = v,
                ));
              }
            },
          ),
        ],
      ),
      if (operation == 'upsert') ...[
        const SizedBox(height: 12),
        // 冲突目标字段选择
        Builder(
          builder: (context) {
            // 从列定义中提取列名
            final columnNames = columns
                .map((c) {
                  if (c is Map) {
                    return c['name'] as String?;
                  }
                  return null;
                })
                .whereType<String>()
                .where((name) => name.isNotEmpty)
                .toList();

            if (columnNames.isEmpty) {
              return _buildTextField(
                label: '冲突目标字段（必填）',
                initialValue: conflictTarget,
                hintText: '请先配置表字段',
                onChanged: (v) {
                  logic.updateStep(step.copyWith(
                    options: Map.from(step.options)..['conflictTarget'] = v,
                  ));
                },
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('冲突目标字段（必填）:', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: columnNames.contains(conflictTarget) ? conflictTarget : null,
                  hint: const Text('选择字段'),
                  isExpanded: true,
                  items: columnNames.map((name) {
                    return DropdownMenuItem(value: name, child: Text(name));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      logic.updateStep(step.copyWith(
                        options: Map.from(step.options)..['conflictTarget'] = v,
                      ));
                    }
                  },
                ),
              ],
            );
          },
        ),
      ],
    ];
  }

  /// 数据库写入字段映射编辑器
  Widget _buildDatabaseWriteFieldMapping(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    List<dynamic> columns,
    List<String> suggestions,
  ) {
    final columnList = columns.map((c) => Map<String, dynamic>.from(c as Map)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '字段映射',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${columnList.length} 个字段',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '将输入数据映射到表字段',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 字段映射列表
        ...columnList.asMap().entries.map((entry) {
          final index = entry.key;
          final column = entry.value;
          return _buildWriteFieldCard(context, logic, step, index, column, suggestions);
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            final newColumn = <String, dynamic>{
              'name': '',
              'sourcePath': '',
            };
            final newColumns = [...columnList, newColumn];
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['columns'] = newColumns,
            ));
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加字段映射'),
        ),
      ],
    );
  }

  /// 单个字段映射卡片
  Widget _buildWriteFieldCard(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
    Map<String, dynamic> column,
    List<String> suggestions,
  ) {
    final nameController = TextEditingController(text: column['name'] as String? ?? '');
    final pathController = TextEditingController(text: column['sourcePath'] as String? ?? '');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '表字段名',
                      isDense: true,
                      hintText: '如: username',
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) {
                      column['name'] = v;
                      _updateWriteColumn(logic, step, index, column);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _removeWriteColumn(logic, step, index),
                  color: AppColors.error,
                ),
              ],
            ),
            const SizedBox(height: 8),
            PathAutocompleteField(
              controller: pathController,
              suggestions: suggestions,
              labelText: '输入数据路径',
              hintText: '如: \${user.name} 或 data.items[0]',
              onChanged: (v) {
                column['sourcePath'] = v;
                _updateWriteColumn(logic, step, index, column);
              },
            ),
            const SizedBox(height: 4),
            Text(
              '从输入数据中提取值写入该字段',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updateWriteColumn(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
    Map<String, dynamic> column,
  ) {
    final columns = (step.options['columns'] as List<dynamic>? ?? [])
        .asMap()
        .entries
        .map((entry) {
      if (entry.key == index) {
        return column;
      }
      return entry.value;
    }).toList();

    logic.updateStep(step.copyWith(
      options: Map.from(step.options)..['columns'] = columns,
    ));
  }

  void _removeWriteColumn(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
  ) {
    final columns = (step.options['columns'] as List<dynamic>? ?? [])
        .asMap()
        .entries
        .where((entry) => entry.key != index)
        .map((entry) => entry.value)
        .toList();

    logic.updateStep(step.copyWith(
      options: Map.from(step.options)..['columns'] = columns,
    ));
  }

  List<Widget> _buildDatabaseCreateConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final tableName = step.options['tableName'] as String? ?? '';
    final ifNotExists = step.options['ifNotExists'] as bool? ?? true;
    final replaceExisting = step.options['replaceExisting'] as bool? ?? false;
    final columns = step.options['columns'] as List<dynamic>? ?? [];

    return [
      _buildTextField(
        label: '表名',
        initialValue: tableName,
        hintText: '输入要创建的表名',
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['tableName'] = v,
          ));
        },
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: CheckboxListTile(
              title: const Text('IF NOT EXISTS', style: TextStyle(fontSize: 12)),
              subtitle: const Text('表存在时跳过创建', style: TextStyle(fontSize: 10)),
              value: ifNotExists,
              onChanged: (v) {
                logic.updateStep(step.copyWith(
                  options: Map.from(step.options)..['ifNotExists'] = v ?? true,
                ));
              },
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: CheckboxListTile(
              title: const Text('替换已存在表', style: TextStyle(fontSize: 12)),
              subtitle: const Text('先删除旧表再创建', style: TextStyle(fontSize: 10)),
              value: replaceExisting,
              onChanged: (v) {
                logic.updateStep(step.copyWith(
                  options: Map.from(step.options)..['replaceExisting'] = v ?? false,
                ));
              },
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _buildTableColumnsEditor(context, logic, step, columns),
    ];
  }

  /// 表格列编辑器
  Widget _buildTableColumnsEditor(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    List<dynamic> columns,
  ) {
    final columnList = columns.map((c) => Map<String, dynamic>.from(c as Map)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '字段定义',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${columnList.length} 个字段',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 字段列表
        ...columnList.asMap().entries.map((entry) {
          final index = entry.key;
          final column = entry.value;
          return _buildColumnEditorCard(context, logic, step, index, column);
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            final newColumn = <String, dynamic>{
              'name': '',
              'type': 'TEXT',
              'nullable': true,
              'primaryKey': false,
              'autoIncrement': false,
            };
            final newColumns = [...columnList, newColumn];
            logic.updateStep(step.copyWith(
              options: Map.from(step.options)..['columns'] = newColumns,
            ));
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加字段'),
        ),
      ],
    );
  }

  /// 单个字段编辑器卡片
  Widget _buildColumnEditorCard(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
    Map<String, dynamic> column,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: column['name'] as String? ?? '',
                    decoration: const InputDecoration(
                      labelText: '字段名',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) {
                      column['name'] = v;
                      _updateColumn(logic, step, index, column);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _removeColumn(logic, step, index),
                  color: AppColors.error,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: column['type'] as String? ?? 'TEXT',
                    decoration: const InputDecoration(
                      labelText: '类型',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'TEXT', child: Text('TEXT')),
                      DropdownMenuItem(value: 'INTEGER', child: Text('INTEGER')),
                      DropdownMenuItem(value: 'REAL', child: Text('REAL')),
                      DropdownMenuItem(value: 'BOOLEAN', child: Text('BOOLEAN')),
                      DropdownMenuItem(value: 'BLOB', child: Text('BLOB')),
                      DropdownMenuItem(value: 'DATETIME', child: Text('DATETIME')),
                    ],
                    onChanged: (v) {
                      column['type'] = v;
                      _updateColumn(logic, step, index, column);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: column['defaultValue'] as String? ?? '',
                    decoration: const InputDecoration(
                      labelText: '默认值（可选）',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) {
                      column['defaultValue'] = v.isEmpty ? null : v;
                      _updateColumn(logic, step, index, column);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                FilterChip(
                  label: const Text('主键', style: TextStyle(fontSize: 11)),
                  selected: column['primaryKey'] as bool? ?? false,
                  onSelected: (v) {
                    column['primaryKey'] = v;
                    if (v) column['nullable'] = false;
                    _updateColumn(logic, step, index, column);
                  },
                  visualDensity: VisualDensity.compact,
                ),
                FilterChip(
                  label: const Text('自增', style: TextStyle(fontSize: 11)),
                  selected: column['autoIncrement'] as bool? ?? false,
                  onSelected: (v) {
                    column['autoIncrement'] = v;
                    if (v) {
                      column['type'] = 'INTEGER';
                      column['primaryKey'] = true;
                    }
                    _updateColumn(logic, step, index, column);
                  },
                  visualDensity: VisualDensity.compact,
                ),
                FilterChip(
                  label: const Text('可空', style: TextStyle(fontSize: 11)),
                  selected: column['nullable'] as bool? ?? true,
                  onSelected: (v) {
                    column['nullable'] = v;
                    _updateColumn(logic, step, index, column);
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _updateColumn(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
    Map<String, dynamic> column,
  ) {
    final columns = (step.options['columns'] as List<dynamic>? ?? [])
        .asMap()
        .entries
        .map((entry) {
      if (entry.key == index) {
        return column;
      }
      return entry.value;
    }).toList();

    logic.updateStep(step.copyWith(
      options: Map.from(step.options)..['columns'] = columns,
    ));
  }

  void _removeColumn(
    WorkflowDesignerLogic logic,
    StepConfig step,
    int index,
  ) {
    final columns = (step.options['columns'] as List<dynamic>? ?? [])
        .asMap()
        .entries
        .where((entry) => entry.key != index)
        .map((entry) => entry.value)
        .toList();

    logic.updateStep(step.copyWith(
      options: Map.from(step.options)..['columns'] = columns,
    ));
  }

  List<Widget> _buildDatabaseQueryConfig(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final query = step.options['query'] as String? ?? '';

    return [
      _buildTextField(
        label: 'SQL 查询',
        initialValue: query,
        hintText: 'SELECT * FROM users WHERE status = ?',
        maxLines: 4,
        onChanged: (v) {
          logic.updateStep(step.copyWith(
            options: Map.from(step.options)..['query'] = v,
          ));
        },
      ),
    ];
  }

  Widget _buildDataPathPicker(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
  ) {
    final controller = _inputPathControllers[step.id] ??= TextEditingController(
      text: step.options['inputPath'] as String? ?? '',
    );

    if (controller.text != (step.options['inputPath'] as String? ?? '')) {
      controller.text = step.options['inputPath'] as String? ?? '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '数据路径',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '例如: data.items[0].name',
                  isDense: true,
                ),
                onChanged: (value) {
                  logic.updateStep(step.copyWith(
                    options: Map.from(step.options)..['inputPath'] = value,
                  ));
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.search, size: 20),
              tooltip: '选择路径',
              onPressed: () => _showDataPathPicker(context, logic, step, controller),
            ),
          ],
        ),
      ],
    );
  }

  void _showDataPathPicker(
    BuildContext context,
    WorkflowDesignerLogic logic,
    StepConfig step,
    TextEditingController controller,
  ) {
    final workflow = logic.state.selectedWorkflow.value;
    if (workflow == null) return;

    StepConfig? previousStep;
    final stepIndex = workflow.steps.indexWhere((s) => s.id == step.id);
    if (stepIndex > 0) {
      previousStep = workflow.steps[stepIndex - 1];
    }

    if (previousStep == null) {
      Get.snackbar('提示', '没有可用的上一步骤作为数据源');
      return;
    }

    final executionResult = logic.state.executionResult.value;
    dynamic sourceData;
    if (executionResult != null) {
      sourceData = executionResult.getOutput(previousStep.id);
    }

    if (sourceData == null) {
      Get.snackbar('提示', '上一步骤没有可用的输出数据，请先执行工作流');
      return;
    }

    Get.dialog(
      AlertDialog(
        title: const Text('选择数据路径'),
        content: SizedBox(
          width: 400,
          height: 300,
          child: _DataPathPickerDialog(
            data: sourceData,
            onPathSelected: (path) {
              controller.text = path;
              logic.updateStep(step.copyWith(
                options: Map.from(step.options)..['inputPath'] = path,
              ));
              Get.back();
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required String initialValue,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? hintText,
  }) {
    return TextFormField(
      initialValue: initialValue,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        hintText: hintText,
      ),
      maxLines: maxLines,
      keyboardType: keyboardType,
      onChanged: onChanged,
    );
  }

  void _handleMenuAction(
    BuildContext context,
    String action,
    WorkflowDesignerLogic logic,
  ) {
    switch (action) {
      case 'new':
        logic.createWorkflow();
        break;
      case 'delete':
        final workflow = logic.state.selectedWorkflow.value;
        if (workflow != null) {
          Get.dialog(
            AlertDialog(
              title: const Text('删除工作流'),
              content: Text('确定要删除 "${workflow.name}" 吗？'),
              actions: [
                TextButton(
                  onPressed: () => Get.back(),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    Get.back();
                    logic.deleteWorkflow(workflow.id);
                  },
                  child: const Text('删除', style: TextStyle(color: AppColors.error)),
                ),
              ],
            ),
          );
        }
        break;
    }
  }

  void _showImportDialog(BuildContext context, WorkflowDesignerLogic logic) {
    final textController = TextEditingController();

    Get.dialog(
      AlertDialog(
        title: const Text('导入工作流'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: textController,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴工作流 JSON...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              logic.importWorkflow(textController.text);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, WorkflowDesignerLogic logic) {
    final json = logic.exportWorkflow();

    Get.dialog(
      AlertDialog(
        title: const Text('导出工作流'),
        content: SizedBox(
          width: 400,
          child: SelectableText(
            json,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showStepDebugDialog(
    BuildContext context,
    StepConfig step,
    StepOutput? output,
  ) {
    showStepDebugDialog(context: context, step: step, output: output);
  }
}

/// 数据路径选择对话框
class _DataPathPickerDialog extends StatefulWidget {
  final dynamic data;
  final ValueChanged<String> onPathSelected;

  const _DataPathPickerDialog({
    required this.data,
    required this.onPathSelected,
  });

  @override
  State<_DataPathPickerDialog> createState() => _DataPathPickerDialogState();
}

class _DataPathPickerDialogState extends State<_DataPathPickerDialog> {
  String _currentPath = '';
  dynamic _currentData;
  final List<_DataPathInfo> _pathSegments = [];

  @override
  void initState() {
    super.initState();
    _currentData = widget.data;
  }

  void _navigateTo(dynamic data, String segment) {
    setState(() {
      _pathSegments.add(_DataPathInfo(segment, _getDataType(data), _formatValue(data)));
      _currentPath = _pathSegments.map((p) => p.path).join('.');
      _currentData = data;
    });
  }

  void _goBack() {
    if (_pathSegments.isEmpty) return;

    setState(() {
      _pathSegments.removeLast();
      _currentPath = _pathSegments.map((p) => p.path).join('.');
      dynamic data = widget.data;
      for (final segment in _pathSegments) {
        data = _getChildData(data, segment.path);
      }
      _currentData = data;
    });
  }

  dynamic _getChildData(dynamic data, String key) {
    if (data is Map) {
      return data[key];
    } else if (data is List) {
      final index = int.tryParse(key);
      if (index != null && index < data.length) {
        return data[index];
      }
    }
    return null;
  }

  String _getDataType(dynamic data) {
    if (data == null) return 'null';
    if (data is Map) return 'object';
    if (data is List) return 'array';
    return data.runtimeType.toString().toLowerCase();
  }

  String _formatValue(dynamic data) {
    if (data == null) return 'null';
    if (data is String) return '"${data.length > 20 ? '${data.substring(0, 20)}...' : data}"';
    if (data is num || data is bool) return data.toString();
    if (data is Map || data is List) return '${_getDataType(data)}(${data.length})';
    return data.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (_pathSegments.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 16),
                  onPressed: _goBack,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              if (_pathSegments.isNotEmpty) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _currentPath.isEmpty ? '(root)' : _currentPath,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              if (_currentPath.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.check, size: 16),
                  onPressed: () => widget.onPathSelected(_currentPath),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: '选择此路径',
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _getDataType(_currentData),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatValue(_currentData),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _buildChildList(),
        ),
      ],
    );
  }

  Widget _buildChildList() {
    if (_currentData == null) {
      return const Center(child: Text('无数据'));
    }

    if (_currentData is Map) {
      final map = _currentData as Map;
      return ListView.builder(
        itemCount: map.keys.length,
        itemBuilder: (context, index) {
          final key = map.keys.elementAt(index);
          final value = map[key];
          return ListTile(
            dense: true,
            leading: Text(
              _getDataType(value),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
            ),
            title: Text(
              key.toString(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            trailing: Text(
              _formatValue(value),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
            ),
            onTap: () => _navigateTo(value, key.toString()),
          );
        },
      );
    }

    if (_currentData is List) {
      final list = _currentData as List;
      return ListView.builder(
        itemCount: list.length,
        itemBuilder: (context, index) {
          final value = list[index];
          return ListTile(
            dense: true,
            leading: Text(
              '[$index]',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
            title: Text(
              _formatValue(value),
              style: const TextStyle(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _navigateTo(value, '[$index]'),
          );
        },
      );
    }

    return const Center(child: Text('无法展开基本类型'));
  }
}

class _DataPathInfo {
  final String path;
  final String type;
  final String preview;

  _DataPathInfo(this.path, this.type, this.preview);
}

/// 网格背景绘制器
class _GridPainter extends CustomPainter {
  static const double gridSize = 40.0;

  _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;

    // 绘制垂直线
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // 绘制水平线
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // 绘制中心线（更明显）
    final centerPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    canvas.drawLine(
      Offset(centerX, 0),
      Offset(centerX, size.height),
      centerPaint,
    );
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      centerPaint,
    );
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}

/// 连接线绘制器
class ConnectionLinePainter extends CustomPainter {
  final List<StepConfig> steps;
  final Map<String, StepPosition> positions;
  final String? connectingFromId;
  final Offset? mousePosition;

  static const double nodeWidth = 180.0;
  static const double nodeHeight = 100.0;
  static const double portRadius = 8.0;

  ConnectionLinePainter({
    required this.steps,
    required this.positions,
    this.connectingFromId,
    this.mousePosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (steps.isEmpty) return;

    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 绘制所有连接线
    for (final step in steps) {
      final fromPos = positions[step.id];
      if (fromPos == null) continue;

      final outputPortX = fromPos.x + nodeWidth;
      final outputPortY = fromPos.y + nodeHeight / 2;

      final nextStepIds = step.nextStepIds;
      if (nextStepIds.isEmpty) continue;

      for (var i = 0; i < nextStepIds.length; i++) {
        final nextStepId = nextStepIds[i];
        final toPos = positions[nextStepId];
        if (toPos == null) continue;

        final inputCount = _countInputsForStep(nextStepId);
        final inputIndex = _getInputIndex(step.id, nextStepId);
        final inputOffset = _getInputOffset(inputIndex, inputCount);

        final inputPortX = toPos.x;
        final inputPortY = toPos.y + nodeHeight / 2 + inputOffset;

        // 设置连接线颜色
        if (i > 0) {
          paint.color = _getBranchColor(i).withValues(alpha: 0.7);
          paint.strokeWidth = 2.5;
        } else {
          paint.color = Colors.blue.withValues(alpha: 0.6);
          paint.strokeWidth = 2.0;
        }

        _drawOrthogonalLine(
          canvas,
          Offset(outputPortX, outputPortY),
          Offset(inputPortX, inputPortY),
          paint,
        );

        // 绘制箭头（指向输入端口）
        _drawArrow(canvas, Offset(inputPortX, inputPortY), paint.color);
      }
    }

    // 绘制连接预览线（从输出端口到鼠标位置）
    if (connectingFromId != null && mousePosition != null) {
      final fromPos = positions[connectingFromId];
      if (fromPos != null) {
        final outputPortX = fromPos.x + nodeWidth;
        final outputPortY = fromPos.y + nodeHeight / 2;

        paint.color = Colors.blue.withValues(alpha: 0.8);
        paint.strokeWidth = 2.0;
        paint.style = PaintingStyle.stroke;

        _drawOrthogonalLine(
          canvas,
          Offset(outputPortX, outputPortY),
          mousePosition!,
          paint,
        );
      }
    }
  }

  /// 绘制正交连接线（先水平再垂直）
  void _drawOrthogonalLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint,
  ) {
    final path = Path();
    path.moveTo(from.dx, from.dy);

    final dx = (to.dx - from.dx).abs();

    if (dx > 50) {
      // 较长连接：使用贝塞尔曲线平滑过渡
      final controlOffset = dx * 0.4;
      path.cubicTo(
        from.dx + controlOffset,
        from.dy,
        to.dx - controlOffset,
        to.dy,
        to.dx,
        to.dy,
      );
    } else {
      // 较短连接：使用折线
      final midX = (from.dx + to.dx) / 2;
      path.lineTo(midX, from.dy);
      path.lineTo(midX, to.dy);
      path.lineTo(to.dx, to.dy);
    }

    canvas.drawPath(path, paint);
  }

  /// 绘制箭头
  void _drawArrow(Canvas canvas, Offset tip, Color color) {
    final arrowPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const arrowSize = 8.0;

    // 箭头方向朝左（指向输入端口）
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - arrowSize, tip.dy - arrowSize / 2)
      ..lineTo(tip.dx - arrowSize, tip.dy + arrowSize / 2)
      ..close();

    canvas.drawPath(path, arrowPaint);
  }

  int _countInputsForStep(String stepId) {
    int count = 0;
    for (final step in steps) {
      count += step.nextStepIds.where((id) => id == stepId).length;
    }
    return count > 0 ? count : 1;
  }

  int _getInputIndex(String fromStepId, String toStepId) {
    int index = 0;
    for (final step in steps) {
      for (final nextId in step.nextStepIds) {
        if (nextId == toStepId) {
          if (step.id == fromStepId) {
            return index;
          }
          index++;
        }
      }
    }
    return 0;
  }

  double _getInputOffset(int index, int total) {
    if (total <= 1) return 0;
    const spacing = 30.0;
    final totalHeight = (total - 1) * spacing;
    return -totalHeight / 2 + index * spacing;
  }

  Color _getBranchColor(int index) {
    const colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
    ];
    return colors[index % colors.length];
  }

  @override
  bool shouldRepaint(ConnectionLinePainter oldDelegate) {
    if (oldDelegate.steps != steps) return true;
    if (oldDelegate.positions != positions) return true;
    if (oldDelegate.connectingFromId != connectingFromId) return true;
    // Check if mousePosition changed (including null state)
    if (oldDelegate.mousePosition == null && mousePosition == null) return false;
    if (oldDelegate.mousePosition == null || mousePosition == null) return true;
    return oldDelegate.mousePosition != mousePosition;
  }
}
