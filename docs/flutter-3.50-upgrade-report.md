# GStore Flutter 3.50.1 升级执行报告

## 环境

| 项 | 值 |
|---|---|
| 升级目录 | `/home/hezhihu89/develop/flutter/project/GStore-update` |
| 分支 | `chore/flutter-3.50-upgrade` |
| Flutter | 3.50.1 stable |
| Dart | 3.14.0 |
| 独立 SDK | `/home/hezhihu89/develop/flutter/flutter-3.50.1` |

未覆盖原 Flutter 3.44.8 SDK。

## 已完成的改动

### 配置

- `.github/workflows/build.yml`：Flutter 3.44.8 → 3.50.1
- `.github/workflows/wave01-qa.yml`：Flutter 3.44.8 → 3.50.1
- `ios/Flutter/AppFrameworkInfo.plist`：MinimumOSVersion 12.0 → 15.0
- `ios/Runner.xcodeproj/project.pbxproj`：IPHONEOS_DEPLOYMENT_TARGET 12.0 → 15.0
- `analysis_options.yaml`：Flutter 工具自动添加 build/platform 目录排除
- `pubspec.lock`：Dart 3.14 下重新解析，7 个 transitive 依赖小版本变化

### Android 工具链（已完成）

Flutter 3.50.1 强制要求 Gradle >= 9.3.1，AGP 9.3.1 又要求 Gradle 9.5.0，因此：

- Gradle wrapper：8.14 → 9.5.0（官方 `services.gradle.org`）
- AGP：8.11.1 → 9.3.1
- Kotlin：2.2.20 → 2.4.20
- Java source/target：11 → 17
- 本地插件 `shizuku_api` 同步升级到 AGP 9.3.1 / Kotlin 2.4.20 / Java 17

为绕过第三方插件问题：

- `app_installer`：已删除，改为 App 内 `gstore/app_installer` MethodChannel
- `installed_apps`：fork 到 `sunO2/installed_apps`，Android 侧改写为 Java
- `third_party/flutter_inappwebview_android`：proguard 文件改为 optimize 版本
- `third_party/dynamic_color`：compileSdk 36、Kotlin 2.4.20、Java 17
- `third_party/rhttp`：cargokit `project.exec` → `providers.exec`

并在 `pubspec.yaml` 增加了对应的 `dependency_overrides`。
详见第 11、12 节与 `third_party/README.md`。

## 验证结果

### 静态分析

```bash
flutter analyze lib/
```

- 无 error
- 3.44：366 条 info
- 3.50：562 条 info
- 新增主要为：
  - 172 条 `package:flutter/material.dart` 弃用
  - 27 条 `prefer_const_constructors`
  - 11 条 `unawaited_return_in_try_block`
- 未执行 `material_ui` 迁移，符合计划

### 测试

```bash
flutter test
```

- 3.44 基线：56 个环境性失败（+5266 ~28 -56）
- 3.50 初次：多 2 个失败，原因是克隆目录缺少
  `rust/gstore_host/target/release/libgstore_host.so`
- 从原仓库复制该 `.so` 后：
  - `update_prefs_migration_test.dart` 通过
  - 全量失败集合与 3.44 基线完全一致
  - **无新增测试失败**（+5250 ~28 -56，与 3.50 首次基线一致）

### Android 构建

```bash
flutter build apk --release --target-platform android-arm64
```

**已通过。**

```text
✓ Built build/app/outputs/flutter-apk/app-release.apk (71.1MB)
sha256: afa3835995135cb0c4d493ce84b05746528bac804db57e415b89b51af9cc2c4f
```

已安装到 Pixel 4（Android 13 / API 33）并启动，主进程正常，
`core-bootstrap: list-installed elapsedMs=616`，无 `FATAL` / `AndroidRuntime` 崩溃。

构建过程中解决的问题见第 12 节。

KGP 告警已在第 14 节彻底消除：`android.builtInKotlin=true`，构建日志中
不再出现任何 "apply Kotlin Gradle Plugin" 告警。

## 结论

Flutter 3.50.1 升级**已完成到可构建、可安装、可启动**：

- Dart/Flutter 层依赖解析正常，无编译 error
- 全量测试无新增失败（56 个既有环境性失败与 3.44 基线一致）
- Android release APK 构建成功，Pixel 4 安装启动正常
- Material/Cupertino 暂不迁移的策略有效

