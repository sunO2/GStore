# GStore 开发日志

## 2025-03-14 - 修复 LocalDbChannel 包名显示

### 🐛 修复问题

#### LocalDbChannel 包名标签显示错误
修复了 LocalDbChannel（本地数据库 GitHub 应用）显示错误包名的问题。

**问题：**
- 之前使用 `appInfo.repositories`（仓库名，如 "GStore-Repositorys"）作为包名显示
- 这不是真正的 Android 包名格式（如 "com.example.app"）

**解决方案：**
- 将 `packageName` 设置为 `null`
- GitHub 仓库类型的应用不再显示包名标签
- 仓库名信息存储在 `extra['repositoryName']` 中以备后用

**修改文件：**
```
lib/core/channel/impl/LocalDbChannel.dart
```

**代码变更：**
```dart
// 之前：使用仓库名作为包名
packageName: appInfo.repositories,

// 现在：不显示包名
packageName: null, // GitHub 仓库类型没有真实的 Android 包名，不显示

// 仓库名存储在 extra 中
extra: {
  'repositoryName': appInfo.repositories,
  // ...
}
```

**显示效果：**
| 渠道 | 包名标签 | 说明 |
|------|---------|------|
| LocalDbChannel (GitHub) | ❌ 不显示 | 仓库不是包名 |
| VivoChannel | ✅ 显示 | 有真实包名 |
| HttpChannel | ✅ 显示 | 取决于 API |

---

## 2025-03-14 - 详情页布局优化

### 🔧 优化内容

#### 版本和包名显示方式优化
将独立的版本/包名模块整合到应用头部卡片中，使用标签方式显示。

**修改文件：**
```
lib/page/detail/view.dart
```

**变更前：**
- 独立的 VersionSection 显示版本和包名
- 版本以普通文本显示在应用名称下方
- 包名单独占用一个卡片

**变更后：**
- 移除独立的 VersionSection
- 版本和包名以标签形式显示在应用头部卡片中
- 与安装状态在同一行，以 Wrap 布局自适应排列

**标签样式：**
| 信息 | 图标 | 颜色 | 样式 |
|-----|------|------|------|
| 版本 | Icons.tag | 主题色 | 圆角边框 + 半透明背景 |
| 包名 | Icons.inventory_2_outlined | 次要色 | 圆角边框 + 半透明背景 |

**UI 效果：**
```
┌─────────────────────────────────────────┐
│ [图标]  应用名称                         │
│         [🏷️ v1.0.0] [📦 com.example.app]   │
│         [未安装]                          │
│                                          │
│ 这里是应用简介...                         │
└─────────────────────────────────────────┘
```

**新增方法：**
- `_buildVersionTag(BuildContext context, String version)` - 构建版本标签
- `_buildPackageTag(BuildContext context, String packageName)` - 构建包名标签

**优势：**
1. 减少卡片数量，页面更简洁
2. 版本和包名信息与应用基本信息关联更紧密
3. 标签样式更现代、美观
4. Wrap 布局支持多标签自动换行

---

## 2025-03-14 - 下载文件平台过滤

### 🔧 优化内容

#### 下载文件列表平台过滤
详情页的下载文件列表现在只显示当前平台（Android）可用的文件类型。

**修改文件：**
```
lib/page/detail/widgets.dart
```

**支持的文件类型：**
| 文件类型 | 扩展名 | 说明 |
|---------|--------|------|
| Android APK | `.apk` | 标准 Android 安装包 |
| Android Bundle | `.aab` | Android App Bundle |
| Android ZIP | `.zip` + 关键词 | 包含 Android 相关关键词的压缩包 |

**ZIP 文件过滤规则：**
只有文件名包含以下关键词之一的 ZIP 文件才会显示：
- `universal`
- `android`
- `arm`
- `mobile`
- `app`

**过滤逻辑：**
```dart
List<DownloadInfo> _filterPlatformDownloads(List<DownloadInfo> downloads) {
  return downloads.where((download) {
    final fileName = download.name.toLowerCase();

    // 直接匹配 APK 和 AAB
    if (fileName.endsWith('.apk')) return true;
    if (fileName.endsWith('.aab')) return true;

    // ZIP 需要包含 Android 相关关键词
    if (fileName.endsWith('.zip')) {
      final keywords = ['universal', 'android', 'arm', 'mobile', 'app'];
      return keywords.any((keyword) => fileName.contains(keyword));
    }

    return false;
  }).toList();
}
```

**用户体验优化：**
- 过滤后的文件数量显示准确
- 如果没有符合条件的文件，显示"该应用暂无适配当前平台的文件"
- 如果完全没有下载文件，显示"该应用暂无可下载文件"

**文件类型标签更新：**
| 扩展名 | 显示标签 |
|--------|---------|
| .apk | Android APK |
| .aab | Android Bundle |
| .zip | 压缩包 |

---

## 2025-03-14 - 详情页下载信息修复与优化

### 📦 新增功能

#### 1. LocalDbChannel 集成 GitHub Releases API
本地数据库渠道现在可以调用 GitHub API 获取应用的 releases 信息。

**修改文件：**
```
lib/core/channel/impl/LocalDbChannel.dart
lib/core/channel/ChannelIntegration.dart
```

**功能特性：**
- 检测应用是否为 GitHub 仓库（通过 user/repositories 字段）
- 调用 GitHub API 获取最新 releases
- 解析 release assets 构建下载列表
- 从 release 获取版本信息
- API 调用失败不影响整体流程（优雅降级）

**数据流：**
```
getAppDetail(appId)
    ↓
从数据库获取 AppInfo (user/repositories)
    ↓
检查是否为 GitHub 仓库
    ↓
调用 GitHub releases API
    ↓
解析 assets → DownloadInfo 列表
    ↓
构建 AppDetailInfo（包含下载信息）
```

#### 2. 详情页下载区域优化
所有渠道现在都会显示下载区域，即使没有可下载文件也会显示友好提示。

**修改文件：**
```
lib/page/detail/widgets.dart
lib/core/channel/impl/GitHubChannel.dart
lib/core/channel/impl/VivoChannel.dart
lib/core/channel/impl/HttpChannel.dart
lib/core/channel/impl/LocalDbChannel.dart
```

**优化内容：**
- 所有渠道始终添加 `DetailSection.downloads`
- `DownloadsSection` 在无文件时显示"该应用暂无可下载文件"消息
- 统一的用户体验，不会出现下载区域消失的情况

#### 3. 增强调试日志
为 LocalDbChannel 添加了详细的调试日志，方便诊断问题。

