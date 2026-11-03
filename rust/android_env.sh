#!/usr/bin/env bash
# Android Rust 交叉编译环境助手（source-only 优先）。
#
# 用法：
#   source rust/android_env.sh <ndk-path> <rust-triple> [api-level]
# 或
#   source rust/android_env.sh
#   android_env <ndk-path> <rust-triple> [api-level]
#
# 为给定 ABI 计算并 export 完整环境：
#   CC_<target> / CXX_<target> / AR_<target>
#   CARGO_TARGET_<TARGET>_LINKER
#   LIBCLANG_PATH（bindgen 加载的 libclang）
#   BINDGEN_EXTRA_CLANG_ARGS（--sysroot / --target / NDK clang 内建头）
#
# 为什么需要 bindgen 参数：rquickjs-sys 在 Android 上走 bindgen，冷构建时
# libclang 不知道 NDK sysroot，会报 `stdbool.h file not found`。只设
# CC/AR/linker 不够，必须显式把 sysroot + clang 内建头交给 libclang。
#
# API level 默认 33：与 build_android_rust.sh / rust/gstore_host/.cargo/config.toml
# 现有宿主编译器（*-android33-clang）保持一致，不抬高也不降低。
# 可用 GSTORE_ANDROID_API 或第 3 个参数覆盖。
#
# 无副作用：source 时不执行任何检查（除非显式传参）；失败返回非 0 并打印原因。

# 不改变调用方的 set -e / set -u 行为；本文件不做全局 set。
android_env() {
    local ndk_path="${1:-}"
    local rust_triple="${2:-}"
    local api="${3:-${GSTORE_ANDROID_API:-33}}"

    if [ -z "$ndk_path" ] || [ -z "$rust_triple" ]; then
        echo "android_env: usage: source rust/android_env.sh <ndk-path> <rust-triple> [api-level]" >&2
        return 2
    fi
    if [ ! -d "$ndk_path" ]; then
        echo "android_env: NDK not found: $ndk_path" >&2
        return 1
    fi

    local llvm="$ndk_path/toolchains/llvm/prebuilt/linux-x86_64"
    if [ ! -d "$llvm" ]; then
        echo "android_env: NDK host toolchain not found: $llvm" >&2
        return 1
    fi

    # Rust target triple -> clang target triple（armv7 在 clang 里带 a）
    local clang_triple
    case "$rust_triple" in
        aarch64-linux-android)
            clang_triple="aarch64-linux-android"
            ;;
        armv7-linux-androideabi)
            clang_triple="armv7a-linux-androideabi"
            ;;
        i686-linux-android)
            clang_triple="i686-linux-android"
            ;;
        x86_64-linux-android)
            clang_triple="x86_64-linux-android"
            ;;
        *)
            echo "android_env: unsupported target '$rust_triple' (expected aarch64-linux-android, armv7-linux-androideabi, i686-linux-android, x86_64-linux-android)" >&2
            return 1
            ;;
    esac

    local clang="$llvm/bin/${clang_triple}${api}-clang"
    if [ ! -x "$clang" ]; then
        echo "android_env: clang compiler not found for API $api: $clang" >&2
        echo "android_env: check the NDK version/API level (try an API shipped by this NDK)" >&2
        return 1
    fi

    local ar="$llvm/bin/llvm-ar"
    if [ ! -x "$ar" ]; then
        echo "android_env: llvm-ar not found: $ar" >&2
        return 1
    fi

    local sysroot="$llvm/sysroot"
    if [ ! -d "$sysroot/usr/include" ]; then
        echo "android_env: NDK sysroot not found: $sysroot" >&2
        return 1
    fi

    # NDK 内 clang 内建头目录随 NDK 版本变化（r26=17, r27=18, r28=19），不能硬编码。
    # 取版本号最高的一份。
    local clang_include
    clang_include="$(ls -d "$llvm"/lib/clang/*/include 2>/dev/null | sort -V | tail -n 1)"
    if [ -z "$clang_include" ] || [ ! -d "$clang_include" ]; then
        echo "android_env: clang builtin include dir not found under $llvm/lib/clang/*/include" >&2
        return 1
    fi

    # bindgen 通过 LIBCLANG_PATH 加载 libclang.so。r27+ 只在 musl/lib 下提供，
    # 旧版同时有 lib/libclang.so；按存在性选择。
    local libclang_dir=""
    if [ -f "$llvm/lib/libclang.so" ]; then
        libclang_dir="$llvm/lib"
    elif [ -f "$llvm/musl/lib/libclang.so" ]; then
        libclang_dir="$llvm/musl/lib"
    else
        echo "android_env: libclang.so not found under $llvm/lib or $llvm/musl/lib" >&2
        return 1
    fi

    local target_env="${rust_triple//-/_}"
    local target_upper
    target_upper="$(printf '%s' "$target_env" | tr '[:lower:]' '[:upper:]')"

    export "CC_${target_env}=$clang"
    export "CXX_${target_env}=$llvm/bin/${clang_triple}${api}-clang++"
    export "AR_${target_env}=$ar"
    export "CARGO_TARGET_${target_upper}_LINKER=$clang"
    export LIBCLANG_PATH="$libclang_dir"
    # -resource-dir 覆盖 libclang 默认内建头目录：CI runner 的系统 libclang
    # 版本与 NDK sysroot 不一致时，-I 会与系统 stdint.h 撞 include guard，
    # 导致 NDK 的 stdint.h 被跳过（unknown type name 'uint32_t'）。
    local clang_resdir="${clang_include%/include}"
    export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$sysroot --target=${clang_triple}${api} -resource-dir ${clang_resdir}"
    # bindgen 也识别 target 专属变量；同时设置，避免调用方断言的 target 与全局不一致。
    export "BINDGEN_EXTRA_CLANG_ARGS_${target_env}=$BINDGEN_EXTRA_CLANG_ARGS"

    echo "android_env: $rust_triple (API $api) CC=$clang" >&2
    echo "android_env: LIBCLANG_PATH=$LIBCLANG_PATH" >&2
    echo "android_env: BINDGEN_EXTRA_CLANG_ARGS=$BINDGEN_EXTRA_CLANG_ARGS" >&2
    return 0
}

_android_env_is_sourced=0
if [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
    case "$ZSH_EVAL_CONTEXT" in
        *:file*) _android_env_is_sourced=1 ;;
    esac
elif [ -n "${BASH_SOURCE:-}" ]; then
    if [ "${BASH_SOURCE[0]:-}" != "${0:-}" ]; then
        _android_env_is_sourced=1
    fi
fi

if [ "$_android_env_is_sourced" -eq 1 ]; then
    # 仅当显式 `source ... <ndk> <abi>` 时才自动执行；source 时不传参
    # （调用脚本自身的位置参数可能恰好有 2 个）必须保持无副作用。
    if [ "$#" -ge 2 ] && [ -d "${1:-}" ]; then
        android_env "$@"
    fi
else
    android_env "$@"
    exit $?
fi
unset _android_env_is_sourced
