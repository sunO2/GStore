// LLM 引擎封装：把 llama.cpp（GGUF）包成「加载/卸载/生成/对话」四个动作。
//
// 并发设计（重要）：
// - **两把锁**：`engine` 保护模型句柄（推理/加载/卸载，天然独占）；
//   `meta` 只存状态元数据，`status` 只读 meta → **推理进行中查询状态不会被阻塞**。
//   早期把两者放在同一把 Mutex 里，导致"推理中打开状态页一直 loading"，此处修正。
// - 生成在本调用线程内同步完成（宿主 ABI 同步语义），不起线程。
// - 锁序固定：先 engine 再 meta（meta 只短暂持有），避免死锁。

use std::sync::Mutex;

use serde_json::{json, Value};

#[cfg(feature = "llama")]
mod llama_impl;

/// 模型加载参数（JSON 载荷解析而来）
#[derive(Clone, Debug)]
pub struct LoadParams {
    pub path: String,
    pub n_ctx: u32,
    pub n_threads: u32,
    pub n_gpu_layers: u32,
    pub n_batch: u32,
}

impl LoadParams {
    pub fn from_json(v: &Value) -> Result<Self, String> {
        let path = v
            .get("path")
            .and_then(|p| p.as_str())
            .ok_or("missing 'path'")?
            .to_string();
        let get_u32 = |k: &str, d: u32| -> u32 {
            v.get(k).and_then(|x| x.as_u64()).map(|x| x as u32).unwrap_or(d)
        };
        Ok(Self {
            path,
            n_ctx: get_u32("n_ctx", 4096),
            n_threads: get_u32("n_threads", default_threads()),
            n_gpu_layers: get_u32("n_gpu_layers", 0),
            n_batch: get_u32("n_batch", 512),
        })
    }
}

/// 默认线程数：可用并行度的一半（留出 UI/解码线程）
fn default_threads() -> u32 {
    let n = std::thread::available_parallelism().map(|v| v.get()).unwrap_or(4);
    (n / 2).max(1) as u32
}

/// 生成参数
#[derive(Clone, Debug)]
pub struct GenParams {
    pub max_tokens: i32,
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: i32,
    pub stop: Vec<String>,
    /// 非空时按 token 流式推送 delta 事件（宿主 → Dart → SSE）
    pub stream_id: Option<String>,
    /// 可选 GBNF 语法（工具调用时用；懒触发，未命中触发词不约束）
    pub grammar: Option<String>,
    /// 懒语法触发词（默认 "<tool_call>"）
    pub grammar_trigger: Option<String>,
}

impl Default for GenParams {
    fn default() -> Self {
        Self {
            max_tokens: 512,
            temperature: 0.7,
            top_p: 0.95,
            top_k: 40,
            stop: Vec::new(),
            stream_id: None,
            grammar: None,
            grammar_trigger: None,
        }
    }
}

impl GenParams {
    pub fn from_json(v: &Value) -> Self {
        let mut p = Self::default();
        if let Some(x) = v.get("max_tokens").and_then(|x| x.as_i64()) {
            p.max_tokens = x as i32;
        }
        if let Some(x) = v.get("temperature").and_then(|x| x.as_f64()) {
            p.temperature = x as f32;
        }
        if let Some(x) = v.get("top_p").and_then(|x| x.as_f64()) {
            p.top_p = x as f32;
        }
        if let Some(x) = v.get("top_k").and_then(|x| x.as_i64()) {
            p.top_k = x as i32;
        }
        if let Some(g) = v.get("grammar").and_then(|x| x.as_str()) {
            if !g.is_empty() {
                p.grammar = Some(g.to_string());
            }
        }
        if let Some(t) = v.get("grammar_trigger").and_then(|x| x.as_str()) {
            if !t.is_empty() {
                p.grammar_trigger = Some(t.to_string());
            }
        }
        if let Some(sid) = v.get("stream_id").and_then(|x| x.as_str()) {
            if !sid.is_empty() {
                p.stream_id = Some(sid.to_string());
            }
        }
        if let Some(arr) = v.get("stop").and_then(|x| x.as_array()) {
            p.stop = arr.iter().filter_map(|s| s.as_str().map(String::from)).collect();
        }
        p
    }
}

