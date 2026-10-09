/// 「请求调试」（Postman-like）纯逻辑层数据模型。
///
/// 目录决策（见 `.omo/plans/proxy-http-capture.md` todo 25）：模型 / 存储 /
/// 发送 / 解析全部放 `lib/core/request_debug/`，UI 页面另放
/// `lib/page/request_debug/`。本文件**不含**任何 IO 或 UI，仅提供可 JSON
/// 往返的不可变模型，供存储（[RequestDebugStore]）与后续发送器 / cURL 编解码 /
/// 环境变量引擎复用。
///
/// 解析策略：必填字段缺失 / 类型错误时抛 [FormatException]，由存储层对
/// **逐条**容错（跳过脏条目）；可选字段缺失安全降级为默认值。
library;

/// id 生成序号：避免同一微秒内批量创建时碰撞。
int _idSeq = 0;

/// copyWith 哨兵：区分「未传参（保留原值）」与「显式传 `null`（清空可空字段）」。
///
/// 可空字段的 copyWith 参数默认为此哨兵；调用方显式传 `null` 即可清空，
/// 从而修复「无法把可空字段改回 null」的数据保真缺陷（todo 13）。
const Object _unset = Object();

/// 生成带前缀的唯一 id。
String generateDebugId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

// ==================== 枚举 ====================

/// 请求体类型（编辑器的「体」分段）。
enum DebugBodyKind {
  none('none'),
  json('json'),
  text('text'),
  formUrlEncoded('form_urlencoded'),
  multipart('multipart'),
  binary('binary');

  const DebugBodyKind(this.wire);

  /// 持久化 / 线缆值。
  final String wire;

  /// 未知值降级为 [DebugBodyKind.none]。
  static DebugBodyKind fromWire(Object? value) => values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DebugBodyKind.none,
      );
}

/// 二进制请求体的输入来源（`bodyKind == binary` 时生效）。
///
/// - [raw]：textarea 文本按 UTF-8 原样作为字节（默认、向后兼容）；
/// - [hex] / [base64]：把文本解码为字节；
/// - [file]：从 [DebugRequest.binaryFilePath] 读取本地文件字节。
enum DebugBinarySource {
  raw('raw'),
  hex('hex'),
  base64('base64'),
  file('file');

  const DebugBinarySource(this.wire);

  /// 持久化 / 线缆值。
  final String wire;

  /// 未知值降级为 [DebugBinarySource.raw]。
  static DebugBinarySource fromWire(Object? value) => values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DebugBinarySource.raw,
      );
}

/// 认证类型（编辑器的「认证」分段）。
enum DebugAuthType {
  none('none'),
  basic('basic'),
  bearer('bearer'),
  apiKey('apiKey');

  const DebugAuthType(this.wire);

  /// 持久化 / 线缆值。
  final String wire;

  /// 未知值降级为 [DebugAuthType.none]。
  static DebugAuthType fromWire(Object? value) => values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DebugAuthType.none,
      );
}

/// 改写规则类型（镜像 Rust `CaptureRule` 的 UI 视图）。
enum DebugRewriteKind {
  /// 替换响应（改写状态码 / 头 / Body）。
  replaceResponse('replace_response'),

  /// 返回本地响应（不真正出网）。
  localResponse('local_response');

  const DebugRewriteKind(this.wire);

  /// 持久化 / 线缆值。
  final String wire;

  /// 未知值降级为 [DebugRewriteKind.replaceResponse]。
  static DebugRewriteKind fromWire(Object? value) => values.firstWhere(
        (e) => e.wire == value,
        orElse: () => DebugRewriteKind.replaceResponse,
      );
}

// ==================== 值对象 ====================

/// 请求 / 响应头（键值 + 启用开关，Postman 语义）。
class DebugHeader {
  const DebugHeader({
    required this.name,
    this.value = '',
    this.enabled = true,
  });

  final String name;
  final String value;
  final bool enabled;

  DebugHeader copyWith({String? name, String? value, bool? enabled}) =>
      DebugHeader(
        name: name ?? this.name,
        value: value ?? this.value,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'enabled': enabled,
      };

