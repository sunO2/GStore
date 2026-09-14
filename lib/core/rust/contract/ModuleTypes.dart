import 'dart:typed_data';

/// 模块 JSON 契约类型（手写，供模块路由解码使用）
///
/// gstore_mod_analyzer / gstore_mod_qr 经 C ABI 返回 JSON，
/// Dart 侧解码回这些类型（与 FRB 生成的旧类型字段一致，业务层无感知）。

/// APK 元数据提取结果（模块 parse_apk_info 响应）
class ApkInfo {
  final String packageName;
  final String versionName;
  final String versionCode;
  final String appName;
  final String minSdk;
  final String mainActivity;

  const ApkInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.appName,
    required this.minSdk,
    required this.mainActivity,
  });
}

/// Manifest 组件枚举结果（模块 parse_components 响应）
class ApkComponents {
  final String packageName;
  final String minSdk;
  final String targetSdk;
  final List<String> services;
  final List<String> activities;
  final List<String> receivers;
  final List<String> providers;

  const ApkComponents({
    required this.packageName,
    required this.minSdk,
    required this.targetSdk,
    required this.services,
    required this.activities,
    required this.receivers,
    required this.providers,
  });
}

/// 单个 ELF .so 的元数据与页对齐检测结果（模块 scan_elf_page_sizes 响应元素）
class ElfSoInfo {
  final String abi;
  final String soName;

  /// zip 内完整路径
  final String path;

  /// 解压后字节数
  final int size;

  /// PT_LOAD 段最小 p_align；-1 表示非 ELF / 无 PT_LOAD / 解析失败
  final int minPageSize;

  /// STORED 条目数据起始偏移的最大 2 的幂因子；0 = 压缩存放或未知
  final int zipAlignment;

  /// 最终 16KB 判定（页对齐 + zip 对齐两个条件都满足）
  final bool aligned16Kb;

  /// `e_type`：2=ET_EXEC / 3=ET_DYN / 4=ET_CORE；-1 非 ELF
  final int elfType;

  /// `DT_NEEDED` 动态依赖
  final List<String> needed;

  /// JNI 导出入口符号（`Java_*` / `JNI_*`）
  final List<String> jniEntryPoints;

  /// 是否已剥离符号表
  final bool stripped;

  /// 解压后内容的 SHA-256（小写 hex）——"是否同一个文件"的强指纹
  final String sha256;

  /// `.note.gnu.build-id`（小写 hex）；未写入时为空
  final String buildId;

  const ElfSoInfo({
    required this.abi,
    required this.soName,
    this.path = '',
    this.size = 0,
    required this.minPageSize,
    this.zipAlignment = 0,
    required this.aligned16Kb,
    this.elfType = -1,
    this.needed = const [],
    this.jniEntryPoints = const [],
    this.stripped = false,
    this.sha256 = '',
    this.buildId = '',
  });
}

/// 整包 ELF 扫描结果（模块 scan_elf_page_sizes 响应）
class ApkElfScanResult {
  final List<ElfSoInfo> soFiles;

  const ApkElfScanResult({required this.soFiles});
}

/// 单项权限（模块 parse_manifest 响应）
class ManifestPermission {
  final String name;

  /// `android:maxSdkVersion`（无则空串）
  final String maxSdkVersion;

  const ManifestPermission({required this.name, this.maxSdkVersion = ''});
}

/// 单条 `<data>` 声明（深链/快捷启动的 scheme/host/path 规则）
class ManifestIntentData {
  final String scheme;
  final String host;
  final String port;
  final String path;
  final String pathPrefix;
  final String pathPattern;
  final String mimeType;

  const ManifestIntentData({
    this.scheme = '',
    this.host = '',
    this.port = '',
    this.path = '',
    this.pathPrefix = '',
    this.pathPattern = '',
    this.mimeType = '',
  });

  /// 是否能拼出 URI（scheme 或 host 至少有一个）
  bool get hasUri => scheme.isNotEmpty || host.isNotEmpty;
}

