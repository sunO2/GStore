# GStore Flutter 3.50 升级计划

## 1. 目标与基线

### 当前基线

| 项目 | 当前值 |
|---|---|
| Flutter | 3.44.8 stable |
| Dart | 3.12.2 |
| CI Flutter | 3.44.8 |
| Android compileSdk / targetSdk | 36 / 36 |
| Android minSdk | 24 |
| AGP | 8.11.1 |
| Gradle | 8.14 |
| Kotlin | 2.2.20 |
| Java source/target | 11 |
| iOS deployment target | 12.0 |
| Rust bridge | flutter_rust_bridge 2.11.1 |
| 主要原生方案 | MethodChannel + flutter_rust_bridge |

### 目标版本

- Flutter **3.50.1 stable**（Dart 3.14.0）
- Android 工具链**必须**升级：Gradle 9.5.0 / AGP 9.3.1 / Kotlin 2.4.20 / Java 17
  - Flutter 3.50.1 要求 Gradle >= 9.3.1
  - AGP 9.3.1 要求 Gradle >= 9.5.0
  - 实测停留在 Gradle 8.14 / AGP 8.11.1 无法完成 Android 构建
- 保持现有 Material/Cupertino import，暂不迁移到 `material_ui` / `cupertino_ui`
- 保持 FRB + MethodChannel 架构，暂不引入 JNIgen / Pigeon native interop
- Android release APK 可构建、可安装、主要页面可用

## 2. 范围与非目标

### 本阶段要做

1. 在独立目录 `GStore-update` 中升级 Flutter 3.50.1
2. 更新 CI 的 Flutter 版本
3. 更新 `pubspec.lock`
4. 提升 iOS deployment target 到 15.0
5. 修复 3.50 引起的编译/测试/构建问题
6. Pixel 4 真机回归
7. 输出升级报告与残留风险

### 本阶段明确不做

- 不做 `material_ui` / `cupertino_ui` 全量迁移
- ~~不迁移 Built-in Kotlin~~（已在本阶段完成，见执行报告第 14 节）
- 不引入 JNIgen / FFIgen / Pigeon native interop
- 不启用 HCPP
- 不重构 Rust/FRB 架构

## 3. 主要收益

### Android / Impeller

- OpenGL shader 初始化移到后台线程，首帧更快
- Mali GPU 纹理加载崩溃修复
- 部分 OpenGL ES 2 纹理问题修复
- PowerVR B 系列 Vulkan 自动回退 OpenGL
- Pixel 4 当前走 Impeller OpenGLES，可能获得首帧与稳定性改善

### 安全

- release 构建拒绝外部 Intent 注入 `route` / `dart_entrypoint` / `cached_engine_id`
- release 构建拒绝运行时 `--dart-flags`

### Framework

- 滚动 / pinned header / sliver overscroll 修复
- 文本选择、RTL、`WidgetSpan` 排序修复
- 图片缓存逻辑尺寸、`reduceMotion`、无障碍修复
- `PageView` 内文本选择不再误翻页

### 后续能力

- JNIgen / FFIgen Objective-C 稳定
- Pigeon native interop preview
- HCPP 在 API 34+ + Vulkan 设备上的性能能力

## 4. 主要风险

### R1. Material/Cupertino 弃用（高）

- 项目有 173 个 `package:flutter/material.dart` import
- `dynamic_color` 的 `DynamicColorBuilder` 回调使用旧 `ColorScheme`
- `flutter_gen_ai_chat_ui`、`re_editor` 等依赖内部仍使用旧 `ThemeData`
- 新旧 Material 是不同库，公共 API 类型不能直接互赋
- 兼容桥 `MaterialUiCompatibilityBridge` 只能解决 `Theme.of` 读取，不能解决 API 类型耦合

**决策：本阶段保留旧 import，不执行 `dart fix migrate_design_widgets`，接受弃用警告。**

### R2. iOS 最低版本提升（中）

- 3.50 支持 iOS 15+
- 当前 `IPHONEOS_DEPLOYMENT_TARGET = 12.0`
- 需要改为 15.0；iOS 12/13/14 用户不再支持

### R3. Android 工具链（已发生，非可选）

- 3.50.1 强制要求 Gradle >= 9.3.1；AGP 9.3.1 要求 Gradle >= 9.5.0
- 实测 Gradle 8.14 / AGP 8.11.1 下构建直接失败，因此本阶段已升级：
  - Gradle 9.5.0
  - AGP 9.3.1
  - Kotlin 2.4.20
  - Java source/target 17
  - compileSdk 36
