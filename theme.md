# GStore 设计规范

## 概述

本文档定义了 GStore 应用的统一设计规范，包括 UI 风格、颜色、布局、文字等。所有开发人员必须严格遵守此规范。

---

## 1. 扁平化设计原则

### 1.1 核心原则

**GStore 采用扁平化设计风格，注重简洁、清晰和一致性。**

```
✅ 遵循原则：
- 无阴影或极淡阴影
- 纯色背景
- 清晰的边框
- 简洁的层次
- 充足的留白

❌ 避免问题：
- 立体阴影效果
- 渐变色（除特殊情况）
- 过度装饰
- 复杂纹理
```

### 1.2 视觉层次

扁平化设计通过以下方式建立视觉层次：
- **颜色对比**：背景色和卡片色的微妙差异
- **边框**：使用细边框区分区域
- **间距**：使用留白创造呼吸感
- **字号**：通过大小而非阴影建立层次

---

## 2. 颜色系统

### 2.1 背景色

使用 **Material 3 动态色** 系统，自动适配用户壁纸。

| 组件 | 亮色模式 | 暗色模式 |
|------|---------|---------|
| 应用背景 | `surfaceContainerLowest` | `surface` |
| AppBar | `surface` | `surface` |
| 卡片 | `surface` | `surfaceContainerLow` |
| 底部导航 | `surface` | `surface` |
| 对话框 | `surface` | `surfaceContainerLow` |
| 底部表单 | `surface` | `surfaceContainerLow` |

### 2.2 主色调

- **主色（Primary）**：从用户壁纸动态提取
- **次要色（Secondary）**：用于辅助元素
- **容器色（Container）**：用于卡片、按钮背景
- **轮廓色（Outline）**：用于边框和分割线

### 2.3 语义色

| 用途 | 颜色 | 常量 |
|------|------|------|
| 成功 | 绿色 | `AppColors.success` |
| 错误 | 红色 | `AppColors.error` |
| 警告 | 橙色 | `AppColors.warning` |
| 信息 | 蓝色 | `AppColors.info` |

### 2.4 文字色

| 等级 | 亮色 | 暗色 | 使用场景 |
|------|------|------|----------|
| Primary | #212121 | #FFFFFF | 主要文字 |
| Secondary | #757575 | #B2FFFFFF (70%) | 次要文字 |
| Tertiary | #9E9E9E | #80FFFFFF (50%) | 辅助文字 |

---

## 3. 布局与间距

### 3.1 间距系统

基于 **4px 网格**：

| 常量 | 数值 | 使用场景 |
|------|------|----------|
| `xs` | 4px | 极小间距 |
| `sm` | 8px | 小间距 |
| `md` | 12px | 中等间距 |
| `lg` | 16px | 标准间距 |
| `xl` | 20px | 大间距 |
| `xxl` | 24px | 超大间距 |
| `xxxl` | 32px | 特大间距 |

### 3.2 卡片内边距

```dart
// 标准卡片内边距
padding: AppSpacing.allLG  // 16px

// 列表项内边距
padding: AppSpacing.symmetric(horizontalLG, verticalSM)  // 16px, 8px

// 对话框内边距
padding: AppSpacing.allXL  // 20px
```

### 3.3 留白原则

```
✅ 推荐做法：
- 卡片之间留出 8-12px 间距
- 章节之间留出 16-24px 间距
- 内容边缘留出 16px 边距
- 使用 padding 而非 margin 创造空间

❌ 避免问题：
- 内容过于拥挤
- 间距不统一
- 留白过多导致信息分散
```

---

## 4. 卡片设计

### 4.1 扁平化卡片规范

```dart
Card(
  elevation: 0,  // 无阴影
  shape: RoundedRectangleBorder(
    borderRadius: AppRadius.allLG,  // 16px
    side: BorderSide(
      color: theme.colorScheme.outlineVariant.withOpacity(0.5),
      width: 1,
    ),
  ),
  // ...
)
```

### 4.2 卡片使用规则

| 场景 | 内边距 | 圆角 | 边框 |
|------|--------|------|------|
| 标准卡片 | 16px | 16px | 细边框 |
| 紧凑卡片 | 12px | 12px | 细边框 |
| 对话框 | 20px | 20px | 细边框 |