/// 单个 `<intent-filter>`
class ManifestIntentFilter {
  final List<String> actions;
  final List<String> categories;

  /// `android:autoVerify="true"`（仅 http/https App Links 有意义）
  final bool autoVerify;
  final List<ManifestIntentData> data;

  const ManifestIntentFilter({
    this.actions = const [],
    this.categories = const [],
    this.autoVerify = false,
    this.data = const [],
  });
}

/// 单个组件（模块 parse_manifest 响应）
class ManifestComponent {
  /// `activity` / `service` / `receiver` / `provider`
  final String kind;
  final String name;
  final String exported;
  final String process;

  /// 嵌套 intent-filter 的 action 列表（全部 filter 的并集）
  final List<String> actions;

  /// 嵌套 intent-filter 明细（含 `<data>`，深链/快捷启动分析用）
  final List<ManifestIntentFilter> intentFilters;

  const ManifestComponent({
    required this.kind,
    required this.name,
    this.exported = '',
    this.process = '',
    this.actions = const [],
    this.intentFilters = const [],
  });
}

/// 一条 meta-data（模块 parse_manifest 响应）
class ManifestMetaData {
  final String name;
  final String value;

  const ManifestMetaData({required this.name, this.value = ''});
}

/// 一条 uses-static-library（模块 parse_manifest 响应）
class ManifestStaticLibrary {
  final String name;
  final String version;
  final String certDigest;

  const ManifestStaticLibrary({
    required this.name,
    this.version = '',
    this.certDigest = '',
  });
}

/// Manifest 深度提取结果（模块 parse_manifest 响应）
class ApkManifestInfo {
  final String packageName;
  final String versionName;
  final String versionCode;
  final String minSdk;
  final String targetSdk;

  /// 编译 SDK（新 AGP 由宿主提供；旧 AGP 从 manifest 根节点读）
  final String compileSdk;

  /// 共享用户 ID
  final String sharedUserId;

  /// 首个 MAIN + LAUNCHER 的 Activity
  final String mainActivity;

  final List<ManifestPermission> permissions;
  final List<ManifestComponent> components;
  final List<ManifestMetaData> metaData;
  final List<ManifestStaticLibrary> staticLibraries;

  const ApkManifestInfo({
    this.packageName = '',
    this.versionName = '',
    this.versionCode = '',
    this.minSdk = '',
    this.targetSdk = '',
    this.compileSdk = '',
    this.sharedUserId = '',
    this.mainActivity = '',
    this.permissions = const [],
    this.components = const [],
    this.metaData = const [],
    this.staticLibraries = const [],
  });

  /// 全部组件 intent-filter 的 action（去重）
  List<String> get allActions {
    final set = <String>{};
    for (final c in components) {
      set.addAll(c.actions);
    }
    return set.toList()..sort();
  }
}

/// 一个 DEX 条目的统计（模块 scan_dex_stats 响应）
class ApkDexStat {
  final String name;
  final int size;
  final int compressedSize;
  final int crc32;

  /// `class_defs_size`；解析失败为 -1
  final int classCount;

  /// DEX 头 checksum（adler32）
  final int checksum;

  /// DEX 头 signature（SHA-1，小写 hex）——编译期算好的内容指纹
  final String headerSha1;

  /// DEX 头声明的文件大小
  final int headerFileSize;

  /// string_ids / type_ids / proto_ids / field_ids / method_ids 数量
  final int stringIds;
  final int typeIds;
  final int protoIds;
  final int fieldIds;
  final int methodIds;

  /// data 区大小
  final int dataSize;

  /// 类集合指纹（排序后类描述符的 SHA-256）——判定 multidex 分包/类搬迁
  final String classDigest;

  const ApkDexStat({
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.classCount,
    this.checksum = 0,
    this.headerSha1 = '',
    this.headerFileSize = 0,
    this.stringIds = 0,
    this.typeIds = 0,
    this.protoIds = 0,
    this.fieldIds = 0,
    this.methodIds = 0,
    this.dataSize = 0,
    this.classDigest = '',
  });

