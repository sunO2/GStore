/// 「请求调试」作用域变量 / 鉴权解析（plan todo 20，纯函数，无 IO / 无 UI）。
///
/// 变量继承顺序（**后者覆盖前者**）：
/// `global → collection（祖先 → 叶子）→ environment → local`。
/// 鉴权继承顺序（就近优先）：
/// `request → 最近的集合（叶子 → 祖先）→ global`。
///
/// 本文件只做纯合并 / 选择，不读取任何存储；store 负责把集合祖先链与当前环境
/// 取出后调用本层（见 `RequestDebugStore.effectiveVarsForRequest`）。
library;

import 'debug_models.dart';

/// 合并多个作用域的变量表：**后者覆盖前者**，返回新表（不修改入参）。
Map<String, String> mergeDebugScopes(List<Map<String, String>> scopes) {
  final out = <String, String>{};
  for (final scope in scopes) {
    out.addAll(scope);
  }
  return out;
}

/// 按 `global → collection → environment → local` 合并有效变量表。
///
/// [collectionChain] 为**祖先 → 叶子**顺序的集合变量表；叶子的同名变量覆盖祖先。
/// 后加入的作用域覆盖先加入的，因此 `local` 优先级最高。
Map<String, String> resolveEffectiveVars({
  Map<String, String> globalVars = const <String, String>{},
  List<Map<String, String>> collectionChain = const <Map<String, String>>[],
  Map<String, String> environmentVars = const <String, String>{},
  Map<String, String> localVars = const <String, String>{},
}) =>
    mergeDebugScopes(<Map<String, String>>[
      globalVars,
      ...collectionChain,
      environmentVars,
      localVars,
    ]);

/// [DebugAuth] 是否「未配置」（`null` 或 [DebugAuthType.none]）。
bool isNoneDebugAuth(DebugAuth? auth) =>
    auth == null || auth.type == DebugAuthType.none;

/// 按 `request → 最近集合（叶子 → 祖先）→ global` 选出有效鉴权。
///
/// [collectionAuthChain] 为**祖先 → 叶子**顺序；从尾部向前找第一个非 none。
/// 全部未配置时返回 `null`。
DebugAuth? resolveEffectiveAuth({
  DebugAuth? requestAuth,
  List<DebugAuth?> collectionAuthChain = const <DebugAuth?>[],
  DebugAuth? globalAuth,
}) {
  if (!isNoneDebugAuth(requestAuth)) return requestAuth;
  for (var i = collectionAuthChain.length - 1; i >= 0; i--) {
    final auth = collectionAuthChain[i];
    if (!isNoneDebugAuth(auth)) return auth;
  }
  if (!isNoneDebugAuth(globalAuth)) return globalAuth;
  return null;
}
