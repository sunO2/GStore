#!/usr/bin/env bash
# 构建本地推理模块 gstore_mod_llm（llama.cpp，GGUF）的 Android 产物。
#
# 用法（后端用参数控制）：
#   rust/build_llm_android.sh                                  # 默认 cpu
#   GSTORE_LLM_GPU=opencl rust/build_llm_android.sh             # 高通 Adreno（OpenCL）
#   GSTORE_LLM_GPU=vulkan rust/build_llm_android.sh             # 跨厂商（Mali/Adreno），需 glslc
#   GSTORE_LLM_GPU=all    rust/build_llm_android.sh             # release 页一键全构建
#
# 产物（变体用文件名后缀区分；`_cpu/_opencl/_vulkan` 会被宿主剥回同一模块名 llm）：
#   libgstore_mod_llm.so             (cpu，默认无后缀)
#   libgstore_mod_llm_opencl.so      (opencl)
#   libgstore_mod_llm_vulkan.so      (vulkan)
#
# 与其它模块不同，本模块：
#   1) 需要 `--features llama` 才会编译 llama.cpp；
#   2) 交叉编译依赖 bindgen → 必须提供宿主的 libclang（用 NDK 自带的即可）；
#   3) 只产出 **arm64-v8a**：32 位 arm 跑 LLM 不现实，x86_64 仅模拟器无分发价值。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
MODULE_DIR="${GSTORE_MODULE_DIR:-$ROOT/release-modules}"
NDK="${GSTORE_NDK_PATH:-/home/hezhihu89/develop/android/sdk/ndk/26.3.11579264}"

if [ ! -d "$NDK" ]; then
    echo "!! NDK 不存在: $NDK（可用 GSTORE_NDK_PATH 覆盖）"
    exit 1
fi

LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$LLVM/sysroot"
API=33
ARCH=arm64-v8a
TARGET=aarch64-linux-android
CC="$LLVM/bin/aarch64-linux-android${API}-clang"
CXX="$LLVM/bin/aarch64-linux-android${API}-clang++"

if [ ! -x "$CC" ]; then
    echo "!! 找不到 NDK clang: $CC"
    exit 1
fi

export ANDROID_NDK_HOME="$NDK"
export ANDROID_NDK_ROOT="$NDK"
export CMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
export CC_aarch64_linux_android="$CC"
export CXX_aarch64_linux_android="$CXX"
export AR_aarch64_linux_android="$LLVM/bin/llvm-ar"
export RANLIB_aarch64_linux_android="$LLVM/bin/llvm-ranlib"
# bindgen 需要 libclang + 目标 sysroot（宿主未装 libclang，用 NDK 自带）
export LIBCLANG_PATH="$LLVM/lib"
# ggml-vulkan 构建期需要 glslc 编译 GLSL 计算着色器；NDK 自带 shader-tools，优先用它
if [ -d "$NDK/shader-tools/linux-x86_64" ]; then
    export PATH="$NDK/shader-tools/linux-x86_64:$PATH"
fi
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SYSROOT --target=aarch64-linux-android${API}"
# cargo 的 linker 环境变量要求目标名全大写（aarch64-linux-android → AARCH64_LINUX_ANDROID）
TARGET_UPPER="${TARGET//-/_}"
TARGET_UPPER="${TARGET_UPPER^^}"
export "CARGO_TARGET_${TARGET_UPPER}_LINKER=$CC"
# 与其它模块一致：静态 libc++（android-static-stdcxx feature 亦会补此链接）
BASE_RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-l:libc++_static.a -C link-arg=-l:libc++abi.a -C link-arg=-Wl,-z,max-page-size=16384"

# 后端选择：cpu | opencl | vulkan | all
# （GSTORE_LLM_FEATURES 为高级逃生口：直接指定 cargo features）
GPU="${GSTORE_LLM_GPU:-cpu}"

