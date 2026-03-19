# 数据导出/导入功能使用指南

## 概述

GStore 提供了完整的数据导出/导入功能，支持：
- ✅ 导出已添加的应用数据
- ✅ 导入备份的应用数据
- ✅ 支持多种导入模式（替换/合并/更新）
- ✅ 支持 JSON 和压缩 JSON 格式
- ✅ 灵活的导出选项

---

## 数据格式

### 推荐格式：JSON

```json
{
  "metadata": {
    "version": "1.0",
    "exportDate": "2024-03-17T12:00:00.000Z",
    "appVersion": "1.0.19",
    "totalApps": 150,
    "channelCounts": {
      "github": 50,
      "fdroid": 30,
      "vivo": 40,
      "localdb": 20,
      "http": 10
    },
    "options": {
      "includeIconUrls": true,
      "includeDescription": true,
      "includeCategory": true,
      "includeExtra": true,
      "compressed": false,
      "enabledOnly": false
    }
  },
  "apps": [
    {
      "channelId": "github",
      "appId": "owner/repo",
      "appName": "应用名称",
      "iconUrl": "https://...",
      "description": "应用描述",
      "category": "工具,开发",
      "addTime": 1710672000000,
      "sortOrder": 0,
      "isEnabled": true,
      "extra": "{}"
    }
  ]
}
```

---

## 使用方式

### 1. 导出数据

#### 基础导出
```dart
final backupService = BackupService.instance;
await backupService.initialize();

// 导出所有数据
final backupData = await backupService.exportData();

// 导出特定渠道
final backupData = await backupService.exportData(
  channels: [ChannelType.github, ChannelType.fdroid],
);

// 导出时包含/排除特定数据
final backupData = await backupService.exportData(
  options: BackupOptions(
    includeIconUrls: true,
    includeDescription: true,
    includeCategory: false,
    includeExtra: false,
    enabledOnly: false, // 仅导出已启用的应用
  ),
);
```

#### 导出到文件
```dart
// 导出到 JSON 文件
final filePath = await backupService.exportToFile();

// 导出到压缩文件（推荐大量数据）
final compressedPath = await backupService.exportToCompressedFile();

// 指定文件路径
final customPath = await backupService.exportToFile(
  filePath: '/path/to/backup.json',
);
```

### 2. 导入数据

#### 从文件导入
```dart
// 替换模式：清空后导入
final result = await backupService.importFromFile(
  filePath,
  mode: BackupImportMode.replace,
);

// 合并模式：只添加不存在的
final result = await backupService.importFromFile(
  filePath,
  mode: BackupImportMode.merge,
);

// 更新模式：更新存在的，添加不存在的
final result = await backupService.importFromFile(
  filePath,
  mode: BackupImportMode.update,
);

// 检查结果
if (result.success) {
  print('导入成功：${result.addedCount} 个应用');
  if (result.skippedCount != null && result.skippedCount! > 0) {
    print('跳过：${result.skippedCount} 个已存在的应用');
  }
} else {
  print('导入失败：${result.error}');
}
```

### 3. 管理备份文件

```dart
// 获取所有备份文件
final backupFiles = await backupService.getBackupFiles();
for (final file in backupFiles) {
  print('文件名：${file.name}');
  print('大小：${file.formattedSize}');
  print('修改时间：${file.modified}');
  print('是否压缩：${file.isCompressed}');
}

// 删除备份文件
await backupService.deleteBackupFile(filePath);
```

### 4. 获取统计信息

```dart
final statistics = await backupService.getStatistics();
print('总应用数：${statistics.totalApps}');
print('已启用：${statistics.enabledApps}');
print('已禁用：${statistics.disabledApps}');
print('各渠道统计：${statistics.channelCounts}');
```

---

## 导出选项详解

### BackupOptions

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `includeIconUrls` | bool | true | 是否包含图标 URL |
| `includeDescription` | bool | true | 是否包含应用描述 |
| `includeCategory` | bool | true | 是否包含分类信息 |
| `includeExtra` | bool | true | 是否包含扩展字段 |
| `compressed` | bool | false | 是否压缩输出（gzip） |
| `enabledOnly` | bool | false | 是否仅导出已启用的应用 |

### 使用示例

```dart
// 仅导出已启用的应用，不包含描述和图标
final backupData = await backupService.exportData(
  options: BackupOptions(
    includeIconUrls: false,
    includeDescription: false,
    includeCategory: true,
    includeExtra: false,
    enabledOnly: true,
  ),
);
```

