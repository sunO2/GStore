# 主题系统使用指南

## 概述

GStore 的设计规范已完全集成到 Flutter 主题系统中。所有文字样式、颜色都会**自动适配亮色/暗色主题**，无需手动硬编码。

---

## 核心原则

### ✅ 正确做法：使用 Theme.of(context)

```dart
// 文字样式 - 自动适配主题
Text('应用名称', style: Theme.of(context).textTheme.titleMedium)
Text('应用描述', style: Theme.of(context).textTheme.bodyMedium)

// 颜色 - 自动适配主题
Container(color: Theme.of(context).colorScheme.primary)
Text('文字', style: TextStyle(color: Theme.of(context).colorScheme.onSurface))
```

### ❌ 错误做法：硬编码样式

```dart
// 不要这样！不会自动适配主题
Text('应用名称', style: AppTypography.titleMedium)
Text('应用描述', style: TextStyle(color: AppColors.textSecondary))
Container(color: Colors.blue)
```

---

## 文字样式映射表

| 使用场景 | 主题样式 | 字号 | 字重 | 自动颜色 |
|---------|---------|------|------|---------|
| **应用名称（列表）** | `titleMedium` | 16 | Medium | 主要文字 |
| **应用描述** | `bodyMedium` | 14 | Regular | 次要文字 |
| **卡片标题** | `titleLarge` | 16 | SemiBold | 主要文字 |
| **小标题** | `titleSmall` | 14 | Medium | 主要文字 |
| **正文内容** | `bodyLarge` | 16 | Regular | 主要文字 |
| **按钮文字** | `labelLarge` | 14 | Medium | Surface |
| **标签文字** | `labelMedium` | 12 | Medium | 辅助文字 |
| **小标签** | `labelSmall` | 11 | Medium | 辅助文字 |
| **页面标题** | `headlineLarge` | 20 | SemiBold | Surface |
| **章节标题** | `headlineMedium` | 18 | SemiBold | Surface |

### 亮色模式颜色
- 主要文字：`#212121` (深灰)
- 次要文字：`#757575` (中灰)
- 辅助文字：`#9E9E9E` (浅灰)

### 暗色模式颜色
- 主要文字：`#FFFFFF` (白色)
- 次要文字：`#B2FFFFFF` (70% 白)
- 辅助文字：`#80FFFFFF` (50% 白)

---

## 常见使用场景

### 1. 应用列表项

```dart
// ✅ 正确
ListTile(
  title: Text(
    app.name,
    style: Theme.of(context).textTheme.titleMedium,
  ),
  subtitle: Text(
    app.des,
    style: Theme.of(context).textTheme.bodyMedium,
  ),
)

// ❌ 错误
ListTile(
  title: Text(
    app.name,
    style: AppTypography.titleMedium.copyWith(
      color: AppColors.textPrimary,
    ),
  ),
  subtitle: Text(
    app.des,
    style: TextStyle(
      fontSize: 14,
      color: Colors.grey[600],
    ),
  ),
)
```

### 2. 详情页

```dart
// ✅ 正确
Column(
  children: [
    Text(
      detail.name,
      style: Theme.of(context).textTheme.headlineSmall,
    ),
    SizedBox(height: 8),
    Text(
      detail.description,
      style: Theme.of(context).textTheme.bodyLarge,
    ),
  ],
)

// ❌ 错误
Column(
  children: [
    Text(
      detail.name,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      ),
    ),
    SizedBox(height: 8),
    Text(
      detail.description,
      style: TextStyle(
        fontSize: 14,
        color: Colors.grey[600],
      ),
    ),
  ],
)
```

### 3. 标签和徽章

```dart
// ✅ 正确
Chip(
  label: Text(
    version,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    ),
  ),
)

// ❌ 错误
Container(
  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  decoration: BoxDecoration(
    color: Colors.blue.withAlpha(130),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Text(
    version,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Colors.white,
    ),
  ),
)
```

### 4. 按钮

```dart
// ✅ 正确 - 使用主题按钮样式
ElevatedButton(
  onPressed: () {},
  child: Text('下载'),
)

// ❌ 错误 - 自定义样式
ElevatedButton(
  onPressed: () {},
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blue,
    foregroundColor: Colors.white,
    padding: EdgeInsets.symmetric(horizontal: 16),
  ),
  child: Text(
    '下载',
    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
  ),
)
```

---

## 颜色使用

### 语义化颜色

```dart
// ✅ 使用主题颜色
Theme.of(context).colorScheme.primary        // 主色
Theme.of(context).colorScheme.secondary      // 次要色
Theme.of(context).colorScheme.error          // 错误色
Theme.of(context).colorScheme.surface        // 表面色
Theme.of(context).colorScheme.onSurface      // 表面上的文字
Theme.of(context).colorScheme.primaryContainer // 主色容器
Theme.of(context).colorScheme.onPrimaryContainer // 主色容器上的文字

// ❌ 硬编码颜色
Colors.blue
Color(0xFF2196F3)
AppColors.primary
```