**日志输出示例：**
```
LocalDbChannel: ========== 开始获取应用详情 ==========
LocalDbChannel: appId = xxx
LocalDbChannel: appInfo.name = xxx
LocalDbChannel: appInfo.user = xxx
LocalDbChannel: appInfo.repositories = xxx
LocalDbChannel: isGitHubRepo = true/false
LocalDbChannel: _githubApi = 已注入/未注入
LocalDbChannel: >>> 正在调用 GitHub API 获取 releases - user/repo
LocalDbChannel: <<< GitHub API 返回 releases 数量 = x
LocalDbChannel: assets 数量 = x
LocalDbChannel: ✓ 添加下载文件 - xxx (x MB)
LocalDbChannel: >>> 最终下载列表数量 = x
LocalDbChannel: ========== 构建详情信息完成 ==========
```

### 🔧 修改内容

#### 1. VivoChannel 字段修复

**问题：** 包名字段使用了错误的字段名，下载文件名格式不正确。

**修复：**
```dart
// 包名优先使用 package_name 字段
final packageName = detail['package_name']?.toString() ??
                   detail['packageName']?.toString() ??
                   appInfo.appId;

// 下载 URL 使用 download_url 字段
final downloadUrl = detail['download_url']?.toString() ??
                   detail['downloadUrl']?.toString();

// 文件名格式: package_name_version_code.apk
final fileName = versionCode != null && versionCode.isNotEmpty
    ? '${packageName}_$versionCode.apk'
    : '${packageName}_${version ?? 'latest'}.apk';
```

**字段映射表：**
| 接口字段 | 用途 | 说明 |
|---------|------|------|
| package_name | 包名 | 优先使用（下划线格式） |
| versionCode | 版本号 | 用于文件名 |
| download_url | 下载地址 | 优先使用（下划线格式） |

#### 2. LocalDbChannel GitHub API 集成

**新增依赖：**
```dart
class LocalDbChannel implements IChannel {
  final AppInfoDatabase _database;
  final GithubRestClient? _githubApi;  // 新增：可选的 GitHub API
  // ...
}
```

**GitHub releases 解析：**
```dart
final releasesJson = await _githubApi!.releases(
  appInfo.user,
  appInfo.repositories,
  1,
  CancelToken(),
);

final List<dynamic> releases = List<dynamic>.from(
  jsonDecode(releasesJson as String) as List,
);

// 解析最新 release 的 assets
if (releases.isNotEmpty) {
  final latestRelease = releases[0] as Map<String, dynamic>;
  final assets = latestRelease['assets'] as List<dynamic>? ?? [];

  for (var asset in assets) {
    downloads.add(DownloadInfo(
      url: asset['browser_download_url']?.toString() ?? '',
      name: asset['name']?.toString() ?? '',
      size: asset['size'] as int?,
      downloadCount: asset['download_count'] as int?,
      version: latestVersion,
      publishedAt: publishedAt,
      platform: _parsePlatformFromAssetName(asset['name']?.toString() ?? ''),
    ));
  }
}
```

#### 3. ChannelIntegration 更新

**修改：** 为 LocalDbChannel 传入 GithubRestClient

```dart
var localDbChannel = LocalDbChannel(
  database: dbManager.dbRepositroies["gstore"]!.db,
  githubApi: githubApi,  // 新增：传入 GitHub API 用于查询 releases
  name: 'LocalDB',
  description: '本地数据库渠道（离线可用）',
  priority: 1,
);
```

### 📊 各渠道下载信息对比

| 渠道 | 下载信息来源 | 版本信息 | 文件名格式 |
|------|-------------|---------|-----------|
| **LocalDbChannel** | GitHub releases API | release name/tag | 保持原始文件名 |
| **GitHubChannel** | GitHub releases API | release name/tag | 保持原始文件名 |
| **VivoChannel** | detail.download_url | versionName | package_name_versionCode.apk |
| **HttpChannel** | HTTP API 响应 | API 提供的 version | API 提供的 name |

### 🐛 修复的问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Vivo 渠道包名取错 | 使用了 `packageName` 而非 `package_name` | 优先使用 `package_name` 字段 |
| Vivo 文件名格式不正确 | 使用 `packageName-version.apk` | 改为 `package_name_versionCode.apk` |
| LocalDbChannel 无下载信息 | 未调用 GitHub API | 集成 releases API |
| 下载区域消失 | 只在有下载时才显示 section | 始终显示，无文件时显示提示 |

### 💡 使用示例

**LocalDbChannel 获取详情（带 GitHub releases）：**
```dart
// 数据库中的应用需要有 user 和 repositories 字段
// 例如：user="octocat", repositories="Hello-World"

final result = await localDbChannel.getAppDetail(appId);
if (result.success && result.data != null) {
  final detail = result.data!;

  // 下载列表（从 GitHub releases 获取）
  for (var download in detail.downloads) {
    print('${download.name} - ${download.formattedSize}');
    print('URL: ${download.url}');
  }

  // 版本信息（从 release 获取）
  print('Version: ${detail.version}');
}
```

### 📝 调试技巧

**查看 LocalDbChannel 获取详情的完整日志：**
```bash
# 运行应用并打开本地数据库应用的详情页
# 查看控制台输出

# 关键日志标识：
# - ========== 开始获取应用详情 ==========
# - >>> 正在调用 GitHub API 获取 releases
# - ✓ 添加下载文件
# - ========== 构建详情信息完成 ==========
```

**诊断问题：**
- `_githubApi = 未注入` → 检查 ChannelIntegration 是否正确传入
- `isGitHubRepo = false` → 检查数据库中的 user/repositories 字段
- `assets 数量 = 0` → 该仓库的 release 没有上传资源文件
- `✗ 获取 GitHub releases 失败` → 查看 stackTrace 了解具体错误

---

## 2025-03-14 - 渠道独立数据库架构重构

### 📦 新增功能

#### 1. 渠道独立数据库系统
每个渠道维护自己的数据库，用于保存搜索/收藏的应用。

**新增文件：**
```
lib/core/channel/database/
├── channel_added_app.dart       # 渠道应用实体
├── channel_added_app_dao.dart   # 数据访问对象
├── channel_database.dart         # 渠道数据库配置
└── channel_database.g.dart       # Floor 生成代码
```

**数据库结构：**
- 文件名：`channel_apps.db`
- 表名：`channel_added_app`
- 字段：
  - `appId` (TEXT, PK) - 应用 ID
  - `name` (TEXT) - 应用名称
  - `user` (TEXT) - 开发者
  - `repositories` (TEXT) - 包名/仓库
  - `icon` (TEXT) - 图标 URL
  - `description` (TEXT) - 描述
  - `category` (TEXT) - 分类（逗号分隔）
  - `addTime` (INTEGER) - 添加时间
  - `channelCode` (TEXT) - 渠道类型代码

