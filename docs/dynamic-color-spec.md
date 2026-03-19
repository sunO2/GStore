# GStore 动态色规范

## 概述

本文档定义了 GStore 应用的**动态色（Dynamic Color）**系统规范，确保应用能够根据用户壁纸自动适配主题色，提供一致且个性化的视觉体验。

---

## 1. 动态色系统

### 1.1 核心概念

**动态色**是 Material 3 引入的色彩系统，能够从用户壁纸中提取主要颜色，并自动生成完整的调色板。

```
用户壁纸 → 提取主色 → 生成调色板 → 应用主题
```

### 1.2 工作原理

1. **颜色提取**：从壁纸中提取 5 个关键颜色
   - Primary（主色）
   - Secondary（次要色）
   - Tertiary（第三色）
   - Error（错误色）
   - Neutral（中性色）

2. **调色板生成**：为每个关键色生成完整色调
   - 生成 13 个色调等级（从 10 到 100）
   - 生成亮色和暗色两个变体

3. **语义化映射**：将调色板映射到 UI 组件
   - 背景色、容器色
   - 文字色
   - 边框色
   - 状态色

### 1.3 技术实现

使用 `dynamic_color` 包：

```dart
DynamicColorBuilder(
  builder: (lightDynamic, darkDynamic) {
    return MaterialApp(
      theme: ThemeDataBuilder.buildLightTheme(lightDynamic),
      darkTheme: ThemeDataBuilder.buildDarkTheme(darkDynamic),
      themeMode: ThemeMode.system,
    );
  },
)
```

---

## 2. ColorScheme 结构

### 2.1 核心调色板

| 调色板 | 说明 | 亮色模式 | 暗色模式 |
|--------|------|---------|---------|
| **primary** | 主色调 | 中等亮度 | 高饱和度 |
| **onPrimary** | 主色上的文字/图标 | 白色 | 深色 |
| **primaryContainer** | 主色容器 | 淡色 | 深色 |
| **onPrimaryContainer** | 主色容器上的文字 | 深色 | 浅色 |
| **secondary** | 次要色调 | 中等亮度 | 高饱和度 |
| **onSecondary** | 次要色上的文字 | 白色 | 深色 |
| **secondaryContainer** | 次要色容器 | 淡色 | 深色 |
| **onSecondaryContainer** | 次要色容器上的文字 | 深色 | 浅色 |
| **tertiary** | 第三色调 | 中等亮度 | 高饱和度 |
| **onTertiary** | 第三色上的文字 | 白色 | 深色 |
| **tertiaryContainer** | 第三色容器 | 淡色 | 深色 |
| **onTertiaryContainer** | 第三色容器上的文字 | 深色 | 浅色 |
| **error** | 错误色 | 红色 | 红色 |
| **onError** | 错误色上的文字 | 白色 | 深色 |
| **errorContainer** | 错误容器 | 淡红色 | 深红色 |
| **onErrorContainer** | 错误容器上的文字 | 深红色 | 浅红色 |

### 2.2 中性色系

| 调色板 | 说明 | 用途 |
|--------|------|------|
| **background** | 背景色 | 页面背景 |
| **onBackground** | 背景上的文字 | 主要文字 |
| **surface** | 表面色 | 卡片、对话框 |
| **onSurface** | 表面上的文字 | 卡片文字 |
| **surfaceVariant** | 表面变体 | 次要表面 |
| **onSurfaceVariant** | 表面变体上的文字 | 次要文字 |
| **outline** | 轮廓色 | 边框、分割线 |
| **outlineVariant** | 轮廓变体 | 淡边框 |
| **shadow** | 阴影色 | 阴影 |
| **scrim** | 遮罩色 | 模态遮罩 |
| **inverseSurface** | 反转表面 | 反转背景 |
| **onInverseSurface** | 反转表面上的文字 | 反转文字 |
| **inversePrimary** | 反转主色 | 反转主色 |

### 2.3 容器色系（按深度排序）

| 容器色 | 亮色模式 | 暗色模式 | 使用场景 |
|--------|---------|---------|----------|
| **surfaceContainerLowest** | 最浅 | 最深 | 背景层 |
| **surfaceContainerLow** | 浅 | 深 | 次背景 |
| **surfaceContainer** | 中等 | 中等 | 标准容器 |
| **surfaceContainerHigh** | 深 | 浅 | 重要容器 |
| **surfaceContainerHighest** | 最深 | 最浅 | 输入框等 |

---

## 3. 使用规范

### 3.1 组件配色规则

```
✅ 推荐做法：
- 使用 Theme.of(context).colorScheme 获取颜色
- 根据组件功能选择合适的色系
- 优先使用容器色作为背景
- 使用对应的 on* 颜色作为文字色

❌ 避免问题：
- 硬编码颜色值
- 直接使用 Colors.xxx
- 混用不同色系
- 忽略亮暗模式差异
```

### 3.2 配色决策树

