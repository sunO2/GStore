/// 「请求调试」窄门面（plan todo 29，可注入）。
///
/// **目录决策**（plan 行 333）：纯逻辑 / 模型 / 存储 / 发送 / 解析放
/// `lib/core/request_debug/`，UI 页面放 `lib/page/request_debug/`；本文件属纯
/// 逻辑层，故落位 `lib/core/request_debug/`（尽管 todo 29 标题写作
/// `lib/page/request_debug/request_debug_facade.dart`）。
///
/// 本门面**聚合**四层既有能力（[RequestDebugStore] / [DebugSender] /
/// cURL 编解码 / 环境变量引擎），并暴露两个跨 feature 接缝：
///
/// 1. **Seam 1 — 从抓包保存**：[saveCaptured] 接受**已映射**的
///    [DebugRequest]（抓包字节 → 模型的映射由 todo 35 负责），写入集合并
///    返回回填了 `collectionId` 的模型。沿用 store 语义：CRUD 仅内存，落盘由
///    调用方显式 [save]。
/// 2. **Seam 2 — 读写 Rust 改写规则**：[CaptureRulesPort] 为抽象端口，生产
///    适配器（包装 `ProxyModule.captureRulesGet/Set/Remove`）在 todo 35 接线；
///    本文件**不** import `ProxyModule`、**不**触碰 FFI。默认
///    [UnavailableCaptureRulesPort] 显式抛 [UnimplementedError]，迫使测试注入
///    假实现；门面在端口边界捕获异常并返回 [CaptureRulesResult.failure]，
///    **绝不**把端口异常向上抛给页面。
///
/// 生产接线用 [DefaultRequestDebugFacade.production]；测试可注入 store /
/// sender / 规则端口的假实现。
library;

import 'curl_codec.dart' as curl_codec;
import 'debug_models.dart';
import 'debug_response.dart';
import 'debug_sender.dart';
import 'env_resolver.dart' as env;
import 'request_debug_store.dart';

// ==================== Seam 2：Rust 改写规则端口 ====================

/// 捕获改写规则端口（Seam 2）。
///
/// 抽象接口：生产实现将由 todo 35 包装 `ProxyModule` 的
/// `captureRulesGet/Set/Remove`；在此之前只能用假实现注入（见
/// [UnavailableCaptureRulesPort]）。
///
/// 实现可在失败时抛异常；门面会在边界捕获并转为显式失败结果。
abstract class CaptureRulesPort {
  /// 读取全部改写规则。
  Future<List<DebugRewriteRule>> getRules();

  /// 新增 / 覆盖一条规则并返回生效后的规则。
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule);

  /// 按 id 删除规则；返回是否确有删除。
  Future<bool> removeRule(String id);
}

/// 默认规则端口：生产适配器尚未接线（todo 35）时使用。
///
/// **显式失败**：所有方法抛 [UnimplementedError]，避免「静默空规则」造成
/// 误导；调用方必须注入假实现或等待 todo 35 的真实适配器。
class UnavailableCaptureRulesPort implements CaptureRulesPort {
  const UnavailableCaptureRulesPort();

  /// 未接线提示（测试据此断言）。
  static const String message =
      '捕获改写规则端口尚未接线（生产适配器在 todo 35 提供）';

  @override
  Future<List<DebugRewriteRule>> getRules() =>
      Future<List<DebugRewriteRule>>.error(UnimplementedError(message));

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) =>
      Future<DebugRewriteRule>.error(UnimplementedError(message));

  @override
  Future<bool> removeRule(String id) =>
      Future<bool>.error(UnimplementedError(message));
}

// ==================== 结果包装 ====================

/// 改写规则端口调用的结果：成功携带模型值，失败携带人类可读错误。
///
/// 门面用它把端口异常（含默认端口的 [UnimplementedError]）转换为**显式
/// 失败结果**，页面无需 try/catch。
class CaptureRulesResult<T> {
  const CaptureRulesResult._(this.value, this.error);

  /// 成功值（失败时为 `null`）。
  final T? value;

  /// 错误信息（成功时为 `null`）。
  final String? error;

  /// 是否成功。
  bool get isSuccess => error == null;

  /// 是否失败。
  bool get isFailure => error != null;

  factory CaptureRulesResult.success(T value) =>
      CaptureRulesResult<T>._(value, null);

  factory CaptureRulesResult.failure(String error) =>
      CaptureRulesResult<T>._(null, error);

  @override
  String toString() => isSuccess
      ? 'CaptureRulesResult.success($value)'
      : 'CaptureRulesResult.failure($error)';
}

// ==================== 窄门面契约 ====================

/// 请求调试窄门面契约：聚合 store / sender / cURL / env，并暴露两个接缝。
///
/// UI（todos 30-34）依赖本契约；测试可注入整体假门面或注入各端口假实现。
abstract class RequestDebugFacade {
  /// 组合的存储层（CRUD 入口）。
  RequestDebugStore get store;

  /// 组合的发送器。
  DebugSender get sender;

  /// Seam 2 的规则端口。
  CaptureRulesPort get captureRules;

  /// 从磁盘加载（store 语义：损坏降级为空，不抛）。
  Future<void> load();