- 第三方插件的 AGP 9 / Gradle 9 兼容问题通过替换、fork、最小 vendor 补丁解决：
  - `app_installer`：已删除，改为 App 内 `gstore/app_installer` MethodChannel
  - `installed_apps`：fork 到 `sunO2/installed_apps`，Android 侧改写为 Java
  - `flutter_inappwebview_android`：vendor，proguard 改为 `proguard-android-optimize.txt`
  - `dynamic_color`：优先尝试升级到 1.9.0（官方声明支持 AGP 9），否则保留 vendor
  - `rhttp`：vendor，cargokit 的 `project.exec` 改为 `providers.exec`
- 本地插件 `packages/shizuku_api` 已升级到 AGP 9.3.1 / Kotlin 2.4.20 / Java 17
- Built-in Kotlin 已启用：`android.builtInKotlin=true`，app 与 `shizuku_api`
  不再 apply KGP；四个 plus/foreground 插件升级到内置 Kotlin 版本，
  `dynamic_color` 升级 1.9.0 并删除 vendor。构建已无 KGP 告警。

### R4. Impeller OpenGLES 视觉回归（中）

Pixel 4 实际后端是 Impeller OpenGLES。需要重点回归：

- AI 对话列表
- 请求调试长列表
- 性能 HUD / 图表
- 代理页面复杂卡片与模糊效果

### R5. 依赖兼容（中）

- 3.50 使用 Dart 3.14
- 重点检查 `flutter_rust_bridge`、`genkit`、`flutter_gen_ai_chat_ui`、`flutter_inappwebview`、`camera`、通知/前台服务插件
- `flutter pub get` 后检查 lockfile 变化

### R6. Web / 桌面（低）

- 项目有 web / desktop 目录，但主发布目标是 Android
- Web 3.50 有 legacy JS interop 弃用、SafeArea 行为变化
- 桌面有 macOS 12+ / Intel Mac 长期弃用策略

## 5. 执行步骤

### Phase 0：准备

- [x] 创建升级计划文档
- [x] 复制仓库到同级 `GStore-update`
- [x] 下载独立 Flutter 3.50.1 SDK，不覆盖当前 3.44.8
- [x] 在升级目录创建独立分支 `chore/flutter-3.50-upgrade`

### Phase 1：SDK 升级与依赖

- [x] 使用 Flutter 3.50.1 执行 `flutter --version`
- [x] 执行 `flutter pub get`
- [x] 检查 `pubspec.lock` 变化
- [x] 执行 `dart analyze lib/`
- [x] 执行现有测试套件
- [x] 记录既有失败用例，区分升级引入的问题

### Phase 2：Android 构建

- [x] 升级到 Gradle 9.5.0 / AGP 9.3.1 / Kotlin 2.4.20 / Java 17
- [x] 构建 `flutter build apk --release --target-platform android-arm64`
- [x] 检查 Rust 模块 `.so`、jniLibs、R8、签名配置
- [x] 安装到 Pixel 4 并启动

### Phase 3：iOS 配置

- [x] `IPHONEOS_DEPLOYMENT_TARGET` 从 12.0 改为 15.0
- [x] 检查 `ios/Flutter/AppFrameworkInfo.plist` 的 MinimumOSVersion
- [x] 检查 SPM / CocoaPods 状态
- [ ] 在有 macOS/Xcode 环境时构建 iOS（本 Linux 环境仅做配置修改）

### Phase 4：真机回归

- [x] Pixel 4（Android 13 / API 33 / Impeller OpenGLES）安装并启动
- [x] 首页 / 发现 / 我的
- [x] AI 助手对话页
- [x] AI 设置页模型/工具双子页
- [x] WebView 调试页（实际加载 example.com）
- [x] 请求调试页（集合/历史/环境/改写规则）
- [x] 已安装应用（图标 / 包名 / 版本）
- [x] App 内系统安装器（`gstore/app_installer` 拉起 PackageInstaller）
- [ ] 文件工作区 / 模型选择 / MCP 工具展开
- [ ] 首帧、滚动、返回过渡帧率

### Phase 5：CI 与收尾

- [x] CI `FLUTTER_VERSION` 改为 3.50.1
- [x] 更新升级报告
- [x] 确认无新增严重 warning（KGP 告警已消除）
- [x] 确认 release APK 产物与 SHA-256
- [ ] 决定是否合并回主仓库

## 6. 验证命令

```bash
# SDK
flutter --version

# 依赖
flutter pub get
flutter pub outdated

# 静态检查
dart analyze lib/

# 单元/组件测试
flutter test

# Android release
flutter build apk --release --target-platform android-arm64

# 安装
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 真机集成测试
flutter test integration_test/webview_smoke_test.dart -d <deviceId>
flutter test integration_test/cookie_sync_smoke_test.dart -d <deviceId>
```