#### 2. 聚合管理器数据库重构
聚合管理器使用 `channelType + appId` 作为复合主键。

**新增文件：**
```
lib/core/aggregate/AppAggregatorDatabase.dart
```

**数据库结构：**
- 文件名：`aggregated_apps.db`
- 表名：`added_apps`
- **复合主键：** `channelId` + `appId`
- 字段：
  - `channelId` (TEXT, PK) - 渠道类型代码
  - `appId` (TEXT, PK) - 应用 ID（在对应渠道中的 ID）
  - `appName` (TEXT) - 应用名称
  - `iconUrl` (TEXT) - 图标 URL
  - `description` (TEXT) - 描述
  - `category` (TEXT) - 分类
  - `addTime` (INTEGER) - 添加时间
  - `sortOrder` (INTEGER) - 排序权重

### 🔧 修改内容

#### 1. VivoChannel 方法重构

**新增方法：**
```dart
// 渠道数据库操作
Future<void> saveSearchResult(AppInfo app)     // 保存搜索结果
Future<void> deleteSearchResult(String appId)   // 删除搜索结果
Future<List<AppInfo>> getChannelApps()         // 获取渠道应用
Future<bool> isInChannel(String appId)         // 检查是否在渠道中

// 聚合管理器操作（占位方法）
Future<void> addToAggregator(AppInfo app)
Future<void> removeFromAggregator(String appId)
```

**更新方法：**
```dart
@override
Future<ChannelResult<List<AppInfo>>> getAllApps()
// 返回渠道数据库中保存的应用（而非空列表）
```

**搜索 Widget 更新：**
- 按钮从"添加"改为"保存"
- 保存成功后调用 `onAppSaved` 回调
- 保存到渠道数据库，而非聚合管理器

#### 2. IChannel 接口更新

**新增可选参数：**
```dart
Widget? getAddAppWidget(
  BuildContext context,
  Function(AppInfo) onAppAdded, {
  VoidCallback? onAppSaved,  // 新增：保存后的回调
});
```

**更新影响的文件：**
- `lib/core/channel/IChannel.dart`
- `lib/core/channel/impl/LocalDbChannel.dart`
- `lib/core/channel/impl/GitHubChannel.dart`
- `lib/core/channel/impl/HttpChannel.dart`
- `lib/core/channel/impl/VivoChannel.dart`

#### 3. 发现页面逻辑更新

**`lib/page/home/tab/discovery/logic.dart`**

`toggleApp()` 方法简化：
- 只处理聚合管理器的添加/移除
- 移除对渠道数据库的直接操作
- 提示文案改为"已添加到首页" / "已从首页移除"

`showAddAppSheet()` 方法更新：
- 添加 `onAppSaved` 回调
- 保存成功后重新加载渠道应用列表

#### 4. vivo 搜索接口更新

**正确的接口地址和参数：**
```
URL: POST https://h5-api.appstore.vivo.com.cn/h5appstore/search/result-list

参数:
{
  'key': '搜索关键词',           // 关键修改：使用 key 而非 word
  'page_index': 1,
  'apps_per_page': 20,
  'target': 'local',
  'cfrom': '2',
  ...defaultParams
}
```

**响应格式：**
```json
{
  "code": 0,
  "data": {
    "appSearchResponse": {
      "value": [
        {
          "id": "应用ID",
          "title_zh": "应用名称",
          "package_name": "包名",
          "icon_url": "图标URL",
          "remark": "描述"
        }
      ]
    }
  }
}
```

### 📐 架构设计

#### 数据流

```
┌─────────────────────────────────────────────────────────────────────┐
│                         用户操作                                     │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                ┌───────────────────┴───────────────────┐
                │                                       │
                ▼                                       ▼
    ┌─────────────────────┐              ┌─────────────────────┐
    │  点击"+" 搜索        │              │  在渠道列表中        │
    │  ↓                   │              │  点击"+"添加          │
    │  搜索并保存到         │              │  ↓                    │
    │  渠道数据库           │              │  添加到聚合管理器      │
    └─────────────────────┘              └─────────────────────┘
                │                                       │
                ▼                                       ▼
    ┌─────────────────────┐              ┌─────────────────────┐
    │  channel_apps.db    │              │  aggregated_apps.db  │
    │  (渠道数据库)         │              │  (聚合管理器)          │
    │                     │              │                     │
    │  vivo: 保存的应用    │              │  vivo: {appId1}      │
    │  github: {...}      │              │  github: {app1}      │
    │  http: {...}        │              │  http: {...}        │
    └─────────────────────┘              └─────────────────────┘
                │                                       │
                ▼                                       ▼
    ┌──────────────────────────────────────────────────────────────┐
    │                     发现页面                                   │
    │  - 显示各渠道保存的应用                                            │
    │  - 点击"+"添加到首页                                               │
    └──────────────────────────────────────────────────────────────┘
                │
                ▼
    ┌──────────────────────────────────────────────────────────────┐
    │                     首页                                       │
    │  - 显示聚合管理器中的所有应用                                       │
    │  - 跨渠道展示                                                      │
    └──────────────────────────────────────────────────────────────┘
```

#### 主键设计

**聚合管理器复合主键：**
```
Table: added_apps
Primary Key: (channelId, appId)

示例：
('vivo', '3438168')     // vivo 渠道的微信
('github', 'wechat')   // github 渠道的微信
('http', 'wx')         // http 渠道的微信
```

这样的设计允许：
- 同一应用在不同渠道中独立管理
- 跨渠道聚合展示时不会冲突
- 使用渠道特定的 appId 而非统一格式

### 📊 数据库对比

| 特性 | 渠道数据库 (channel_apps.db) | 聚合管理器 (aggregated_apps.db) |
|------|------------------------------|----------------------------------|
| 用途 | 保存搜索/收藏的应用 | 首页显示的应用 |
| 主键 | appId | (channelId, appId) 复合主键 |
| 数据来源 | 用户搜索保存 | 用户从渠道列表添加 |
| 显示位置 | 发现页面渠道列表 | 首页 |
| 数据范围 | 每个渠道独立 | 跨渠道聚合 |

### 💡 使用流程

**第一步：搜索并保存**
1. 打开"发现"页面
2. 点击右上角"+"按钮
3. 选择渠道（如 vivo）
4. 搜索应用（如"微信"）
5. 点击"保存"按钮
6. 应用保存到渠道数据库
7. 发现页面的 vivo 渠道列表中显示该应用