  /// 是否有可用的头指纹（解析失败/旧模块输出时为 false）
  bool get hasHeaderFingerprint => headerSha1.isNotEmpty;
}

/// 整包 DEX 统计（模块 scan_dex_stats 响应）
/// `resources.arsc` 里的一个资源条目（默认配置）
class ApkArscResource {
  /// 资源 id：0xPPTTEEEE
  final int id;
  final String typeName;
  final String key;
  final String valueKind;
  final String value;

  const ApkArscResource({
    this.id = 0,
    this.typeName = '',
    this.key = '',
    this.valueKind = '',
    this.value = '',
  });

  /// 展示用标识：`0x7f010001 string/app_name`
  String get label =>
      '0x${id.toRadixString(16).padLeft(8, '0')} $typeName/$key';
}

/// `resources.arsc` 浅解析结果（模块 scan_apk_structure 响应）
class ApkArscInfo {
  final bool parsed;
  final int packageCount;
  final List<String> packageNames;
  final int typeCount;
  final List<String> typeNames;
  final int globalStringCount;
  final int keyCount;
  final int entryInstances;
  final List<String> configs;

  /// 默认配置下的资源条目（资源级 diff）
  final List<ApkArscResource> resources;

  /// 资源条目是否因上限被截断
  final bool resourcesTruncated;

  const ApkArscInfo({
    this.parsed = false,
    this.packageCount = 0,
    this.packageNames = const [],
    this.typeCount = 0,
    this.typeNames = const [],
    this.globalStringCount = 0,
    this.keyCount = 0,
    this.entryInstances = 0,
    this.configs = const [],
    this.resources = const [],
    this.resourcesTruncated = false,
  });
}

class ApkDexStats {
  final List<ApkDexStat> dexFiles;
  final int totalClassCount;

  const ApkDexStats({
    this.dexFiles = const [],
    this.totalClassCount = 0,
  });
}

/// 签名方案检测结果（模块 detect_signature_schemes 响应）
class ApkSignatureSchemes {
  final bool hasV1;
  final bool hasV2;
  final bool hasV3;
  final bool hasV31;
  final bool hasV32;
  final bool hasV4;

  /// 命中的方案标签（如 `["V2","V3"]`）
  final List<String> schemes;

  /// 签名块内出现的全部 ID（诊断用）
  final List<int> signingBlockIds;

  const ApkSignatureSchemes({
    this.hasV1 = false,
    this.hasV2 = false,
    this.hasV3 = false,
    this.hasV31 = false,
    this.hasV32 = false,
    this.hasV4 = false,
    this.schemes = const [],
    this.signingBlockIds = const [],
  });
}

/// APK 特征（模块 scan_features 响应）
class ApkFeatures {
  final bool kotlinUsed;
  final bool jetpackCompose;
  final bool kmp;
  final bool xposedModule;
  final bool playSigning;
  final bool pwa;
  final bool liveUpdateNotification;

  /// AGP 版本（未知为空串）
  final String agpVersion;

  /// 判定依据（诊断用）
  final List<String> evidence;

  const ApkFeatures({
    this.kotlinUsed = false,
    this.jetpackCompose = false,
    this.kmp = false,
    this.xposedModule = false,
    this.playSigning = false,
    this.pwa = false,
    this.liveUpdateNotification = false,
    this.agpVersion = '',
    this.evidence = const [],
  });

  /// 用于展示的特征标签（顺序稳定）
  List<String> get labels => [
        if (kotlinUsed) 'Kotlin',
        if (jetpackCompose) 'Jetpack Compose',
        if (kmp) 'KMP',
        if (xposedModule) 'Xposed',
        if (playSigning) 'Play 签名',
        if (pwa) 'PWA',
        if (liveUpdateNotification) '即时更新通知',
      ];
}

/// 一条规则命中（模块 match_libraries 响应）
class RuleHit {
  final String ruleName;
  final String label;

  /// `native` / `dex` / `component` / `static` / `action`
  final String kind;