## 7. 成功标准

- Flutter 3.50.1 下 `flutter pub get` 成功
- `dart analyze lib/` 无新增 error
- 现有可运行测试通过；既有环境性失败不扩大
- Android release APK 构建成功
- Pixel 4 安装启动正常
- 主要页面无崩溃、无严重布局回归
- AI 设置返回对话页无明显掉帧
- WebView/请求调试/Cookie 同步功能正常

## 8. 回滚方案

- 升级工作只在 `GStore-update` 的独立分支进行
- 主仓库 `main` 不受影响
- 若升级失败，直接删除 `GStore-update` 或切回升级前提交
- Flutter 3.50.1 使用独立 SDK 目录，不覆盖当前 3.44.8

## 9. 后续独立阶段

以下工作不阻塞 3.50 升级，但建议后续单独做：

1. Material/Cupertino 迁移到 `material_ui` / `cupertino_ui`
   - 先等待 `dynamic_color`、`flutter_gen_ai_chat_ui`、`re_editor` 等依赖迁移
   - 使用 `MaterialUiCompatibilityBridge` 过渡
2. `packages/shizuku_api` 迁移到 AGP Built-in Kotlin
3. AGP 9 / Gradle 9 / Java 17 升级
4. JNIgen 替代部分 MethodChannel 样板
5. API 34+ Vulkan 设备测试 HCPP

---

## 10. 实际执行发现（2026-11-27）

在 `GStore-update` 中使用 Flutter 3.50.1 实测后，原计划中“保持 AGP 8.11 / Gradle 8.14”的假设**不成立**。

### 10.1 Flutter 3.50.1 强制 Android 工具链升级

```text
Flutter 3.50.1 最低要求 Gradle 9.3.1
AGP 9.3.1 最低要求 Gradle 9.5.0
```

因此 Android 构建必须升级：

```text
Gradle 8.14      -> 9.5.0
AGP 8.11.1       -> 9.3.1
Kotlin 2.2.20    -> 2.4.20（当前兼容方案）
Java source/target 11 -> 17（当前兼容方案）
```

这不是可选的“后续阶段”，而是 Flutter 3.50 Android 构建的前置条件。

### 10.2 已完成的验证

- Flutter 3.50.1 / Dart 3.14.0 安装成功
- `flutter pub get` 成功（lockfile 仅少量 transitive 版本变化）
- `flutter analyze lib/` 无 error；新增 172 条 Material 弃用 info
- 全量测试与 3.44 基线对比：**55 个既有环境性失败完全一致，无新增失败**
- 新增的唯一失败是克隆目录缺少 `rust/gstore_host/target/release/libgstore_host.so`；
  从原仓库复制后该测试通过

### 10.3 Android 构建当前阻塞点

已定位并按顺序出现：

1. `Flutter 3.50.1 requires Gradle >= 9.3.1`
2. `AGP 9.3.1 requires Gradle >= 9.5.0`
3. `app_installer 1.3.1` 使用已被 Gradle 9 移除的 `jcenter()`
4. `flutter_inappwebview_android 1.1.3` 使用 AGP 9 不再支持的
   `getDefaultProguardFile('proguard-android.txt')`
5. `dynamic_color 1.7.0` 的 `compileSdkVersion 31` 低于 AGP 9 依赖要求
6. `installed_apps` git 版本在 Kotlin 2.4 下出现 nullable 编译错误
7. Flutter 3.50 警告以下插件仍 apply Kotlin Gradle Plugin：
   `device_info_plus`、`dynamic_color`、`flutter_foreground_task`、
   `installed_apps`、`package_info_plus`、`shared_preferences_android`、
   `shizuku_api`

**结论：Flutter 3.50 升级实际包含一次完整的 Android AGP 9 / Built-in Kotlin 迁移，工作量明显大于单纯 SDK 升级。**

### 10.4 当前建议

- 不要在同一个 PR 中同时完成 Flutter 3.50 + AGP 9 + 全量插件迁移
- 先保留 `GStore-update` 作为实验分支，记录上述阻塞点
- 下一阶段优先做：
  1. 升级/替换 `app_installer`（改为本地 MethodChannel 或维护 fork）
  2. 升级或 fork `flutter_inappwebview_android`、`dynamic_color`、`installed_apps`
  3. 将本地插件 `shizuku_api` 迁移到 Built-in Kotlin
  4. 逐个验证其余 KGP 插件
  5. 最后再合并回主仓库
