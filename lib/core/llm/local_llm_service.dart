import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';

import 'local_llm_engine.dart';

/// 本地模型条目（GGUF）
class LocalLlmModel {
  final String id;
  final String name;
  final String url;
  final String fileName;
  final int sizeBytes;
  final String quant;
  final double paramsB;
  final int installedAt;

  const LocalLlmModel({
    required this.id,
    required this.name,
    required this.url,
    required this.fileName,
    required this.sizeBytes,
    required this.quant,
    required this.paramsB,
    required this.installedAt,
  });

  factory LocalLlmModel.fromJson(Map<String, dynamic> j) => LocalLlmModel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        fileName: j['fileName'] as String? ?? '',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        quant: j['quant'] as String? ?? '',
        paramsB: (j['paramsB'] as num?)?.toDouble() ?? 0,
        installedAt: (j['installedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'quant': quant,
        'paramsB': paramsB,
        'installedAt': installedAt,
      };
}

/// 本地推理服务：模型文件管理（下载走 Flutter DownloadManager）+ 加载/对话 +
/// 面向 Agent 的 **本地 OpenAI 兼容端点**（loopback）。
///
/// 为何把 HTTP 端点放在 Dart 而不是模块内：dlopen 的 .so 里 spawn 线程在 Android
/// 会 SIGSEGV（见 gstore_mod_repo 约束），故模块只做同步推理，端点由 Dart 代理。
class LocalLlmService {
  LocalLlmService._();

  static final LocalLlmService instance = LocalLlmService._();

  final LocalLlmEngine _engine = LocalLlmEngine.instance;

  Directory? _dir;
  final Map<String, LocalLlmModel> _models = {};
  bool _indexed = false;

  HttpServer? _server;
  String? _token;
  int _serverPort = 0;

  final Random _rand = Random.secure();

  // ---------------------------------------------------------------- 目录/索引

  Future<Directory> _modelsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'gstore_models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<File> _indexFile() async => File(p.join((await _modelsDir()).path, 'models.json'));