```
需要上色？
├─ 背景色
│  ├─ 页面背景 → surfaceContainerLowest / surface
│  ├─ 卡片 → surface / surfaceContainerLow
│  ├─ 对话框 → surface / surfaceContainerLow
│  └─ 输入框 → surfaceContainerHighest
│
├─ 文字色
│  ├─ 主要文字 → onSurface / onSurfaceVariant
│  ├─ 次要文字 → onSurfaceVariant (70%)
│  └─ 辅助文字 → onSurfaceVariant (50%)
│
├─ 交互色
│  ├─ 主要操作 → primary / onPrimary
│  ├─ 次要操作 → secondary / onSecondary
│  └─ 强调操作 → tertiary / onTertiary
│
├─ 边框色
│  ├─ 标准边框 → outline
│  └─ 淡边框 → outlineVariant (30-50%)
│
└─ 状态色
   ├─ 成功 → primary（绿色调）
   ├─ 错误 → error
   ├─ 警告 → tertiary（橙色调）
   └─ 信息 → secondary（蓝色调）
```

### 3.3 透明度规范

| 场景 | 透明度 | 示例 |
|------|--------|------|
| 边框（亮色） | 50% | `outline.withOpacity(0.5)` |
| 边框（暗色） | 30% | `outline.withOpacity(0.3)` |
| 遮罩 | 32% | `scrim.withOpacity(0.32)` |
| 禁用状态 | 38% | `onSurface.withOpacity(0.38)` |
| 悬停状态 | 8% | `primary.withOpacity(0.08)` |
| 焦点状态 | 12% | `primary.withOpacity(0.12)` |
| 按下状态 | 16% | `primary.withOpacity(0.16)` |

---

## 4. 代码示例

### 4.1 获取动态色

```dart
// ✅ 正确：从主题获取
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      color: colorScheme.surface,           // 卡片背景
      child: Text(
        'Hello',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurface,      // 文字颜色
        ),
      ),
    );
  }
}

// ❌ 错误：硬编码颜色
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,  // 不适应动态色
      child: Text(
        'Hello',
        style: TextStyle(color: Colors.black),
      ),
    );
  }
}
```

### 4.2 卡片配色

```dart
Card(
  elevation: 0,
  color: theme.colorScheme.surface,
  shape: RoundedRectangleBorder(
    borderRadius: AppRadius.allLG,
    side: BorderSide(
      color: theme.colorScheme.outlineVariant.withOpacity(0.5),
      width: 1,
    ),
  ),
  child: Padding(
    padding: AppSpacing.allLG,
    child: Column(
      children: [
        Text(
          '标题',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        Text(
          '次要信息',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  ),
)
```

### 4.3 按钮配色

```dart
// 主要按钮
ElevatedButton(
  style: ElevatedButton.styleFrom(
    elevation: 0,
    backgroundColor: theme.colorScheme.primary,
    foregroundColor: theme.colorScheme.onPrimary,
  ),
  onPressed: () {},
  child: Text('确定'),
)

// 次要按钮
OutlinedButton(
  style: OutlinedButton.styleFrom(
    elevation: 0,
    foregroundColor: theme.colorScheme.primary,
    side: BorderSide(
      color: theme.colorScheme.outline,
      width: 1,
    ),
  ),
  onPressed: () {},
  child: Text('取消'),
)
```

### 4.4 输入框配色

```dart
TextField(
  decoration: InputDecoration(
    filled: true,
    fillColor: theme.colorScheme.surfaceContainerHighest,
    border: OutlineInputBorder(
      borderRadius: AppRadius.allMD,
      borderSide: BorderSide(
        color: theme.colorScheme.outline,
        width: 1,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: AppRadius.allMD,
      borderSide: BorderSide(
        color: theme.colorScheme.primary,
        width: 2,
      ),
    ),
    hintStyle: theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  ),
)
```

### 4.5 状态指示

```dart
// 成功状态
Container(
  padding: AppSpacing.allSM,
  decoration: BoxDecoration(
    color: theme.colorScheme.primaryContainer.withOpacity(0.5),
    borderRadius: AppRadius.allSM,
    border: Border.all(
      color: theme.colorScheme.primary.withOpacity(0.5),
      width: 1,
    ),
  ),
  child: Row(
    children: [
      Icon(
        Icons.check_circle,
        size: 16,
        color: theme.colorScheme.primary,
      ),
      SizedBox(width: AppSpacing.xs),
      Text(
        '成功',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    ],
  ),
)

// 错误状态
Container(
  padding: AppSpacing.allSM,
  decoration: BoxDecoration(
    color: theme.colorScheme.errorContainer.withOpacity(0.5),
    borderRadius: AppRadius.allSM,
  ),
  child: Row(
    children: [
      Icon(
        Icons.error,
        size: 16,
        color: theme.colorScheme.error,
      ),
      SizedBox(width: AppSpacing.xs),
      Text(
        '错误',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    ],
  ),
)
```

---

## 5. 兼容性处理

### 5.1 回退方案