  factory DebugHeader.fromJson(Map<String, dynamic> json) => DebugHeader(
        name: _asString(json['name']),
        value: _asString(json['value']),
        enabled: _asBool(json['enabled'], fallback: true),
      );
}

/// URL 查询参数（键值 + 启用开关）。
class DebugQueryParam {
  const DebugQueryParam({
    required this.name,
    this.value = '',
    this.enabled = true,
  });

  final String name;
  final String value;
  final bool enabled;

  DebugQueryParam copyWith({String? name, String? value, bool? enabled}) =>
      DebugQueryParam(
        name: name ?? this.name,
        value: value ?? this.value,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'enabled': enabled,
      };

  factory DebugQueryParam.fromJson(Map<String, dynamic> json) =>
      DebugQueryParam(
        name: _asString(json['name']),
        value: _asString(json['value']),
        enabled: _asBool(json['enabled'], fallback: true),
      );
}

/// 请求 Cookie。
class DebugCookie {
  const DebugCookie({
    required this.name,
    this.value = '',
    this.domain,
    this.path,
  });

  final String name;
  final String value;
  final String? domain;
  final String? path;

  DebugCookie copyWith({
    String? name,
    String? value,
    String? domain,
    String? path,
  }) =>
      DebugCookie(
        name: name ?? this.name,
        value: value ?? this.value,
        domain: domain ?? this.domain,
        path: path ?? this.path,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        if (domain != null) 'domain': domain,
        if (path != null) 'path': path,
      };

  factory DebugCookie.fromJson(Map<String, dynamic> json) => DebugCookie(
        name: _asString(json['name']),
        value: _asString(json['value']),
        domain: _asStringOrNull(json['domain']),
        path: _asStringOrNull(json['path']),
      );
}

/// multipart 表单项（`bodyKind == multipart`）。
///
/// [filePath] 非空表示**文件项**（发送前由 IO 辅助读取字节，文件名取
/// [fileName] 或路径 basename）；否则为普通文本项（[value]）。
class DebugMultipartField {
  const DebugMultipartField({
    required this.name,
    this.value = '',
    this.filePath,
    this.fileName,
    this.contentType,
    this.enabled = true,
  });

  final String name;
  final String value;
  final String? filePath;
  final String? fileName;
  final String? contentType;
  final bool enabled;

  bool get isFile => filePath != null && filePath!.isNotEmpty;

  DebugMultipartField copyWith({
    String? name,
    String? value,
    String? filePath,
    String? fileName,
    String? contentType,
    bool? enabled,
  }) =>
      DebugMultipartField(
        name: name ?? this.name,
        value: value ?? this.value,
        filePath: filePath ?? this.filePath,
        fileName: fileName ?? this.fileName,
        contentType: contentType ?? this.contentType,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        if (filePath != null) 'filePath': filePath,
        if (fileName != null) 'fileName': fileName,
        if (contentType != null) 'contentType': contentType,
        'enabled': enabled,
      };

  factory DebugMultipartField.fromJson(Map<String, dynamic> json) =>
      DebugMultipartField(
        name: _asString(json['name']),
        value: _asString(json['value']),
        filePath: _asStringOrNull(json['filePath']),
        fileName: _asStringOrNull(json['fileName']),
        contentType: _asStringOrNull(json['contentType']),
        enabled: _asBool(json['enabled'], fallback: true),
      );
}

/// 认证配置（按 [type] 取用相应字段，其余为 null）。
class DebugAuth {
  const DebugAuth({
    this.type = DebugAuthType.none,
    this.username,
    this.password,
    this.token,
    this.apiKeyName,
    this.apiKeyValue,
    this.apiKeyIn,
  });

  final DebugAuthType type;
  final String? username;
  final String? password;
  final String? token;
  final String? apiKeyName;
  final String? apiKeyValue;

  /// apiKey 注入位置：`header` | `query`。
  final String? apiKeyIn;