### 4.3 卡片层次

```
背景 → 卡片1 → 卡片2 → 内容
  ↑      ↑      ↑      ↑
 淡色   略深   更深   最深
```

---

## 5. 按钮设计

### 5.1 按钮类型

| 类型 | 样式 | 使用场景 |
|------|------|----------|
| Elevated Button | 填充，主色 | 主要操作 |
| Outlined Button | 轮廓，透明 | 次要操作 |
| Text Button | 文本，透明 | 辅助操作 |

### 5.2 按钮规范

```dart
// 主要按钮 - 扁平化，无阴影
ElevatedButton(
  style: ElevatedButton.styleFrom(
    elevation: 0,
    shadowColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: AppRadius.allSM,  // 8px
    ),
  ),
  child: Text('确定'),
)

// 轮廓按钮
OutlinedButton(
  style: OutlinedButton.styleFrom(
    elevation: 0,
    side: BorderSide(
      color: theme.colorScheme.outline,
      width: 1,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: AppRadius.allSM,
    ),
  ),
  child: Text('取消'),
)
```

### 5.3 按钮尺寸

| 尺寸 | 高度 | 内边距 | 字号 |
|------|------|--------|------|
| Small | 32px | 8px 水平 | 12px |
| Medium | 40px | 12px 水平 | 14px |
| Large | 48px | 16px 水平 | 16px |

### 5.4 分段式按钮（SegmentedButton）

#### 设计规范

分段式按钮用于在一组互斥的选项中进行切换，使用扁平化设计风格。

```dart
SegmentedButton<T>(
  segments: const [
    ButtonSegment(
      value: T.value1,
      label: Text('选项1'),
      icon: Icon(Icons.icon1, size: AppTypography.iconSM),
    ),
    ButtonSegment(
      value: T.value2,
      label: Text('选项2'),
      icon: Icon(Icons.icon2, size: AppTypography.iconSM),
    ),
  ],
  selected: {currentValue},
  onSelectionChanged: (Set<T> newSelection) {
    final newValue = newSelection.first;
    // 处理选择变化
  },
  style: ButtonStyle(
    // 背景色
    backgroundColor: WidgetStateProperty.resolveWith<Color?>(
      (states) {
        if (states.contains(WidgetState.selected)) {
          return theme.colorScheme.primaryContainer;
        }
        return Colors.transparent;
      },
    ),
    // 前景色（文字/图标）
    foregroundColor: WidgetStateProperty.resolveWith<Color?>(
      (states) {
        if (states.contains(WidgetState.selected)) {
          return theme.colorScheme.onPrimaryContainer;
        }
        return theme.colorScheme.onSurface;
      },
    ),
    // 边框
    side: WidgetStateProperty.all<BorderSide>(
      BorderSide(
        color: theme.colorScheme.outlineVariant.withOpacity(0.5),
        width: 1,
      ),
    ),
  ),
)
```

#### 状态样式

| 状态 | 背景色 | 前景色 | 边框 |
|------|--------|--------|------|
| 选中 | primaryContainer | onPrimaryContainer | 细边框 |
| 未选中 | transparent | onSurface | 细边框 |
| 悬停 | primaryContainer × 0.08 | - | 细边框 |
| 按下 | primaryContainer × 0.12 | - | 细边框 |

#### 图标规范

```
✅ 推荐使用：
- Material Icons 图标
- 图标大小：AppTypography.iconSM (16px)
- 图标位置：label 之前（默认）

❌ 避免问题：
- 混用不同风格的图标
- 过大或过小的图标
- 缺少图标的分段按钮
```

#### 使用场景

```
✅ 适合使用分段式按钮：
- 主题模式切换（系统/浅色/深色）
- 恢复模式选择（覆盖/合并/更新）
- 视图切换（列表/网格/卡片）
- 排序方式（最新/最热/名称）
- 时间范围（今天/本周/本月）

❌ 不适合使用：
- 单个选项（使用单选按钮）
- 独立的多选（使用复选框）
- 二元开关（使用 Switch）
- 导航（使用 TabBar）
```

#### 最佳实践

