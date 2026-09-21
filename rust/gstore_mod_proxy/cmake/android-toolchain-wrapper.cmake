# Android CMake toolchain wrapper for gstore_mod_proxy's C/C++ deps (BoringSSL).
#
# Why this exists
# ---------------
# boring-sys builds BoringSSL via the `cmake` crate. For Android it normally
# supplies ANDROID_ABI + the NDK android.toolchain.cmake itself, but it also
# passes -DCMAKE_C_COMPILER/-DCMAKE_CXX_COMPILER explicitly, which conflicts
# with the NDK toolchain's own compiler selection (CMake cache reset mid-build).
# Worse, BoringSSL only guards its bundled Google Benchmark against
# cross-compilation for Apple targets -- on Android the benchmark regex-backend
# try_compile cannot run and configure aborts.
#
# This wrapper is only used on Android (Cargo sets CARGO_CFG_TARGET_OS for build
# scripts; cmake inherits it). It:
#   1. must be selected *instead of* boring-sys's own params -- boring-sys
#      early-returns when CMAKE_TOOLCHAIN_FILE is set (build/main.rs:237);
#   2. selects ANDROID_ABI from the Rust target arch;
#   3. turns BUILD_TESTING off and pins HAVE_STD_REGEX so BoringSSL's bundled
#      benchmark does not try to run a cross-compiled probe;
#   4. delegates to the NDK toolchain, which sets the compilers/sysroot.
#
# This mirrors the zxing-cpp cross-compile approach documented in
# rust/ARCHITECTURE.md (P2 note) and build_android_rust.sh.
if(NOT "$ENV{CARGO_CFG_TARGET_OS}" STREQUAL "android")
  return()
endif()

if("$ENV{CARGO_CFG_TARGET_ARCH}" STREQUAL "aarch64")
  set(ANDROID_ABI "arm64-v8a" CACHE STRING "" FORCE)
elseif("$ENV{CARGO_CFG_TARGET_ARCH}" STREQUAL "x86_64")
  set(ANDROID_ABI "x86_64" CACHE STRING "" FORCE)
elseif("$ENV{CARGO_CFG_TARGET_ARCH}" STREQUAL "arm")
  set(ANDROID_ABI "armeabi-v7a" CACHE STRING "" FORCE)
elseif("$ENV{CARGO_CFG_TARGET_ARCH}" STREQUAL "x86")
  set(ANDROID_ABI "x86" CACHE STRING "" FORCE)
endif()

set(ANDROID_PLATFORM "android-33" CACHE STRING "" FORCE)

# BoringSSL bundles Google Benchmark under `if(BUILD_TESTING)`. Its C++ feature
# probes (std::regex backend) are compiled+linked but cannot be run during an
# Android cross build, and BoringSSL does not set CMAKE_CROSSCOMPILING for
# Android. Disable test targets and pin the probe result.
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(HAVE_STD_REGEX 1 CACHE BOOL "" FORCE)

include($ENV{ANDROID_NDK_ROOT}/build/cmake/android.toolchain.cmake)