  /// 可空字段使用哨兵语义：缺省保留原值，**显式传 `null` 清空**。
  DebugAuth copyWith({
    DebugAuthType? type,
    Object? username = _unset,
    Object? password = _unset,
    Object? token = _unset,
    Object? apiKeyName = _unset,
    Object? apiKeyValue = _unset,
    Object? apiKeyIn = _unset,
  }) =>
      DebugAuth(
        type: type ?? this.type,
        username: identical(username, _unset)
            ? this.username
            : username as String?,
        password: identical(password, _unset)
            ? this.password
            : password as String?,
        token: identical(token, _unset) ? this.token : token as String?,
        apiKeyName: identical(apiKeyName, _unset)
            ? this.apiKeyName
            : apiKeyName as String?,
        apiKeyValue: identical(apiKeyValue, _unset)
            ? this.apiKeyValue
            : apiKeyValue as String?,
        apiKeyIn: identical(apiKeyIn, _unset)
            ? this.apiKeyIn
            : apiKeyIn as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type.wire,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
        if (token != null) 'token': token,
        if (apiKeyName != null) 'apiKeyName': apiKeyName,
        if (apiKeyValue != null) 'apiKeyValue': apiKeyValue,
        if (apiKeyIn != null) 'apiKeyIn': apiKeyIn,
      };

  factory DebugAuth.fromJson(Map<String, dynamic> json) => DebugAuth(
        type: DebugAuthType.fromWire(json['type']),
        username: _asStringOrNull(json['username']),
        password: _asStringOrNull(json['password']),
        token: _asStringOrNull(json['token']),
        apiKeyName: _asStringOrNull(json['apiKeyName']),
        apiKeyValue: _asStringOrNull(json['apiKeyValue']),
        apiKeyIn: _asStringOrNull(json['apiKeyIn']),
      );
}

/// 保存请求时附带的响应覆盖（来自抓包「保存到请求调试」）。
class DebugResponseOverride {
  DebugResponseOverride({
    this.statusCode,
    this.headers,
    this.body,
  });

  final int? statusCode;
  final List<DebugHeader>? headers;
  final String? body;

  Map<String, dynamic> toJson() => {
        if (statusCode != null) 'statusCode': statusCode,
        if (headers != null)
          'headers': headers!.map((e) => e.toJson()).toList(),
        if (body != null) 'body': body,
      };

  factory DebugResponseOverride.fromJson(Map<String, dynamic> json) =>
      DebugResponseOverride(
        statusCode: _asIntOrNull(json['statusCode']),
        headers: _headersOrNull(json['headers']),
        body: _asStringOrNull(json['body']),
      );
}

// ==================== 核心模型 ====================

/// 请求。
class DebugRequest {
  DebugRequest({
    required this.id,
    required this.name,
    this.method = 'GET',
    this.url = '',
    List<DebugHeader>? headers,
    List<DebugQueryParam>? query,
    this.body = '',
    this.bodyKind = DebugBodyKind.none,
    this.binarySource = DebugBinarySource.raw,
    this.binaryFilePath,
    List<DebugMultipartField>? multipartFields,
    this.auth,
    List<DebugCookie>? cookies,
    this.collectionId,
    this.overrides,
    this.timeoutMs,
    this.followRedirects,
    this.useCookieJar,
    this.skipTlsVerify,
  })  : headers = headers ?? [],
        query = query ?? [],
        multipartFields = multipartFields ?? [],
        cookies = cookies ?? [];

  final String id;
  final String name;

  /// HTTP 方法（大写，如 `GET` / `POST`）。
  final String method;
  final String url;
  final List<DebugHeader> headers;
  final List<DebugQueryParam> query;
  final String body;
  final DebugBodyKind bodyKind;

  /// `bodyKind == binary` 时的输入来源（默认 [DebugBinarySource.raw]）。
  final DebugBinarySource binarySource;

  /// `binarySource == file` 时的本地文件路径。
  final String? binaryFilePath;

  /// `bodyKind == multipart` 的结构化字段 / 文件项。
  final List<DebugMultipartField> multipartFields;
  final DebugAuth? auth;
  final List<DebugCookie> cookies;

  /// 所属集合 id（嵌套于 [DebugCollection.requests] 时由存储回填）。
  final String? collectionId;

  /// 保存时附带的响应覆盖（可空）。
  final DebugResponseOverride? overrides;