/// 状态元数据：`status` 只读这里（不触碰推理锁）
#[derive(Default, Clone)]
struct Meta {
    loaded: bool,
    model_path: String,
    n_ctx: u32,
    n_threads: u32,
    n_gpu_layers: u32,
    n_batch: u32,
    backend: String,
    busy: bool,
    last_error: Option<String>,
}

/// 已加载模型（按 feature 分支持有引擎）
#[cfg(feature = "llama")]
struct Loaded {
    engine: llama_impl::LlamaEngine,
}

// llama.cpp 句柄含裸指针：所有访问都在 `engine: Mutex<..>` 内串行化，据此标注 Send
// （`Mutex<T>: Sync` 需要 `T: Send`）。
#[cfg(feature = "llama")]
unsafe impl Send for Loaded {}

#[cfg(not(feature = "llama"))]
struct Loaded {
    _marker: (),
}

/// 模块实例持有的引擎状态（两把锁，见文件头说明）
pub struct EngineState {
    engine: Mutex<Option<Loaded>>,
    /// 宿主分配的实例 id（流式事件回传用）
    instance_id: std::sync::atomic::AtomicU64,
    meta: Mutex<Meta>,
}

impl Default for EngineState {
    fn default() -> Self {
        Self {
            engine: Mutex::new(None),
            instance_id: std::sync::atomic::AtomicU64::new(0),
            meta: Mutex::new(Meta { n_ctx: 4096, ..Default::default() }),
        }
    }
}

// llama.cpp 的模型/上下文句柄非 Send 标记，但所有访问都在本结构的两把锁内串行化，
// 且宿主 ABI 亦为串行调用；据此显式标注 Send（跨宿主线程共享实例表所需）。
#[cfg(feature = "llama")]
unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

/// 推理期间的 busy 标记守卫（panic 也能复位）
struct BusyGuard<'a>(&'a EngineState);

impl Drop for BusyGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut m) = self.0.meta.lock() {
            m.busy = false;
        }
    }
}

impl EngineState {
    /// 由 lib.rs 在创建实例时注入宿主分配的 id（流式事件回传用）
    pub fn set_instance_id(&self, id: u64) {
        self.instance_id
            .store(id, std::sync::atomic::Ordering::SeqCst);
    }

    fn set_busy(&self, busy: bool) {
        if let Ok(mut m) = self.meta.lock() {
            m.busy = busy;
        }
    }