```dart
// ✅ 推荐：使用 AppSegmentedButton 统一封装
import 'package:gstore/core/design/design_tokens.dart';

AppSegmentedButton<T>(
  value: currentValue,
  segments: [
    AppSegment(value: T.value1, label: '选项1', icon: Icons.icon1),
    AppSegment(value: T.value2, label: '选项2', icon: Icons.icon2),
  ],
  onChanged: (T value) {
    // 处理选择变化
  },
)

// ✅ 推荐：带图标的分段按钮
AppSegmentedButton<AppThemeMode>(
  value: themeMode,
  segments: [
    AppSegment(value: AppThemeMode.system, label: '系统', icon: Icons.brightness_auto),
    AppSegment(value: AppThemeMode.light, label: '浅色', icon: Icons.light_mode),
    AppSegment(value: AppThemeMode.dark, label: '深色', icon: Icons.dark_mode),
  ],
  onChanged: (AppThemeMode mode) => setThemeMode(mode),
)

// ❌ 避免：直接使用 SegmentedButton 而不统一样式
SegmentedButton<T>(...) // 缺少统一样式
```

---

## 6. 表单设计

### 6.1 输入框规范

```dart
TextField(
  decoration: InputDecoration(
    contentPadding: AppSpacing.allMD,  // 12px
    border: OutlineInputBorder(
      borderRadius: AppRadius.allMD,  // 12px
      borderSide: BorderSide(
        color: theme.colorScheme.outline,
        width: 1,
      ),
    ),
    filled: true,
    fillColor: theme.colorScheme.surfaceContainerHighest,
  ),
)
```

### 6.2 输入框状态

| 状态 | 边框色 | 背景色 |
|------|--------|--------|
| 默认 | outline | surfaceContainerHighest |
| 聚焦 | primary（2px） | surfaceContainerHighest |
| 错误 | error | errorContainer（淡） |
| 禁用 | outlineVariant | surfaceContainerHighest |

---

## 7. 导航设计

### 7.1 底部导航栏

```dart
NavigationBar(
  backgroundColor: theme.colorScheme.surface,
  elevation: 0,  // 扁平化
  height: 80,
  indicatorColor: theme.colorScheme.primaryContainer,
)
```

### 7.2 AppBar 规范

```dart
AppBar(
  elevation: 0,  // 扁平化
  scrolledUnderElevation: 0,  // 滚动时也无阴影
  backgroundColor: theme.colorScheme.surface,
  centerTitle: true,
)
```

---

## 8. 图标与插图

### 8.1 图标规范

```
✅ 推荐使用：
- Material Icons (系统图标)
- 自定义图标保持一致风格
- 图标大小：20-24px

❌ 避免问题：
- 混用不同风格的图标
- 过度复杂的图标
- 阴影或渐变图标
```

### 8.2 图标尺寸

| 用途 | 尺寸 |
|------|------|
| 列表图标 | 20px |
| 按钮图标 | 20px |
| AppBar 图标 | 24px |
| 大图标 | 32-48px |

---

## 9. 动画与过渡

### 9.1 动画时长

| 类型 | 时长 | 常量 |
|------|------|------|
| 快速 | 150ms | `AppAnimations.durationFast` |
| 标准 | 300ms | `AppAnimations.durationNormal` |
| 中等 | 400ms | `AppAnimations.durationMedium` |
| 缓慢 | 500ms | `AppAnimations.durationSlow` |

### 9.2 缓动曲线

```dart
// 标准曲线
Curves.easeInOut

// 强调曲线
Curves.easeOutCubic

// 进入曲线
Curves.easeOut

// 离开曲线
Curves.easeIn
```

---

## 10. 圆角规范

### 10.1 圆角等级

| 常量 | 数值 | 使用场景 |
|------|------|----------|
| `xs` | 4px | 小元素 |
| `sm` | 8px | 按钮、标签 |
| `md` | 12px | 输入框、小卡片 |
| `lg` | 16px | 标准卡片 |
| `xl` | 20px | 对话框 |
| `xxl` | 24px | 底部表单 |

### 10.2 圆角使用规则

```dart
// 按钮
BorderRadius.all(AppRadius.allSM)  // 8px

// 卡片
BorderRadius.all(AppRadius.allLG)  // 16px

// 对话框
BorderRadius.all(AppRadius.allXL)  // 20px
```

---

## 11. 暗黑模式

### 11.1 适配原则