  Future<void> _ensureIndex() async {
    if (_indexed) return;
    _indexed = true;
    try {
      final f = await _indexFile();
      if (f.existsSync()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map<String, dynamic>) {
              final m = LocalLlmModel.fromJson(e);
              if (m.id.isNotEmpty) _models[m.id] = m;
            }
          }
        }
      }
    } catch (e) {
      appLog.error('LocalLlmService: 读取模型索引失败 - $e');
    }
    await _saveIndex();
  }

  Future<void> _saveIndex() async {
    try {
      final f = await _indexFile();
      await f.writeAsString(
        jsonEncode(_models.values.map((m) => m.toJson()).toList()),
        flush: true,
      );
    } catch (e) {
      appLog.error('LocalLlmService: 保存模型索引失败 - $e');
    }
  }

  /// 模型文件路径
  Future<String> modelPath(LocalLlmModel m) async =>
      p.join((await _modelsDir()).path, m.id, m.fileName);

  // ---------------------------------------------------------------- 模型管理

  /// 已登记模型（含是否已下载）
  Future<List<LocalLlmModel>> listModels() async {
    await _ensureIndex();
    return _models.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 是否已下载（文件存在且非空）
  Future<bool> isDownloaded(LocalLlmModel m) async {
    final f = File(await modelPath(m));
    return f.existsSync() && f.lengthSync() > 0;
  }

  /// 登记一个模型（来自内置目录或用户手填 URL）
  Future<LocalLlmModel> addModel({
    required String id,
    required String name,
    required String url,
    String? fileName,
    int sizeBytes = 0,
    String quant = '',
    double paramsB = 0,
  }) async {
    await _ensureIndex();
    final model = LocalLlmModel(
      id: id,
      name: name,
      url: url,
      fileName: fileName ?? p.basename(Uri.parse(url).path),
      sizeBytes: sizeBytes,
      quant: quant,
      paramsB: paramsB,
      installedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _models[id] = model;
    await _saveIndex();
    return model;
  }

  /// 下载模型：复用 DownloadManager（断点续传/进度/持久化），返回任务 id。
  /// 注意：`download()` 立即返回排队任务，**完成与否必须由 [watchDownload] 判定**。
  Future<int?> downloadModel(LocalLlmModel m, {bool force = false}) async {
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) throw StateError('下载服务不可用（IDownloadService 未注册）');
    final dir = await _modelsDir();
    final savePath = p.join(dir.path, m.id, m.fileName);
    await Directory(p.dirname(savePath)).create(recursive: true);
    final task = await service.download(
      'gstore_llm',
      m.name,
      '1',
      m.url,
      m.fileName,
      downloadSize: m.sizeBytes > 0 ? m.sizeBytes : null,
      saveFileName: savePath,
      forceDownload: force,
      installAfterDownload: false, // 模型不是 APK，禁止走安装钩子
    );
    return task.id;
  }

  /// 订阅下载进度（DownloadTask 流）
  Stream<DownloadTask> watchDownload(int taskId) {
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) throw StateError('下载服务不可用（IDownloadService 未注册）');
    return service.watch(taskId);
  }

  Future<void> deleteModel(String id) async {
    await _ensureIndex();
    final m = _models[id];
    try {
      final f = File(await modelPath(m!));
      if (f.existsSync()) await f.delete();
      final d = f.parent;
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (e) {
      appLog.error('LocalLlmService: 删除模型文件失败 - $e');
    }
    _models.remove(id);
    await _saveIndex();
  }

  // ---------------------------------------------------------------- 推理

  Future<bool> engineAvailable() => _engine.ensureReady();

  Future<Map<String, dynamic>> capabilities() => _engine.capabilities();

  /// 加载模型到内存
  Future<Map<String, dynamic>> loadModel(
    String id, {
    int nCtx = 4096,
    int? nThreads,
    int nGpuLayers = 0,
  }) async {
    await _ensureIndex();
    final m = _models[id];
    if (m == null) throw StateError('未知模型: $id');
    final path = await modelPath(m);
    if (!File(path).existsSync()) throw StateError('模型未下载: ${m.name}');
    return _engine.loadModel(
      path: path,
      nCtx: nCtx,
      nThreads: nThreads,
      nGpuLayers: nGpuLayers,
    );
  }

  Future<Map<String, dynamic>> unloadModel() => _engine.unloadModel();

  Future<Map<String, dynamic>> status() => _engine.status();

  /// 直接对话（不经本地端点）
  Future<Map<String, dynamic>> chat(
    List<Map<String, String>> messages, {
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.95,
    int topK = 40,
    List<String>? stop,
    String? streamId,
    String? grammar,
    String? grammarTrigger,
  }) =>
      _engine.chat(
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        topK: topK,
        stop: stop,
        streamId: streamId,
        grammar: grammar,
        grammarTrigger: grammarTrigger,
      );

  // ------------------------------------------------- 本地 OpenAI 兼容端点

  /// 本地端点 baseUrl（未启动为 null）。可直接填入 Agent 模型配置。
  String? get baseUrl => _server == null ? null : 'http://127.0.0.1:$_serverPort/v1';

  /// 本地端点 apiKey（Bearer token；防止同机其它 App 调用本机模型）
  String? get apiKey => _token;

  bool get serverRunning => _server != null;

  /// 默认固定端口：保证 baseUrl 跨启动稳定
  /// （随机端口会让已写入 AI 助手的配置失效）
  static const int defaultPort = 18321;

  /// 启动 loopback OpenAI 兼容端点：GET /v1/models、POST /v1/chat/completions。
  Future<String> startServer({int port = defaultPort}) async {
    if (_server != null) return baseUrl!;
    _token = await _loadOrCreateToken();
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: false);
    } on SocketException catch (e) {
      // 固定端口被占用 → 退化为随机端口（此时需重新「应用到 AI 助手」）
      appLog.warning('LocalLlmService: 端口 $port 被占用，改用随机端口 - $e');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    }
    _server = server;
    _serverPort = server.port;
    appLog.info('LocalLlmService: 本地端点已启动 http://127.0.0.1:$_serverPort/v1');
    unawaited(_serve(server));
    return baseUrl!;
  }

  /// token 持久化：**跨启动保持不变**——否则每次重启端点都会换密钥，
  /// 已写入 AI 助手的那份配置会直接 401。首次生成后落盘复用。
  Future<String> _loadOrCreateToken() async {
    final f = File(p.join((await _modelsDir()).path, '.local_llm_token'));
    try {
      if (f.existsSync()) {
        final t = (await f.readAsString()).trim();
        if (t.isNotEmpty) return t;
      }
    } catch (e) {
      appLog.warning('LocalLlmService: 读取本地端点 token 失败 - $e');
    }
    final t = _randomToken();
    try {
      await f.writeAsString(t, flush: true);
    } catch (e) {
      appLog.warning('LocalLlmService: 保存本地端点 token 失败 - $e');
    }
    return t;
  }

  Future<void> stopServer() async {
    final s = _server;
    _server = null;
    if (s != null) {
      await s.close(force: true);
      appLog.info('LocalLlmService: 本地端点已停止');
    }
  }

  String _randomToken() {
    final bytes = List<int>.generate(24, (_) => _rand.nextInt(256));
    return base64UrlEncode(bytes);
  }

  bool _authorized(HttpRequest req) {
    final auth = req.headers.value('authorization') ?? '';
    return _token != null && auth == 'Bearer $_token';
  }

  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      try {
        await _handle(req);
      } catch (e) {
        appLog.error('LocalLlmService: 处理请求失败 - $e');
        try {
          req.response.statusCode = 500;
          req.response.write(jsonEncode({'error': {'message': '$e'}}));
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    appLog.info('LocalLlmService: ${req.method} ${req.uri.path}');
    if (!_authorized(req)) {
      appLog.warning('LocalLlmService: 鉴权失败 → 401');
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.write(jsonEncode({'error': {'message': 'invalid api key'}}));
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    if (req.method == 'GET' && (path == '/v1/models' || path == '/models')) {
      final models = await listModels();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'object': 'list',
        'data': [
          for (final m in models)
            {'id': m.id, 'object': 'model', 'owned_by': 'local-gstore'},
        ],
      }));
      await req.response.close();
      return;
    }

    if (req.method == 'POST' && path == '/v1/chat/completions') {
      final body = await utf8.decoder.bind(req).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      await _chatCompletion(req, json);
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    req.response.write(jsonEncode({'error': {'message': 'not found'}}));
    await req.response.close();
  }

  /// 工具调用 JSON 的 GBNF（懒触发：仅当模型输出 `<tool_call>` 后才强制合法 JSON）
  static const String _toolCallGrammar = r'''
root ::= "{" ws "\"name\"" ws ":" ws string ws "," ws "\"arguments\"" ws ":" ws value ws "}"
string ::= "\"" char* "\""
char ::= [^"\\] | "\\" ["\\/bfnrt]
value ::= object | array | string | number | "true" | "false" | "null"
object ::= "{" ws ( string ws ":" ws value ( ws "," ws string ws ":" ws value )* )? ws "}"
array ::= "[" ws ( value ( ws "," ws value )* )? ws "]"
number ::= "-"? [0-9]+ ( "." [0-9]+ )? ( [eE] [+-]? [0-9]+ )?
ws ::= [ \t\n\r]*
''';

  /// 工具说明 + 输出契约（本地模型无原生 tools 模板，用提示 + 懒语法约束替代）
  String _toolSystemPrompt(List<dynamic> tools) {
    final specs = <Map<String, dynamic>>[];
    for (final t in tools) {
      if (t is Map && t['function'] is Map) {
        final f = t['function'] as Map;
        specs.add({
          'name': f['name'],
          'description': f['description'],
          'parameters': f['parameters'],
        });
      }
    }
    return '你可以调用下列工具（JSON Schema）：\n${jsonEncode(specs)}\n\n'
        '规则：\n'
        '- 需要执行操作时，只输出一行：'
        '<tool_call>{"name":"工具名","arguments":{参数}}</tool_call>\n'
        '- arguments 必须符合该工具 parameters 的 JSON Schema。\n'
        '- 不需要工具时，直接用自然语言回答，且不要出现 <tool_call>。';
  }

  /// 从模型输出解析工具调用（容错：取第一个 <tool_call>{...}</tool_call>）
  ({String name, Map<String, dynamic> args})? _parseToolCall(String text) {
    final m =
        RegExp(r'<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>').firstMatch(text);
    if (m == null) return null;
    try {
      final obj = jsonDecode(m.group(1)!) as Map<String, dynamic>;
      final name = (obj['name'] ?? '').toString();
      if (name.isEmpty) return null;
      var args = obj['arguments'];
      if (args is String) {
        try {
          args = jsonDecode(args);
        } catch (_) {}
      }
      return (
        name: name,
        args: args is Map
            ? Map<String, dynamic>.from(args)
            : <String, dynamic>{},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _chatCompletion(HttpRequest req, Map<String, dynamic> json) async {
    final rawMessages = (json['messages'] as List?) ?? const [];
    final rawTools = (json['tools'] as List?) ?? const [];
    final toolsPresent = rawTools.isNotEmpty;

    // 消息转换：tool 结果回灌为文本；assistant 的 tool_calls 还原为 <tool_call> 文本
    final messages = <Map<String, String>>[];
    for (final m in rawMessages) {
      if (m is! Map) continue;
      final role = (m['role'] ?? 'user').toString();
      final content = (m['content'] ?? '').toString();
      if (role == 'tool') {
        final name = (m['name'] ?? '').toString();
        messages.add({
          'role': 'user',
          'content': '工具${name.isEmpty ? '' : ' $name'} 的执行结果：$content',
        });
        continue;
      }
      final toolCalls = m['tool_calls'];
      if (role == 'assistant' && toolCalls is List && toolCalls.isNotEmpty) {
        final buf = StringBuffer();
        for (final tc in toolCalls) {
          final fn = (tc is Map) ? tc['function'] : null;
          if (fn is Map) {
            buf.write('<tool_call>${jsonEncode({
                  'name': fn['name'],
                  'arguments': fn['arguments'],
                })}</tool_call>');
          }
        }
        if (content.isNotEmpty) buf.write(content);
        messages.add({'role': 'assistant', 'content': buf.toString()});
        continue;
      }
      messages.add({'role': role, 'content': content});
    }
    if (toolsPresent) {
      messages.insert(0, {'role': 'system', 'content': _toolSystemPrompt(rawTools)});
    }

    final maxTokens = (json['max_tokens'] as num?)?.toInt() ?? 512;
    final temperature = (json['temperature'] as num?)?.toDouble() ?? 0.7;
    final topP = (json['top_p'] as num?)?.toDouble() ?? 0.95;
    final stream = json['stream'] == true;
    final modelName = (json['model'] ?? 'local').toString();
    final id = 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    appLog.info(
        'LocalLlmService: 请求 stream=$stream model=$modelName messages=${messages.length} '
        'tools=${rawTools.length} max_tokens=$maxTokens');

    Map<String, dynamic> toolCallsJson(
            ({String name, Map<String, dynamic> args}) p) =>
        {
          'id': 'call_${DateTime.now().microsecondsSinceEpoch}',
          'type': 'function',
          'function': {'name': p.name, 'arguments': jsonEncode(p.args)},
        };

    // ---------------- 非流式 ----------------
    if (!stream) {
      final result = await chat(messages,
          maxTokens: maxTokens,
          temperature: temperature,
          topP: topP,
          grammar: toolsPresent ? _toolCallGrammar : null,
          grammarTrigger: toolsPresent ? '<tool_call>' : null);
      final raw = (result['text'] ?? '').toString();
      final parsed = toolsPresent ? _parseToolCall(raw) : null;
      final text = parsed == null ? raw : '';
      final tokens = (result['tokens'] as num?)?.toInt() ?? 0;
      appLog.info('LocalLlmService: 生成完成 tokens=$tokens ms=${result['ms']} '
          'text_len=${raw.length} tool_call=${parsed?.name ?? '-'}');
      try {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'id': id,
          'object': 'chat.completion',
          'created': created,
          'model': modelName,
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': text.isEmpty ? null : text,
                if (parsed != null) 'tool_calls': [toolCallsJson(parsed)],
              },
              'finish_reason': parsed != null ? 'tool_calls' : 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': 0,
            'completion_tokens': tokens,
            'total_tokens': tokens,
          },
        }));
        await req.response.close();
      } catch (e) {
        appLog.warning('LocalLlmService: 回写 JSON 失败（客户端可能已断开）- $e');
      }
      return;
    }

    void writeSse(Map<String, dynamic> delta, String? finish) {
      req.response.write('data: ${jsonEncode({
            'id': id,
            'object': 'chat.completion.chunk',
            'created': created,
            'model': modelName,
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': finish}
            ],
          })}\n\n');
    }

    // ---------------- 工具轮次：SSE 单块（tool_calls 或 content） ----------------
    if (toolsPresent) {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      try {
        final result = await chat(messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            grammar: _toolCallGrammar,
            grammarTrigger: '<tool_call>');
        final raw = (result['text'] ?? '').toString();
        final parsed = _parseToolCall(raw);
        appLog.info('LocalLlmService: 工具轮次完成 text_len=${raw.length} '
            'tool_call=${parsed?.name ?? '-'}');
        if (parsed != null) {
          writeSse({'role': 'assistant', 'tool_calls': [toolCallsJson(parsed)]},
              'tool_calls');
        } else {
          writeSse({'role': 'assistant', 'content': raw}, 'stop');
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      } catch (e) {
        appLog.warning('LocalLlmService: 工具轮次回写失败 - $e');
      }
      return;
    }

    // ---------------- 普通对话：真流式 ----------------
    req.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    final streamId = 'llm_${DateTime.now().microsecondsSinceEpoch}';
    var emittedChars = 0;
    var wroteRole = false;
    StreamSubscription<dynamic>? sub;
    try {
      sub = RustModuleManager.instance.moduleEvents.listen((ev) {
        try {
          if (ev.eventType != 'llm.delta') return;
          final m = jsonDecode(utf8.decode(ev.data as List<int>))
              as Map<String, dynamic>;
          if (m['stream_id'] != streamId) return;
          final delta = (m['delta'] ?? '').toString();
          if (delta.isEmpty) return;
          emittedChars += delta.length;
          if (!wroteRole) {
            wroteRole = true;
            writeSse({'role': 'assistant', 'content': delta}, null);
          } else {
            writeSse({'content': delta}, null);
          }
          unawaited(req.response.flush());
        } catch (_) {}
      });
      appLog.info('LocalLlmService: 开始流式推理 stream_id=$streamId');
      final result = await chat(messages,
          maxTokens: maxTokens,
          temperature: temperature,
          topP: topP,
          streamId: streamId);
      final text = (result['text'] ?? '').toString();
      final tokens = (result['tokens'] as num?)?.toInt() ?? 0;
      appLog.info('LocalLlmService: 流式推理完成 tokens=$tokens ms=${result['ms']} '
          'prefill=${result['prefill_ms']}ms/${result['prefill_tokens']}tok '
          '(${(result['prefill_tps'] as num?)?.toStringAsFixed(1)} tok/s) '
          'decode=${result['decode_ms']}ms/${result['decode_tokens']}tok '
          '(${(result['decode_tps'] as num?)?.toStringAsFixed(1)} tok/s) '
          '已推送=$emittedChars 字');
      if (emittedChars == 0 && text.isNotEmpty) {
        writeSse({'role': 'assistant', 'content': text}, null);
      }
      writeSse(const {}, 'stop');
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    } catch (e) {
      appLog.warning('LocalLlmService: 流式回写失败（客户端可能已断开）- $e');
    } finally {
      await sub?.cancel();
    }
  }
}