    /// 加载模型（重复调用会先卸载旧模型）
    pub fn load(&self, v: &Value) -> Result<Value, String> {
        let params = LoadParams::from_json(v)?;
        crate::log_message(
            1,
            &format!(
                "llm: 开始加载模型 path={} n_ctx={} n_threads={} n_gpu_layers={} n_batch={}",
                params.path, params.n_ctx, params.n_threads, params.n_gpu_layers, params.n_batch
            ),
        );
        if !std::path::Path::new(&params.path).exists() {
            crate::log_message(3, &format!("llm: 模型文件不存在 {}", params.path));
            let msg = format!("model file not found: {}", params.path);
            if let Ok(mut m) = self.meta.lock() {
                m.last_error = Some(msg.clone());
            }
            return Err(msg);
        }

        // 独占 engine 锁（推理/加载互斥）
        let mut guard = self.engine.lock().map_err(|_| "engine lock poisoned".to_string())?;
        *guard = None; // 先卸载旧模型
        self.set_busy(false);

        #[cfg(feature = "llama")]
        {
            let started = std::time::Instant::now();
            let engine = match llama_impl::LlamaEngine::load(&params) {
                Ok(e) => e,
                Err(e) => {
                    crate::log_message(3, &format!("llm: 模型加载失败 - {e}"));
                    if let Ok(mut m) = self.meta.lock() {
                        m.loaded = false;
                        m.last_error = Some(e.clone());
                    }
                    return Err(e);
                }
            };
            let backend = engine.backend_name().to_string();
            *guard = Some(Loaded { engine });
            crate::log_message(
                1,
                &format!(
                    "llm: 模型加载完成 backend={backend} 耗时={}ms",
                    started.elapsed().as_millis()
                ),
            );
            if let Ok(mut m) = self.meta.lock() {
                m.loaded = true;
                m.model_path = params.path.clone();
                m.n_ctx = params.n_ctx;
                m.n_threads = params.n_threads;
                m.n_gpu_layers = params.n_gpu_layers;
                m.n_batch = params.n_batch;
                m.backend = backend.clone();
                m.last_error = None;
            }
            return Ok(json!({
                "ok": true,
                "model_path": params.path,
                "n_ctx": params.n_ctx,
                "n_gpu_layers": params.n_gpu_layers,
                "backend": backend,
            }));
        }

        #[cfg(not(feature = "llama"))]
        {
            let _ = params;
            Err("llm feature disabled: 该构建未编译 llama.cpp（需 --features llama）".to_string())
        }
    }

    /// 卸载模型（幂等）
    pub fn unload(&self) -> Result<Value, String> {
        let mut guard = self.engine.lock().map_err(|_| "engine lock poisoned".to_string())?;
        if guard.is_some() {
            crate::log_message(1, "llm: 卸载模型");
        }
        *guard = None; // Drop 触发 llama.cpp 资源释放
        if let Ok(mut m) = self.meta.lock() {
            m.loaded = false;
            m.model_path.clear();
            m.busy = false;
        }
        Ok(json!({ "ok": true }))
    }

    /// 运行状态：**只读 meta，不阻塞推理**
    pub fn status(&self) -> Value {
        let m = match self.meta.lock() {
            Ok(m) => m.clone(),
            Err(_) => Meta::default(),
        };
        if !m.loaded {
            return json!({ "loaded": false, "busy": m.busy, "llama": cfg!(feature = "llama"), "last_error": m.last_error });
        }
        json!({
            "loaded": m.loaded,
            "busy": m.busy,
            "model_path": m.model_path,
            "n_ctx": m.n_ctx,
            "n_threads": m.n_threads,
            "n_batch": m.n_batch,
            "n_gpu_layers": m.n_gpu_layers,
            "backend": m.backend,
        })
    }

    /// 纯文本生成（prompt 已按模型模板拼好）
    pub fn generate(&self, v: &Value) -> Result<Value, String> {
        let prompt = v.get("prompt").and_then(|p| p.as_str()).ok_or("missing 'prompt'")?;
        let params = GenParams::from_json(v);
        self.run(prompt, &params)
    }

    /// 对话生成：messages 按模型 chat 模板拼 prompt（模板缺失回退通用格式）
    pub fn chat(&self, v: &Value) -> Result<Value, String> {
        let messages = v.get("messages").and_then(|m| m.as_array()).ok_or("missing 'messages'")?;
        let params = GenParams::from_json(v);
        let prompt = {
            // engine 锁只用于拼模板（快），不跨越生成
            let guard = self.engine.lock().map_err(|_| "engine lock poisoned".to_string())?;
            self.build_prompt(guard.as_ref(), messages)?
        };
        self.run(&prompt, &params)
    }

    #[cfg(feature = "llama")]
    fn build_prompt(&self, loaded: Option<&Loaded>, messages: &[Value]) -> Result<String, String> {
        let l = loaded.ok_or("no model loaded")?;
        match llama_impl::apply_chat_template(&l.engine, messages) {
            Ok(p) => Ok(p),
            Err(e) => {
                crate::log_message(2, &format!("llm: chat 模板不可用，回退通用格式 - {e}"));
                Ok(fallback_chat_prompt(messages))
            }
        }
    }

