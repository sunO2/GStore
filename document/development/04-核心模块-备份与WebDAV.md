# 核心模块：备份与 WebDAV

> 开发 Wiki 第四篇 · 数据导出导入与云端同步

## 1. 模块结构

```
lib/core/service/backup_service.dart   # 备份核心服务
lib/core/model/BackupData.dart         # 备份数据模型（json_serializable）
lib/core/webdav/
├── webdav_client.dart                 # WebDAV 客户端（dio）
└── webdav_config.dart                 # 配置模型 + secure_storage 存储
lib/page/backup/                       # 备份管理页
lib/page/webdav_config/                # WebDAV 配置页
```

## 2. 数据模型（BackupData.dart）

| 类 | 说明 |
| --- | --- |
| `BackupVersion` | 格式版本：`v1_0`（仅聚合库）、`v2_0`（聚合库 + 渠道库） |
| `BackupMetadata` | 元数据：版本、导出时间、应用版本、总数、各渠道数量、选项 |
| `BackupOptions` | 导出选项：是否含图标/描述/分类/extra/压缩/仅启用/应用配置 |
| `BackupAppItem` | 聚合库应用条目（含渠道、排序、启用状态） |
| `ChannelAppBackupItem` | 渠道库应用条目（可序列化的 ChannelAddedApp） |
| `BackupData` | 完整备份（metadata + apps + channelApps + appConfig + extras） |

> 说明：`extras`（v2.1 新增）可携带 F-Droid 源列表、Agent 配置等扩展数据。

### 序列化约定

- `BackupData.fromJson` 兼容 v1.0（无 `channelApps` 字段）。
- `BackupVersion` 用 `@JsonValue('1.0'/'2.0')` 序列化。
- 嵌套对象在 `jsonEncode` 时展开（生成代码直接持有对象）。

## 3. BackupService API

| 方法 | 说明 |
| --- | --- |
| `exportData({options, channels})` | 导出为内存对象 |
| `exportToFile(...)` / `exportToCompressedFile(...)` | 导出到本地文件（JSON / tar.gz） |
| `importFromFile(...)` / `importData(...)` | 导入（替换/合并模式） |
| `getBackupFiles()` | 列出本地备份文件 |
| `deleteBackupFile(path)` | 删除备份 |
| `uploadToWebDav(config, {compressed, includeAppConfig})` | 上传到 WebDAV（tar.gz） |
| `downloadFromWebDav(config, remotePath, {mode, restoreAppConfig})` | 从 WebDAV 下载并导入 |
| `testWebDavConnection(config)` | 连接测试 |
| `getStatistics()` | 备份统计 |

### 导入模式（BackupImportMode）

- `replace`：替换现有数据。
- `merge`：合并（默认）。

### 导入流程

```
downloadFromWebDav
  → WebDavClient.downloadFile(remotePath)   # GET 下载字节
  → gzip.decode + TarDecoder                # 解压 tar.gz
  → 提取 apps.json / app_config.json
  → BackupData.fromJson（版本校验 v1.0/v2.0）
  → ConfigManager.importAll（可选，恢复应用配置）
  → importData（替换/合并写入聚合库与渠道库）
```

## 4. WebDAV 客户端（webdav_client.dart）

基于 dio，所有路径自动规范化（补 `/`、去 `//`）：

| 方法 | HTTP 方法 | 说明 |
| --- | --- | --- |
| `testConnection` | OPTIONS + MKCOL | 连通性与认证探测 |
| `ensureDirectory(dirPath)` | MKCOL | 确保目录存在（201/405 视为成功） |
| `uploadFile(remotePath, data)` | PUT | 上传（429 自动重试 3 次，2s/4s/6s 退避） |
| `downloadFile(remotePath)` | GET | 下载为字节 |
| `deleteFile(remotePath)` | DELETE | 删除 |
| `fileExists(remotePath)` | HEAD | 存在性检查 |
| `listFiles(dirPath, {pattern})` | PROPFIND | 列目录（解析 XML，支持通配符过滤） |
| `findLatestFile(dirPath, pattern)` | — | 查找最新匹配文件 |

### 认证

Basic Auth（`base64(username:password)`），请求头注入。

### 配置文件

`webdav_config.dart`：

- `WebDavConfig`：url / username / password / backupPath（默认 `/GStore`）/ enableHttps。
- `baseUrl` getter：自动补 `https://`（或 http），带协议时移除末尾斜杠。
- `WebDavConfigManager`：基于 `flutter_secure_storage` 存取凭据。

## 5. 备份文件命名

```
gstore_backup_2026-08-10T10-30-00.tar.gz   # WebDAV / 压缩导出
```

文件名含时间戳（ISO8601 去冒号），`listFiles` 用 `gstore_backup_*.tar.gz` 模式过滤。

## 6. 相关测试

`test/backup_data_test.dart`：模型序列化往返、v1.0 兼容、统计、转换函数。
`test/webdav_config_test.dart`：配置序列化、baseUrl 协议处理、isValid、copyWith。

## 7. 使用文档

用户向的使用指南见《使用 Wiki · 备份与恢复》。
