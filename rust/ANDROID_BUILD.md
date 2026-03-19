# Rust Android 构建脚本使用指南

## 概述

本项目提供了三个脚本来构建 Rust Android 库（.so 文件）：

1. **build_android_standalone.sh** - 推荐使用（独立版本）
2. **build_android_simple.sh** - 简化版本
3. **build_android_rust.sh** - 完整版本

生成的 so 文件会自动复制到 `android/app/src/main/jniLibs/` 目录。

## 快速开始

### 一键构建（推荐）

```bash
./build_android_standalone.sh
```

这个脚本会：
- 自动为所有 Android 架构编译 Rust 库
- 自动安装所需的 Rust targets
- 自动复制 so 文件到正确的位置
- 显示构建进度和结果

### 清理并重新构建

```bash
./build_android_standalone.sh clean
```

## 构建脚本对比

| 脚本 | 特点 | 推荐场景 |
|------|------|----------|
| build_android_standalone.sh | 无需 NDK，自动配置 | 日常开发 |
| build_android_simple.sh | 自动检测 NDK | 有 NDK 时使用 |
| build_android_rust.sh | 完整功能，支持清理 | CI/CD 环境 |

## 生成的文件

构建成功后，会在以下目录生成 so 文件：

```
android/app/src/main/jniLibs/
├── arm64-v8a/libfdroid_repo.so    (~3.5 MB) - 64位 ARM，推荐
├── armeabi-v7a/libfdroid_repo.so  (~3.2 MB) - 32位 ARM，兼容老设备
├── x86/libfdroid_repo.so          (~3.6 MB) - 32位 x86，模拟器
└── x86_64/libfdroid_repo.so        (~3.8 MB) - 64位 x86，模拟器
```

## 验证构建

运行脚本后，检查输出：

```bash
ls -lh android/app/src/main/jniLibs/*/
```

预期输出：
```
arm64-v8a/:
total 3500
-rwxrwxr-x 1 user user 3500000 Mar 15 16:00 libfdroid_repo.so

armeabi-v7a/:
total 3200
-rwxrwxr-x 1 user user 3200000 Mar 15 16:00 libfdroid_repo.so

x86/:
total 3600
-rwxrwxr-x 1 user user 3600000 Mar 15 16:00 libfdroid_repo.so

x86_64/:
total 3800
-rwxrwxr-x 1 user user 3800000 Mar 15 16:00 libfdroid_repo.so
```

## 构建流程

```
1. 安装 Rust Targets
   ↓
2. 编译 Rust 代码 (cargo build --release --target <arch>)
   ↓
3. 复制 .so 文件到 jniLibs/<arch>/
   ↓
4. Flutter 打包 APK 时自动包含这些文件
```

## 手动构建（如果脚本失败）

### 只构建特定架构

```bash
cd rust/fdroid_repo

# 构建 arm64-v8a (最常用)
cargo build --release --target aarch64-linux-android

# 复制到 Android 目录
mkdir -p ../../android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/libfdroid_repo.so \
   ../../android/app/src/main/jniLibs/arm64-v8a/
```

### 构建所有架构

```bash
cd rust/fdroid_repo

# 安装所有 targets
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup target add i686-linux-android
rustup target add x86_64-linux-android

# 构建每个架构
for target in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    cargo build --release --target $target
done

# 复制文件
mkdir -p ../../android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}
cp target/*/release/libfdroid_repo.so ../../android/app/src/main/jniLibs/*/
```

## APK 打包

构建 Rust 库后，正常构建 Flutter APK 即可：

```bash
# Debug 版本
flutter build apk --debug

# Release 版本
flutter build apk --release
```

Flutter 会自动将 jniLibs 目录中的 so 文件打包到 APK 中。

## 系统要求

### 必需

- **Rust** (1.70+)
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

### 可选

- **Android NDK** - 提供更好的性能和兼容性
  - 通过 Android Studio SDK Manager 安装
  - 或手动下载

## 故障排除

### 问题 1: linker not found

**错误**: `error: linker ... not found`

**原因**: 缺少 Android 工具链