### 文字颜色

```dart
// ✅ 使用 TextTheme（已包含正确的颜色）
Theme.of(context).textTheme.titleMedium  // 包含主要文字颜色
Theme.of(context).textTheme.bodyMedium   // 包含次要文字颜色
Theme.of(context).textTheme.labelMedium  // 包含辅助文字颜色

// 需要自定义颜色时，使用 ColorScheme
TextStyle(
  color: Theme.of(context).colorScheme.onSurface,
)
TextStyle(
  color: Theme.of(context).colorScheme.primary,
)
```

---

## Material 内置组件

以下组件会**自动使用主题样式**，无需额外设置：

### 自动适配的组件

```dart
// 这些组件会自动使用主题中定义的样式
AppBar()           // 自动使用 appBarTheme
Card()            // 自动使用 cardTheme
ListTile()        // 自动使用 listTileTheme
ElevatedButton()  // 自动使用 elevatedButtonTheme
TextButton()      // 自动使用 textButtonTheme
OutlinedButton()  // 自动使用 outlinedButtonTheme
TextField()       // 自动使用 inputDecorationTheme
Dialog()          // 自动使用 dialogTheme
BottomSheet()     // 自动使用 bottomSheetTheme
NavigationBar()   // 自动使用 navigationBarTheme
Chip()            // 自动使用 chipTheme
SnackBar()        // 自动使用 snackBarTheme
```

### 示例

```dart
// ✅ 简洁写法 - 自动使用主题样式
AppBar(
  title: Text('标题'),
  backgroundColor: Colors.transparent, // 会自动使用主题的 surface 色
)

ElevatedButton(
  onPressed: () {},
  child: Text('按钮'),
)

TextField(
  decoration: InputDecoration(
    hintText: '请输入...',
  ),
)
```

---

## 响应式主题切换

当用户切换主题时，使用 `Theme.of(context)` 的所有组件会**自动更新**，无需任何额外代码：

```dart
// 这个组件会自动响应主题变化
Text(
  '自动适配主题',
  style: Theme.of(context).textTheme.titleMedium,
)
```

---

## 自定义样式扩展

如果需要基于主题样式进行微调，使用 `copyWith`：

```dart
// ✅ 基于主题样式扩展
Text(
  '自定义样式',
  style: Theme.of(context).textTheme.titleMedium?.copyWith(
    color: Theme.of(context).colorScheme.primary, // 使用主题色
    fontSize: 18, // 调整大小
  ),
)

// ❌ 完全自定义
Text(
  '自定义样式',
  style: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: Colors.blue,
  ),
)
```

---

## 检查清单

在 Code Review 时，检查以下要点：

- [ ] 所有文字使用 `Theme.of(context).textTheme.*`
- [ ] 所有颜色使用 `Theme.of(context).colorScheme.*`
- [ ] 没有硬编码 `Colors.*`
- [ ] 没有硬编码 `Color(0xFF...)`
- [ ] 没有硬编码 `fontSize: 数字`
- [ ] 没有硬编码 `fontWeight: FontWeight.*`
- [ ] 使用 Material 内置组件（AppBar、Card、ListTile 等）

---

## 迁移指南

### 从硬编码迁移到主题

#### 迁移前
```dart
Text(
  '应用名称',
  style: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Colors.black,
  ),
)
```

#### 迁移后
```dart
Text(
  '应用名称',
  style: Theme.of(context).textTheme.titleMedium,
)
```

### 批量替换

使用以下正则表达式进行批量替换：

| 查找 | 替换为 |
|------|--------|
| `TextStyle(fontSize: 16, fontWeight: FontWeight.w600)` | `Theme.of(context).textTheme.titleMedium` |
| `TextStyle(fontSize: 14, fontWeight: FontWeight.w500)` | `Theme.of(context).textTheme.titleSmall` |
| `TextStyle(fontSize: 14)` | `Theme.of(context).textTheme.bodyMedium` |
| `TextStyle(fontSize: 12)` | `Theme.of(context).textTheme.bodySmall` |
| `color: Colors.black` | `color: Theme.of(context).colorScheme.onSurface` |
| `color: Colors.grey\[600\]` | `color: Theme.of(context).colorScheme.onSurfaceVariant` |

---

## 总结

### 记住这三点

1. **文字样式用 TextTheme**
   ```dart
   Theme.of(context).textTheme.titleMedium
   ```

2. **颜色用 ColorScheme**
   ```dart
   Theme.of(context).colorScheme.primary
   ```

3. **组件用 Material 内置**
   ```dart
   AppBar、Card、ListTile、ElevatedButton...
   ```

### 优势

- ✅ 自动适配亮色/暗色主题
- ✅ 零硬编码
- ✅ 统一视觉风格
- ✅ 易于维护
- ✅ 支持主题热切换

---

更新日期：2024-03-17