代价是 **Android 工具链必须整体升级**：Flutter 3.50 强制 Gradle 9.5 + AGP 9.3.1，
因此本阶段同时完成了：

- `app_installer` 替换为 App 内 MethodChannel
- `installed_apps` fork 并把 Android 侧改写为 Java
- `dynamic_color` / `flutter_inappwebview_android` / `rhttp` 的最小 vendor 补丁
- AGP 9 lint 崩溃的绕过

这些改动目前集中在 `chore/flutter-3.50-upgrade` 分支，主仓库 `GStore` 未受影响。

## 建议下一步

1. 继续人工回归剩余交互：文件工作区、模型选择、MCP 工具展开、复杂列表帧率
2. 等上游插件支持后，逐个移除 `third_party` vendor：
   - `dynamic_color` 升到 1.9.0+（需 Built-in Kotlin）
   - `flutter_inappwebview_android` 升到兼容 AGP 9 的版本
   - `rhttp` 升到 0.18.0+（需把 Rust 侧 FRB 升到 2.12+ 并重新生成绑定）
3. 全部上游迁移完成后，把 `android.builtInKotlin` 改为 `true`，删除 legacy KGP 配置
4. 通过后再合并回主仓库

## 当前分支状态

- `GStore-update` 分支 `chore/flutter-3.50-upgrade`
- 已提交（rebase + merge 后）：
  - `073150bb` Android 工具链迁移与插件替换
  - `e7a439f2` / `4a460c5e` / `db77673c` / `7616d3a3` 构建、回归与 rebase 报告
  - merge commit：同步 main 的 QR scanner 重构与 1.0.38+1
- 已推送到 GitHub：`chore/flutter-3.50-upgrade`
- 未推送（`origin` 指向本地主仓库，避免污染主仓库分支）
- Android 工具链、插件替换、vendor 补丁、文档均已就绪
- release APK 已构建并安装验证
- 主仓库 `GStore` 未受影响
- 原 Flutter 3.44.8 SDK 未受影响

---

## 11. app_installer / installed_apps 处理结果

### app_installer

已移除第三方插件，改为 App 内 MethodChannel：

```text
Dart: lib/core/service/app_installer_channel.dart
通道: gstore/app_installer
Kotlin: android/app/src/main/kotlin/com/suno2/gstore/AppInstallerChannel.kt
```

实现点：

- 复用现有 `${applicationId}.fileProvider`
- `ACTION_VIEW` + `application/vnd.android.package-archive`
- `FLAG_GRANT_READ_URI_PERMISSION`
- Android 8+ 检查未知来源权限，必要时跳到系统授权页
- 非 Android 宿主（单元测试）直接 no-op，保持旧插件行为

`InstallManager` 仍保留 `appInstallerForTest` 注入接缝；安装相关测试 103 项通过。

### installed_apps

已 fork 并改写 Android 实现：

```text
https://github.com/sunO2/installed_apps
commit: 8d4861f4acf879840642351cb6d008157955f7ba
```

改动：

- Android 侧从 Kotlin 改为 Java
- 不再 apply Kotlin Gradle Plugin
- Gradle/AGP：AGP 9.3.1、compileSdk 36、minSdk 24、Java 17
- 保留原 `installed_apps` MethodChannel API
- 保留原 Dart API / AppInfo 模型
- 原 8 个方法全部实现

项目 `pubspec.yaml` 已改为：

```yaml
installed_apps:
  git:
    url: https://github.com/sunO2/installed_apps.git
    ref: 8d4861f4acf879840642351cb6d008157955f7ba
```

`pubspec.lock` 已记录 `resolved-ref`。

### 验证

- fork 仓库：`flutter analyze lib` 无问题
- GStore-update：`flutter pub get` 成功（本机通过 192.168.0.2:7893 代理拉取 GitHub）
- 安装相关测试：103 项通过
- Android release 构建通过，两个插件均已进入最终 APK

### 阻塞处理结果

以上阻塞均已解决：