  /// 命中的具体项（.so 名 / 类名 / 组件名 / 库名 / action）
  final String matched;
  final bool isRegex;

  /// 组件类型（1=service 2=activity 3=receiver 4=provider；非组件为 0）
  final int componentType;

  const RuleHit({
    required this.ruleName,
    required this.label,
    required this.kind,
    required this.matched,
    this.isRegex = false,
    this.componentType = 0,
  });
}

/// 构建版本（模块 scan_build_versions 响应）
class ApkBuildVersions {
  final String kotlinVersion;
  final String gradleVersion;
  final String javaVersion;
  final String composeVersion;
  final String agpVersion;

  const ApkBuildVersions({
    this.kotlinVersion = '',
    this.gradleVersion = '',
    this.javaVersion = '',
    this.composeVersion = '',
    this.agpVersion = '',
  });
}

/// 规则匹配结果（模块 match_libraries 响应）
class RuleMatchResult {
  final List<RuleHit> hits;

  /// 因正则语法超出模块支持子集而被跳过的规则数（宿主可回退处理）
  final int skippedRegex;

  /// 扫描到的 DEX 类名总数（诊断用）
  final int dexClassCount;

  const RuleMatchResult({
    this.hits = const [],
    this.skippedRegex = 0,
    this.dexClassCount = 0,
  });
}

/// 聚合报告（模块 scan_apk_report 响应）
///
/// 各节与单能力方法返回同构，可直接复用同一批解析器；
/// 某一节失败时该节为 null 并把原因记入 [errors]，其余节不受影响。
class ApkReport {
  /// 逐节失败原因
  final List<String> errors;
  final ApkStructure? structure;
  final ApkManifestInfo? manifest;
  final ApkDexStats? dexStats;
  final ApkElfScanResult? elf;
  final ApkSignatureSchemes? signature;
  final ApkFeatures features;
  final RuleMatchResult? matches;

  /// 构建版本（Kotlin/Gradle/Java/Compose/AGP）
  final ApkBuildVersions buildVersions;

  /// 扫描到的 DEX 类名数量 / 使用的 DEX 模式数量（诊断用）
  final int dexClassCount;
  final int dexPatternCount;

  const ApkReport({
    this.errors = const [],
    this.structure,
    this.manifest,
    this.dexStats,
    this.elf,
    this.signature,
    this.features = const ApkFeatures(),
    this.matches,
    this.buildVersions = const ApkBuildVersions(),
    this.dexClassCount = 0,
    this.dexPatternCount = 0,
  });

  bool get hasErrors => errors.isNotEmpty;
}

/// 二维码单帧解码结果（模块 decode_luma 响应）
class QrDecodeResult {
  final String text;
  final String format;
  final Float64List points;
  final Uint8List rawBytes;
  final bool isMirrored;
  final bool isInverted;

  /// 是否成功解码（false = 仅定位到候选，text 为空）
  final bool isValid;

  /// 不可读候选的失败类型：'' | none | checksum | format | unsupported
  final String error;

  /// 符号朝向（度）
  final int orientation;

  const QrDecodeResult({
    required this.text,
    required this.format,
    required this.points,
    required this.rawBytes,
    required this.isMirrored,
    required this.isInverted,
    this.isValid = false,
    this.error = '',
    this.orientation = 0,
  });

  /// 是否「定位到但校验失败」：几何可信、像素质量不足。
  /// 与「完全没检测到」是不同的信号——后者调焦段无收益，前者可能放大/提对比度就能解开。
  bool get isChecksumFailure => error == 'checksum';
}

/// 一个 .so 条目（模块 scan_apk_structure 响应元素）。
/// 全部字段来自 zip 中央目录，**无需解压**即可获得。
class ApkSoEntry {
  /// 文件名（如 libcrypto.so）
  final String name;

  /// zip 内完整路径（如 lib/arm64-v8a/libcrypto.so）
  final String path;

  /// 解压后字节数
  final int size;

  /// 压缩后字节数
  final int compressedSize;

