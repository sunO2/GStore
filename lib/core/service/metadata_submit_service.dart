import 'package:gstore/core/core.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/github_client.dart';

/// 元数据提交服务
///
/// 向 GStore-Repositorys 提交 issue，触发 Actions 自动提取
/// GitHub release APK 的应用名、包名、图标、版本信息，写入 metadata/ 目录。
class MetadataSubmitService {
  MetadataSubmitService();

  static MetadataSubmitService? _instance;

  static MetadataSubmitService get instance =>
      _instance ??= MetadataSubmitService();

  /// 目标仓库（存储元数据的开源仓库）
  static const String repoOwner = MetadataRepository.repoOwner;
  static const String repoName = MetadataRepository.repoName;

  /// 提交元数据提取请求
  ///
  /// [owner]/[repo]：目标应用的 GitHub 仓库；
  /// [assetKeyword]：APK 资产关键词（可选，留空则取最新 release 第一个 .apk）。
  /// 返回 issue 链接；未登录返回 null（调用方负责引导登录）。
  Future<String?> submitAppMetadata({
    required String owner,
    required String repo,
    String? assetKeyword,
  }) async {
    final userManager = UserManager.instance;
    final token = await userManager.getToken();
    if (token == null || token.isEmpty) {
      appLog.error('MetadataSubmitService: 未登录，无法提交 issue');
      return null;
    }

    final api = ModuleManager.instance.require<GithubRestClient>();
    final resp = await api.createIssue(
      repoOwner,
      repoName,
      {
        'title': '[app-metadata] $owner/$repo',
        'labels': ['app-metadata'],
        'body': _buildIssueBody(owner, repo, assetKeyword),
      },
    );

    // 提交成功：清除该应用缓存（含负缓存），Actions 生成后再次查看即可拉到最新
    await MetadataRepository.instance.removeCache(owner, repo);

    appLog.info('MetadataSubmitService: 提交成功 - $owner/$repo #${resp.number}');
    return resp.htmlUrl;
  }

  /// 构造与仓库 Issue 模板一致的 body（供 Actions 固定校验）
  String _buildIssueBody(String owner, String repo, String? assetKeyword) {
    final keyword = (assetKeyword == null || assetKeyword.trim().isEmpty)
        ? '-'
        : assetKeyword.trim();
    return '''
### 说明

提交后 GitHub Actions 会自动处理：下载最新 release 中的 APK → 提取元数据（应用名 / 包名 / 图标 / versionName / versionCode）→ 写入 \`metadata/\` 目录 → 完成后关闭本 issue。

### 仓库地址

https://github.com/$owner/$repo

### APK 资产关键词（可选）

$keyword

### 确认

- [x] 该仓库的最新 release 中包含 .apk 文件
''';
  }
}
