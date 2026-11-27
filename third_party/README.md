# third_party

本目录已不再存放任何 vendor 包。

Flutter 3.50.1 / AGP 9 升级过程中需要的插件补丁，最终都改成了 GitHub commit 依赖：

| 包 | 处理方式 |
|---|---|
| `installed_apps` | fork：<https://github.com/sunO2/installed_apps>，Android 侧改写为 Java |
| `rhttp` | fork：<https://github.com/sunO2/rhttp>，AGP 9 + Built-in Kotlin 条件 apply KGP |
| `flutter_inappwebview_android` | fork：<https://github.com/sunO2/flutter_inappwebview_android>，proguard 默认文件改为 AGP 9 的 optimize 版本 |

`dynamic_color` 已直接升级到上游 1.9.0，无需 fork。

所有 fork 都固定到完整 commit，并在各自 README 中说明改动内容。
上游发布兼容 AGP 9 的正式版后，可以逐个删除 `dependency_overrides` 并切回 pub.dev。