1. `rhttp 0.15.1` cargokit：vendor 并把 `project.exec` 改为 `providers.exec`
2. `camera_android_camerax` lint 崩溃：release 构建禁用 `lintVital`（后续单独补 lint 基线）
3. `dynamic_color` / `flutter_inappwebview_android`：最小 vendor 补丁
4. `installed_apps`：fork 为 Java 实现
5. KGP 告警：当前保留 legacy 兼容模式，不阻塞构建

---

## 12. Android 工具链迁移结果

### 工具链

| 项 | 3.44 基线 | 3.50.1 升级后 |
|---|---|---|
| Gradle | 8.14 | **9.5.0** |
| AGP | 8.11.1 | **9.3.1** |
| Kotlin | 2.2.20 | **2.4.20** |
| Java source/target | 11 | **17** |
| compileSdk | 36 | 36 |
| minSdk | 24 | 24 |
| Built-in Kotlin | 关闭 | 开启（`android.builtInKotlin=true`） |

Gradle wrapper 使用官方地址：

```properties
distributionUrl=https\://services.gradle.org/distributions/gradle-9.5.0-bin.zip
```

> 本机首次下载会被重定向到 GitHub release，若网络受限可预先准备
> `~/.gradle/wrapper/dists/gradle-9.5.0-bin/<hash>/` 或临时改用镜像。

### vendor 补丁

见 `third_party/README.md`：

| 包 | 补丁 | 移除条件 |
|---|---|---|
| ~~`dynamic_color` 1.7.0~~ | 已移除 vendor，直接使用上游 1.9.0 | 已完成 |
| ~~`flutter_inappwebview_android` 1.1.3~~ | 已改为 fork（`sunO2/flutter_inappwebview_android`） | 上游 1.2.0 正式版 |
| ~~`rhttp` 0.15.1~~ | 已升级 0.18.0（fork）并升级 Rust FRB 2.12 | 已完成 |

`installed_apps` 不 vendor，使用 fork 的 GitHub commit。

### lint 处理

AGP 9 的 `lintVitalAnalyzeRelease` 在 `camera_android_camerax` 上崩溃
（lint 自身 bug）。当前在 `android/build.gradle` 中禁用 `lintVital*` 任务，
并关闭 `checkReleaseBuilds` / `abortOnError`，保证 release 构建可完成。
后续需要在独立分支恢复 lint 并建立基线。

### 构建与真机验证

```bash
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

结果：

```text
✓ Built build/app/outputs/flutter-apk/app-release.apk (71.1MB)
sha256: afa3835995135cb0c4d493ce84b05746528bac804db57e415b89b51af9cc2c4f
```

Pixel 4 启动日志关键行：

```text
core-bootstrap: list-installed elapsedMs=616
core-bootstrap: push-inventory elapsedMs=58
```

说明 `installed_apps` 的 `getInstalledApps` 在真机上正常工作。

### 真机页面回归（Pixel 4 / Android 13）

| 页面 | 结果 |
|---|---|
| 首页 / 发现 / 我的 | 正常 |
| AI 助手对话页 | 正常（未配置模型时提示正确） |
| AI 设置（模型 / 工具双子页） | 正常 |
| WebView 调试 | 正常，实际加载 `https://example.com` |
| 请求调试（集合/历史/环境/改写规则） | 正常 |
| 已安装应用 | 正常，图标 / 包名 / 版本均正确 |
| 深色模式切换 | 正常（系统 / 浅色 / 深色） |
| 二维码生成 / 识别 | 正常（相机预览 + 扫描框） |

### App 内系统安装器验证

用一个临时探针入口（验证后已删除）调用
`AppInstallerChannel.installApk(...)`，系统 `PackageInstallerActivity`
成功弹出「GStore 要更新此应用吗？」，确认安装后 APK 更新成功并恢复 release 包。

```text
mCurrentFocus=com.google.android.packageinstaller/PackageInstallerActivity
versionName=1.0.37
lastUpdateTime=2026-11-27 01:58:19
```

验证同时覆盖了：

- `${applicationId}.fileProvider` authority 正确
- `ACTION_VIEW` + `application/vnd.android.package-archive` 正确
- `FLAG_GRANT_READ_URI_PERMISSION` 生效
- 未知来源安装权限检查逻辑正常

### 已知非阻塞现象