  /// 落盘（store 语义：失败返回 `false`，不抛）。
  Future<bool> save();

  /// 发送一次请求，归一化为 [DebugResponse]（失败结构化，不抛）。
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers,
    List<DebugQueryParam> query,
    String body,
    bool followRedirects,
    Duration? timeout,
    bool useCookies,
  });

  /// 解析 cURL（永不抛，结构化错误）。
  curl_codec.CurlParseResult parseCurl(String curlText);

  /// 导出 cURL（单引号转义）。
  String toCurl(DebugRequest request);

  /// `{{var}}` 替换（纯函数）。
  env.ResolveResult resolveEnv(String text, Map<String, String> vars);

  /// `{{var}}` 替换，取 [environment] 的变量表（纯函数）。
  env.ResolveResult resolveEnvIn(String text, DebugEnvironment environment);

  /// **Seam 1**：把已映射的抓包请求写入 [collectionId] 对应集合。
  ///
  /// 返回回填了 [DebugRequest.collectionId] 的模型；仅内存写入，持久化由
  /// 调用方随后 [save]。
  Future<DebugRequest> saveCaptured({
    required String collectionId,
    required DebugRequest request,
  });

  /// **Seam 2**：读取改写规则（端口异常转为显式失败结果）。
  Future<CaptureRulesResult<List<DebugRewriteRule>>> getCaptureRules();

  /// **Seam 2**：新增 / 覆盖改写规则（端口异常转为显式失败结果）。
  Future<CaptureRulesResult<DebugRewriteRule>> setCaptureRule(
    DebugRewriteRule rule,
  );

  /// **Seam 2**：删除改写规则（端口异常转为显式失败结果）。
  Future<CaptureRulesResult<bool>> removeCaptureRule(String id);
}

// ==================== 生产实现 ====================

/// 默认门面：把注入的 store / sender / 规则端口聚合为窄接口。
///
/// 生产用 [DefaultRequestDebugFacade.production] 装配真实 `store` / `sender`
/// 与未接线的规则端口；测试用主构造函数注入假实现。
class DefaultRequestDebugFacade implements RequestDebugFacade {
  DefaultRequestDebugFacade({
    required this.store,
    required this.sender,
    CaptureRulesPort? captureRules,
  }) : captureRules = captureRules ?? const UnavailableCaptureRulesPort();

  /// 生产组合：真实 [RequestDebugStore] / [DebugSender] + 未接线规则端口。
  ///
  /// 规则端口的生产适配器在 todo 35 接线，本工厂暂用
  /// [UnavailableCaptureRulesPort]（调用即显式失败）。
  factory DefaultRequestDebugFacade.production({
    DebugStoreDirectoryProvider? directoryProvider,
    DebugSender? sender,
    CaptureRulesPort? captureRules,
  }) =>
      DefaultRequestDebugFacade(
        store: RequestDebugStore(directoryProvider: directoryProvider),
        sender: sender ?? DebugSender(),
        captureRules: captureRules,
      );

  @override
  final RequestDebugStore store;

  @override
  final DebugSender sender;

  @override
  final CaptureRulesPort captureRules;

  @override
  Future<void> load() => store.load();

  @override
  Future<bool> save() => store.save();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
  }) =>
      sender.send(
        method: method,
        url: url,
        headers: headers,
        query: query,
        body: body,
        followRedirects: followRedirects,
        timeout: timeout,
        useCookies: useCookies,
      );

  @override
  curl_codec.CurlParseResult parseCurl(String curlText) => curl_codec.parseCurl(curlText);

  @override
  String toCurl(DebugRequest request) => curl_codec.toCurl(request);

  @override
  env.ResolveResult resolveEnv(String text, Map<String, String> vars) =>
      env.resolveEnv(text, vars);

  @override
  env.ResolveResult resolveEnvIn(String text, DebugEnvironment environment) =>
      env.resolveEnvIn(text, environment);

  @override
  Future<DebugRequest> saveCaptured({
    required String collectionId,
    required DebugRequest request,
  }) async {
    // store.addRequest 会把 collectionId 回填进返回模型（单一真源在集合内）。
    return store.addRequest(collectionId, request);
  }

  @override
  Future<CaptureRulesResult<List<DebugRewriteRule>>> getCaptureRules() =>
      _guardRules<List<DebugRewriteRule>>(captureRules.getRules);

  @override
  Future<CaptureRulesResult<DebugRewriteRule>> setCaptureRule(
    DebugRewriteRule rule,
  ) =>
      _guardRules<DebugRewriteRule>(() => captureRules.setRule(rule));

  @override
  Future<CaptureRulesResult<bool>> removeCaptureRule(String id) =>
      _guardRules<bool>(() => captureRules.removeRule(id));

  /// 端口边界：把任何异常转为 [CaptureRulesResult.failure]，绝不向上抛。
  static Future<CaptureRulesResult<T>> _guardRules<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return CaptureRulesResult<T>.success(await operation());
    } catch (error) {
      return CaptureRulesResult<T>.failure(_describe(error));
    }
  }

  static String _describe(Object error) =>
      error is UnimplementedError && error.message != null
          ? error.message!
          : error.toString();
}
