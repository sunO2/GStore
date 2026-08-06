<div align="center">

# GStore

**基于开源数据的跨渠道软件商店，为 Android 用户提供安全、可审计的应用发现、下载与更新体验。**

[![项目状态](https://img.shields.io/badge/项目状态-开发中-yellowgreen.svg)](https://github.com/sunO2/GStore)
[![GitHub release](https://img.shields.io/github/v/release/sunO2/GStore)](https://github.com/sunO2/GStore/releases)
[![GitHub stars](https://img.shields.io/github/stars/sunO2/GStore)](https://github.com/sunO2/GStore)
[![GitHub issues](https://img.shields.io/github/issues/sunO2/GStore)](https://github.com/sunO2/GStore/issues)
[![GitHub pull requests](https://img.shields.io/github/issues-pr/sunO2/GStore)](https://github.com/sunO2/GStore/pulls)
[![GitHub downloads](https://img.shields.io/github/downloads/sunO2/GStore/total)](https://github.com/sunO2/GStore/releases)
[![License](https://img.shields.io/github/license/sunO2/GStore)](https://github.com/sunO2/GStore/blob/main/LICENSE)

</div>

---

## 目录

- [简介](#简介)
- [主要特性](#主要特性)
- [开源数据仓库](#开源数据仓库)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
  - [安装使用](#安装使用)
  - [本地构建](#本地构建)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [平台支持](#平台支持)
- [贡献指南](#贡献指南)
- [许可证](#许可证)

## 简介

GStore 是一个建立在**开放、透明**原则之上的软件商店。所有软件数据均开源托管，任何人都可以查看、审计与贡献。

它通过统一的渠道抽象层聚合多个软件来源（GitHub、F-Droid、vivo 应用市场、HTTP API 及本地数据库），提供一站式的软件发现、下载、更新与备份管理。数据与代码的双重开放，保证了软件来源的可追溯性与安全性。

## 主要特性

- **多渠道应用聚合** — 统一接入 GitHub、F-Droid、vivo、HTTP API 与本地数据库等多种来源，聚合展示并支持频道筛选。
- **可靠的多任务下载** — 支持断点续传、并发控制、失败自动重试，以及强制重新下载。
- **静默安装（Shizuku）** — 通过 Shizuku 授权实现免确认静默安装，未授权时自动回退系统安装器。
- **开源数据驱动** — 应用数据完全开源，支持服务端数据库自动更新（带版本检测与增量提示）。
- **GitHub 加速代理** — 内置可配置的 GitHub 代理前缀，改善国内访问体验。
- **本地数据备份** — 支持本地文件与 WebDAV 云端双向备份/恢复，备份可包含应用配置。
- **离线可用** — 内置本地数据库渠道，无网络时仍可浏览已收录应用。
- **全文搜索** — 基于 SQLite FTS5 的全文索引（设备不支持时自动降级 LIKE 搜索）。
- **Material You 动态配色** — 支持 Android 12+ 跟随系统取色，同时提供亮/暗主题。
- **自定义频道** — 支持扩展自定义应用来源，灵活管理应用集合。
- **Agent 助手（Genkit）** — 集成 Google Genkit 与多模型后端，提供智能交互能力。

## 开源数据仓库

GStore 的应用数据（应用列表、描述、下载链接、版本信息等）托管在独立的开源仓库：

**[GStore-Repositorys](https://github.com/sunO2/GStore-Repositorys)**

### 数据仓库特点

- **数据驱动** — 商店展示内容完全由该仓库数据驱动，应用内可一键更新数据库。
- **社区共建** — 欢迎通过 Issue / Pull Request 添加软件、修正信息或补充数据。
- **格式规范** — 数据格式遵循仓库内定义的规范，详见 [数据格式说明](https://github.com/sunO2/GStore-Repositorys/blob/main/README.md)。

### 如何贡献数据

1. Fork [GStore-Repositorys](https://github.com/sunO2/GStore-Repositorys)
2. 按数据规范在相应目录添加或修改软件数据
3. 提交 Pull Request，等待审核合并

## 环境要求

| 组件 | 版本 |
| --- | --- |
| Flutter | >= 3.44（当前 3.44.x 已验证） |
| Dart | >= 3.5.3 |
| Android Gradle Plugin | 8.11.x |
| Gradle | 8.14 |
| Kotlin | 2.2.x |

> 构建 Android 产物时请确保 Android SDK / NDK 环境就绪。

## 快速开始

### 安装使用

1. 前往 [Release 页面](https://github.com/sunO2/GStore/releases) 下载最新 APK；
2. 完成安装（需允许"安装未知来源应用"）；
3. 在**发现**页浏览并添加应用，或进入**设置 → 数据库更新**获取最新数据；
4. 在应用详情页下载并安装应用。

### 本地构建

```bash
# 克隆仓库
git clone https://github.com/sunO2/GStore.git
cd GStore

# 安装依赖
flutter pub get

# 运行调试
flutter run

# 构建 Release APK（arm64）
flutter build apk --release --target-platform android-arm64
```

> **F-Droid 渠道（可选）**：高性能仓库解析依赖 Rust 库（`rust/fdroid_repo`）。
> 如需启用，先执行 `./build_android_rust.sh` 构建 Rust Android 库。

## 项目结构

```text
lib/
├── core/            # 核心层：渠道抽象、聚合管理、服务、主题、代理等
│   ├── channel/     # 渠道系统（本地库 / GitHub / vivo / F-Droid）
│   ├── aggregate/   # 首页应用聚合管理器
│   ├── service/     # 下载、数据库、备份、安装等服务
│   └── theme/       # Material You / 主题系统
├── db/              # Floor（SQLite）实体与 DAO
├── http/            # 网络层：GitHub API、下载状态管理
├── page/            # 页面层：首页、发现、下载、设置、备份、WebDAV 配置等
├── rust/            # flutter_rust_bridge 生成的 FFI 绑定
└── compent/         # 通用组件
rust/fdroid_repo/    # Rust 实现的 F-Droid 仓库解析库
assets/              # 静态资源（图标、默认数据库等）
```

## 技术栈

| 类别 | 技术 |
| --- | --- |
| UI 框架 | Flutter（Material Design 3） |
| 状态管理 | GetX（响应式状态、依赖注入、路由） |
| 网络请求 | Dio、Retrofit、rhttp（curl 高性能 HTTP） |
| 本地存储 | Floor（SQLite ORM）、shared_preferences、flutter_secure_storage |
| 图像加载 | cached_network_image |
| 网页浏览 | flutter_inappwebview |
| 静默安装 | shizuku_api |
| AI 助手 | Genkit、genkit_google_genai、genkit_openai |
| Rust 集成 | flutter_rust_bridge（FFI，F-Droid 解析） |
| 持续集成 | GitHub Actions（多架构 APK / AAB 构建发布） |

## 平台支持

- **Android**（主要目标平台）：arm64-v8a / armeabi-v7a / x86 / x86_64
- **iOS / Web / Linux / macOS / Windows**：基于 Flutter 跨平台支持，功能逐步完善中

## 贡献指南

欢迎任何形式的贡献：代码、数据、文档、Bug 报告与功能建议。

- **提交 Issue** — 报告 Bug 或提出功能建议
- **提交 Pull Request** — 修复 Bug、开发新功能或完善文档
- **贡献数据** — 参考 [数据仓库](#开源数据仓库) 部分提交软件数据
- **参与讨论** — 在 Issue 评论区交流想法

## 许可证

本项目基于 **GPL-3.0** 开源协议分发，详情见 [LICENSE](LICENSE)。