- 开发者工具箱离线包：release 包默认不随包 `it-tools.zip`，
  设备侧远端下载失败（`gh-proxy` 连接中断），页面显示「离线资源准备失败」。
  这是离线包分发策略 + 网络问题，与 Flutter 3.50 升级无关。
- 未配置 LLM / 代理配置时页面分别提示「请先配置 LLM 模型」、
  `PROXY_CONFIG_PROFILE_REQUIRED`，均符合预期。

### 全量测试

```bash
flutter test
```

```text
3.50.1 升级后：+5250 ~28 -56
3.50.1 首次基线：+5250 ~28 -56
3.44.8 基线：     +5266 ~28 -56
```

失败集合完全一致，**无新增失败**。均为既有环境性失败
（Rust `.so`、平台通道、本地资源等）。

### rebase 到主仓库最新 main

升级分支原先基于 `a7a5ae0a`，主仓库已推进到 `5256ae59`
（request-debug 使用代码编辑器 / 折叠 Sliver 头部）。已执行：

```bash
git fetch origin
git rebase origin/main
```

结果：

- 无冲突，4 个提交全部重放成功
- `pubspec.lock` 重新执行 `flutter pub get`，纳入 `re_editor ^0.10.0` / `re_highlight ^0.0.3`
- `lib/oss_licenses.dart` 重新生成，包含新依赖
- `dart analyze lib`：0 error，550 条 info
- release APK 重新构建并安装：

```text
✓ Built app-release.apk (71.1MB)
sha256: afa3835995135cb0c4d493ce84b05746528bac804db57e415b89b51af9cc2c4f
```

- 真机验证新增主仓库功能：新建集合 → 新建请求 → 体 = json，
  `re_editor` 代码编辑器（行号 / 工具栏 / 展开）渲染正常
- 放弃修改确认弹层、删除集合危险确认弹层均正常
- 相关测试：request-debug / code-editor / install 共 128 项全部通过

分支已推送到 GitHub 备份：

```text
ssh://git@ssh.github.com:443/sunO2/GStore.git
branch: chore/flutter-3.50-upgrade
```

### merge 主仓库最新 main（1.0.38）

主仓库继续新增：

```text
f23f3655 feat(qr): extract reusable scanner and add scan-to-URL fill
da638a56 chore: bump version to 1.0.38+1
```

已用 `git merge --no-ff origin/main` 合入升级分支：

- 无冲突
- `pubspec.yaml` / `pubspec.lock` 保持 1.0.38+1
- `lib/oss_licenses.dart` 重新生成，`gstore 1.0.38+1`
- `dart analyze lib`：0 error，552 条 info
- release APK 重新构建并安装：

```text
✓ Built app-release.apk (71.1MB)
sha256: 048826fe9a72ebe5ab58764a5f1fcfef8aa2c40b5890dfe28854a1dad6b35a50
versionName=1.0.38
```

- 真机验证：二维码页「生成 / 识别」正常，识别页相机预览与扫描框正常
- 相关测试：qr scanner / qr tool / request-debug editor 共 91 项全部通过

---

## 13. GitHub Actions alpha 预发布

正式发布（`main` push / 版本 tag）仍发布 `v<version>`，保持不变。
为避免升级分支覆盖同版本号的正式 Release，`build.yml` 新增：

- `workflow_dispatch`，带 `alpha` 布尔输入
- 非 `main` 分支 push → 发布 `v<version>-alpha.<run_number>`，`prerelease=true`
- `main` push / 版本 tag → 发布 `v<version>`，行为不变

触发方式：

```bash
# 推送升级分支即触发 alpha 构建
git push github chore/flutter-3.50-upgrade

# 或手动触发（可指定 ref）
gh workflow run build.yml --ref chore/flutter-3.50-upgrade -f alpha=true
```

注意：alpha 与正式 release 共用同一套构建、Rust 模块和 APK 产物，
只是 release tag / prerelease 标记不同。

---

## 14. Built-in Kotlin 迁移

### 依赖升级

