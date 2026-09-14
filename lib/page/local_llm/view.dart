import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/llm/local_llm_service.dart';
import 'package:gstore/core/logger/LogManager.dart';

/// 本地大模型（GGUF / llama.cpp）配置页：
/// 模型下载 / 列表 / 加载 / 卸载 / 参数 / 本地 OpenAI 兼容端点。
class LocalLlmPage extends StatefulWidget {
  const LocalLlmPage({super.key});

  @override
  State<LocalLlmPage> createState() => _LocalLlmPageState();
}

/// 推荐模型预设（ModelScope 国内可直连；下载前请确认 URL 与文件名）
///
/// ModelScope 直链格式：`.../models/<org>/<repo>/resolve/master/<file>`
/// 若你更习惯 HuggingFace 镜像，可把 `www.modelscope.cn/models/<org>/<repo>/resolve/master/`
/// 换成 `hf-mirror.com/<org>/<repo>/resolve/main/`（文件同名）。
const _presets = <({String name, String url, int sizeBytes, String quant})>[
  (
    name: 'Qwen2.5-0.5B-Instruct Q4_K_M（推荐入门）',
    url: 'https://www.modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sizeBytes: 491400032,
    quant: 'Q4_K_M',
  ),
  (
    name: 'Qwen2.5-1.5B-Instruct Q4_K_M（中文更好）',
    url: 'https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1117320736,
    quant: 'Q4_K_M',
  ),
  (
    name: 'Qwen2.5-1.5B-Instruct Q2_K（更省内存）',
    url: 'https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q2_k.gguf',
    sizeBytes: 752880160,
    quant: 'Q2_K',
  ),
];

class _LocalLlmPageState extends State<LocalLlmPage> {
  final _service = LocalLlmService.instance;

  bool _loading = true;
  bool _engineReady = false;
  Map<String, dynamic> _status = const {};
  List<({LocalLlmModel model, bool downloaded})> _models = const [];

  // 推理参数
  int _nCtx = 4096;
  int _nThreads = 4;
  int _nGpuLayers = 0;

  // 下载进度（模型 id -> 0..1 / 文案）
  final Map<String, double> _progress = {};
  final Map<String, StreamSubscription<DownloadTask>> _subs = {};