```
✅ 必须适配：
- 背景色：使用深色而非黑色
- 文字色：使用浅色
- 卡片色：使用略深于背景的色
- 边框：使用更透明的边框（30% vs 50%）

❌ 避免问题：
- 使用纯黑色背景（#000000）
- 直接反转颜色
- 忽略暗黑模式下的可读性
```

### 11.2 暗黑模式配色

| 元素 | 亮色模式 | 暗黑模式 |
|------|---------|---------|
| 背景 | surfaceContainerLowest | surface |
| 卡片 | surface | surfaceContainerLow |
| AppBar | surface | surface |
| 边框透明度 | 50% | 30% |

---

## 12. 代码示例

### 12.1 标准卡片

```dart
Card(
  margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  child: Padding(
    padding: AppSpacing.allLG,
    child: Column(
      children: [
        Text(
          '标题',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SizedBox(height: AppSpacing.sm),
        Text(
          '内容',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  ),
)
```

### 12.2 扁平化按钮

```dart
Row(
  children: [
    ElevatedButton(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: AppSpacing.symmetric(horizontalLG, verticalMD),
      ),
      onPressed: () {},
      child: Text('确定'),
    ),
    SizedBox(width: AppSpacing.sm),
    OutlinedButton(
      style: OutlinedButton.styleFrom(
        elevation: 0,
        padding: AppSpacing.symmetric(horizontalLG, verticalMD),
      ),
      onPressed: () {},
      child: Text('取消'),
    ),
  ],
)
```

### 12.3 状态指示

```dart
// 成功状态
Container(
  padding: AppSpacing.allSM,
  decoration: BoxDecoration(
    color: AppColors.successLight,
    borderRadius: AppRadius.allSM,
    border: Border.all(
      color: AppColors.success,
      width: 1,
    ),
  ),
  child: Row(
    children: [
      Icon(Icons.check_circle, size: 16, color: AppColors.success),
      SizedBox(width: AppSpacing.xs),
      Text('成功', style: AppTypography.labelMedium),
    ],
  ),
)
```

---

## 13. 常见组件模板

### 13.1 空状态

```dart
Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        Icons.inbox,
        size: 64,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      SizedBox(height: AppSpacing.lg),
      Text(
        '暂无内容',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      SizedBox(height: AppSpacing.sm),
      Text(
        '点击下方按钮添加',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  ),
)
```

### 13.2 加载状态

```dart
Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      CircularProgressIndicator(),
      SizedBox(height: AppSpacing.md),
      Text(
        '加载中...',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  ),
)
```

### 13.3 错误状态

```dart
Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        Icons.error_outline,
        size: 64,
        color: AppColors.error,
      ),
      SizedBox(height: AppSpacing.lg),
      Text(
        '加载失败',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      SizedBox(height: AppSpacing.sm),
      Text(
        errorMessage,
        style: Theme.of(context).textTheme.bodyMedium,
        textAlign: TextAlign.center,
      ),
      SizedBox(height: AppSpacing.lg),
      ElevatedButton(
        onPressed: retry,
        child: Text('重试'),
      ),
    ],
  ),
)
```

---

## 14. 检查清单

### 14.1 UI 设计检查

- [ ] 卡片无阴影（elevation: 0）
- [ ] 使用系统动态色
- [ ] 暗黑模式正确适配
- [ ] 边框使用 outlineVariant
- [ ] 间距符合 4px 网格
- [ ] 圆角使用设计令牌
- [ ] 按钮无阴影
- [ ] AppBar 无滚动阴影
- [ ] 文字使用语义化颜色
- [ ] 状态颜色使用正确

### 14.2 代码质量检查

- [ ] 无硬编码颜色值
- [ ] 无硬编码字号
- [ ] 无硬编码间距
- [ ] 无硬编码圆角
- [ ] 使用 Theme.of(context) 获取主题
- [ ] 响应式设计适配暗黑模式

---

## 15. 弹框设计规范

### 15.1 Dialog（对话框）

#### 设计规范

```dart
// 标准对话框
Dialog(
  elevation: 0,
  backgroundColor: theme.colorScheme.dialogSurface,
  shape: RoundedRectangleBorder(
    borderRadius: AppRadius.allXL,  // 20px
    side: BorderSide(
      color: theme.colorScheme.borderLight,
      width: 1,
    ),
  ),
  insetPadding: AppSpacing.horizontalLG,  // 16px
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: 400),
    child: Padding(
      padding: AppSpacing.allXL,  // 20px
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [...],
      ),
    ),
  ),
)
```

