#!/bin/bash

# 构建 Rust 项目为 Android so 文件
# 这是一个简化版本，使用自动检测的 NDK 路径

set -e

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$PROJECT_ROOT/rust/fdroid_repo"
ANDROID_LIB_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs"

# 自动检测 NDK
detect_ndk() {
    # 常见的 NDK 路径
    local ndk_paths=(
        "$ANDROID_NDK_HOME"
        "$ANDROID_SDK_ROOT/ndk-bundle"
        "$HOME/Android/Sdk/ndk/26.1.10909125"
        "$HOME/Android/Sdk/ndk-bundle"
        "/opt/android-sdk/ndk/26.1.10909125"
        "/opt/android-sdk/ndk"
    )

    for path in "${ndk_paths[@]}"; do
        if [ -n "$path" ] && [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# 检测 NDK 版本
detect_ndk_version() {
    local ndk_path="$1"
    local properties="$ndk_path/source.properties"
    if [ -f "$properties" ]; then
        grep "Pkg.Revision" "$properties" | cut -d= -f2
    else
        echo "unknown"
    fi
}

NDK_PATH=$(detect_ndk)
if [ $? -eq 0 ]; then
    NDK_VERSION=$(detect_ndk_version "$NDK_PATH")
    echo_info "找到 Android NDK $NDK_VERSION: $NDK_PATH"
else
    echo_warning "未找到 Android NDK"
    echo_info "将尝试使用默认 Rust 工具链..."
fi

# 创建输出目录
mkdir -p "$ANDROID_LIB_DIR"/{arm64-v8a,armeabi-v7a,x86,x86_64}

# 定义架构
declare -A TARGETS=(
    ["arm64-v8a"]="aarch64-linux-android"
    ["armeabi-v7a"]="armv7-linux-androideabi"
    ["x86_64"]="x86_64-linux-android"
    ["x86"]="i686-linux-android"
)

cd "$RUST_DIR"

echo_info "开始构建 Android so 文件..."
echo ""

# 为每个架构构建
for arch in "${!TARGETS[@]}"; do
    target="${TARGETS[$arch]}"

    echo_info "构建 $arch ($target)..."

    # 安装 target
    rustup target add "$target" 2>/dev/null || true

    # 如果找到 NDK，更新配置
    if [ -n "$NDK_PATH" ]; then
        # 提取 NDK 版本号
        NDK_VER=$(echo "$NDK_VERSION" | cut -d. -f1)

        # 更新 .cargo/config.toml 中的路径
        if [ -f ".cargo/config.toml" ]; then
            sed -i "s|/opt/android-sdk/ndk/[0-9.]*|/opt/android-sdk/ndk/$NDK_VERSION|g" .cargo/config.toml
            sed -i "s|$NDK_PATH|/opt/android-sdk/ndk/$NDK_VERSION|g" .cargo/config.toml
        fi
    fi

    # 构建
    if cargo build --release --target "$target" 2>&1; then
        # 复制 so 文件
        cp "target/$target/release/libfdroid_repo.so" "$ANDROID_LIB_DIR/$arch/"

        # 显示大小
        size=$(du -h "$ANDROID_LIB_DIR/$arch/libfdroid_repo.so" | cut -f1)
        echo_success "$arch: $size"
    else
        echo_warning "$arch: 构建失败"
    fi

    echo ""
done

echo_info "=========================================="
echo_success "构建完成！"
echo_info "=========================================="
echo ""
echo_info "生成的文件:"
ls -lh "$ANDROID_LIB_DIR"/*/
echo ""
echo_info "这些文件会在构建 APK 时自动包含"
