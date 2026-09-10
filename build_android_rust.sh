#!/bin/bash
# Rust Android 库构建脚本
# 使用实际的 NDK 路径直接构建所有架构

set -e  # 遇到错误立即退出

# 配置
NDK_PATH="/home/hezhihu89/develop/android/sdk/ndk/26.3.11579264"
PROJECT_DIR="/home/hezhihu89/develop/flutter/project/GStore/rust/fdroid_repo"
ANDROID_LIB_DIR="/home/hezhihu89/develop/flutter/project/GStore/android/app/src/main/jniLibs"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查 NDK 是否存在
if [ ! -d "$NDK_PATH" ]; then
    echo_error "NDK not found at: $NDK_PATH"
    echo_error "Please update NDK_PATH in this script"
    exit 1
fi

# 切换到项目目录
cd "$PROJECT_DIR"

# 架构配置 (target -> Android ABI)
declare -A ARCHS=(
    ["aarch64-linux-android"]="arm64-v8a"
    ["armv7-linux-androideabi"]="armeabi-v7a"
    ["x86_64-linux-android"]="x86_64"
    ["i686-linux-android"]="x86"
)

# zxing-cpp bundled 依赖 cmake；Android 交叉编译必须显式指定 NDK 工具链，
# 否则 cmake 用宿主编译器产出错误架构对象。为每个 ABI 生成包装 toolchain 文件
# （强制 ANDROID_ABI/PLATFORM 后 include NDK 官方 android.toolchain.cmake）。
TOOLCHAIN_DIR="$PROJECT_DIR/target/cmake-toolchain"
mkdir -p "$TOOLCHAIN_DIR"

# 构建函数
build_arch() {
    local target=$1
    local arch_name=$2

    echo_info "Building for $arch_name ($target)..."

    # 目标->ANDROID_ABI（arm64-v8a / armeabi-v7a / x86_64 / x86）
    local android_abi="$arch_name"

    # 生成该 ABI 的 cmake 包装 toolchain 文件
    local toolchain_file="$TOOLCHAIN_DIR/$arch_name.cmake"
    cat > "$toolchain_file" << EOF
set(ANDROID_ABI $android_abi CACHE STRING "" FORCE)
set(ANDROID_PLATFORM android-33 CACHE STRING "" FORCE)
include(\$ENV{ANDROID_NDK_ROOT}/build/cmake/android.toolchain.cmake)
EOF

    # 将 target 名称中的 - 替换为 _ 用于环境变量
    local target_underscore="${target//-/_}"

    # 设置环境变量 (dart-sys 需要这些)
    # NDK 工具链名称: <target><api_level>-clang, 例如 aarch64-linux-android33-clang
    # armv7 例外：NDK 实际文件名带 `a`（armv7a-linux-androideabi33-clang），直接拼接会得到不存在的路径
    local clang_name="${target}33-clang"
    if [ "$target" = "armv7-linux-androideabi" ]; then
        clang_name="armv7a-linux-androideabi33-clang"
    fi
    export "CC_${target_underscore}=$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/$clang_name"
    export "CXX_${target_underscore}=$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/${clang_name%clang}clang++"
    export "AR_${target_underscore}=$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"

    # zxing-cpp cmake 构建所需的 NDK 环境（cmake crate 不转发 ANDROID_ABI 环境变量，
    # 只能通过 CMAKE_TOOLCHAIN_FILE 包装文件强制 ABI）
    export ANDROID_NDK_HOME="$NDK_PATH"
    export ANDROID_NDK_ROOT="$NDK_PATH"
    export CMAKE_TOOLCHAIN_FILE="$toolchain_file"

    # 静态链接 libc++：zxing-cpp 的 C++ 对象引用 libc++ 符号（std::string 等），
    # 其 build.rs 对含 linux 的 target 发出 -lstdc++ → NDK 空壳 libstdc++.so 无法解析，
    # 导致 dlopen 报 cannot locate symbol。rustc 的链接对 clang 驱动而言是 C 链接，
    # -static-libstdc++ 被忽略（argument unused），必须显式链入 libc++_static.a + libc++abi.a。
    export RUSTFLAGS="-C link-arg=-l:libc++_static.a -C link-arg=-l:libc++abi.a"

    # armv7: ring/cc 等需要旧式工具链名（arm-linux-androideabi-clang）
    # NDK 的 armv7a...clang 是相对 symlink（复制会断链），改用包装脚本调用真实 NDK 包装
    if [ "$target" = "armv7-linux-androideabi" ]; then
        local toolchain_bin="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"
        local symlink_dir="$PROJECT_DIR/target/toolchain-bin"
        mkdir -p "$symlink_dir"
        cat > "$symlink_dir/arm-linux-androideabi-clang" << EOF
#!/bin/sh
exec "$toolchain_bin/armv7a-linux-androideabi33-clang" "\$@"
EOF
        cat > "$symlink_dir/arm-linux-androideabi-clang++" << EOF
#!/bin/sh
exec "$toolchain_bin/armv7a-linux-androideabi33-clang++" "\$@"
EOF
        ln -sf "$toolchain_bin/llvm-ar" "$symlink_dir/arm-linux-androideabi-ar"
        chmod +x "$symlink_dir/arm-linux-androideabi-clang" "$symlink_dir/arm-linux-androideabi-clang++"
        export PATH="$symlink_dir:$PATH"
    fi

    # 检查 target 是否已安装
    if ! rustup target list --installed | grep -q "$target"; then
        echo_info "Installing Rust target: $target"
        rustup target add "$target"
    fi

    # 构建
    cargo build --release --target "$target"

    # 检查构建结果
    if [ -f "target/$target/release/libfdroid_repo.so" ]; then
        local size=$(ls -lh "target/$target/release/libfdroid_repo.so" | awk '{print $5}')
        echo_success "✓ Built libfdroid_repo.so ($size) for $arch_name"

        # 复制到 Android 目录
        mkdir -p "$ANDROID_LIB_DIR/$arch_name"
        cp "target/$target/release/libfdroid_repo.so" "$ANDROID_LIB_DIR/$arch_name/"
        echo_info "✓ Copied to $ANDROID_LIB_DIR/$arch_name/"
    else
        echo_error "✗ Build failed for $arch_name"
        return 1
    fi
}

