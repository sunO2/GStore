import 'dart:convert';
import 'dart:typed_data';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 本地推理引擎 `gstore_mod_llm`（llama.cpp / GGUF）的 Dart 侧薄封装。
///
/// 职责边界：**只负责模块挂载、实例创建与 JSON 往返**；
/// 模型文件管理、下载、对外 OpenAI 兼容端点由 `LocalLlmService` 负责。
/// 生成在模块内同步完成（宿主 ABI 同步语义），因此调用会阻塞当前 FRB worker。
class LocalLlmEngine {
  LocalLlmEngine._();

  static final LocalLlmEngine instance = LocalLlmEngine._();

  RustModuleInstance? _instance;
  bool _tried = false;
  bool _available = false;

  /// 模块是否可用（首次 [ensureReady] 之后有效）
  bool get available => _available;

  /// 是否已加载模型（本地缓存，[status] 为准）
  bool get hasModule => _instance != null;

  /// 挂载模块并创建实例（幂等）
  Future<bool> ensureReady() async {
    if (_instance != null) return true;
    if (_tried) return false;
    _tried = true;
    try {
      final ok = await RustModuleLoader.instance.ensureModule('llm');
      if (!ok) {
        appLog.warning('LocalLlmEngine: 未找到 gstore_mod_llm（内置/本地/远程均不可用）');
        return false;
      }
      final ModuleHandle handle = await RustModuleManager.instance.loadModule('llm');
      final inst = await RustModuleInstance.create('llm', handle);
      _instance = inst;
      _available = true;
      appLog.info('LocalLlmEngine: 模块就绪');
      return true;
    } catch (e) {
      appLog.error('LocalLlmEngine: 模块初始化失败 - $e');
      _available = false;
      return false;
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> body,
  ) async {
    if (!await ensureReady()) {
      throw StateError('本地推理模块不可用（gstore_mod_llm 未安装或加载失败）');
    }
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final sw = Stopwatch()..start();
    appLog.info('LocalLlmEngine: → $method');
    try {
      final bytes = await _instance!.callModule(method, payload);
      sw.stop();
      appLog.info('LocalLlmEngine: ← $method (${sw.elapsedMilliseconds}ms)');
      if (bytes.isEmpty) return const <String, dynamic>{};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'value': decoded};
    } catch (e) {
      sw.stop();
      appLog.error('LocalLlmEngine: ✗ $method (${sw.elapsedMilliseconds}ms) - $e');
      rethrow;
    }
  }

  /// 引擎信息（是否编译了 llama.cpp、当前是否已加载模型等）
  Future<Map<String, dynamic>> capabilities() => _call('capabilities', const {});

  /// 当前状态：{loaded, model_path, n_ctx, n_threads, n_gpu_layers, backend}
  Future<Map<String, dynamic>> status() => _call('status', const {});

  /// 加载模型（path 为 GGUF 绝对路径）
  Future<Map<String, dynamic>> loadModel({
    required String path,
    int? nCtx,
    int? nThreads,
    int? nGpuLayers,
    int? nBatch,
  }) =>
      _call('load_model', <String, dynamic>{
        'path': path,
        if (nCtx != null) 'n_ctx': nCtx,
        if (nThreads != null) 'n_threads': nThreads,
        if (nGpuLayers != null) 'n_gpu_layers': nGpuLayers,
        if (nBatch != null) 'n_batch': nBatch,
      });

  /// 卸载模型（幂等）
  Future<Map<String, dynamic>> unloadModel() => _call('unload_model', const {});

  /// 对话补全：messages = [{role, content}]，返回 {text, tokens, ms, tokens_per_sec, backend}
  Future<Map<String, dynamic>> chat(
    List<Map<String, String>> messages, {
    int? maxTokens,
    double? temperature,
    double? topP,
    int? topK,
    List<String>? stop,
    String? streamId,
    String? grammar,
    String? grammarTrigger,
  }) =>
      _call('chat', <String, dynamic>{
        'messages': messages,
        if (streamId != null) 'stream_id': streamId,
        if (grammar != null) 'grammar': grammar,
        if (grammarTrigger != null) 'grammar_trigger': grammarTrigger,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (stop != null) 'stop': stop,
      });
}
