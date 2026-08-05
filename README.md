# GStore

[![项目状态：开发中](https://img.shields.io/badge/项目状态-开发中-yellowgreen.svg)](https://github.com/sunO2/GStore)
[![GitHub release](https://img.shields.io/github/v/release/sunO2/GStore?style=flat&refresh=0)](https://github.com/sunO2/GStore/releases)
[![GitHub repo stars](https://img.shields.io/github/stars/sunO2/GStore?style=flat&refresh=0)](https://github.com/sunO2/GStore)
[![GitHub issues](https://img.shields.io/github/issues/sunO2/GStore?style=flat&refresh=0)](https://github.com/sunO2/GStore/issues)
![GitHub pull requests](https://img.shields.io/github/issues-pr/sunO2/GStore?style=flat&refresh=0)
[![GitHub all releases](https://img.shields.io/github/downloads/sunO2/GStore/total?style=flat&refresh=0)](https://github.com/sunO2/GStore/releases)
[![GitHub](https://img.shields.io/github/license/sunO2/GStore?style=flat&refresh=0)](https://github.com/sunO2/GStore/blob/main/LICENSE)

# GStore 软件商店

**一个基于开源项目的软件商店，旨在为您提供便捷、安全、可信赖的软件发现、下载和更新体验。**

GStore 不仅仅是一个软件下载平台，更是一个建立在开放、透明原则之上的软件生态系统。我们整合精选的开源项目，为您提供丰富的软件选择，同时保证软件来源的可追溯性和安全性。您可以在这里轻松浏览、下载并管理您需要的各种软件，所有软件数据均开源，欢迎社区共同维护和完善。

## ✨ 主要特性

* **多渠道应用聚合**: 支持 GitHub、F-Droid、vivo 应用市场、HTTP API 及本地数据库等多种应用来源，统一聚合展示。
* **精选开源软件**: GStore 收录经过筛选和审核的优质开源软件，确保软件的质量和安全性。告别广告和捆绑，专注于纯粹的软件体验。
* **一站式软件管理**: 无需在多个网站之间跳转，GStore 提供集中的软件展示、下载和更新平台，简化您的软件管理流程。
* **简洁直观的界面**: 我们注重用户体验，GStore 拥有清晰、友好的用户界面，让您轻松浏览和找到所需的软件。
* **快速便捷的下载**: 提供高速稳定的下载服务，支持断点续传、并发控制和失败自动重试，让您快速获取心仪的软件。
* **软件更新提醒**: 及时推送软件更新信息，帮助您保持软件版本最新，享受最佳功能和安全性。
* **自定义频道**: 支持添加和管理自定义应用频道，灵活扩展您的应用来源。
* **Material You 动态配色**: 原生支持 Android 12+ 动态主题，随系统取色自动适配。
* **工作流引擎**: 内置可视化工作流设计器，支持自动化流程编排。
* **完全开源的数据**: GStore 的软件数据全部开源，任何人都可以查看、贡献和审计，保证数据的透明度和社区参与性。

## 🗂️ 开源软件数据仓库

GStore 软件商店的核心数据——软件列表、描述、下载链接、更新信息等，全部托管在独立的开源仓库 [**GStore-Repositorys**](https://github.com/sunO2/GStore-Repositorys)。

我们坚信数据的开放和透明是构建可信赖软件生态的基础。

**GStore-Repositorys 仓库的特点：**

* **数据驱动**: 软件商店的展示内容完全由该仓库的数据驱动。
* **社区共建**: 欢迎社区成员共同维护和完善软件数据，提交 Issue 和 Pull Request 来添加新的软件、更新软件信息或修复错误。
* **格式规范**: 我们定义了清晰的数据格式规范，方便您理解和参与数据贡献。具体数据格式规范请参考 [GStore-Repositorys 仓库的 README.md](https://github.com/sunO2/GStore-Repositorys/blob/main/README.md)。

**如何参与数据贡献？**

1. **Fork [GStore-Repositorys](https://github.com/sunO2/GStore-Repositorys) 仓库**
2. **按照数据格式规范，在 `data` 目录下添加或修改软件数据文件**
3. **提交 Pull Request，等待审核合并**

您的贡献将帮助 GStore 软件商店变得更加丰富和完善，感谢您的参与！

## 🚀 快速开始

### 如果您是用户

1. **下载 GStore 安装包**: 前往 [GStore 项目的 Release 页面](https://github.com/sunO2/GStore/releases) 下载最新版本的 APK。
2. **安装 GStore**: 运行 APK 完成安装（需允许"安装未知来源应用"权限）。
3. **浏览应用**: 在"首页"浏览已添加的应用，或在"发现"页面探索新应用。
4. **添加应用**: 通过搜索、浏览或添加自定义频道来扩充您的应用列表。
5. **下载安装**: 点击应用详情页的"下载"按钮即可下载并安装。
6. **更新管理**: GStore 会定期检查更新，在"更新中心"统一管理。

### 如果您是开发者

```bash
# 克隆仓库
git clone https://github.com/sunO2/GStore.git
cd GStore

# 获取依赖
flutter pub get

# 运行调试
flutter run

# 构建 APK
flutter build apk --release --target-platform android-arm64
```

> 注意：F-Droid 渠道的高性能解析依赖 Rust 库（`rust/fdroid_repo`）。如需启用该功能，请先构建 Rust Android 库（参考 `build_android_rust.sh`）。

## 🛠️ 技术栈

* **前端框架**: Flutter（Material Design 3）
* **状态管理**: GetX（响应式状态 + 依赖注入 + 路由）
* **网络请求**: Dio、Retrofit、rhttp（基于 curl 的高性能 HTTP 客户端）
* **本地存储**: Floor（SQLite ORM）、shared_preferences、flutter_secure_storage
* **数据库**: SQLite
* **图像处理**: cached_network_image
* **网页浏览**: flutter_inappwebview
* **后端加速**: Rust + flutter_rust_bridge（FFI 集成，用于 F-Droid 仓库高性能解析）
* **持续集成**: GitHub Actions（自动构建多架构 APK / AAB 并发布 Release）

## 📦 支持的平台

* **Android**（主要平台，支持 arm64-v8a / armeabi-v7a / x86 / x86_64）
* iOS / Web / Linux / macOS / Windows（Flutter 跨平台支持，功能逐步完善中）

## 🤝 贡献

我们非常欢迎社区的贡献，无论是代码贡献、数据贡献、文档完善、Bug 报告，还是功能建议，都将帮助 GStore 变得更好。

您可以通过以下方式参与贡献：

* **提交 Issue**: 如果您在使用过程中遇到 Bug，或者有任何功能建议，欢迎提交 Issue。
* **提交 Pull Request**: 如果您有能力修复 Bug 或开发新功能，欢迎提交 Pull Request。
* **贡献软件数据**: 如果您希望推荐新的开源软件加入 GStore，或者发现现有软件数据需要更新，请参考 [GStore-Repositorys](https://github.com/sunO2/GStore-Repositorys) 仓库的说明，提交数据贡献。
* **参与讨论**: 在 Issue 评论区或社区论坛参与讨论，分享您的想法和建议。
* **推广 GStore**: 如果您喜欢 GStore，欢迎分享给您的朋友和同事，让更多人了解和使用 GStore。

## 📜 许可证

本项目使用 **GPL-3.0** 开源许可证。查看 [LICENSE](LICENSE) 了解详情。