# 主流程
echo_info "======================================"
echo_info "Rust Android Library Build Script"
echo_info "======================================"
echo_info "NDK: $NDK_PATH"
echo_info "Project: $PROJECT_DIR"
echo_info "Output: $ANDROID_LIB_DIR"
echo ""

# 清理旧的构建产物（可选）
if [ "$1" = "clean" ]; then
    echo_info "Cleaning build artifacts..."
    cargo clean
    echo_success "✓ Clean complete"
    echo ""
fi

# 记录开始时间
start_time=$(date +%s)

# 构建每个架构
FAILED=0
for target in "${!ARCHS[@]}"; do
    if ! build_arch "$target" "${ARCHS[$target]}"; then
        echo_warn "Build failed for $target, continuing..."
        FAILED=1
    fi
    echo ""
done

# 计算总耗时
end_time=$(date +%s)
duration=$((end_time - start_time))
if [ $duration -ge 60 ]; then
    minutes=$((duration / 60))
    seconds=$((duration % 60))
    time_str="${minutes}m ${seconds}s"
else
    time_str="${duration}s"
fi

# 总结
echo_info "======================================"
echo_info "Build Summary"
echo_info "======================================"
echo_info "Total time: $time_str"
echo ""

if [ $FAILED -eq 0 ]; then
    echo_success "✓ All architectures built successfully!"
    echo ""
    echo_info "Generated files:"
    for arch_dir in "$ANDROID_LIB_DIR"/*/; do
        if [ -f "$arch_dir/libfdroid_repo.so" ]; then
            arch=$(basename "$arch_dir")
            size=$(ls -lh "$arch_dir/libfdroid_repo.so" | awk '{print $5}')
            echo_info "  - $arch: libfdroid_repo.so ($size)"
        fi
    done
    echo ""
    echo_info "Next steps:"
    echo_info "  1. Build Flutter APK: flutter build apk --release"
    echo_info "  2. Install on device: flutter install"
    exit 0
else
    echo_error "✗ Some builds failed. Check the output above."
    exit 1
fi