  /// 条目 CRC32
  final int crc32;

  /// 是否以 STORED（不压缩）存放：只有它才谈得上数据偏移对齐
  final bool stored;

  /// STORED 条目数据起始偏移的最大 2 的幂因子（对齐 LibChecker zipAlignment）；
  /// 非 STORED 为 0
  final int zipAlignment;

  const ApkSoEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.stored,
    required this.zipAlignment,
  });
}

/// 单个 ABI 目录下的原生库分组
/// 一个 `assets/**` 条目（模块 scan_apk_structure 响应）
///
/// `crc32` 是**解压后内容**指纹 → 可直接判定"同名 asset 是否内容一致"，无需解压。
class ApkAssetEntry {
  /// zip 内完整路径（如 `assets/models/x.tflite`）
  final String path;

  /// 相对 `assets/` 的路径
  final String name;

  /// 解压后字节数
  final int size;

  /// 压缩后字节数
  final int compressedSize;

  /// 条目 CRC32（内容指纹）
  final int crc32;

  /// 是否以 STORED（不压缩）存放
  final bool stored;

  const ApkAssetEntry({
    required this.path,
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.stored,
  });
}

class ApkAbiLibs {
  /// ABI 目录名（如 arm64-v8a）
  final String abi;

  /// 该 ABI 下的库清单（按文件名排序）
  final List<ApkSoEntry> libs;

  /// 该 ABI 下库的解压后总字节数
  final int totalSize;

  const ApkAbiLibs({
    required this.abi,
    required this.libs,
    required this.totalSize,
  });
}

/// 一个 DEX 条目
class ApkDexEntry {
  /// 条目名（如 classes2.dex）
  final String name;

  /// 解压后字节数
  final int size;

  /// 压缩后字节数
  final int compressedSize;

  /// 条目 CRC32
  final int crc32;

  const ApkDexEntry({
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.crc32,
  });
}

/// APK 结构清单（模块 scan_apk_structure 响应）
class ApkStructure {
  /// APK 文件本身大小
  final int fileSize;

  /// zip 条目总数
  final int entryCount;

  /// 全部条目解压后总字节数
  final int totalUncompressed;

  /// STORED（未压缩）条目数量
  final int storedEntryCount;

  /// 按 ABI 分组的原生库（ABI 名升序）
  final List<ApkAbiLibs> abis;

  /// `assets/**/*.so`
  final List<ApkSoEntry> assetsSo;

  /// `assets/**` 全量清单（含 `.so`）
  final List<ApkAssetEntry> assets;

  /// DEX 文件清单
  final List<ApkDexEntry> dexFiles;

  /// resources.arsc 解压后大小（缺失为 0）
  final int resourcesArscSize;

  /// resources.arsc 条目 CRC32（内容指纹；缺失为 0）
  final int resourcesArscCrc32;

  /// resources.arsc 是否 STORED 存放
  final bool resourcesArscStored;

  /// resources.arsc 浅解析（包名/类型/字符串池/配置维度）
  final ApkArscInfo arsc;

  /// resources.arsc 压缩后字节数
  final int resourcesArscCompressedSize;

  /// 是否含 AndroidManifest.xml
  final bool hasManifest;

  const ApkStructure({
    required this.fileSize,
    required this.entryCount,
    required this.totalUncompressed,
    required this.storedEntryCount,
    required this.abis,
    required this.assetsSo,
    required this.assets,
    required this.dexFiles,
    required this.resourcesArscSize,
    required this.resourcesArscCrc32,
    required this.resourcesArscStored,
    this.arsc = const ApkArscInfo(),
    this.resourcesArscCompressedSize = 0,
    required this.hasManifest,
  });

  /// 全部 ABI 目录名
  List<String> get abiNames => [for (final a in abis) a.abi];

  /// 全部 `lib/<abi>/*.so` 的文件名（去重，供规则匹配 / 伴随验证）
  Set<String> get nativeSoNames => {
        for (final group in abis)
          for (final lib in group.libs) lib.name,
      };
}