#### 对话框结构

```
┌─────────────────────────────┐
│ 20px padding                │
│                             │
│  [Icon] (可选)              │
│                             │
│  标题 (titleLarge)          │
│  12px spacing               │
│  内容 (bodyMedium)          │
│  24px spacing               │
│  [操作按钮]                 │
│                             │
└─────────────────────────────┘
```

#### 按钮布局

```dart
// 双按钮 - 右对齐
Row(
  mainAxisAlignment: MainAxisAlignment.end,
  children: [
    TextButton('取消'),
    SizedBox(width: AppSpacing.sm),
    FilledButton('确定'),
  ],
)

// 单按钮 - 居中
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    FilledButton('确定'),
  ],
)
```

### 15.2 Snackbar（消息提示）

#### 设计规范

```dart
Get.snackbar(
  '',  // 标题为空，使用自定义内容
  '',  // 内容为空，使用自定义内容
  backgroundColor: theme.colorScheme.surface,
  borderRadius: AppRadius.allMD,  // 12px
  boxShadows: [],
  margin: AppSpacing.allLG,
  padding: AppSpacing.allMD,  // 12px
  snackPosition: SnackPosition.BOTTOM,
  duration: const Duration(seconds: 3),
  animationDuration: AppAnimations.durationNormal,
  forwardAnimationCurve: Curves.easeOutCubic,
  reverseAnimationCurve: Curves.easeInCubic,
  barBlur: 0,
  blockBackgroundInteraction: false,
  titleText: Text(
    '标题',
    style: theme.textTheme.titleSmall,
  ),
  messageText: Text(
    '内容',
    style: theme.textTheme.bodySmall,
  ),
  // 使用自定义内容
  snackStyle: SnackStyle.GROUNDED,
  colorText: theme.colorScheme.onSurface,
  leftBarIndicatorColor: theme.colorScheme.primary,
)
```

#### Snackbar 类型

| 类型 | 图标 | 左侧指示条颜色 |
|------|------|---------------|
| 成功 | check_circle | success (绿色) |
| 错误 | error | error (红色) |
| 警告 | warning | warning (橙色) |
| 信息 | info | info (蓝色) |

### 15.3 BottomSheet（底部弹窗）

#### 设计规范

```dart
Get.bottomSheet(
  Container(
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.only(
        topLeft: AppRadius.allXXL,  // 24px
        topRight: AppRadius.allXXL,
      ),
      border: Border(
        top: BorderSide(
          color: theme.colorScheme.borderLight,
          width: 1,
        ),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 拖拽指示器
        Container(
          margin: AppSpacing.verticalMD,
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: theme.colorScheme.outlineVariant,
            borderRadius: AppRadius.allXS,
          ),
        ),
        // 内容
        Padding(
          padding: AppSpacing.allLG,
          child: [...],
        ),
      ],
    ),
  ),
  backgroundColor: Colors.transparent,
  isDismissible: true,
  enableDrag: true,
  isScrollControlled: true,
)
```

#### BottomSheet 结构

```
┌─────────────────────────────┐
│  ━━  (拖拽指示器)            │
├─────────────────────────────┤
│ 16px padding                │
│                             │
│  标题 (titleLarge)          │
│  12px spacing               │
│  内容 (bodyMedium)          │
│  16px padding               │
│                             │
└─────────────────────────────┘
```

### 15.4 Alert（确认对话框）

#### 设计规范

```dart
// Alert 是 Dialog 的特殊形式，带有确认/取消操作
Dialog(
  elevation: 0,
  backgroundColor: theme.colorScheme.dialogSurface,
  shape: RoundedRectangleBorder(
    borderRadius: AppRadius.allXL,
    side: BorderSide(
      color: theme.colorScheme.borderLight,
      width: 1,
    ),
  ),
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: 400),
    child: Padding(
      padding: AppSpacing.allXL,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 图标（可选）
          if (icon != null) ...[
            Icon(icon, size: 48, color: iconColor),
            SizedBox(height: AppSpacing.lg),
          ],
          // 标题
          Text(
            title,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: AppSpacing.md),
          // 内容
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: AppSpacing.xxl),
          // 操作按钮
          Row(...),
        ],
      ),
    ),
  ),
)
```