    #[cfg(not(feature = "llama"))]
    fn build_prompt(&self, _loaded: Option<&Loaded>, messages: &[Value]) -> Result<String, String> {
        Ok(fallback_chat_prompt(messages))
    }

    #[cfg(feature = "llama")]
    fn run(&self, prompt: &str, params: &GenParams) -> Result<Value, String> {
        // 独占 engine 锁直到生成结束
        let mut guard = self.engine.lock().map_err(|_| "engine lock poisoned".to_string())?;
        let l = guard.as_mut().ok_or("no model loaded")?;
        self.set_busy(true);
        let _busy = BusyGuard(self);
        let instance_id = self
            .instance_id
            .load(std::sync::atomic::Ordering::SeqCst);
        crate::log_message(
            1,
            &format!(
                "llm: 开始推理 prompt_chars={} max_tokens={} temp={}",
                prompt.len(),
                params.max_tokens,
                params.temperature
            ),
        );
        let out = l.engine.generate(prompt, params, instance_id)?;
        crate::log_message(
            1,
            &format!(
                "llm: 推理完成 tokens={} 耗时={}ms {:.1} tok/s",
                out.get("tokens").and_then(|v| v.as_i64()).unwrap_or(0),
                out.get("ms").and_then(|v| v.as_i64()).unwrap_or(0),
                out.get("tokens_per_sec").and_then(|v| v.as_f64()).unwrap_or(0.0),
            ),
        );
        Ok(out)
    }

    #[cfg(not(feature = "llama"))]
    fn run(&self, prompt: &str, params: &GenParams) -> Result<Value, String> {
        let _ = (prompt, params);
        Err("llm feature disabled: 该构建未编译 llama.cpp（需 --features llama）".to_string())
    }
}

/// 无 chat 模板时的通用兜底格式
pub fn fallback_chat_prompt(messages: &[Value]) -> String {
    let mut out = String::new();
    for m in messages {
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("user");
        let content = m.get("content").and_then(|c| c.as_str()).unwrap_or("");
        out.push_str(&format!("{role}: {content}\n"));
    }
    out.push_str("assistant: ");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_params_defaults() {
        let p = LoadParams::from_json(&json!({"path": "/tmp/x.gguf"})).unwrap();
        assert_eq!(p.n_ctx, 4096);
        assert_eq!(p.n_gpu_layers, 0);
        assert!(p.n_threads >= 1);
    }

    #[test]
    fn gen_params_parse() {
        let p = GenParams::from_json(
            &json!({"max_tokens": 32, "temperature": 0.1, "stop": ["</s>"]}),
        );
        assert_eq!(p.max_tokens, 32);
        assert!((p.temperature - 0.1).abs() < 1e-6);
        assert_eq!(p.stop, vec!["</s>".to_string()]);
    }

    #[test]
    fn load_rejects_missing_file() {
        let st = EngineState::default();
        let err = st.load(&json!({"path": "/definitely/not/here.gguf"})).unwrap_err();
        assert!(err.contains("not found"), "got: {err}");
    }

    #[test]
    fn status_reflects_load_state() {
        let st = EngineState::default();
        assert_eq!(st.status()["loaded"], json!(false));
    }

    #[test]
    fn status_does_not_block_on_engine_lock() {
        // 模拟"推理中"：持有 engine 锁，status 仍应立即返回（只读 meta）
        let st = EngineState::default();
        let _held = st.engine.lock().unwrap();
        let s = st.status();
        assert_eq!(s["loaded"], json!(false));
    }

    #[test]
    fn fallback_prompt_includes_roles() {
        let p = fallback_chat_prompt(&[
            json!({"role": "system", "content": "s"}),
            json!({"role": "user", "content": "u"}),
        ]);
        assert!(p.contains("system: s"));
        assert!(p.ends_with("assistant: "));
    }
}