---

## 导入模式详解

### BackupImportMode

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `replace` | 替换模式：清空后导入 | 完全恢复备份 |
| `merge` | 合并模式：只添加不存在的 | 合并多个备份 |
| `update` | 更新模式：更新存在的，添加不存在的 | 同步更新 |

### 使用场景

#### 替换模式 (Replace)
```dart
// 完全恢复到备份状态
// 会先清空所有已添加的应用，然后导入备份中的所有应用
await backupService.importFromFile(
  filePath,
  mode: BackupImportMode.replace,
);
```

#### 合并模式 (Merge)
```dart
// 合并多个备份文件
// 只添加不存在的应用，不会更新已存在的应用
await backupService.importFromFile(
  backup1,
  mode: BackupImportMode.merge,
);
await backupService.importFromFile(
  backup2,
  mode: BackupImportMode.merge,
);
```

#### 更新模式 (Update)
```dart
// 更新应用信息
// 更新已存在的应用，添加不存在的应用
await backupService.importFromFile(
  filePath,
  mode: BackupImportMode.update,
);
```

---

## 文件位置

### 默认备份路径

```
[data directory]/backups/
├── gstore_backup_2024-03-17T12-00-00.json
├── gstore_backup_2024-03-17T12-00-00.json.gz
├── gstore_backup_2024-03-18T08-30-15.json
└── ...
```

### Android 路径
```
/data/data/com.example.gstore/app_flutter/backups/
```

### 获取备份目录
```dart
final directory = await getApplicationDocumentsDirectory();
final backupDir = Directory(path.join(directory.path, 'backups'));
```

---

## 完整示例

### 导出示例

```dart
class BackupPage extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('数据备份')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.backup),
            title: Text('导出所有应用'),
            subtitle: Text('导出已添加的所有应用数据'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _exportAllApps(context),
          ),
          ListTile(
            leading: Icon(Icons.compress),
            title: Text('导出压缩备份'),
            subtitle: Text('导出为压缩格式，节省空间'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _exportCompressed(context),
          ),
          ListTile(
            leading: Icon(Icons.restore),
            title: Text('导入备份'),
            subtitle: Text('从备份文件恢复数据'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _importBackup(context),
          ),
          ListTile(
            leading: Icon(Icons.folder),
            title: Text('备份文件'),
            subtitle: Text('查看和管理备份文件'),
            trailing: Icon(Icons.chevron_right),
            onTap: () => _showBackupFiles(context),
          ),
        ],
      ),
    );
  }

  Future<void> _exportAllApps(BuildContext context) async {
    try {
      final backupService = BackupService.instance;
      await backupService.initialize();

      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );

      // 执行导出
      final filePath = await backupService.exportToFile();

      Navigator.pop(context); // 关闭进度对话框

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出成功：$filePath')),
      );
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _exportCompressed(BuildContext context) async {
    try {
      final backupService = BackupService.instance;
      await backupService.initialize();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );

      final filePath = await backupService.exportToCompressedFile();

      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出成功：$filePath')),
      );
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    // TODO: 实现文件选择器
    final filePath = '/path/to/backup.json';

    try {
      final backupService = BackupService.instance;
      await backupService.initialize();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );

      final result = await backupService.importFromFile(
        filePath,
        mode: BackupImportMode.merge,
      );

      Navigator.pop(context);

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '导入成功！添加了 ${result.addedCount} 个应用'
              '${result.skippedCount != null && result.skippedCount! > 0 ? '，跳过 ${result.skippedCount} 个已存在的应用' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _showBackupFiles(BuildContext context) async {
    try {
      final backupService = BackupService.instance;
      await backupService.initialize();

      final backupFiles = await backupService.getBackupFiles();

      if (backupFiles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('没有找到备份文件')),
        );
        return;
      }

      showModalBottomSheet(
        context: context,
        builder: (context) => Container(
          height: 400,
          child: ListView.builder(
            itemCount: backupFiles.length,
            itemBuilder: (context, index) {
              final file = backupFiles[index];
              return ListTile(
                leading: Icon(Icons.description),
                title: Text(file.name),
                subtitle: Text(
                  '${file.formattedSize} • ${file.modified}',
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete),
                  onPressed: () async {
                    await backupService.deleteBackupFile(file.path);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已删除')),
                    );
                  },
                ),
                onTap: () {
                  // 导入选中的备份
                  Navigator.pop(context);
                  _importFromFile(context, file.path);
                },
              );
            },
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取备份列表失败：$e')),
      );
    }
  }

  Future<void> _importFromFile(BuildContext context, String filePath) async {
    // 实现导入逻辑
  }
}
```

