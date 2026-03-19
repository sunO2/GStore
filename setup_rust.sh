#!/bin/bash

echo "Setting up Rust F-Droid Repo Manager..."

# 1. 检查 flutter_rust_bridge CLI 是否已安装
if ! command -v flutter_rust_bridge_codegen &> /dev/null; then
    echo "Installing flutter_rust_bridge CLI..."
    cargo install flutter_rust_bridge@latest
else
    echo "flutter_rust_bridge CLI already installed"
fi

# 2. 进入 Flutter 项目根目录
cd /home/hezhihu89/develop/flutter/project/GStore

# 3. 安装 Flutter 依赖
echo "Installing Flutter dependencies..."
flutter pub get

# 4. 生成 bridge 代码
echo "Generating bridge code..."
cd rust/fdroid_repo
FRB_DEBUG_SKIP_SANITY_CHECK_CLASS_NAME_DUPLICATES=1 \
flutter_rust_bridge_codegen generate \
  --config-file frb_config.yaml

# 5. 构建 Rust 库
echo "Building Rust library..."
cargo build --release

# 6. 返回 Flutter 项目根目录
cd ../..

echo ""
echo "Setup complete!"
echo ""
echo "Rust library compiled successfully:"
echo "  - target/release/libfdroid_repo.so (Linux)"
echo "  - target/release/libfdroid_repo.a (Static library)"
echo ""
echo "Generated Dart bridge code:"
echo "  - lib/core/rust/generated/"
echo ""
echo "Next steps:"
echo "  1. flutter run                    # Run the app"
echo "  2. flutter build apk             # Build APK"
echo ""
echo "Note: First run may be slower due to Rust compilation"
echo ""