  // ==================== 每请求网络选项（plan todo 4）====================
  //
  // 全部可选：`null` 表示「采用发送器默认」（30s / 跟随重定向 / 使用 Cookie
  // jar / 严格证书）。刻意不落地默认值，保证旧数据与新旧代码端到端兼容；
  // 版本/迁移由 todo 10 负责，本模型**不单独升版**。

  /// 请求超时（毫秒）；`null` = 默认 30s。
  final int? timeoutMs;

  /// 是否跟随重定向；`null` = 默认跟随。
  final bool? followRedirects;

  /// 是否使用 Cookie jar；`null` = 默认使用。
  final bool? useCookieJar;

  /// 是否跳过 TLS 证书校验；`null`/`false` = 严格校验（默认）。
  final bool? skipTlsVerify;

  /// 可空字段使用哨兵语义：缺省保留原值，**显式传 `null` 清空**
  /// （`auth` / `overrides` / `collectionId` / `binaryFilePath` / 每请求网络选项）。
  DebugRequest copyWith({
    String? id,
    String? name,
    String? method,
    String? url,
    List<DebugHeader>? headers,
    List<DebugQueryParam>? query,
    String? body,
    DebugBodyKind? bodyKind,
    DebugBinarySource? binarySource,
    Object? binaryFilePath = _unset,
    List<DebugMultipartField>? multipartFields,
    Object? auth = _unset,
    List<DebugCookie>? cookies,
    Object? collectionId = _unset,
    Object? overrides = _unset,
    Object? timeoutMs = _unset,
    Object? followRedirects = _unset,
    Object? useCookieJar = _unset,
    Object? skipTlsVerify = _unset,
  }) =>
      DebugRequest(
        id: id ?? this.id,
        name: name ?? this.name,
        method: method ?? this.method,
        url: url ?? this.url,
        headers: headers ?? this.headers,
        query: query ?? this.query,
        body: body ?? this.body,
        bodyKind: bodyKind ?? this.bodyKind,
        binarySource: binarySource ?? this.binarySource,
        binaryFilePath: identical(binaryFilePath, _unset)
            ? this.binaryFilePath
            : binaryFilePath as String?,
        multipartFields: multipartFields ?? this.multipartFields,
        auth: identical(auth, _unset) ? this.auth : auth as DebugAuth?,
        cookies: cookies ?? this.cookies,
        collectionId: identical(collectionId, _unset)
            ? this.collectionId
            : collectionId as String?,
        overrides: identical(overrides, _unset)
            ? this.overrides
            : overrides as DebugResponseOverride?,
        timeoutMs: identical(timeoutMs, _unset)
            ? this.timeoutMs
            : timeoutMs as int?,
        followRedirects: identical(followRedirects, _unset)
            ? this.followRedirects
            : followRedirects as bool?,
        useCookieJar: identical(useCookieJar, _unset)
            ? this.useCookieJar
            : useCookieJar as bool?,
        skipTlsVerify: identical(skipTlsVerify, _unset)
            ? this.skipTlsVerify
            : skipTlsVerify as bool?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'method': method,
        'url': url,
        'headers': headers.map((e) => e.toJson()).toList(),
        'query': query.map((e) => e.toJson()).toList(),
        'body': body,
        'bodyKind': bodyKind.wire,
        if (binarySource != DebugBinarySource.raw)
          'binarySource': binarySource.wire,
        if (binaryFilePath != null) 'binaryFilePath': binaryFilePath,
        if (multipartFields.isNotEmpty)
          'multipartFields': multipartFields.map((e) => e.toJson()).toList(),
        if (auth != null) 'auth': auth!.toJson(),
        'cookies': cookies.map((e) => e.toJson()).toList(),
        if (collectionId != null) 'collectionId': collectionId,
        if (overrides != null) 'overrides': overrides!.toJson(),
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
        if (followRedirects != null) 'followRedirects': followRedirects,
        if (useCookieJar != null) 'useCookieJar': useCookieJar,
        if (skipTlsVerify != null) 'skipTlsVerify': skipTlsVerify,
      };