**第二步：添加到首页**
1. 在发现页面的 vivo 渠道列表中找到应用
2. 点击应用卡片的"+"按钮
3. 应用添加到聚合管理器数据库
4. 首页显示该应用

### 🔑 关键代码片段

**VivoChannel 搜索实现：**
```dart
@override
Widget? getAddAppWidget(
  BuildContext context,
  Function(AppInfo) onAppAdded, {
  VoidCallback? onAppSaved,
}) {
  return _VivoAddAppWidget(
    channel: this,
    onAppAdded: onAppAdded,
    onAppSaved: onAppSaved,
  );
}
```

**保存到渠道数据库：**
```dart
Future<void> _saveToChannel(AppInfo app) async {
  await widget.channel.saveSearchResult(app);

  // 通知父组件刷新渠道列表
  widget.onAppSaved?.call();

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('已保存 ${app.name}')),
  );
}
```

**发现页面刷新逻辑：**
```dart
final addWidget = channel.getAddAppWidget(
  context,
  (app) async { /* ... */ },
  onAppSaved: () async {
    // 保存后重新加载该渠道的应用列表
    final result = await channel.getAllApps(forceRefresh: true);
    if (result.success && result.data != null) {
      state.channelApps[channel.info.type] = result.data!;
    }
  },
);
```

### 🐛 注意事项

1. **渠道数据库持久化**：搜索保存的应用会持久化存储，应用关闭后不丢失

2. **聚合管理器隔离**：不同渠道的相同应用可以独立添加到首页

3. **vivo 渠道特殊性**：
   - 没有获取所有应用的接口
   - `getAllApps()` 返回渠道数据库中保存的应用
   - 必须通过搜索发现应用

4. **API 变更**：vivo 搜索接口从 `/h5appstore/search/sug-list` 改为 `/h5appstore/search/result-list`，参数从 `word` 改为 `key`

### 📝 新增文件

```
lib/core/channel/database/
├── channel_added_app.dart
├── channel_added_app_dao.dart
├── channel_database.dart
└── channel_database.g.dart

lib/core/aggregate/
└── AppAggregatorDatabase.dart
```

### 🔧 修改文件

```
lib/core/channel/
├── IChannel.dart                        # 新增 onAppSaved 参数
└── impl/
    ├── VivoChannel.dart                # 重构方法、更新搜索 API
    ├── LocalDbChannel.dart             # 更新 getAddAppWidget 签名
    ├── GitHubChannel.dart              # 更新 getAddAppWidget 签名
    └── HttpChannel.dart                 # 更新 getAddAppWidget 签名

lib/page/home/tab/discovery/
└── logic.dart                            # 简化 toggleApp、更新 showAddAppSheet
```

---

## 2024-12-19 - 新增 vivo 应用市场渠道

### 📦 新增功能

#### vivo 应用市场渠道 (VivoChannel)
新增 vivo 应用市场数据源，支持搜索和获取应用详情。

**新增文件：**
```
lib/core/channel/impl/VivoChannel.dart
```

**支持的接口：**
| 功能 | 接口 | 说明 |
|------|------|------|
| 搜索应用 | `POST /h5appstore/search/sug-list` | 根据关键词搜索应用 |
| 应用详情 | `GET /detailInfo` | 根据 appId 获取应用详情 |

**接口参数：**
```dart
// 默认参数
{
  'imei': '1234567890',
  'av': '18',
  'app_version': '2100',
  'pictype': 'webp',
  'h5_websource': 'h5appstore',
  'supportBundle': 'false',
}

// 搜索参数
{
  'word': '搜索关键词',
  ...默认参数,
}

// 详情参数
{
  'appId': '应用ID',
  'frompage': 'messageh5',
  ...默认参数,
}
```

**数据映射：**
| vivo 字段 | AppInfo 字段 | 说明 |
|-----------|-------------|------|
| appId | appId | 应用 ID |
| appName | name | 应用名称 |
| packageName | repositories | 包名（用作 appId） |
| developerName | user | 开发者名称 |
| icon | icon | 应用图标 |
| introduction / shortIntroduction | des | 应用描述 |
| categoryName | category | 应用分类 |
| downloadUrl | (保留) | 下载链接 |

**渠道配置：**
```dart
ChannelType.vivo('vivo', 'vivo 应用市场', 4)
```

### 🔧 修改内容

#### 1. 渠道类型枚举

**`lib/core/channel/model/ChannelType.dart`**
```dart
/// vivo 应用市场渠道
vivo('vivo', 'vivo 应用市场', 4),
```

#### 2. 渠道导出

**`lib/core/channel/channel.dart`**
```dart
export 'impl/VivoChannel.dart';
```

#### 3. 渠道初始化

**`lib/core/channel/ChannelIntegration.dart`**
```dart
var vivoChannel = VivoChannel(
  dio: DioClient().get(),
  name: 'vivo',
  description: 'vivo 应用市场',
  priority: 4,
);

manager.registerChannels([
  localDbChannel,
  githubChannel,
  vivoChannel,
]);
```

#### 4. UI 支持

**`lib/page/home/tab/discovery/logic.dart`**
```dart
case ChannelType.vivo:
  return Icons.phone_android;
```

**`lib/page/home/tab/discovery/view.dart`**
```dart
case ChannelType.vivo:
  return 'vivo';
```

**`lib/page/home/tab/applist/view.dart`**
```dart
case ChannelType.vivo:
  return const Color(0xFF4155D0); // vivo 蓝

case ChannelType.vivo:
  return 'vivo';
```

### 📐 渠道总览

| 渠道 | 优先级 | 离线 | 搜索 | 详情 | 全部应用 | 分类 |
|------|--------|------|------|------|----------|------|
| LocalDB | 1 | ✅ | ✅ | ✅ | ✅ | ✅ |
| GitHub | 2 | ❌ | ✅ | ✅ | ✅ | ✅ |
| HTTP | 3 | ❌ | ✅ | ✅ | ✅ | ✅ |
| **vivo** | **4** | **❌** | **✅** | **✅** | **❌** | **❌** |

### 💡 使用示例

**搜索 vivo 应用：**
```dart
final manager = Get.find(tag: 'channelManager');

// 搜索微信应用
var result = await manager.searchApps(
  '微信',
  from: ChannelType.vivo,
);

if (result.success) {
  for (var app in result.data!) {
    print('${app.name} - ${app.appId}');
  }
}
```

**获取应用详情：**
```dart
var result = await manager.getAppInfo(
  '1133200', // vivo appId
  from: ChannelType.vivo,
);
```

### 🐛 注意事项

1. **getAllApps 限制**：vivo 渠道不支持获取所有应用列表，只能通过搜索发现应用

