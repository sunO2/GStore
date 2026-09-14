// 数据模型定义（宿主保留：**仅为满足 FRB 生成的 Dart 类型**；实现均已迁至对应模块）
//
// 注意：这些结构体当前不参与宿主业务逻辑。Dart 业务侧解码用的是手写的
// `lib/core/rust/contract/ModuleTypes.dart` / `Contract.dart`，而非此处生成的 Dart 类。
// 删除本文件需要同步重跑 flutter_rust_bridge codegen（生成的 frb_generated.rs /
// lib/core/rust/generated/*.dart 引用这些类型），因此暂以注释形式标注为待清理。

/// APK 解析结果（从 AndroidManifest 提取的真实应用信息；实现已移至 gstore_mod_analyzer 模块）
#[derive(Clone, Debug, Default)]
pub struct ApkInfo {
    /// 真实包名（如 com.termux）
    pub package_name: String,
    /// 版本名（如 0.118.0）
    pub version_name: String,
    /// 版本码
    pub version_code: String,
    /// 应用名称
    pub app_name: String,
    /// 最低支持 SDK
    pub min_sdk: String,
    /// 主 Activity
    pub main_activity: String,
}

/// 二维码单帧解码结果（zxing-cpp；类型保留供 FRB 生成 Dart 类，实现已移至 gstore_mod_qr 模块）
#[derive(Debug)]
pub struct QrDecodeResult {
    pub text: String,
    pub format: String,
    pub points: Vec<f64>,
    pub raw_bytes: Vec<u8>,
    pub symbology_identifier: String,
    pub is_mirrored: bool,
    pub is_inverted: bool,
}

/// Manifest 组件枚举结果（类型保留供 FRB 生成 Dart 类，实现已移至 gstore_mod_analyzer 模块）
#[derive(Clone, Debug, Default)]
pub struct ApkComponents {
    /// 应用包名（manifest/package）
    pub package_name: String,
    /// minSdkVersion（uses-sdk）
    pub min_sdk: String,
    /// targetSdkVersion（uses-sdk）
    pub target_sdk: String,
    /// <service> 完整类名
    pub services: Vec<String>,
    /// <activity> + <activity-alias> 完整类名
    pub activities: Vec<String>,
    /// <receiver> 完整类名
    pub receivers: Vec<String>,
    /// <provider> 完整类名
    pub providers: Vec<String>,
}

/// 单个 ELF .so 的页对齐检测结果（类型保留供 FRB 生成 Dart 类，实现已移至 gstore_mod_analyzer 模块）
#[derive(Clone, Debug, Default)]
pub struct ElfSoInfo {
    /// 所在 ABI 目录（如 `arm64-v8a`）
    pub abi: String,
    /// .so 文件名（如 `libfoo.so`）
    pub so_name: String,
    /// PT_LOAD 段最小 p_align；-1 表示非 ELF / 无 PT_LOAD / 解析失败
    pub min_page_size: i64,
    /// min_page_size > 0 且能被 16384 整除
    pub aligned_16kb: bool,
}

/// 整包扫描结果（类型保留供 FRB 生成 Dart 类，实现已移至 gstore_mod_analyzer 模块）
#[derive(Clone, Debug, Default)]
pub struct ApkElfScanResult {
    /// 命中的 `lib/<abi>/*.so` 检测结果列表
    pub so_files: Vec<ElfSoInfo>,
}