#### Alert 类型

| 类型 | 图标 | 颜色 |
|------|------|------|
| 成功 | check_circle | success |
| 错误 | error | error |
| 警告 | warning | warning |
| 信息 | info | info |
| 确认 | help_outline | primary |

### 15.5 弹框通用原则

#### 显示时机

```
✅ 使用 Dialog：
- 需要用户确认的操作
- 重要的系统通知
- 表单输入
- 多步骤操作

✅ 使用 Snackbar：
- 轻量级通知
- 操作成功/失败反馈
- 非阻塞提示
- 短暂的信息展示

✅ 使用 BottomSheet：
- 选择列表
- 简单表单
- 从底部滑出的内容
- 移动端友好的交互

✅ 使用 Alert：
- 删除确认
- 重要操作警告
- 破坏性操作确认
- 系统级通知
```

#### 动画规范

| 弹框类型 | 进入动画 | 退出动画 | 时长 |
|---------|---------|---------|------|
| Dialog | fadeIn | fadeOut | 300ms |
| Snackbar | slideUp + fadeIn | slideDown + fadeOut | 300ms |
| BottomSheet | slideUp | slideDown | 400ms |
| Alert | scale + fadeIn | scale + fadeOut | 300ms |

#### 尺寸限制

| 弹框类型 | 最大宽度 | 内边距 |
|---------|---------|--------|
| Dialog | 400px | 20px |
| Alert | 400px | 20px |
| Snackbar | 无限制 | 12px |
| BottomSheet | 100% | 16px |

#### 文字规范

| 元素 | 字体样式 | 字号 | 字重 |
|------|---------|------|------|
| 标题 | titleLarge | 22sp | w600 |
| 内容 | bodyMedium | 14sp | w400 |
| 按钮 | labelLarge | 14sp | w500 |

### 15.6 使用统一组件

```dart
// 推荐使用 AppDialogs 统一封装
import 'package:gstore/core/design/design_tokens.dart';

// 显示 Dialog
await AppDialogs.showDialog(
  title: '标题',
  content: '内容',
  confirmText: '确定',
  onConfirm: () {},
);

// 显示 Snackbar
AppDialogs.showSuccess('操作成功');
AppDialogs.showError('操作失败');
AppDialogs.showWarning('警告信息');
AppDialogs.showInfo('提示信息');

// 显示 BottomSheet
await AppDialogs.showBottomSheet(
  title: '选择',
  children: [...],
);

// 显示 Alert
final confirmed = await AppDialogs.showConfirmDialog(
  title: '确认删除？',
  message: '此操作无法撤销',
  confirmText: '删除',
  isDangerous: true,
);
```

---

## 16. 快速参考

### 16.1 常用组合

| 组件 | 内边距 | 圆角 | 阴影 |
|------|--------|------|------|
| 标准卡片 | 16px | 16px | 0 |
| 紧凑卡片 | 12px | 12px | 0 |
| 对话框 | 20px | 20px | 0 |
| 按钮 | 12px 水平 | 8px | 0 |
| 列表项 | 16px 水平，8px 垂直 | 12px | 0 |

### 16.2 颜色映射

| 用途 | 亮色模式 | 暗黑模式 |
|------|---------|---------|
| 背景色 | surfaceContainerLowest | surface |
| 卡片色 | surface | surfaceContainerLow |
| 边框色 | outlineVariant (50%) | outlineVariant (30%) |
| 主要文字 | onSurface | onSurface |
| 次要文字 | onSurfaceVariant (70%) | onSurfaceVariant (70%) |
| 辅助文字 | onSurfaceVariant (50%) | onSurfaceVariant (50%) |

### 16.3 弹框快速参考

| 组件 | 圆角 | 边框 | 内边距 |
|------|------|------|--------|
| Dialog | 20px | 细边框 | 20px |
| Snackbar | 12px | 无 | 12px |
| BottomSheet | 24px(顶) | 顶边框 | 16px |
| Alert | 20px | 细边框 | 20px |

---

最后更新：2024-03-18