2. **appId 格式**：vivo 使用数字 appId（如 1133200），在 AppInfo 中使用包名作为 appId

3. **网络要求**：需要网络连接，不支持离线使用

---

## 2024-12-19 - 应用聚合架构（应用订阅/收藏系统）

### 📦 新增功能

#### 1. 应用聚合管理器 (AppAggregatorManager)
构建了应用订阅/收藏系统，支持从不同渠道添加应用到个人收藏。

**新增文件：**
```
lib/core/aggregate/
├── aggregate.dart                    # 统一导出
├── AppAggregatorManager.dart         # 应用聚合管理器
└── AppAddedDatabase.dart             # 已添加应用数据库
```

**核心功能：**
- 添加/移除应用（跨渠道管理）
- 查询所有已添加应用（按添加时间排序）
- 从各渠道获取应用详情（聚合显示）
- Stream 实时通知应用列表变化
- SQLite 持久化存储

**数据结构：**
```dart
// 全局索引
Map<ChannelType, Set<String>> addedAppsIndex = {
  ChannelType.localDb: {'app1', 'app2', ...},
  ChannelType.github: {'app3', 'app4', ...},
  ChannelType.http: {'app5', 'app6', ...},
}

// 聚合应用信息
class AggregatedAppInfo {
  final AddedAppInfo addedAppInfo;  // 已添加记录
  final AppInfo appInfo;            // 应用详情
  final ChannelType channel;        // 来源渠道
  final bool isFromCache;          // 是否来自缓存
  final String? error;             // 错误信息
}
```

#### 2. "发现"页面 (DiscoveryPage)
新增了应用浏览和添加页面，支持从各渠道发现并添加应用。

**新增文件：**
```
lib/page/home/tab/discovery/
├── state.dart      # 状态管理
├── logic.dart      # 业务逻辑
└── view.dart       # UI 界面
```

**功能特性：**
- 按渠道分组展示所有应用
- 显示应用添加状态
- 单个应用添加/移除
- 批量添加（全渠道）
- 清空渠道已添加应用
- 三种显示模式：全部/已添加/未添加
- 搜索功能
- 实时统计信息

#### 3. 首页改为聚合展示
修改首页为展示已添加应用的聚合页面。

**修改文件：**
```
lib/page/home/tab/applist/
├── state.dart      # 修改为使用 AggregatedAppInfo
├── logic.dart      # 修改为使用 AppAggregatorManager
└── view.dart       # 添加移除功能、渠道标识
```

**新增功能：**
- 显示所有已添加应用（跨渠道聚合）
- 按添加时间倒序排列
- 渠道标识角标（DB/GH/API）
- 快捷移除按钮
- 空状态引导（去发现页面添加）
- 加载/错误状态处理
- 实时监听应用列表变化

### 🔧 修改内容

#### 1. 首页导航更新

**`lib/page/home/view.dart`**
- 添加"发现"标签页（第2个位置）
- 标签顺序：首页 → 发现 → 分类 → Channel

#### 2. 主入口初始化

**`lib/main.dart`**
```dart
// 初始化应用聚合管理器
final aggregator = AppAggregatorManager.instance;
await aggregator.initialize();
Get.put(aggregator, tag: 'aggregatorManager');
```

**`lib/core/core.dart`**
```dart
// 新增导出
export 'package:gstore/core/aggregate/aggregate.dart';
```

### 📐 架构设计

#### 页面结构
```
┌─────────────────────────────────────────────────────────────────┐
│                        首页标签                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │    首页      │  │    发现      │  │   分类       │         │
│  │ (聚合展示)   │  │ (浏览添加)   │  │              │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│         │                  │                                   │
│         ▼                  ▼                                   │
│  ┌─────────────────────────────────────────────────────┐       │
│  │           AppAggregatorManager                      │       │
│  │     (应用聚合管理器 - 维护全局索引)                  │       │
│  │     - 添加/移除应用                                  │       │
│  │     - 查询已添加应用                                │       │
│  │     - 跨渠道聚合                                    │       │
│  │     - Stream 实时通知                               │       │
│  └─────────────────────────────────────────────────────┘       │
│         │                                                          │
│         ├─────────────┬─────────────┬─────────────┐              │
│         ▼             ▼             ▼             ▼              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐         │
│  │LocalDB   │  │ GitHub   │  │  Http    │  │  ...     │         │
│  │ Channel  │  │ Channel  │  │ Channel  │  │ Channel  │         │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

#### 数据流
```
用户添加应用
    │
    ▼
发现页面 (选择渠道)
    │
    ▼
AppAggregatorManager.addApp()
    │
    ├─► 存储到 added_apps.db
    │
    ├─► 更新内存索引
    │
    └─► Stream 广播通知
            │
            ▼
        首页监听变化
            │
            ▼
        刷新应用列表
```

### 📊 数据库表设计

**added_apps 表：**
| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键（自增） |
| channelId | TEXT | 渠道类型（local_db/github/http） |
| appId | TEXT | 应用 ID |
| appName | TEXT | 应用名称 |
| iconUrl | TEXT | 图标 URL |
| description | TEXT | 描述 |
| category | TEXT | 分类（逗号分隔） |
| addTime | INTEGER | 添加时间（毫秒时间戳） |
| sortOrder | INTEGER | 排序权重 |
| isEnabled | INTEGER | 是否启用 (0/1) |

### 💡 使用场景

1. **用户添加应用**
   - 在"发现"页面浏览各渠道应用
   - 点击添加按钮添加到收藏
   - 首页自动显示已添加的应用

2. **应用聚合展示**
   - 首页显示所有已添加应用（跨渠道）
   - 显示渠道标识（DB/GH/API）
   - 按添加时间排序

3. **移除应用**
   - 首页应用卡片上点击移除按钮
   - 发现页面切换添加状态
   - 实时同步到所有页面

### 🐛 修复的问题

| 问题 | 解决方案 |
|------|----------|
| Floor 数据库 COUNT 查询返回类型 | 改为 `Future<int?>` 并处理 null |
| StreamController 未导入 | 添加 `import 'dart:async';` |
| nullable Widget 返回类型 | 将 Obx 移到外层容器 |
| const Icon 非const表达式 | 使用 Colors.orange[700] 或移除 const |

### 📝 扩展指南

**添加新渠道：**
1. 实现 `IChannel` 接口
2. 在 `ChannelIntegration.initialize()` 中注册
3. 渠道自动出现在发现页面

**自定义应用排序：**
```dart
// 在 AggregatedAppInfo 中添加自定义排序字段
// 修改 getAggregatedApps() 的排序逻辑
```

---

## 2024-12-19 - IChannel 数据渠道体系

### 📦 新增功能

#### 1. IChannel 抽象接口体系
构建了可扩展的数据渠道抽象层，支持多种数据源统一访问。

**新增文件：**
```
lib/core/channel/
├── channel.dart                 # 统一导出
├── ChannelIntegration.dart      # 集成示例
├── IChannel.dart               # 核心接口定义
├── ChannelManager.dart         # 渠道管理器
├── model/
│   ├── ChannelType.dart        # 渠道类型枚举
│   ├── ChannelInfo.dart        # 渠道元信息
│   └── ChannelResult.dart      # 统一返回结果
└── impl/
    ├── LocalDbChannel.dart     # 本地数据库渠道
    ├── GitHubChannel.dart      # GitHub API 渠道
    └── HttpChannel.dart        # HTTP API 渠道