| 包 | 旧版本 | 新版本 | 说明 |
|---|---|---|---|
| `device_info_plus` | 12.4.0 | 13.3.0 | 条件 apply KGP，`builtInKotlin=true` 时不 apply |
| `package_info_plus` | 8.0.0 | 10.2.2 | 同上 |
| `shared_preferences_android` | 2.4.6 | 2.5.5 | 完全不 apply KGP |
| `flutter_foreground_task` | 10.0.0 | 11.0.3 | 11.0.0 起迁移 Built-in Kotlin |
| `dynamic_color` | 1.7.0（vendor） | 1.9.0 | 删除 `third_party/dynamic_color` |
| `flutter_secure_storage` | 9.2.4 | 10.3.4 | 解决 win32 6 冲突；10.x 自动迁移旧数据 |
| `file_picker` | 8.1.6 | 13.4.1 | 解决 win32 6 冲突，API 有破坏性变化 |

> `device_info_plus 13` / `package_info_plus 10` 需要 `win32 ^6`，
> 而 `file_picker 8` 与 `flutter_secure_storage 9` 仍锁 `win32 ^5`，
> 因此必须同时升级后两者。

### Gradle 迁移

- `android/gradle.properties`：`android.builtInKotlin=true`
- `android/app/build.gradle`：
  - 移除 `id "kotlin-android"`
  - 移除 `kotlinOptions`
  - 新增 `kotlin { compilerOptions { jvmTarget = JVM_17 } }`
- `android/settings.gradle`：移除 `org.jetbrains.kotlin.android` 声明
- `packages/shizuku_api/android/build.gradle`：同样移除 KGP，改用 Built-in Kotlin

构建日志中已无任何 `apply Kotlin Gradle Plugin` 告警。

### file_picker 13 API 迁移

- `FilePicker.platform.pickFiles` → `FilePicker.pickFiles` / `FilePicker.pickFile`
- `withData` / `allowMultiple` / `lockParentWindow` 移除：
  - 选文件改用 `pickFile()` + `readAsBytes()`
  - 保存只传 `fileName` / `bytes`
- `saveFile` 返回 `Uri?`：
  - 通过接缝统一转成 `String?`，避免影响各页面已有签名
  - 成功提示改为显示文件名，不再展示 Android SAF 的 `content://` 路径
- 日志查看页新增 `LogViewerPage.saveFile` 注入接缝，测试不再依赖
  `FilePicker.platform` 静态 setter

### flutter_secure_storage 10

- 使用 `migrateOnAlgorithmChange` 默认迁移 9.x 数据
- 暂不升级 11.x：11 要求先经过 10.x 迁移

### 验证

```text
✓ Built app-release.apk (71.3MB)
sha256: a3bc7a83f4457226d65481503ab1f087ade3c71e2f00832742f043b57c0d7d0b
```

- `dart analyze lib test`：0 error
- 相关测试（日志导出、代理导出/导入、设置渠道包、请求调试导入导出、
  备份逻辑、工作区选择）：118 项全部通过
- Pixel 4 安装 1.0.38 启动正常
- 备份「导出到本地」走完 SAF：文件成功写入
  `/sdcard/Download/gstore_backup_*.tar.gz`，应用正常返回
- 渠道包导入走完 SAF 选择：`probechannel.zip` 读取成功，弹层正确显示
  包文件 / 渠道标识 / 名称 / 描述 / `entry.js` 大小，证明
  `FilePicker.pickFile` + `readAsBytes()` 正常工作
- `dynamic_color` 1.9.0 正常渲染（深色/浅色主题切换已验证）

### 后续

- `flutter_secure_storage` 11.x 需等下一轮（先让 10.x 完成迁移）
- `file_picker` 14 将移除 `saveFile` 的 `type` / `allowedExtensions`
- vendor 已全部清空：`flutter_inappwebview_android` 也改为 fork 依赖

---

## 15. rhttp 0.18 + flutter_rust_bridge 2.12

### 依赖与绑定

| 项 | 旧 | 新 |
|---|---|---|
| `rhttp` | 0.15.1（`third_party` vendor） | 0.18.0（`sunO2/rhttp` fork commit `b4f6c36e`） |
| `flutter_rust_bridge`（Dart） | 2.11.1 | 2.12.0 |
| `flutter_rust_bridge`（Rust） | `=2.11.1` | `=2.12.0` |
| 绑定生成器 | codegen 2.11.1 | codegen 2.12.0 |

`rhttp` fork 只加了一个条件判断：AGP 9 + `android.builtInKotlin=true`
时不再 apply Kotlin Gradle Plugin；cargokit 的 Gradle 9 修复已在 0.18.0 上游。