  factory DebugRequest.fromJson(Map<String, dynamic> json) => DebugRequest(
        id: _requireString(json, 'id'),
        name: _asString(json['name']),
        method: _asString(json['method'], fallback: 'GET'),
        url: _asString(json['url']),
        headers: _headers(json['headers']),
        query: _queries(json['query']),
        body: _asString(json['body']),
        bodyKind: DebugBodyKind.fromWire(json['bodyKind']),
        binarySource: DebugBinarySource.fromWire(json['binarySource']),
        binaryFilePath: _asStringOrNull(json['binaryFilePath']),
        multipartFields: _multipartFields(json['multipartFields']),
        auth: _auth(json['auth']),
        cookies: _cookies(json['cookies']),
        collectionId: _asStringOrNull(json['collectionId']),
        overrides: _overrides(json['overrides']),
        timeoutMs: _asIntOrNull(json['timeoutMs']),
        followRedirects: _asBoolOrNull(json['followRedirects']),
        useCookieJar: _asBoolOrNull(json['useCookieJar']),
        skipTlsVerify: _asBoolOrNull(json['skipTlsVerify']),
      );
}

/// 集合 / 文件夹（[parentId] 非空表示嵌套子文件夹）。
///
/// 支持**集合 / 文件夹级变量与鉴权**（plan todo 20）：[vars] 参与
/// `{{var}}` 作用域解析（被后代请求以「后覆盖前」继承），[auth] 作为子请求的
/// 默认鉴权（请求自身鉴权优先）。[secretVars] 标记其中哪些变量是密钥（值走
/// 安全存储，见 [DebugSecretCodec]）。
class DebugCollection {
  DebugCollection({
    required this.id,
    required this.name,
    this.parentId,
    List<DebugRequest>? requests,
    Map<String, String>? vars,
    Set<String>? secretVars,
    this.auth,
  })  : requests = requests ?? [],
        vars = vars ?? {},
        secretVars = secretVars ?? <String>{};

  final String id;
  final String name;

  /// 父集合 id（`null` = 顶层）。
  final String? parentId;

  /// 该集合下的请求（嵌套为持久化的单一真源）。
  final List<DebugRequest> requests;

  /// 集合 / 文件夹级变量（供后代请求继承）。
  final Map<String, String> vars;

  /// 集合级密钥变量名集合（其值经安全存储，store 只存引用）。
  final Set<String> secretVars;

  /// 集合级默认鉴权（子请求自身鉴权优先于本字段）。
  final DebugAuth? auth;

  /// 可空字段（[parentId] / [auth]）使用哨兵语义：缺省保留原值，**显式传
  /// `null` 清空**；其余字段缺省保留。
  DebugCollection copyWith({
    String? id,
    String? name,
    Object? parentId = _unset,
    List<DebugRequest>? requests,
    Map<String, String>? vars,
    Set<String>? secretVars,
    Object? auth = _unset,
  }) =>
      DebugCollection(
        id: id ?? this.id,
        name: name ?? this.name,
        parentId: identical(parentId, _unset)
            ? this.parentId
            : parentId as String?,
        requests: requests ?? this.requests,
        vars: vars ?? this.vars,
        secretVars: secretVars ?? this.secretVars,
        auth: identical(auth, _unset) ? this.auth : auth as DebugAuth?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (parentId != null) 'parentId': parentId,
        'requests': requests.map((e) => e.toJson()).toList(),
        if (vars.isNotEmpty) 'vars': vars,
        if (secretVars.isNotEmpty) 'secretVars': secretVars.toList(),
        if (auth != null) 'auth': auth!.toJson(),
      };

  factory DebugCollection.fromJson(Map<String, dynamic> json) =>
      DebugCollection(
        id: _requireString(json, 'id'),
        name: _asString(json['name']),
        parentId: _asStringOrNull(json['parentId']),
        requests: _requests(json['requests']),
        vars: _stringMap(json['vars']),
        secretVars: _stringSet(json['secretVars']),
        auth: _auth(json['auth']),
      );
}

/// 响应摘要（历史条目用；不保留完整大 Body）。
class DebugResponseSummary {
  const DebugResponseSummary({
    this.statusCode,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.error,
  });

  final int? statusCode;
  final int durationMs;
  final int sizeBytes;

  /// 结构化错误（连接失败 / 超时为非 null，且不抛异常）。
  final String? error;

