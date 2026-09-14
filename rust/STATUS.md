# Rust 模块化后端 - 集成状态

> 本文件描述**当前实现状态**。设计文档见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

## 概述

Rust 模块化后端**已实施并启用**：宿主 `gstore_host.so` + 三个按需模块
（`gstore_mod_qr` / `gstore_mod_analyzer` / `gstore_mod_repo`），经 flutter_rust_bridge 2.11.1
与 Dart 通信，模块经 C ABI + dlopen 由宿主动态挂载。

> 历史说明：本文件早期版本曾记录"Rust 后端因 FRB 重复类定义问题被禁用、暂用 Dart 实现"。
> 该问题已解决（FRB 2.11 的 opaque 模式），Rust 后端当前为**主路径**，Dart 侧只保留降级实现。

## 结构

```
rust/
├── gstore_contract/     # 共享契约层：C ABI 结构体 / 信封 / 错误模型 / 签名
├── gstore_host/         # 宿主（libgstore_host.so）：FRB 桥 + 注册表 + dlopen 适配
├── gstore_mod_qr/       # 二维码模块（按需）
├── gstore_mod_analyzer/ # APK 分析模块（按需）
├── gstore_mod_repo/     # F-Droid 仓库模块（有状态 SQLite + 异步下载）
├── build_all.sh         # 一键构建全部 crate
├── test_all.sh          # 一键测试全部 crate
└── sign_module.py       # 发布端模块签名（Ed25519）
```

**无 Cargo workspace**：宿主必须 `panic = "abort"`、模块必须 `panic = "unwind"`（边界
`catch_unwind` 隔离），而 Cargo 禁止在 `[profile.*.package.*]` 覆盖 `panic`，故各 crate
独立、由 `build_all.sh` / `test_all.sh` 统一编排。

## 当前能力

- ✅ 宿主 FRB 桥（`ModuleHandle` / `InstanceHandle` / 日志流 / 事件流）
- ✅ 模块注册表：单锁 `Registry`，同名幂等，refcount 引用计数，preload 常驻
- ✅ 动态挂载：`dlopen` + C ABI 握手，ABI 版本双向校验
- ✅ 统一信封（protobuf）+ 状态码 + 错误码，**域错误跨 ABI 透传**（不塌成 500）
- ✅ 超时与取消：`call_envelope_with_timeout` + 在途表 + 模块 `cancel`（repo 下载支持）
- ✅ 下载模块签名校验：宿主 `mount_from_so` 前校验 `.sig`/`.meta`（无签名=内置信任）
- ✅ 内置（jniLibs）与远程（下载 + SHA-256 + 签名）两条加载路径
- ✅ 事件通道：模块 `emit_event` → Dart 广播流（`RustModuleManager.moduleEvents`）
- ✅ 统一事件系统（双向）：Dart `AppEventBus` 收口 DB / 模块生命周期 / 配置事件源；Rust 模块
  `emit_event` 上行接入统一总线；标记 `downlink` 的事件（如 `config.changed`）经宿主 ABI
  `on_event` 下发到模块（**ABI v2**）

## 构建 / 测试

```bash
# 本地（debug）构建全部 crate
rust/build_all.sh

# 全部 crate 测试（会先构建模块 .so；host 集成测试缺 .so 会 fail）
rust/test_all.sh

# Android（NDK 交叉编译，含模块 release 产物 + 清单）
./build_android_rust.sh
./generate_modules_manifest.sh
python3 rust/sign_module.py rust/release-modules <private_key.pem>   # 可选：发布签名
```

Android 侧集成测试：`cd rust/gstore_host && cargo test`（需先构建各模块 debug .so；
无模块时可设 `GSTORE_ALLOW_MISSING_MODULE=1` 显式跳过——CI 不应设置该变量）。

## 文档校正（与旧文档的差异）

- 旧文档提到的 `rust/fdroid_repo/`、`frb_config.yaml`、`lib/core/rust/FdroidRustRepoManager.dart`
  均已不存在；当前路径见上。
- 域内 payload 为 **JSON**（信封本身为 protobuf），并非"全 protobuf"。见 ARCHITECTURE.md。
- 下载/哈希/签名校验横跨两端：Dart 负责下载与写侧车，宿主负责 dlopen 前校验。
