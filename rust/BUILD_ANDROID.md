# Android Rust 构建脚本使用说明

## 脚本说明

项目提供了两个脚本来构建 Rust Android 库：

### 1. build_android_simple.sh（推荐）

简化版构建脚本，自动检测 NDK 并构建所有架构。

**使用方法**：
```bash
./build_android_simple.sh
```

**特点**：
- 自动检测 Android NDK
- 自动配置工具链路径
- 构建所有主要架构（arm64-v8a, armeabi-v7a, x86, x86_64）
- 自动复制到 android/app/src/main/jniLibs/

**生成的文件**：
```
android/app/src/main/jniLibs/
├── arm64-v8a/libfdroid_repo.so
├── armeabi-v7a/libfdroid_repo.so
├── x86/libfdroid_repo.so
└── x86_64/libfdroid_repo.so
```

### 2. build_android_rust.sh（完整版）

完整版构建脚本，提供更多选项和错误处理。

**使用方法**：
```bash
# 正常构建
./build_android_rust.sh

# 清理并重新构建
./build_android_rust.sh clean
```

## 系统要求

### 必需工具

1. **Rust 工具链**
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

2. **Android NDK** (可选但推荐)
   - 通过 Android Studio 安装
   - 或手动下载到 `/opt/android-sdk/ndk/`
   - 设置环境变量 `ANDROID_NDK_HOME`

3. **Rust Android Targets**
   ```bash
   rustup target add aarch64-linux-android
   rustup target add armv7-linux-androideabi
   rustup target add i686-linux-android
   rustup target add x86_64-linux-android
   ```

## 快速开始

### 第一次使用

```bash
# 1. 构建所有架构
./build_android_simple.sh

# 2. 构建 APK（会自动包含 so 文件）
flutter build apk --release
```

### 只构建特定架构

```bash
# 只构建 arm64-v8a (最常用的架构)
cd rust/fdroid_repo
cargo build --release --target aarch64-linux-android
mkdir -p ../../android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/libfdroid_repo.so \
   ../../android/app/src/main/jniLibs/arm64-v8a/
```

## 输出说明

### 文件大小（参考）

| 架构 | 大小 | 说明 |
|------|------|------|
| arm64-v8a | ~3.5 MB | 64位 ARM（推荐） |
| armeabi-v7a | ~3.2 MB | 32位 ARM（兼容旧设备） |
| x86_64 | ~3.8 MB | 64位 x86（模拟器） |
| x86 | ~3.6 MB | 32位 x86（旧模拟器） |

### APK 大小影响

- 只包含 arm64-v8a: APK 增加 ~3.5 MB
- 包含所有架构: APK 增加 ~14 MB（每个用户只会下载对应架构的 so）

## 故障排除

### 问题 1: NDK 未找到

**错误**: `error: linker not found`

**解决方案**:
```bash
# 方法 A: 设置 NDK 环境变量
export ANDROID_NDK_HOME=/path/to/ndk

# 方法 B: 使用默认路径
sudo apt-get install android-sdk-ndk
```

### 问题 2: 链接器错误

**错误**: `failed to execute linker`

**解决方案**:
```bash
# 安装必要的工具
sudo apt-get install build-essential
```

### 问题 3: Target 未知

**错误**: `error: unknown target`

**解决方案**:
```bash
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup target add i686-linux-android
rustup target add x86_64-linux-android
```

### 问题 4: 缺少 OpenSSL（如果使用）

**错误**: `could not find native_ssl`

**解决方案**: 在 Cargo.toml 中使用 `features = ["vendored"]`

## 在 Gradle 中配置（可选）

如果需要在 build.gradle 中手动配置：

```gradle
android {
    // ... 其他配置

    // 指定 so 文件的位置
    sourceSets {
        main {
            jniLibs.srcDirs = ['src/main/jniLibs']
        }
    }

    // 打包时只包含必要的架构
    packagingOptions {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    // ABI 过滤（可选）
    splits {
        abi {
            enable true
            reset()
            include 'arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'
            universalApk false
        }
    }
}
```

## CI/CD 集成

在 CI 中自动构建：

```yaml
# .github/workflows/build.yml
- name: Build Rust Android Libraries
  run: |
    ./build_android_simple.sh

- name: Build Flutter APK
  run: |
    flutter build apk --release
```

## 性能提示

1. **增量构建**: 脚本会自动检查并只重新构建修改的文件
2. **并行构建**: 可以同时构建多个架构来加快速度
3. **最小化 APK**: 只打包 arm64-v8a 可以显著减小 APK 大小

## 相关链接

- [Rust Android 开发](https://github.com/tokio-rs/console/blob/master/.cargo/config.toml)
- [Android NDK 下载](https://developer.android.com/ndk/downloads)
- [Flutter FFI](https://docs.flutter.dev/development/platform-integration/android/c-interop)