**解决方案**:
```bash
# 方案 A: 使用预编译的工具链（推荐）
# 脚本会自动处理，无需手动配置

# 方案 B: 安装 NDK
sudo apt-get install android-sdk-ndk

# 方案 C: 使用 Docker
docker run --rm -v $(pwd):/app -w /app rustlang/rust:latest \
  cargo build --release --target aarch64-linux-android
```

### 问题 2: Unknown target

**错误**: `error: unknown target ...`

**解决方案**:
```bash
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup target add i686-linux-android
rustup target add x86_64-linux-android
```

### 问题 3: jniLibs 文件未被包含到 APK

**解决方案**:
- 确保 android/app/build.gradle 中有 `sourceSets` 配置（已添加）
- 确保 .so 文件在正确的目录中
- 清理并重新构建: `flutter clean && flutter build apk`

### 问题 4: 权限错误

**错误**: `Permission denied`

**解决方案**:
```bash
chmod +x build_android_*.sh
```

## 性能和大小

### 文件大小

| 架构 | 大小 | 设备覆盖率 |
|------|------|------------|
| arm64-v8a | ~3.5 MB | ~95% (现代设备) |
| armeabi-v7a | ~3.2 MB | ~5% (旧设备) |
| x86_64 | ~3.8 MB | 模拟器 |
| x86 | ~3.6 MB | 旧模拟器 |

### APK 大小影响

- **只包含 arm64-v8a**: APK 增加 ~3.5 MB
- **包含所有架构**: APK 增加 ~14 MB（但每个用户只下载对应架构）

### 优化建议

1. **只打包 arm64-v8a** - 覆盖 95% 的设备，最小化 APK
2. **使用 App Bundles (.aab)** - Google Play 自动优化 APK 大小

## Gradle 配置说明

已在 `android/app/build.gradle` 中添加：

```gradle
defaultConfig {
    ndk {
        abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'
    }
}

sourceSets {
    main {
        jniLibs.srcDirs = ['src/main/jniLibs']
    }
}
```

这些配置确保：
- APK 只包含指定的 ABI
- jniLibs 目录被正确识别
- Native 库被正确打包

## CI/CD 集成

### GitHub Actions 示例

```yaml
name: Build with Rust Native

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v2

      - name: Install Rust
        run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

      - name: Install Flutter
        uses: subosito/flutter-action@v2

      - name: Build Rust Android Libraries
        run: ./build_android_standalone.sh

      - name: Build APK
        run: flutter build apk --release
```

### GitLab CI 示例

```yaml
build:
  script:
    - curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    - ./build_android_standalone.sh
    - flutter build apk --release
  artifacts:
    paths:
      - build/app/outputs/flutter-apk/app-release.apk
```

## 更新 Rust 代码后

修改 Rust 代码后：

1. 重新构建 so 文件：
   ```bash
   ./build_android_standalone.sh clean
   ./build_android_standalone.sh
   ```

2. 或者只重新构建修改的架构（更快）：
   ```bash
   cd rust/fdroid_repo
   cargo build --release --target aarch64-linux-android
   cp target/aarch64-linux-android/release/libfdroid_repo.so \
      ../../android/app/src/main/jniLibs/arm64-v8a/
   ```

3. 正常构建 Flutter APK 即可

## 相关文件

- `rust/fdroid_repo/Cargo.toml` - Rust 项目配置
- `rust/fdroid_repo/src/` - Rust 源代码
- `android/app/build.gradle` - Android Gradle 配置
- `android/app/src/main/jniLibs/` - Native 库输出目录

## 技术细节

### 编译目标

| Rust Target | Android ABI | 说明 |
|------------|-------------|------|
| aarch64-linux-android | arm64-v8a | 64位 ARM (推荐) |
| armv7-linux-androideabi | armeabi-v7a | 32位 ARM |
| i686-linux-android | x86 | 32位 x86 |
| x86_64-linux-android | x86_64 | 64位 x86 |

### 优化配置

Rust 代码已配置为发布模式优化：

```toml
[profile.release]
opt-level = "z"     # 优化大小
lto = true          # 链接时优化
codegen-units = 1   # 单编译单元
strip = true        # 移除符号
panic = "abort"     # 减小代码大小
```

## 下一步

1. 运行构建脚本
2. 验证 so 文件已生成
3. 构建 Flutter APK
4. 在设备上测试 native 库

如遇问题，请查看本文件的"故障排除"部分。