  Map<String, dynamic> toJson() => {
        if (statusCode != null) 'statusCode': statusCode,
        'durationMs': durationMs,
        'sizeBytes': sizeBytes,
        if (error != null) 'error': error,
      };

  factory DebugResponseSummary.fromJson(Map<String, dynamic> json) =>
      DebugResponseSummary(
        statusCode: _asIntOrNull(json['statusCode']),
        durationMs: _asInt(json['durationMs']),
        sizeBytes: _asInt(json['sizeBytes']),
        error: _asStringOrNull(json['error']),
      );
}

/// 历史条目里的响应快照：**可选**、有界、可 JSON 往返、可回看。
///
/// 与完整 [DebugResponse] 不同，本模型不保留原始字节（[DebugResponse.bodyBytes]），
/// 仅保留**有界**的文本预览（超过 [maxBodyChars] 即截断并置 [truncated]）与
/// 展示所需的状态码 / 头 / Cookie / 耗时 / 真实大小 / 错误。目的是让历史可回看
/// 响应，同时避免历史文件无限膨胀。
///
/// **兼容**：旧 store 的历史没有该字段，[DebugHistoryEntry.responseSnapshot]
/// 为 `null`；本模型**不单独升版**（版本 / 迁移由后续 todo 统一负责）。
class DebugResponseSnapshot {
  const DebugResponseSnapshot({
    this.statusCode = 0,
    this.headers = const <String, List<String>>{},
    this.bodyText = '',
    this.cookies = const <DebugCookie>[],
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.error,
    this.truncated = false,
  });

  /// HTTP 状态码；失败 / 出错时为 0。
  final int statusCode;

  /// 归一化响应头（键小写；多值头为列表）。
  final Map<String, List<String>> headers;

  /// 有界文本预览（UTF-8，允许畸形字节）。
  final String bodyText;

  /// 响应携带的 Set-Cookie 解析结果（视图）。
  final List<DebugCookie> cookies;

  /// 端到端耗时（毫秒）。
  final int durationMs;

  /// 真实响应体字节数（截断前；截断不影响此值）。
  final int sizeBytes;

  /// 结构化错误（连接失败 / 超时为非 null）。
  final String? error;

  /// 是否因超过 [maxBodyChars] 而截断了 [bodyText]。
  final bool truncated;

  /// Body 文本快照上限（字符）：超出即截断并置 [truncated]。
  static const int maxBodyChars = 100000;

  Map<String, dynamic> toJson() => {
        'statusCode': statusCode,
        if (headers.isNotEmpty)
          'headers': headers.map(
            (key, values) => MapEntry(key, List<String>.of(values)),
          ),
        if (bodyText.isNotEmpty) 'bodyText': bodyText,
        if (cookies.isNotEmpty)
          'cookies': cookies.map((e) => e.toJson()).toList(),
        'durationMs': durationMs,
        'sizeBytes': sizeBytes,
        if (error != null) 'error': error,
        if (truncated) 'truncated': truncated,
      };

  factory DebugResponseSnapshot.fromJson(Map<String, dynamic> json) =>
      DebugResponseSnapshot(
        statusCode: _asInt(json['statusCode']),
        headers: _stringListMap(json['headers']),
        bodyText: _asString(json['bodyText']),
        cookies: _cookies(json['cookies']),
        durationMs: _asInt(json['durationMs']),
        sizeBytes: _asInt(json['sizeBytes']),
        error: _asStringOrNull(json['error']),
        truncated: _asBool(json['truncated'], fallback: false),
      );
}

/// 历史条目（一次发送的请求 + 响应摘要 + 可选响应快照，最新在前）。
class DebugHistoryEntry {
  DebugHistoryEntry({
    required this.id,
    required this.tsMs,
    required this.request,
    required this.responseSummary,
    this.responseSnapshot,
  });

  final String id;
  final int tsMs;
  final DebugRequest request;
  final DebugResponseSummary responseSummary;

