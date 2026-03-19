# 主题系统重构对比

## 改进前后对比

### ❌ 改进前：硬编码样式

```dart
// 每个地方都需要硬编码颜色和样式
Text(
  app.name,
  style: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Colors.black,
  ),
)

Text(
  app.des,
  style: TextStyle(
    fontSize: 14,
    color: Colors.grey[600],
  ),
)

Container(
  color: Colors.blue.withAlpha(130),
  child: Text(
    '标签',
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Colors.white,
    ),
  ),
)
```

**问题：**
- ❌ 颜色硬编码，不会自动适配暗色主题
- ❌ 样式分散，难以统一修改
- ❌ 需要手动处理主题切换
- ❌ 代码冗余，到处都是相同的样式定义

---

### ✅ 改进后：使用主题系统

```dart
// 简洁、统一、自动适配主题
Text(
  app.name,
  style: Theme.of(context).textTheme.titleMedium,
)

Text(
  app.des,
  style: Theme.of(context).textTheme.bodyMedium,
)

Chip(
  label: Text(
    '标签',
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    ),
  ),
)
```

**优势：**
- ✅ 自动适配亮色/暗色主题
- ✅ 样式集中管理，易于维护
- ✅ 代码简洁，减少重复
- ✅ 符合 Material Design 规范

---

## 架构对比

### 改进前

```
┌─────────────────────────────────────┐
│         组件（硬编码样式）            │
├─────────────────────────────────────┤
│  AppTypography（静态常量）            │
│  AppColors（静态常量）                │
├─────────────────────────────────────┤
│         ThemeData（部分主题）          │
└─────────────────────────────────────┘
```

**问题：**
- AppTypography 和 AppColors 是独立的静态常量
- 与 Theme.of(context) 脱节
- 无法自动响应主题变化
- 需要手动指定颜色

### 改进后

```
┌─────────────────────────────────────┐
│      组件（Theme.of(context)）       │
├─────────────────────────────────────┤
│    ThemeData（完整的主题定义）        │
│  ├─ TextTheme（文字样式 + 颜色）      │
│  ├─ ColorScheme（主题色）             │
│  └─ Component Themes（组件主题）      │
├─────────────────────────────────────┤
│    AppTypography（设计令牌）          │
│    AppColors（设计令牌）              │
└─────────────────────────────────────┘
```

**改进：**
- 设计令牌（AppTypography/AppColors）作为 Theme 的基础
- Theme 集成了完整的文字样式和颜色
- 组件通过 Theme.of(context) 获取，自动适配
- 层次清晰，职责分明

---

## 文字样式对比

### 改进前：需要手动指定颜色

```dart
// 应用名称
Text(
  app.name,
  style: AppTypography.titleMedium.copyWith(
    color: AppColors.textPrimary, // 需要手动指定
  ),
)

// 应用描述
Text(
  app.des,
  style: AppTypography.bodyMedium.copyWith(
    color: AppColors.textSecondary, // 需要手动指定
  ),
)

// 标签
Text(
  tag,
  style: AppTypography.labelMedium.copyWith(
    color: AppColors.textTertiary, // 需要手动指定
  ),
)
```

### 改进后：颜色已内置

```dart
// 应用名称
Text(
  app.name,
  style: Theme.of(context).textTheme.titleMedium,
  // 颜色已内置：亮色 #212121，暗色 #FFFFFF
)

// 应用描述
Text(
  app.des,
  style: Theme.of(context).textTheme.bodyMedium,
  // 颜色已内置：亮色 #757575，暗色 #B2FFFFFF
)

// 标签
Text(
  tag,
  style: Theme.of(context).textTheme.labelMedium,
  // 颜色已内置：亮色 #9E9E9E，暗色 #80FFFFFF
)
```

---

## 主题适配对比

### 改进前：手动处理主题

```dart
Widget _buildText(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;

  return Text(
    '标题',
    style: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: isDark ? Colors.white : Colors.black, // 手动判断
    ),
  );
}
```

### 改进后：自动适配

```dart
Widget _buildText(BuildContext context) {
  return Text(
    '标题',
    style: Theme.of(context).textTheme.titleMedium,
    // 自动使用正确的颜色，无需手动判断
  );
}
```

---

## 代码量对比

### 示例：应用列表项

#### 改进前（需要 25 行）

```dart
ListTile(
  title: Text(
    app.name,
    style: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: Colors.black,
      height: 1.5,
      letterSpacing: 0,
    ),
  ),
  subtitle: Text(
    app.des,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: Colors.grey[600],
      height: 1.5,
      letterSpacing: 0,
    ),
  ),
  trailing: Icon(
    Icons.chevron_right,
    size: 20,
    color: Colors.grey[600],
  ),
)
```

#### 改进后（只需 10 行）

```dart
ListTile(
  title: Text(
    app.name,
    style: Theme.of(context).textTheme.titleMedium,
  ),
  subtitle: Text(
    app.des,
    style: Theme.of(context).textTheme.bodyMedium,
  ),
  trailing: Icon(Icons.chevron_right),
)
```

**减少 60% 的代码量！**

---

## Material 组件支持对比

### 改进前：需要自定义样式

```dart
AppBar(
  title: Text('标题'),
  backgroundColor: Colors.white,
  elevation: 0,
  centerTitle: true,
)

ElevatedButton(
  onPressed: () {},
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blue,
    foregroundColor: Colors.white,
    padding: EdgeInsets.symmetric(horizontal: 16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    ),
  ),
  child: Text(
    '按钮',
    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
  ),
)
```

### 改进后：自动使用主题样式

```dart
AppBar(
  title: Text('标题'),
  // 自动使用主题的 surface 色、无阴影、居中
)

ElevatedButton(
  onPressed: () {},
  child: Text('按钮'),
  // 自动使用主题的颜色、间距、圆角、文字样式
)
```

---

## 完整示例对比

### 应用列表卡片

#### 改进前（80+ 行）

```dart
Card(
  elevation: 4,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  ),
  child: Padding(
    padding: EdgeInsets.all(16),
    child: Column(
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                app.icon,
                width: 64,
                height: 64,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                children: [
                  Text(
                    app.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    app.des,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 8),
                  Wrap(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.withAlpha(50),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.blue.withAlpha(180),
                          ),
                        ),
                        child: Text(
                          app.version,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  ),
)
```

#### 改进后（50 行）

```dart
Card(
  child: Padding(
    padding: AppSpacing.allLG,
    child: Column(
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: AppRadius.allMD,
              child: Image.network(
                app.icon,
                width: 64,
                height: 64,
              ),
            ),
            SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                children: [
                  Text(
                    app.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    app.des,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Chip(
                    label: Text(app.version),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  ),
)
```

**减少 38% 的代码量，且自动适配主题！**

---

## 总结

| 方面 | 改进前 | 改进后 |
|------|--------|--------|
| **代码量** | 多（需要硬编码） | 少（使用主题） |
| **主题适配** | 手动处理 | 自动适配 |
| **一致性** | 难以保证 | 统一管理 |
| **维护性** | 分散在各处 | 集中在主题 |
| **暗色模式** | 需要手动实现 | 自动支持 |
| **Material 规范** | 部分遵守 | 完全符合 |

---

## 迁移建议

1. **第一步**：将所有 `TextStyle` 替换为 `Theme.of(context).textTheme.*`
2. **第二步**：将所有硬编码颜色替换为 `Theme.of(context).colorScheme.*`
3. **第三步**：使用 Material 内置组件（AppBar、Card、ListTile 等）
4. **第四步**：删除不必要的自定义样式

---

更新日期：2024-03-17