# $1=变体名 $2=输出名后缀 $3=cargo features
build_one() {
    local variant="$1" suffix="$2" features="$3"
    local rustflags="$BASE_RUSTFLAGS"

    case "$variant" in
        opencl)
            # llama-cpp-sys-2 交叉编译 OpenCL 读 OPENCL_INCLUDE_DIR / OPENCL_LIBRARY；
            # 头文件已内置 third_party/OpenCL-Headers；链接期只需占位库（运行期由加载器按名找设备实现）。
            local third_party="$ROOT/gstore_mod_llm/third_party/OpenCL-Headers"
            export OPENCL_INCLUDE_DIR="$third_party"
            export OPENCL_LIBRARY="$third_party/stub/$ARCH/libOpenCL.so"
            export PYTHON3_EXECUTABLE="$(command -v python3 || echo python3)"
            # 必须把 -lOpenCL 显式加进**最终链接**（cmake 挂在静态库上不会传播到 cdylib）；
            # --no-as-needed 保证占位库即使不解析符号也保留 DT_NEEDED，
            # 运行期由加载器按名 libOpenCL.so 找设备实现来解析那批 cl* 未定义符号。
            rustflags="$rustflags -C link-arg=-Wl,--no-as-needed -C link-arg=-L$third_party/stub/$ARCH -C link-arg=-lOpenCL"
            ;;
        vulkan)
            if ! command -v glslc >/dev/null 2>&1; then
                echo "    [vulkan] 跳过：缺少 glslc/shaderc（ggml-vulkan 构建期需编译 GLSL 着色器）"
                return 2
            fi
            # NDK 只带 Vulkan C 头；ggml-vulkan 需要 C++ 头 <vulkan/vulkan.hpp>。
            # 已内置 Khronos Vulkan-Headers（同版本单体集合，VK_HEADER_VERSION 一致）。
            local vk="$ROOT/gstore_mod_llm/third_party/Vulkan-Headers/include"
            if [ ! -f "$vk/vulkan/vulkan.hpp" ]; then
                echo "    [vulkan] 跳过：缺少内置 Vulkan-Headers（$vk/vulkan/vulkan.hpp）"
                return 2
            fi
            export VULKAN_INCLUDE_DIR="$vk"
            # ggml-vulkan 还要 SPIRV-Headers 的 CONFIG 包 + spirv.hpp（已内置最小实现）
            export SPIRV_HEADERS_DIR="$ROOT/gstore_mod_llm/third_party/SPIRV-Headers"
            export SPIRV_HEADERS_INCLUDE_DIR="$SPIRV_HEADERS_DIR/include"
            ;;
    esac

    local out_name="libgstore_mod_llm${suffix}.so"
    echo "==> building $out_name / $ARCH (features=$features)"
    (
        cd "$PROJECT/rust/gstore_mod_llm"
        RUSTFLAGS="$rustflags" cargo build --release --features "$features" --target "$TARGET"
    )
    local out="$MODULE_DIR/$ARCH"
    mkdir -p "$out"
    cp "$PROJECT/rust/gstore_mod_llm/target/$TARGET/release/libgstore_mod_llm.so" "$out/$out_name"
    echo "✓ $out_name ($(stat -c%s "$out/$out_name" 2>/dev/null || echo '?') bytes) -> $out/$out_name"
}

if [ -n "${GSTORE_LLM_FEATURES:-}" ]; then
    # 高级逃生口：直接指定 features，输出后缀按是否含 gpu-* 推断
    suffix=""
    case ",$GSTORE_LLM_FEATURES," in
        *",gpu-opencl,"*) suffix="_opencl" ;;
        *",gpu-vulkan,"*) suffix="_vulkan" ;;
    esac
    build_one custom "$suffix" "$GSTORE_LLM_FEATURES"
    exit $?
fi

case "$GPU" in
    cpu)    build_one cpu    ""        "llama" ;;
    opencl) build_one opencl "_opencl" "llama,gpu-opencl" ;;
    vulkan) build_one vulkan "_vulkan" "llama,gpu-vulkan" ;;
    all)
        # release 页一键全构建：逐个变体产出；缺依赖/失败的变体跳过但不影响其它变体
        build_one cpu    ""        "llama" || true
        build_one opencl "_opencl" "llama,gpu-opencl" || true
        build_one vulkan "_vulkan" "llama,gpu-vulkan" || echo "    [vulkan] 构建失败/跳过（不影响其它变体）"
        ;;
    *)
        echo "!! 未知 GSTORE_LLM_GPU=$GPU（可选 cpu|opencl|vulkan|all）"
        exit 1
        ;;
esac