  /// 可选响应快照（旧数据 / 未记录时为 `null`）。
  final DebugResponseSnapshot? responseSnapshot;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tsMs': tsMs,
        'request': request.toJson(),
        'responseSummary': responseSummary.toJson(),
        if (responseSnapshot != null)
          'responseSnapshot': responseSnapshot!.toJson(),
      };

  factory DebugHistoryEntry.fromJson(Map<String, dynamic> json) {
    final request = json['request'];
    if (request is! Map) {
      throw const FormatException('DebugHistoryEntry.request 缺失');
    }
    return DebugHistoryEntry(
      id: _requireString(json, 'id'),
      tsMs: _requireInt(json, 'tsMs'),
      request: DebugRequest.fromJson(request.cast<String, dynamic>()),
      responseSummary: _summary(json['responseSummary']),
      responseSnapshot: _responseSnapshot(json['responseSnapshot']),
    );
  }
}

/// 环境（键值变量，供 `{{var}}` 替换）。
///
/// [secretVars] 标记哪些变量名为**密钥**（值走安全存储，见 todo 9）：这些键
/// 的值不落明文于 store 文件，仅存引用。未标记的变量按普通明文持久化。
/// 该字段可选，缺省为空集合（旧数据 / 无密钥用户安全降级）。
class DebugEnvironment {
  DebugEnvironment({
    required this.id,
    required this.name,
    Map<String, String>? vars,
    Set<String>? secretVars,
  })  : vars = vars ?? {},
        secretVars = secretVars ?? <String>{};

  final String id;
  final String name;
  final Map<String, String> vars;

  /// 密钥变量名集合（其值经安全存储，store 只存引用）。
  final Set<String> secretVars;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'vars': vars,
        if (secretVars.isNotEmpty) 'secretVars': secretVars.toList(),
      };

  factory DebugEnvironment.fromJson(Map<String, dynamic> json) =>
      DebugEnvironment(
        id: _requireString(json, 'id'),
        name: _asString(json['name']),
        vars: _stringMap(json['vars']),
        secretVars: _stringSet(json['secretVars']),
      );
}

/// 改写规则（镜像 Rust `CaptureRule` 的 UI 视图；默认关闭）。
///
/// 注意：规则是**全局引擎能力**（非单请求私有），且仅作用于 h1/h2
/// 请求；WS 帧仅捕获不改写（UI 需明确标注）。
class DebugRewriteRule {
  const DebugRewriteRule({
    required this.id,
    this.enabled = false,
    this.method,
    required this.url,
    required this.kind,
    this.remark,
    this.statusCode,
    this.respHeaders,
    this.respBody,
    this.delayMs = 0,
    this.hitCount = 0,
  });

  final String id;
  final bool enabled;

  /// 精确匹配的方法（`null` = 不限方法）。
  final String? method;

  /// 精确匹配的 URL。
  final String url;
  final DebugRewriteKind kind;
  final String? remark;
  final int? statusCode;
  final List<DebugHeader>? respHeaders;
  final String? respBody;

  /// 命中后注入的延迟毫秒（`0` = 不延迟）。镜像 Rust `CaptureRule.delayMs`；
  /// 本波仅存储 / 展示，MITM 注入尚未实现。
  final int delayMs;
  final int hitCount;

  DebugRewriteRule copyWith({
    String? id,
    bool? enabled,
    String? method,
    String? url,
    DebugRewriteKind? kind,
    String? remark,
    int? statusCode,
    List<DebugHeader>? respHeaders,
    String? respBody,
    int? delayMs,
    int? hitCount,
  }) =>
      DebugRewriteRule(
        id: id ?? this.id,
        enabled: enabled ?? this.enabled,
        method: method ?? this.method,
        url: url ?? this.url,
        kind: kind ?? this.kind,
        remark: remark ?? this.remark,
        statusCode: statusCode ?? this.statusCode,
        respHeaders: respHeaders ?? this.respHeaders,
        respBody: respBody ?? this.respBody,
        delayMs: delayMs ?? this.delayMs,
        hitCount: hitCount ?? this.hitCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'enabled': enabled,
        if (method != null) 'method': method,
        'url': url,
        'kind': kind.wire,
        if (remark != null) 'remark': remark,
        if (statusCode != null) 'statusCode': statusCode,
        if (respHeaders != null)
          'respHeaders': respHeaders!.map((e) => e.toJson()).toList(),
        if (respBody != null) 'respBody': respBody,
        if (delayMs != 0) 'delayMs': delayMs,
        'hitCount': hitCount,
      };