```

**核心接口定义：**
```dart
abstract interface class IChannel {
  // 获取所有应用
  Future<ChannelResult<List<AppInfo>>> getAllApps({bool forceRefresh});

  // 获取单个应用
  Future<ChannelResult<AppInfo?>> getAppInfo(String appId, {bool forceRefresh});

  // 搜索应用
  Future<ChannelResult<List<AppInfo>>> searchApps(String keyword, {bool forceRefresh});

  // 按分类搜索
  Future<ChannelResult<List<AppInfo>>> searchByCategory(String categoryId, {bool forceRefresh});

  // 获取所有分类
  Future<ChannelResult<List<AppCategory>>> getAllCategories({bool forceRefresh});

  // 检查更新
  Future<ChannelResult<bool>> checkUpdate();

  // 执行更新
  Future<ChannelResult<bool>> doUpdate({Function(int current, int total)? onProgress});

  // 缓存管理
  Future<void> clearCache();
  Future<int> getCacheSize();
}
```

**渠道管理器特性：**
- 多渠道注册与优先级管理
- 手动指定渠道查询
- 自动降级查询（`getAllAppsWithFallback`）
- 渠道可用性检查
- 统一的缓存管理

#### 2. Channel 测试页面
新增了用于测试渠道系统的独立页面。

**新增文件：**
```
lib/page/home/tab/channeltest/
├── state.dart      # 状态管理
├── logic.dart      # 业务逻辑
└── view.dart       # UI 界面
```

**功能特性：**
- 渠道选择器（支持切换 LocalDB/GitHub/Http）
- 7 种测试操作（getAllApps、getAppInfo、searchApps、searchByCategory、getAllCategories、checkUpdate、checkAllUpdates）
- 动态参数输入（根据操作类型显示不同输入框）
- 结果元信息显示（来源渠道、成功状态、是否缓存）
- 应用列表展示
- 缓存管理功能

### 🔧 修改内容

#### 1. 核心配置更新

**`lib/main.dart`**
```dart
// 新增导入
import 'package:gstore/core/channel/ChannelIntegration.dart';

// 在 registerService() 中初始化渠道系统
await ChannelIntegration.initialize();
```

**`lib/core/core.dart`**
```dart
// 新增导出
export 'package:gstore/core/channel/channel.dart';
```

**`lib/core/icons/Icons.dart`**
```dart
// 新增 Channel 相关图标（使用 Material Icons 替代）
```

#### 2. 首页导航更新

**`lib/page/home/view.dart`**
- 添加 Channel 测试页面到 PageView
- 新增底部导航栏 "Channel" 标签（使用 Icons.science）

### 📐 架构设计

#### 渠道类型与优先级
| 渠道 | 优先级 | 离线支持 | 说明 |
|------|--------|----------|------|
| LocalDbChannel | 1 | ✅ | 本地 SQLite 数据库 |
| GitHubChannel | 2 | ❌ | GitHub API |
| HttpChannel | 3 | ❌ | 通用 HTTP API |

#### 数据流
```
UI 层
  ↓
ChannelManager (统一入口)
  ↓
IChannel 抽象接口
  ↓
具体实现 (LocalDbChannel/GitHubChannel/HttpChannel)
  ↓
数据源 (数据库/GitHub API/HTTP API)
```

### 💡 使用示例

#### 基本使用
```dart
final manager = Get.find(tag: 'channelManager');

// 使用默认渠道
var result = await manager.getAllApps();

// 指定渠道
var result = await manager.getAllApps(from: ChannelType.localDb);

// 自动降级
var result = await manager.getAllAppsWithFallback(
  preferredOrder: [ChannelType.localDb, ChannelType.github],
);
```

#### 在 Logic 中使用
```dart
class ApplistLogic extends GetxController {
  late ChannelManager _channelManager;

  @override
  void onReady() async {
    _channelManager = Get.find(tag: 'channelManager');
    await _loadApps();
  }

  Future<void> _loadApps() async {
    var result = await _channelManager.getAllApps(
      from: ChannelType.localDb,
    );

    if (result.success) {
      state.apps = result.data ?? [];
      state.dataFrom = result.from; // 显示数据来源
      update();
    }
  }
}
```

### 🐛 修复的问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 自定义图标代码点不存在 | AliIcon 中新增的图标无对应字体 | 替换为 Material Icons |
| FilterChip.checkmark 参数不存在 | Flutter API 变更 | 改用 showCheckmark: false |
| 变量名冲突 | available 同时用作列表和布尔值 | 重命名为 availableTypes/isAvailable |
| DatabaseExecutor.path 不存在 | Floor 数据库接口无 path 属性 | 简化 getCacheSize() 实现 |

### 📝 后续扩展

如需添加新渠道，实现 `IChannel` 接口即可：

```dart
class CustomChannel implements IChannel {
  @override
  ChannelInfo info = ChannelInfo(
    type: ChannelType.custom,
    name: 'CustomChannel',
    description: '自定义数据源',
  );

  // 实现接口方法...
}