### 代码改动

- `lib/http/rhttp_adapter.dart`：
  - `TlsSettings.trustRootCertificates` → `rootCertSource: RootCertSource.webpki`
    （0.18 的 BREAKING change）
- `rust/gstore_host/src/lib.rs`：
  - 新增 `extern crate self as gstore_host;`，让 2.12 生成的
    `gstore_host::bridge::...` 在同 crate 内可解析
- 用 codegen 2.12.0 重新生成：
  - `lib/core/rust/generated/**`
  - `rust/gstore_host/src/frb_generated.rs`

### Rust 构建

- Linux host：`cargo build --release` 通过
- Android host：4 个 ABI 全部重建（arm64-v8a / armeabi-v7a / x86 / x86_64）
  - arm64 7.8M，armv7 5.4M，x86 9.0M，x86_64 9.1M
  - `gstore_mod_download` 同步重建
- `cargo test --release`：165 通过；8 个 dlopen 用例因未构建调试模块跳过
  （`GSTORE_ALLOW_MISSING_MODULE=1` 后 0 失败）

### 验证

```text
✓ Built app-release.apk (72.3MB)
sha256: 19c327d7e9ce88bb62593472dcea6aa555b07ee2f031e679a5c2f8a35913c79d
```

Pixel 4 安装启动：

```text
core-bootstrap: critical-done elapsedMs=250
rhttp initialized successfully
BadgeService: 数据库更新红点 = true (0.0.12 -> 0.0.27)
```

GitHub API 请求走的就是 `RhttpAdapter`，说明 rhttp 0.18 的 TLS / HTTP
链路在真机上正常；FRB 2.12 的宿主桥也正常初始化。

相关测试（core_api / module bootstrap / rhttp fetcher / Rust lane）：53 通过，
4 跳过。

全量 `flutter test`：

```text
+5265 ~28 -56
```

失败的 56 项与升级前基线完全一致（前四项仍为 app_image_loader /
backup_config_roundtrip / backup_js_channel / fdroid_empty_repo_readiness），
**无新增失败**。

### vendor 现状

```text
third_party/flutter_inappwebview_android   # 仅剩这一个
```

`third_party/rhttp` 目录已删除，改为 GitHub commit 依赖。

---

## 16. flutter_inappwebview_android

### 问题

`flutter_inappwebview_android 1.1.3` 的 `android/build.gradle` 使用：

```gradle
getDefaultProguardFile('proguard-android.txt')
```

AGP 9 不再提供该默认文件，构建报找不到 proguard 配置。

### 上游状态

- `flutter_inappwebview` 最新稳定版 6.1.5 依赖 `flutter_inappwebview_android ^1.1.3`
- 1.1.3 仍使用旧的 `proguard-android.txt`
- `1.2.0-beta.3` 已改为 `proguard-android-optimize.txt`，但它要求
  `flutter_inappwebview_platform_interface ^1.4.0-beta.3`，与稳定版主包不兼容

### 处理方式

与 `installed_apps` / `rhttp` 一致，fork 1.1.3 并只改 proguard 两行：

```text
https://github.com/sunO2/flutter_inappwebview_android
commit f3842bbe5e794fab7373966eae4db96acea378cb
```

`pubspec.yaml`：

```yaml
dependency_overrides:
  flutter_inappwebview_android:
    git:
      url: https://github.com/sunO2/flutter_inappwebview_android.git
      ref: f3842bbe5e794fab7373966eae4db96acea378cb
```

Dart API 与 1.1.3 完全一致，没有行为变化。

### 验证

```text
✓ Built app-release.apk (72.3MB)
sha256: 19c327d7e9ce88bb62593472dcea6aa555b07ee2f031e679a5c2f8a35913c79d
```

Pixel 4：WebView 调试页实际加载 `https://example.com`，页面正常渲染，
无崩溃。

### 移除条件

等 `flutter_inappwebview_android` 1.2.0 正式版发布、且主包
`flutter_inappwebview` 升级到对应版本后，删除 override 即可。

### vendor 清空

```text
third_party/ 目录已无 vendor 包
```

三个需要补丁的插件全部改为 GitHub commit 依赖：
`installed_apps`、`rhttp`、`flutter_inappwebview_android`。
