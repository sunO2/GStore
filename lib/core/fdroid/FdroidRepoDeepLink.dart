/// F-Droid 仓库深链解析（P0）
///
/// F-Droid 客户端为仓库 URL 注册了 intent filter，`fdroidrepos://` 即 https、
/// `fdroidrepo://` 即 http。深链常带 `?fingerprint=<sha256>`，用于添加**第三方源**
/// （含 Bitwarden 那种「独立应用私有源」）时确认仓库身份（TOFU）。
///
/// 这里只做「解析与归一化」，下载时的候选地址（含 `/fdroid/repo` 自动发现）由
/// 模块侧 `normalize_repo_urls` 负责，避免两处逻辑漂移。
class FdroidRepoDeepLink {
  const FdroidRepoDeepLink({required this.url, this.fingerprint});

  /// 归一化后的仓库地址（已去 query/fragment）
  final String url;

  /// 期望的仓库签名指纹（SHA-256 十六进制，大写后便于比对）；缺省表示用户未提供
  final String? fingerprint;

  /// 解析用户输入或深链。无法解析（空/无主机）返回 null。
  static FdroidRepoDeepLink? parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    String scheme;
    String rest;
    if (raw.startsWith('fdroidrepos://')) {
      scheme = 'https';
      rest = raw.substring('fdroidrepos://'.length);
    } else if (raw.startsWith('fdroidrepo://')) {
      scheme = 'http';
      rest = raw.substring('fdroidrepo://'.length);
    } else if (raw.contains('://')) {
      final idx = raw.indexOf('://');
      scheme = raw.substring(0, idx);
      rest = raw.substring(idx + 3);
    } else {
      scheme = 'https';
      rest = raw;
    }

    String? fingerprint;
    if (rest.contains('?')) {
      final qi = rest.indexOf('?');
      final query = rest.substring(qi + 1);
      rest = rest.substring(0, qi);
      for (final pair in query.split('&')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final k = pair.substring(0, eq).toLowerCase();
        if (k == 'fingerprint') {
          final v = Uri.decodeComponent(pair.substring(eq + 1)).trim();
          if (v.isNotEmpty) fingerprint = v.toUpperCase().replaceAll(':', '');
        }
      }
    }
    // fragment 不参与
    final hash = rest.indexOf('#');
    if (hash >= 0) rest = rest.substring(0, hash);
    rest = rest.replaceAll(RegExp(r'/+$'), '');
    if (rest.isEmpty) return null;
    // 至少要有一个主机段
    if (!rest.contains('.') && !rest.contains(':')) return null;

    return FdroidRepoDeepLink(
      url: '$scheme://$rest',
      fingerprint: fingerprint,
    );
  }
}
