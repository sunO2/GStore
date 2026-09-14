import 'package:gstore/core/rust/contract/ModuleTypes.dart';

/// `<data>` → URI 文案；scheme 与 host 都为空时返回 null（不是深链）。
///
/// 路径按「精确 path > pathPrefix（补 `*` 表示前缀匹配）> pathPattern（正则原样保留）」取值。
///
/// 抽到 core 层供「应用分析页展示」与「快照采集」共用，避免两处实现漂移。
String? deepLinkUriOf(ManifestIntentData d) {
  if (!d.hasUri) return null;
  final path = d.path.isNotEmpty
      ? d.path
      : d.pathPrefix.isNotEmpty
          ? '${d.pathPrefix}*'
          : d.pathPattern;
  final sb = StringBuffer();
  if (d.scheme.isNotEmpty) sb.write('${d.scheme}://');
  if (d.host.isNotEmpty) sb.write(d.host);
  if (d.host.isNotEmpty && d.port.isNotEmpty) sb.write(':${d.port}');
  if (path.isNotEmpty) {
    if (!path.startsWith('/')) sb.write('/');
    sb.write(path);
  }
  return sb.toString();
}

/// 组件的全部深链 URI（同一 `<data>` 内 scheme/host/path 是组合条件，
/// 同一 filter 下多条 `<data>` 是并列规则 → 逐条展开）。
///
/// 返回已排序去重的 URI 列表。
List<String> componentDeepLinks(ManifestComponent component) {
  final out = <String>{};
  for (final f in component.intentFilters) {
    for (final d in f.data) {
      final uri = deepLinkUriOf(d);
      if (uri != null) out.add(uri);
    }
  }
  return out.toList()..sort();
}