当动态色不可用时（如旧版 Android），使用预设种子颜色：

```dart
ColorScheme getColorScheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: Colors.blue,  // 默认种子色
    brightness: brightness,
  );
}
```

### 5.2 测试用颜色

为了确保适配效果，建议使用不同色调的壁纸测试：

| 色调 | 种子色 |
|------|--------|
| 蓝色 | `Colors.blue` |
| 绿色 | `Colors.green` |
| 红色 | `Colors.red` |
| 紫色 | `Colors.purple` |
| 橙色 | `Colors.orange` |

---

## 6. 最佳实践

### 6.1 设计原则

```
✅ 必须遵守：
- 所有 UI 组件使用动态色
- 文字颜色与背景颜色成对使用（surface + onSurface）
- 边框使用 outline 或 outlineVariant
- 适配亮色和暗色两种主题
- 测试不同壁纸下的显示效果

❌ 绝对禁止：
- 硬编码颜色值
- 使用不匹配的文字/背景组合
- 忽略暗黑模式
- 使用过时的 Material 2 颜色
```

### 6.2 性能优化

- 避免在 build 方法中重复获取 Theme.of(context)
- 缓存常用的颜色和样式
- 使用 const 构造函数减少重建

```dart
class MyWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // ✅ 缓存主题
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Container(
      color: colorScheme.surface,
      child: Text('Hello', style: textTheme.bodyLarge),
    );
  }
}
```

### 6.3 调试技巧

在开发时可以强制使用特定色调测试：

```dart
// 临时：强制使用绿色调
ColorScheme getColorScheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: Colors.green,
    brightness: brightness,
  );
}
```

---

## 7. 检查清单

### 7.1 动态色适配检查

- [ ] 所有组件使用 `Theme.of(context).colorScheme`
- [ ] 文字使用对应的 `on*` 颜色
- [ ] 背景使用容器色（surfaceContainer*）
- [ ] 边框使用 outline 或 outlineVariant
- [ ] 按钮使用 primary/secondary/tertiary
- [ ] 状态使用 error 或对应色调
- [ ] 亮色主题显示正常
- [ ] 暗色主题显示正常
- [ ] 不同壁纸下颜色协调
- [ ] 无硬编码颜色值

### 7.2 组件检查

| 组件 | 检查项 |
|------|--------|
| Card | 使用 surface，onSurface 用于文字 |
| Button | primary/onPrimary 或 outline |
| TextField | surfaceContainerHighest，outline 边框 |
| Dialog | surface，圆角，细边框 |
| Chip | surfaceContainerHighest |
| Snackbar | surfaceContainerHigh |
| BottomSheet | surfaceContainerLow |
| Divider | outlineVariant |
| AppBar | surface，无阴影 |

---

## 8. 常见问题

### Q1: 如何在非 Widget 中获取颜色？

使用 `AppColors` 中的语义化颜色，它们会适配主题：

```dart
// 语义化颜色（自动适配主题）
Text('主要文字', style: TextStyle(color: AppColors.textPrimary))
Text('次要文字', style: TextStyle(color: AppColors.textSecondary))
```

### Q2: 如何自定义某些颜色而不破坏动态色？

使用 `ThemeData` 的 `copyWith` 方法：

```dart
theme.copyWith(
  colorScheme: theme.colorScheme.copyWith(
    primary: customColor,  // 自定义主色
  ),
)
```

### Q3: 如何确保暗黑模式正常工作？

- 使用 `Theme.of(context).brightness` 判断模式
- 测试两种模式下的显示效果
- 使用 `colorScheme.brightness` 而非硬编码

---

## 9. 快速参考

### 9.1 常用颜色映射

| 用途 | 亮色模式 | 暗色模式 |
|------|---------|---------|
| 背景色 | surfaceContainerLowest | surface |
| 卡片色 | surface | surfaceContainerLow |
| 对话框色 | surface | surfaceContainerLow |
| 输入框色 | surfaceContainerHighest | surfaceContainerHighest |
| 主要文字 | onSurface | onSurface |
| 次要文字 | onSurfaceVariant (70%) | onSurfaceVariant (70%) |
| 标准边框 | outline (50%) | outline (30%) |
| 淡边框 | outlineVariant (50%) | outlineVariant (30%) |

### 9.2 颜色选择速查

```
需要背景色？
├─ 最淡 → surfaceContainerLowest
├─ 淡 → surfaceContainerLow
├─ 标准 → surface
├─ 深 → surfaceContainerHigh
└─ 最深 → surfaceContainerHighest

需要文字色？
├─ 主要 → onSurface
├─ 次要 → onSurfaceVariant
└─ 辅助 → onSurfaceVariant.withOpacity(0.6)

需要强调色？
├─ 主要 → primary
├─ 次要 → secondary
├─ 第三 → tertiary
└─ 错误 → error

需要边框色？
├─ 标准 → outline
└─ 淡 → outlineVariant
```

---

最后更新：2024-03-18