  factory DebugRewriteRule.fromJson(Map<String, dynamic> json) =>
      DebugRewriteRule(
        id: _requireString(json, 'id'),
        enabled: _asBool(json['enabled'], fallback: false),
        method: _asStringOrNull(json['method']),
        url: _asString(json['url']),
        kind: DebugRewriteKind.fromWire(json['kind']),
        remark: _asStringOrNull(json['remark']),
        statusCode: _asIntOrNull(json['statusCode']),
        respHeaders: _headersOrNull(json['respHeaders']),
        respBody: _asStringOrNull(json['respBody']),
        delayMs: _asInt(json['delayMs']),
        hitCount: _asInt(json['hitCount']),
      );
}

// ==================== 解析辅助（私有） ====================

String _asString(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _asStringOrNull(Object? value) {
  if (value == null) return null;
  return value is String ? value : value.toString();
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _asBool(Object? value, {required bool fallback}) =>
    value is bool ? value : fallback;

/// 容忍解码：非 bool（含缺失 / 类型错误）→ `null`（由调用方取默认）。
bool? _asBoolOrNull(Object? value) => value is bool ? value : null;

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('缺少必填字段 "$key"');
}

int _requireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('缺少必填字段 "$key"');
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return {};
  return value.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
}

/// 容忍解码字符串集合：非 List → 空；元素非字符串 → 跳过。
Set<String> _stringSet(Object? value) {
  if (value is! List) return <String>{};
  return value.whereType<String>().toSet();
}

/// 容忍解码多值头映射：非 Map → 空；值非 List → 单元素列表。
Map<String, List<String>> _stringListMap(Object? value) {
  if (value is! Map) return {};
  final out = <String, List<String>>{};
  value.forEach((k, v) {
    if (v is List) {
      out[k.toString()] = v.map((e) => e?.toString() ?? '').toList();
    } else if (v != null) {
      out[k.toString()] = <String>[v.toString()];
    }
  });
  return out;
}

/// 容忍解码历史响应快照：非对象 / 损坏 → `null`（不牵连条目主体）。
DebugResponseSnapshot? _responseSnapshot(Object? value) {
  if (value is! Map) return null;
  try {
    return DebugResponseSnapshot.fromJson(value.cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}

/// 逐项容错解析：跳过非对象与单个解析失败（损坏）的条目。
///
/// 关键：一个损坏的嵌套条目（如集合内某个请求缺 `id`）**绝不牵连**同类其余
/// 条目或外层集合——坏条目被隔离，其余照常加载（todo 10）。
List<T> _tolerantList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parse,
) {
  if (value is! List) return <T>[];
  final out = <T>[];
  for (final item in value) {
    if (item is! Map) continue;
    try {
      out.add(parse(item.cast<String, dynamic>()));
    } catch (_) {
      // 单个损坏条目被隔离。
    }
  }
  return out;
}

List<DebugHeader> _headers(Object? value) =>
    _tolerantList(value, DebugHeader.fromJson);

List<DebugHeader>? _headersOrNull(Object? value) {
  if (value is! List) return null;
  return _headers(value);
}

List<DebugQueryParam> _queries(Object? value) =>
    _tolerantList(value, DebugQueryParam.fromJson);

List<DebugCookie> _cookies(Object? value) =>
    _tolerantList(value, DebugCookie.fromJson);

List<DebugMultipartField> _multipartFields(Object? value) =>
    _tolerantList(value, DebugMultipartField.fromJson);

List<DebugRequest> _requests(Object? value) =>
    _tolerantList(value, DebugRequest.fromJson);

DebugAuth? _auth(Object? value) =>
    value is Map ? DebugAuth.fromJson(value.cast<String, dynamic>()) : null;

DebugResponseOverride? _overrides(Object? value) => value is Map
    ? DebugResponseOverride.fromJson(value.cast<String, dynamic>())
    : null;

DebugResponseSummary _summary(Object? value) => value is Map
    ? DebugResponseSummary.fromJson(value.cast<String, dynamic>())
    : const DebugResponseSummary();