---

## 高级用法

### 自定义导出格式

如果需要修改导出格式，可以继承或修改 `BackupData` 类：

```dart
class CustomBackupData extends BackupData {
  final String customField;

  CustomBackupData({
    required BackupMetadata metadata,
    required List<BackupAppItem> apps,
    required this.customField,
  }) : super(metadata: metadata, apps: apps);

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json['customField'] = customField;
    return json;
  }
}
```

### 增量备份

```dart
// 仅导出最近 7 天添加的应用
final now = DateTime.now();
final weekAgo = now.subtract(Duration(days: 7));

final allApps = await _aggregatorDb.addedAppDao.getAllAddedApps();
final recentApps = allApps
    .where((app) => app.addTime >= weekAgo.millisecondsSinceEpoch)
    .map((app) => BackupAppItem.fromAddedAppInfo(app, options))
    .toList();
```

### 分渠道备份

```dart
// 为每个渠道单独创建备份文件
for (final channel in ChannelType.values) {
  final backupData = await backupService.exportData(
    channels: [channel],
  );

  final fileName = 'gstore_backup_${channel.code}_${DateTime.now().millisecondsSinceEpoch}.json';
  final filePath = path.join(backupDir.path, fileName);

  final jsonString = jsonEncode(backupData.toJson());
  await File(filePath).writeAsString(jsonString);
}
```

---

## 最佳实践

### 1. 定期备份
```dart
// 每周自动备份
Timer.periodic(Duration(days: 7), (timer) async {
  final backupService = BackupService.instance;
  final filePath = await backupService.exportToCompressedFile();
  debugPrint('自动备份完成：$filePath');
});
```

### 2. 导出前验证
```dart
// 检查是否有应用可导出
final statistics = await backupService.getStatistics();
if (statistics.totalApps == 0) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('无法导出'),
      content: Text('您还没有添加任何应用'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('确定'),
        ),
      ],
    ),
  );
  return;
}
```

### 3. 导入前确认
```dart
// 显示导入预览
final backupData = await backupService.exportData();
final appCount = backupData.apps.length;

final confirmed = await showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text('确认导入'),
    content: Text('即将导入 $appCount 个应用，是否继续？'),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text('导入'),
      ),
    ],
  ),
);

if (confirmed == true) {
  await backupService.importFromFile(filePath);
}
```

### 4. 错误处理
```dart
try {
  final result = await backupService.importFromFile(filePath);

  if (result.success) {
    // 导入成功
    await _refreshAppList();
  } else {
    // 导入失败，显示错误信息
    showErrorDialog(result.error ?? '未知错误');
  }
} on BackupException catch (e) {
  showErrorDialog('备份文件错误：${e.message}');
} on FormatException catch (e) {
  showErrorDialog('备份文件格式错误：${e.message}');
} catch (e) {
  showErrorDialog('导入失败：${e.toString()}');
}
```

---

## 常见问题

### Q1: 备份文件在哪里？
A: 备份文件默认存储在应用的文档目录下的 `backups` 文件夹中。Android 路径为：
```
/data/data/com.example.gstore/app_flutter/backups/
```

### Q2: 如何在其他设备上使用备份？
A:
1. 将备份文件从设备导出
2. 通过文件传输（如 Google Drive、邮件）发送到目标设备
3. 在目标设备上导入备份文件

### Q3: 支持哪些版本的数据？
A: 当前仅支持 `1.0` 版本。如果旧版本格式不兼容，会提示错误。

### Q4: 压缩文件和普通文件有什么区别？
A: 压缩文件（`.json.gz`）使用 gzip 压缩，可以节省约 60-80% 的空间，适合大量数据备份。

### Q5: 导入时会覆盖现有数据吗？
A: 取决于导入模式：
- `replace` 模式：会清空后导入
- `merge` 模式：只添加不存在的
- `update` 模式：更新存在的，添加不存在的

---

## 更新日志

### v1.0.0
- ✅ 初始版本
- ✅ 支持 JSON 和压缩 JSON 格式
- ✅ 支持三种导入模式（替换/合并/更新）
- ✅ 灵活的导出选项
- ✅ 备份文件管理
- ✅ 统计信息

---

更新日期：2024-03-17