  String? _serverUrl;
  String? _apiKey;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    // 模块挂载/宿主初始化可能较慢，加超时避免"一直 loading"无信息
    final ready = await _service
        .engineAvailable()
        .timeout(const Duration(seconds: 30), onTimeout: () {
      appLog.error('LocalLlmPage: 引擎初始化超时（30s）');
      return false;
    });
    var status = const <String, dynamic>{};
    if (ready) {
      try {
        status = await _service.status();
      } catch (e) {
        appLog.warning('LocalLlmPage: 读取引擎状态失败 - $e');
      }
    }
    final models = await _service.listModels();
    final withFlag = <({LocalLlmModel model, bool downloaded})>[];
    for (final m in models) {
      withFlag.add((model: m, downloaded: await _service.isDownloaded(m)));
    }
    if (!mounted) return;
    setState(() {
      _engineReady = ready;
      _status = status;
      _models = withFlag;
      _serverUrl = _service.baseUrl;
      _apiKey = _service.apiKey;
      _loading = false;
    });
  }

  // --------------------------------------------------------------- 操作

  Future<void> _addModelDialog({({String name, String url, int sizeBytes, String quant})? preset}) async {
    final nameCtl = TextEditingController(text: preset?.name ?? '');
    final urlCtl = TextEditingController(text: preset?.url ?? '');
    final added = await AppDialogs.showBottomSheet<bool>(
      title: '添加模型',
      children: [
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('填写 GGUF 文件的直链地址（下载后保存在应用私有目录）。'),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: urlCtl,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'GGUF 直链 URL'),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => AppDialogs.popSheet<bool>(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () => AppDialogs.popSheet<bool>(true),
                    child: const Text('添加'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    if (added != true) return;
    final name = nameCtl.text.trim();
    final url = urlCtl.text.trim();
    if (name.isEmpty || url.isEmpty) {
      AppDialogs.showError('名称与 URL 不能为空');
      return;
    }
    final id = url.hashCode.toRadixString(16);
    await _service.addModel(
      id: id,
      name: name,
      url: url,
      sizeBytes: preset?.sizeBytes ?? 0,
      quant: preset?.quant ?? '',
    );
    await _refresh();
  }

  Future<void> _download(LocalLlmModel m) async {
    if (_progress.containsKey(m.id)) return;
    setState(() => _progress[m.id] = 0);
    try {
      final taskId = await _service.downloadModel(m);
      if (taskId == null) throw StateError('下载任务创建失败');
      final sub = _service.watchDownload(taskId).listen((t) {
        if (!mounted) return;
        final total = t.total > 0 ? t.total : m.sizeBytes;
        final ratio = total > 0 ? (t.received / total).clamp(0.0, 1.0) : 0.0;
        setState(() => _progress[m.id] = ratio);
        if (t.isCompleted) {
          _subs.remove(m.id)?.cancel();
          setState(() => _progress.remove(m.id));
          appLog.info('LocalLlmPage: ${m.name} 下载完成');
          _refresh();
        } else if (!t.isActive && t.error != null) {
          _subs.remove(m.id)?.cancel();
          setState(() => _progress.remove(m.id));
          AppDialogs.showError('下载失败: ${t.error}');
        }
      });
      _subs[m.id] = sub;
    } catch (e) {
      setState(() => _progress.remove(m.id));
      AppDialogs.showError('下载失败: $e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      AppDialogs.showError('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load(LocalLlmModel m) => _run(() async {
        await _service.loadModel(
          m.id,
          nCtx: _nCtx,
          nThreads: _nThreads,
          nGpuLayers: _nGpuLayers,
        );
        AppDialogs.showSuccess('已加载 ${m.name}');
        await _refresh();
      });

  Future<void> _unload() => _run(() async {
        await _service.unloadModel();
        await _refresh();
      });

  Future<void> _toggleServer() => _run(() async {
        if (_service.serverRunning) {
          await _service.stopServer();
        } else {
          final url = await _service.startServer();
          appLog.info('LocalLlmPage: 本地端点 $url');
        }
        await _refresh();
      });

  /// 一键把本地端点写入 AI 助手模型配置（provider=OpenAI 兼容 + 关闭工具调用）
  Future<void> _applyToAgent() => _run(() async {
        final url = _service.baseUrl;
        final key = _service.apiKey;
        if (url == null || key == null) {
          throw StateError('请先启动本地端点');
        }
        // 用当前已加载模型作为展示名/model 字段
        var modelId = 'local';
        var label = '本地模型';
        final loadedPath = _status['model_path'] as String?;
        if (loadedPath != null) {
          for (final e in _models) {
            if (await _service.modelPath(e.model) == loadedPath) {
              modelId = e.model.id;
              label = e.model.name;
              break;
            }
          }
        }
        final store = await AgentModelStore.load();
        await store.add(
          AgentModel(
            id: 'local-llm',
            name: '本地模型 · $label',
            provider: AgentLlmProvider.openai,
            apiKey: key,
            model: modelId,
            baseUrl: url,
            toolsEnabled: false, // 本地小模型 function calling 不可靠 → 降级纯问答
          ),
          select: true,
        );
        AppDialogs.showSuccess('已应用为 AI 助手当前模型（已关闭工具调用）');
      });

  // --------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('本地模型')),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: AppSpacing.md),
                  Text('正在初始化本地推理模块…'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              children: [
                _engineCard(context),
                _paramsCard(context),
                _endpointCard(context),
                _modelsCard(context),
                _presetsCard(context),
              ],
            ),
    );
  }

  Widget _card({required Widget child}) => Card(
        margin: AppSpacing.onlyHorizontalLG.add(const EdgeInsets.only(bottom: AppSpacing.md)),
        child: child,
      );

  Widget _engineCard(BuildContext context) {
    final loaded = _status['loaded'] == true;
    final busy = _status['busy'] == true;
    final available = _engineReady;
    return _card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              available ? Icons.memory : Icons.error_outline,
              color: available ? Theme.of(context).colorScheme.primary : null,
            ),
            title: const Text('推理引擎'),
            subtitle: Text(
              available
                  ? (busy
                      ? '推理中…（状态查询不会被阻塞）'
                      : (loaded
                          ? '已加载: ${_status['model_path'] ?? '-'}\n'
                              'ctx=${_status['n_ctx']} threads=${_status['n_threads']} '
                              'gpu=${_status['n_gpu_layers']} backend=${_status['backend']}'
                          : '模块就绪，未加载模型'))
                  : '模块不可用（gstore_mod_llm 未安装，仅 arm64 提供）',
            ),
            isThreeLine: available && loaded,
          ),
          if (loaded)
            Padding(
              padding: AppSpacing.onlyHorizontalLG.add(const EdgeInsets.only(bottom: AppSpacing.md)),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _unload(),
                  child: const Text('卸载模型'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _paramsCard(BuildContext context) {
    return _card(
      child: ExpansionTile(
        leading: const Icon(Icons.tune),
        title: const Text('推理参数'),
        subtitle: Text('ctx=$_nCtx  threads=$_nThreads  GPU层=$_nGpuLayers'),
        children: [
          _slider('上下文长度 (n_ctx)', _nCtx.toDouble(), 512, 16384, 512,
              (v) => setState(() => _nCtx = v.round())),
          _slider('线程数 (n_threads)', _nThreads.toDouble(), 1, 16, 1,
              (v) => setState(() => _nThreads = v.round())),
          _slider('GPU 卸载层数 (n_gpu_layers)', _nGpuLayers.toDouble(), 0, 99, 1,
              (v) => setState(() => _nGpuLayers = v.round()),
              hint: '0=纯 CPU；>0 需设备提供 OpenCL（Adreno）。'
                  '本构建后端=${_status['backend'] ?? 'cpu'}'),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, double step,
      ValueChanged<double> onChanged,
      {String? hint}) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG.add(const EdgeInsets.only(bottom: AppSpacing.sm)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text('${value.round()}'),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
          if (hint != null)
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _endpointCard(BuildContext context) {
    final running = _service.serverRunning;
    return _card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(running ? Icons.cloud_done : Icons.cloud_off),
            title: const Text('本地 OpenAI 兼容端点'),
            subtitle: Text(
              running
                  ? 'baseUrl: $_serverUrl\napiKey: ${_apiKey ?? '-'}\n'
                      '（在 AI 助手模型配置里选 OpenAI 兼容，填入以上地址与密钥）'
                  : '未启动；启动后 Agent 可选用本地模型',
            ),
            isThreeLine: running,
          ),
          Padding(
            padding: AppSpacing.onlyHorizontalLG.add(const EdgeInsets.only(bottom: AppSpacing.md)),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : () => _toggleServer(),
                        child: Text(running ? '停止端点' : '启动端点'),
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: AppSpacing.sm),
                      IconButton(
                        tooltip: '复制 baseUrl',
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: _serverUrl ?? ''));
                          AppDialogs.showSuccess('已复制 baseUrl');
                        },
                      ),
                    ],
                  ],
                ),
                if (running) ...[
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _applyToAgent(),
                      icon: const Icon(Icons.smart_toy_outlined),
                      label: const Text('应用到 AI 助手（关闭工具调用）'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelsCard(BuildContext context) {
    return _card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.list_alt),
            title: Text('已添加模型'),
          ),
          if (_models.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: Text('暂无模型，点击下方推荐或手动添加'),
            ),
          for (final entry in _models) _modelTile(context, entry),
        ],
      ),
    );
  }

  Widget _modelTile(BuildContext context, ({LocalLlmModel model, bool downloaded}) entry) {
    final m = entry.model;
    final progress = _progress[m.id];
    final sizeText = m.sizeBytes > 0
        ? '${(m.sizeBytes / 1024 / 1024).round()} MB'
        : '';
    final loadedPath = _status['model_path'] as String?;
    final isLoaded = _status['loaded'] == true && loadedPath != null && loadedPath.contains(m.id);

    return Column(
      children: [
        ListTile(
          leading: Icon(entry.downloaded ? Icons.check_circle : Icons.download_for_offline_outlined),
          title: Text(m.name),
          subtitle: Text([
            if (m.quant.isNotEmpty) m.quant,
            if (sizeText.isNotEmpty) sizeText,
            entry.downloaded ? '已下载' : '未下载',
          ].join(' · ')),
          trailing: entry.downloaded
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLoaded)
                      const Icon(Icons.play_circle, color: Colors.green)
                    else
                      IconButton(
                        tooltip: '加载',
                        icon: const Icon(Icons.play_arrow),
                        onPressed: _busy ? null : () => _load(m),
                      ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _busy
                          ? null
                          : () async {
                              await _service.deleteModel(m.id);
                              await _refresh();
                            },
                    ),
                  ],
                )
              : (progress != null
                  ? SizedBox(
                      width: 64,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 4),
                          Text('${(progress * 100).round()}%',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    )
                  : IconButton(
                      tooltip: '下载',
                      icon: const Icon(Icons.download),
                      onPressed: _busy ? null : () => _download(m),
                    )),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _presetsCard(BuildContext context) {
    return _card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.auto_awesome),
            title: Text('推荐模型'),
            subtitle: Text('一键预填（下载前请确认 URL 与文件名）'),
          ),
          for (final p in _presets)
            ListTile(
              title: Text(p.name),
              subtitle: Text('${p.quant} · ${(p.sizeBytes / 1024 / 1024).round()} MB'),
              trailing: const Icon(Icons.add),
              onTap: _busy ? null : () => _addModelDialog(preset: p),
            ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('手动添加模型（URL）'),
            onTap: _busy ? null : () => _addModelDialog(),
          ),
        ],
      ),
    );
  }
}
