# third_party 补丁包说明

本目录只存放 **Flutter 3.50.1 / AGP 9.3.1 / Gradle 9.5.0 升级阻塞** 相关的最小 vendor 补丁。
所有包均通过 `pubspec.yaml` 的 `dependency_overrides` 指向本目录。

| 包 | 原版本 | 补丁内容 | 后续方案 |
|---|---|---|---|
| `dynamic_color` | 1.7.0 | `compileSdk 36`、Kotlin 2.4.20、AGP 9.3.1、Java 17 | 上游 1.9.0+ 支持 AGP 9，但要求 Built-in Kotlin；待全局启用后再升级 |
| `flutter_inappwebview_android` | 1.1.3 | `proguard-android.txt` → `proguard-android-optimize.txt`（AGP 9 不再提供旧文件） | 等上游发布兼容 AGP 9 的版本后移除 |
| `rhttp` | 0.15.1 | cargokit `plugin.gradle` 的 `project.exec` → `providers.exec`（Gradle 9 移除前者） | 升级到 0.18.0 需要 `flutter_rust_bridge ^2.12`，会牵动 Rust 绑定重新生成，暂缓 |

`installed_apps` 不在此目录：已 fork 到
<https://github.com/sunO2/installed_apps>（Android 侧改写为 Java），
`pubspec.yaml` 使用固定 commit `8d4861f4acf879840642351cb6d008157955f7ba`。

## 维护方式

升级任一上游包时：

1. 删除对应 `dependency_overrides` 条目
2. 执行 `flutter pub get`
3. 重新跑 `flutter build apk --release --target-platform android-arm64`
4. 构建通过后删除对应 `third_party/<包名>` 目录

## 注意

- 这些补丁只解决构建兼容，不改变 Dart API。
- 不要在这些目录里做业务改动；业务代码一律放在 `lib/`。