// 注册渠道
ChannelManager.instance.registerChannel(CustomChannel());
```

---

## 文件清单

### 本次修改新增文件 (18 个)
**聚合管理系统：**
- `lib/core/aggregate/aggregate.dart`
- `lib/core/aggregate/AppAggregatorManager.dart`
- `lib/core/aggregate/AppAddedDatabase.dart`

**发现页面：**
- `lib/page/home/tab/discovery/state.dart`
- `lib/page/home/tab/discovery/logic.dart`
- `lib/page/home/tab/discovery/view.dart`

**IChannel 体系：**
- `lib/core/channel/channel.dart`
- `lib/core/channel/ChannelIntegration.dart`
- `lib/core/channel/IChannel.dart`
- `lib/core/channel/ChannelManager.dart`
- `lib/core/channel/model/ChannelType.dart`
- `lib/core/channel/model/ChannelInfo.dart`
- `lib/core/channel/model/ChannelResult.dart`
- `lib/core/channel/impl/LocalDbChannel.dart`
- `lib/core/channel/impl/GitHubChannel.dart`
- `lib/core/channel/impl/HttpChannel.dart`

**Channel 测试页面：**
- `lib/page/home/tab/channeltest/state.dart`
- `lib/page/home/tab/channeltest/logic.dart`
- `lib/page/home/tab/channeltest/view.dart`

- `develop-log.md`

### 本次修改文件 (7 个)
- `lib/main.dart` - 添加聚合管理器和渠道系统初始化
- `lib/core/core.dart` - 导出新模块
- `lib/page/home/view.dart` - 添加发现和 Channel 标签页
- `lib/page/home/tab/applist/state.dart` - 改为使用 AggregatedAppInfo
- `lib/page/home/tab/applist/logic.dart` - 改为使用 AppAggregatorManager
- `lib/page/home/tab/applist/view.dart` - 添加移除功能和渠道标识
- `lib/core/icons/Icons.dart` - 添加图标常量


### 📦 新增功能

#### 1. IChannel 抽象接口体系
构建了可扩展的数据渠道抽象层，支持多种数据源统一访问。

**新增文件：**
```
lib/core/channel/
├── channel.dart                 # 统一导出
├── ChannelIntegration.dart      # 集成示例
├── IChannel.dart               # 核心接口定义
├── ChannelManager.dart         # 渠道管理器
├── model/
│   ├── ChannelType.dart        # 渠道类型枚举
│   ├── ChannelInfo.dart        # 渠道元信息
│   └── ChannelResult.dart      # 统一返回结果
└── impl/
    ├── LocalDbChannel.dart     # 本地数据库渠道
    ├── GitHubChannel.dart      # GitHub API 渠道
    └── HttpChannel.dart        # HTTP API 渠道
```

**核心接口定义：**
```dart
abstract interface class IChannel {
  // 获取所有应用
  Future<ChannelResult<List<AppInfo>>> getAllApps({bool forceRefresh});

  // 获取单个应用
  Future<ChannelResult<AppInfo?>> getAppInfo(String appId, {bool forceRefresh});

  // 搜索应用
  Future<ChannelResult<List<AppInfo>>> searchApps(String keyword, {bool forceRefresh});

  // 按分类搜索
  Future<ChannelResult<List<AppInfo>>> searchByCategory(String categoryId, {bool forceRefresh});

  // 获取所有分类
  Future<ChannelResult<List<AppCategory>>> getAllCategories({bool forceRefresh});

  // 检查更新
  Future<ChannelResult<bool>> checkUpdate();

  // 执行更新
  Future<ChannelResult<bool>> doUpdate({Function(int current, int total)? onProgress});

  // 缓存管理
  Future<void> clearCache();
  Future<int> getCacheSize();
}
```

**渠道管理器特性：**
- 多渠道注册与优先级管理
- 手动指定渠道查询
- 自动降级查询（`getAllAppsWithFallback`）
- 渠道可用性检查
- 统一的缓存管理

#### 2. Channel 测试页面
新增了用于测试渠道系统的独立页面。

**新增文件：**
```
lib/page/home/tab/channeltest/
├── state.dart      # 状态管理
├── logic.dart      # 业务逻辑
└── view.dart       # UI 界面
```

**功能特性：**
- 渠道选择器（支持切换 LocalDB/GitHub/Http）
- 7 种测试操作（getAllApps、getAppInfo、searchApps、searchByCategory、getAllCategories、checkUpdate、checkAllUpdates）
- 动态参数输入（根据操作类型显示不同输入框）
- 结果元信息显示（来源渠道、成功状态、是否缓存）
- 应用列表展示
- 缓存管理功能

### 🔧 修改内容

#### 1. 核心配置更新

**`lib/main.dart`**
```dart
// 新增导入
import 'package:gstore/core/channel/ChannelIntegration.dart';

// 在 registerService() 中初始化渠道系统
await ChannelIntegration.initialize();
```

**`lib/core/core.dart`**
```dart
// 新增导出
export 'package:gstore/core/channel/channel.dart';
```

**`lib/core/icons/Icons.dart`**
```dart
// 新增 Channel 相关图标（使用 Material Icons 替代）
```

#### 2. 首页导航更新

**`lib/page/home/view.dart`**
- 添加 Channel 测试页面到 PageView
- 新增底部导航栏 "Channel" 标签（使用 Icons.science）

### 📐 架构设计

#### 渠道类型与优先级
| 渠道 | 优先级 | 离线支持 | 说明 |
|------|--------|----------|------|
| LocalDbChannel | 1 | ✅ | 本地 SQLite 数据库 |
| GitHubChannel | 2 | ❌ | GitHub API |
| HttpChannel | 3 | ❌ | 通用 HTTP API |

#### 数据流
```
UI 层
  ↓
ChannelManager (统一入口)
  ↓
IChannel 抽象接口
  ↓
具体实现 (LocalDbChannel/GitHubChannel/HttpChannel)
  ↓
数据源 (数据库/GitHub API/HTTP API)
```

### 💡 使用示例

#### 基本使用
```dart
final manager = Get.find(tag: 'channelManager');

// 使用默认渠道
var result = await manager.getAllApps();

// 指定渠道
var result = await manager.getAllApps(from: ChannelType.localDb);

// 自动降级
var result = await manager.getAllAppsWithFallback(
  preferredOrder: [ChannelType.localDb, ChannelType.github],
);
```

#### 在 Logic 中使用
```dart
class ApplistLogic extends GetxController {
  late ChannelManager _channelManager;

  @override
  void onReady() async {
    _channelManager = Get.find(tag: 'channelManager');
    await _loadApps();
  }

  Future<void> _loadApps() async {
    var result = await _channelManager.getAllApps(
      from: ChannelType.localDb,
    );

    if (result.success) {
      state.apps = result.data ?? [];
      state.dataFrom = result.from; // 显示数据来源
      update();
    }
  }
}
```

### 🐛 修复的问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 自定义图标代码点不存在 | AliIcon 中新增的图标无对应字体 | 替换为 Material Icons |
| FilterChip.checkmark 参数不存在 | Flutter API 变更 | 改用 showCheckmark: false |
| 变量名冲突 | available 同时用作列表和布尔值 | 重命名为 availableTypes/isAvailable |
| DatabaseExecutor.path 不存在 | Floor 数据库接口无 path 属性 | 简化 getCacheSize() 实现 |

### 📝 后续扩展

如需添加新渠道，实现 `IChannel` 接口即可：

```dart
class CustomChannel implements IChannel {
  @override
  ChannelInfo info = ChannelInfo(
    type: ChannelType.custom,
    name: 'CustomChannel',
    description: '自定义数据源',
  );

