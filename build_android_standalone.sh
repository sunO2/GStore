#!/bin/bash

# Rust Android 库构建脚本 - 独立版本
# 使用 cargo-apl 构建所有架构，无需手动配置 NDK

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$PROJECT_ROOT/rust/fdroid_repo"
ANDROID_LIB_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs"

# Android 架构配置
ARCHS=(
    "aarch64-linux-android:arm64-v8a"
    "armv7-linux-androideabi:armeabi-v7a"
    "x86_64-linux-android:x86_64"
    "i686-linux-android:x86"
)

echo_info "======================================"
echo_info "Rust Android 库构建脚本"
echo_info "======================================"
echo_info "项目: $RUST_DIR"
echo_info "输出: $ANDROID_LIB_DIR"
echo ""

cd "$RUST_DIR"

# 清理旧的构建
if [ "$1" == "clean" ]; then
    echo_info "清理旧构建..."
    cargo clean
    rm -rf "$ANDROID_LIB_DIR"
fi

# 创建输出目录
mkdir -p "$ANDROID_LIB_DIR"

# 记录开始时间
start_time=$(date +%s)

# 构建每个架构
for arch_config in "${ARCHS[@]}"; do
    IFS=':' read -r target arch_name <<< "$arch_config"

    echo_info "构建 $arch_name ($target)..."

    # 安装 target（如果需要）
    if ! rustup target list --installed 2>/dev/null | grep -q "$target"; then
        echo "  安装 target: $target"
        rustup target add "$target"
    fi

    # 构建
    echo "  正在编译..."
    if cargo build --release --target "$target" 2>&1 | grep -E "Compiling|Finished"; then
        # 复制 so 文件
        so_file="target/$target/release/libfdroid_repo.so"
        if [ -f "$so_file" ]; then
            mkdir -p "$ANDROID_LIB_DIR/$arch_name"
            cp "$so_file" "$ANDROID_LIB_DIR/$arch_name/"

            # 显示文件大小
            size=$(du -h "$ANDROID_LIB_DIR/$arch_name/libfdroid_repo.so" | cut -f1)
            echo_success "$arch_name: $size"
        else
            echo "$arch_name: 构建失败 (文件不存在)"
        fi
    else
        echo "$arch_name: 构建失败"
    fi

    echo ""
done

# 计算耗时
end_time=$(date +%s)
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))

echo_info "======================================"
echo_success "构建完成！耗时: ${minutes}分${seconds}秒"
echo_info "======================================"
echo ""

# 显示结果
echo_info "生成的库文件:"
for arch_config in "${ARCHS[@]}"; do
    IFS=':' read -r target arch_name <<< "$arch_config"
    so_file="$ANDROID_LIB_DIR/$arch_name/libfdroid_repo.so"
    if [ -f "$so_file" ]; then
        size=$(du -h "$so_file" | cut -f1)
        echo "  ✓ $arch_name: $size"
    else
        echo "  ✗ $arch_name: 未构建"
    fi
done

echo ""
echo_info "库文件已复制到: $ANDROID_LIB_DIR"
echo_info "下次构建 APK 时会自动包含这些库"