  // 实现接口方法...
}

// 注册渠道
ChannelManager.instance.registerChannel(CustomChannel());
```

---

## 文件清单

### 新增文件 (11 个)
- `lib/core/channel/channel.dart`
- `lib/core/channel/ChannelIntegration.dart`
- `lib/core/channel/IChannel.dart`
- `lib/core/channel/ChannelManager.dart`
- `lib/core/channel/model/ChannelType.dart`
- `lib/core/channel/model/ChannelInfo.dart`
- `lib/core/channel/model/ChannelResult.dart`
- `lib/core/channel/impl/LocalDbChannel.dart`
- `lib/core/channel/impl/GitHubChannel.dart`
- `lib/core/channel/impl/HttpChannel.dart`
- `lib/page/home/tab/channeltest/state.dart`
- `lib/page/home/tab/channeltest/logic.dart`
- `lib/page/home/tab/channeltest/view.dart`
- `develop-log.md`

### 修改文件 (4 个)
- `lib/main.dart` - 添加渠道系统初始化
- `lib/core/core.dart` - 添加渠道模块导出
- `lib/core/icons/Icons.dart` - 添加 Channel 图标常量
- `lib/page/home/view.dart` - 添加 Channel 测试标签页

---

## 2025-03-14 - 统一详情页面架构

### 📦 新增功能

#### 1. 统一应用详情数据模型

**新增文件：**
```
lib/core/model/AppDetailInfo.dart
```

**核心类：**
- `AppDetailInfo` - 统一的应用详情信息
  - 基础字段：appId, name, icon, description, version, developer, packageName, projectUrl
  - `sections` - 可展示的区块列表（动态控制显示内容）
  - `downloads` - 下载信息列表
  - `extra` - 渠道特有扩展信息（Map类型，灵活扩展）

- `DownloadInfo` - 下载信息
  - url, name, size, downloadCount, version, publishedAt, platform

- `ScreenshotInfo` - 应用截图
  - url, description

- `StatisticsInfo` - 统计数据
  - stars, forks, watchers（GitHub）
  - downloads, rating, ratingCount, favorites（应用商店）

- `DetailSection` - 详情页可展示的区块枚举
  - version, statistics, screenshots, readme, downloads, rating, developer, changelog, permissions

#### 2. IChannel 接口扩展

**新增方法：**
```dart
Future<ChannelResult<AppDetailInfo>> getAppDetail(String appId, {bool forceRefresh});
```

各渠道实现：
- **GitHubChannel**: stars, forks, README, releases 下载链接
- **VivoChannel**: 截图、评分、下载量、权限说明、详细介绍
- **LocalDbChannel**: 版本、下载、README（从本地数据库获取）
- **HttpChannel**: 基础信息、下载（从 HTTP API 获取）

#### 3. 详情页面 Section 组件系统

**新增文件：**
```
lib/page/detail/widgets.dart
```

**可复用组件：**
- `VersionSection` - 版本信息
- `StatisticsSection` - 统计数据（支持 GitHub stars/forks 和应用商店评分）
- `ScreenshotsSection` - 应用截图（横向滚动）
- `ReadmeSection` - README/详细介绍（Markdown 渲染）
- `DownloadsSection` - 下载列表（支持下载和二维码）
- `RatingSection` - 评分信息（星星显示）
- `DeveloperSection` - 开发者信息
- `ChangelogSection` - 更新日志
- `PermissionsSection` - 权限说明

#### 4. 重构详情页面

**修改文件：**
```
lib/page/detail/state.dart
lib/page/detail/logic.dart
lib/page/detail/view.dart
```

**核心变化：**
- 不再直接访问 GitHub API
- 通过 `ChannelManager.getAppDetail()` 获取统一数据
- 根据 `sections` 列表动态渲染页面
- 支持不同渠道显示不同的内容组合

### 🔧 实现细节

#### 详情页面数据流

```
用户点击应用
    ↓
传递 AggregatedAppInfo(appInfo, channel)
    ↓
DetailLogic.loadDetail()
    ↓
ChannelManager.getChannel(channel)
    ↓
channel.getAppDetail(appId)
    ↓
返回 AppDetailInfo {
  sections: [...],      // 告诉页面该显示什么
  downloads: [...],     // 下载列表
  extra: {              // 渠道特有数据
    statistics: StatisticsInfo,
    screenshots: [...],
    readme: "...",
  }
}
    ↓
根据 sections 动态渲染各个 Section 组件
```

#### 不同渠道的 Sections 示例

| 渠道 | Sections | 说明 |
|------|----------|------|
| GitHub | statistics, version, downloads, readme | 显示 stars/forks |
| vivo | version, screenshots, statistics, rating, downloads, readme, permissions | 显示截图和评分 |
| LocalDb | readme | 最小数据集 |
| Http | version, downloads, readme | 取决于 API |

#### 平台检测

下载文件名自动解析平台信息：
```dart
String? _parsePlatformFromAssetName(String fileName) {
  if (fileName.contains('universal')) return 'universal';
  if (fileName.contains('arm64')) return 'arm64-v8a';
  if (fileName.contains('armeabi-v7a')) return 'armeabi-v7a';
  if (fileName.contains('x86_64')) return 'x86_64';
  // ...
}
```

### 🐛 修复的问题

| 问题 | 解决方案 |
|------|----------|
| jsonDecode 返回类型不匹配 | 添加 `as String` 类型转换 |
| LocalDbChannel.getAllReleases 不存在 | 简化实现，不依赖 release 数据 |
| CustomLinkBuilder 未定义 | 移除自定义 builder，使用默认 Markdown 样式 |
| ScalableImageWidget 未导入 | 简化 imageBuilder，只支持网络图片 |
| onLinkTap 空安全问题 | 使用 `?.call()` 安全调用 |
| state 变量作用域问题 | 在 _buildHeader 中添加 `final state = logic.state;` |

### 📊 架构优势

1. **统一数据模型**：不同渠道返回相同结构的数据
2. **灵活扩展**：通过 `extra` 字段支持渠道特有信息
3. **动态渲染**：根据 `sections` 控制显示内容
4. **解耦合**：页面不直接依赖特定渠道的 API

### 📝 后续优化

1. 添加缓存机制，减少重复请求
2. 支持离线查看已加载的详情
3. 添加更多渠道特有 Section（如评论、评价历史等）
4. 优化 Markdown 渲染，支持更多语法和样式
