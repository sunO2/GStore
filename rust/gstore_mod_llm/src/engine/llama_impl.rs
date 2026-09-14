//! llama.cpp 引擎实现（`--features llama` 时编译）。
//!
//! 说明：
//! - 模型以 `Box<LlamaModel>` 常驻，`LlamaContext` **每次生成临时创建**——`new_context`
//!   只借用 model，因此无需自引用结构（避免 ouroboros 之类依赖）。
//! - 生成全程在本调用线程同步执行，不起线程（Android 上 dlopen 的 .so 内起线程会崩）。

use std::num::NonZeroU32;
use std::path::Path;
use std::time::Instant;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
use llama_cpp_2::token::LlamaToken;
use llama_cpp_2::TokenToStringError;
use llama_cpp_2::sampling::LlamaSampler;
use serde_json::{json, Value};

use crate::engine::{GenParams, LoadParams};

pub struct LlamaEngine {
    backend: LlamaBackend,
    model: Box<LlamaModel>,
    params: LoadParams,
}

impl LlamaEngine {
    pub fn load(p: &LoadParams) -> Result<Self, String> {
        // 如实告知：请求了 GPU 卸载但本构建没编 GPU 后端时，llama.cpp 会忽略并按 CPU 跑
        if p.n_gpu_layers > 0 && !cfg!(any(feature = "gpu-vulkan", feature = "gpu-opencl")) {
            crate::log_message(
                2,
                &format!(
                    "llm: 请求 n_gpu_layers={} 但本构建未编译 GPU 后端（vulkan/opencl）→ 实际按纯 CPU 运行",
                    p.n_gpu_layers
                ),
            );
        }
        let backend = LlamaBackend::init().map_err(|e| format!("backend init: {e}"))?;
        let model_params = LlamaModelParams::default().with_n_gpu_layers(p.n_gpu_layers);
        let model = LlamaModel::load_from_file(&backend, Path::new(&p.path), &model_params)
            .map_err(|e| format!("load model: {e}"))?;
        Ok(Self { backend, model: Box::new(model), params: p.clone() })
    }

    /// 本模块**编译期**启用的后端（并非运行时实际卸载成功与否）。
    /// 需运行时确认请结合加载日志里的 backend 字段与 llama.cpp 自身输出。
    pub fn backend_name(&self) -> &'static str {
        if cfg!(feature = "gpu-vulkan") {
            "vulkan"
        } else if cfg!(feature = "gpu-opencl") {
            "opencl"
        } else {
            "cpu"
        }
    }

    fn ctx_params(&self) -> LlamaContextParams {
        LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(self.params.n_ctx))
            .with_n_batch(self.params.n_batch)
            .with_n_threads(self.params.n_threads as i32)
            .with_n_threads_batch(self.params.n_threads as i32)
    }

    /// 同步生成：返回 { text, tokens, ms, tokens_per_sec }
    pub fn generate(&mut self, prompt: &str, g: &GenParams, instance_id: u64) -> Result<Value, String> {
        let started = Instant::now();
        let mut ctx = self
            .model
            .new_context(&self.backend, self.ctx_params())
            .map_err(|e| format!("new_context: {e}"))?;
        ctx.clear_kv_cache();

        let tokens = self
            .model
            .str_to_token(prompt, AddBos::Always)
            .map_err(|e| format!("tokenize: {e}"))?;
        if tokens.is_empty() {
            return Err("empty prompt".to_string());
        }
        crate::log_message(
            1,
            &format!(
                "llm: 提示已分词 tokens={} n_batch={} n_ctx={}",
                tokens.len(),
                self.params.n_batch,
                self.params.n_ctx
            ),
        );

        // 提示分块解码；仅最后一个 token 需要 logits
        let n_batch = (self.params.n_batch.max(1) as usize).min(tokens.len());
        let mut pos: i32 = 0;
        let mut idx = 0usize;
        while idx < tokens.len() {
            let end = (idx + n_batch).min(tokens.len());
            let mut batch = LlamaBatch::new(end - idx, 1);
            for (k, tok) in tokens[idx..end].iter().enumerate() {
                let is_last = idx + k == tokens.len() - 1;
                batch
                    .add(*tok, pos, &[0], is_last)
                    .map_err(|e| format!("batch add: {e}"))?;
                pos += 1;
            }
            if pos as usize > self.params.n_ctx as usize {
                return Err(format!(
                    "prompt 超出上下文: {} > n_ctx {}",
                    pos, self.params.n_ctx
                ));
            }
            ctx.decode(&mut batch).map_err(|e| format!("decode: {e}"))?;
            idx = end;
        }

        // 采样链（grammar 必须放在最后，作为最终过滤器）
        let mut chain: Vec<LlamaSampler> = if g.temperature <= 0.0 {
            vec![LlamaSampler::greedy()]
        } else {
            vec![
                LlamaSampler::temp(g.temperature),
                LlamaSampler::top_k(g.top_k.max(1)),
                LlamaSampler::top_p(g.top_p, 1),
                LlamaSampler::dist(1234),
            ]
        };
        if let Some(grammar) = g.grammar.as_deref() {
            let trigger = g
                .grammar_trigger
                .as_deref()
                .unwrap_or("<tool_call>")
                .to_string();
            match LlamaSampler::grammar_lazy(
                &self.model,
                grammar,
                "root",
                [trigger.as_bytes()],
                &[],
            ) {
                Ok(gs) => {
                    crate::log_message(
                        1,
                        &format!("llm: 已启用懒语法（触发词 {trigger}）"),
                    );
                    chain.push(gs);
                }
                Err(e) => crate::log_message(
                    2,
                    &format!("llm: grammar 初始化失败，本次不约束输出 - {e:?}"),
                ),
            }
        }
        let mut sampler = LlamaSampler::chain_simple(chain);

        let mut generated: Vec<LlamaToken> = Vec::new();
        let mut batch = LlamaBatch::new(1, 1);
        // 流式：累积字节 → 整段 lossy 解码 → 只把"稳定的新增后缀"推给宿主，
        // 避免多字节 UTF-8 被从中间切开时吐出乱码（先不推，等下一个 token 补齐）。
        let mut stream_bytes: Vec<u8> = Vec::new();
        let mut stream_emitted = String::new();
        for _ in 0..g.max_tokens.max(1) {
            let token = sampler.sample(&ctx, -1);
            sampler.accept(token);
            if self.model.is_eog_token(token) {
                break;
            }
            generated.push(token);

            if g.stream_id.is_some() {
                collect_token_bytes(&self.model, token, &mut stream_bytes);
                let cur = String::from_utf8_lossy(&stream_bytes).to_string();
                if cur.len() > stream_emitted.len() && cur.starts_with(stream_emitted.as_str()) {
                    let delta = cur[stream_emitted.len()..].to_string();
                    if !delta.is_empty() {
                        let ev = json!({
                            "kind": "llm.delta",
                            "stream_id": g.stream_id,
                            "instance": instance_id,
                            "delta": delta,
                        });
                        crate::emit_event(instance_id, "llm.delta", ev.to_string().as_bytes());
                        stream_emitted = cur;
                    }
                }
            }

            // stop 串命中即结束（按当前全文判断）
            if !g.stop.is_empty() {
                let cur = decode_tokens(&self.model, &generated);
                if g.stop.iter().any(|s| !s.is_empty() && cur.contains(s.as_str())) {
                    break;
                }
            }

            batch.clear();
            batch
                .add(token, pos, &[0], true)
                .map_err(|e| format!("batch add: {e}"))?;
            pos += 1;
            ctx.decode(&mut batch).map_err(|e| format!("decode: {e}"))?;
        }

        let produced = generated.len() as i32;
        let mut text = decode_tokens(&self.model, &generated);
        if !g.stop.is_empty() {
            if let Some(cut) = g
                .stop
                .iter()
                .filter(|s| !s.is_empty())
                .filter_map(|s| text.find(s.as_str()))
                .min()
            {
                text.truncate(cut);
            }
        }

        let ms = started.elapsed().as_millis() as u64;
        if g.stream_id.is_some() {
            let ev = json!({
                "kind": "llm.done",
                "stream_id": g.stream_id,
                "instance": instance_id,
                "text": text,
                "tokens": produced,
                "ms": ms,
            });
            crate::emit_event(instance_id, "llm.done", ev.to_string().as_bytes());
        }
        // 关键：prefill（读提示词）与 decode（写字）分开计时。
        // 把两者混在一个 tok/s 里会严重误导：长提示词的 prefill 会把"生成速度"摊薄到看似很慢。
        let t = ctx.timings();
        let (p_ms, p_n) = (t.t_p_eval_ms(), t.n_p_eval());
        let (d_ms, d_n) = (t.t_eval_ms(), t.n_eval());
        let p_tps = if p_ms > 0.0 { p_n as f64 * 1000.0 / p_ms } else { 0.0 };
        let d_tps = if d_ms > 0.0 { d_n as f64 * 1000.0 / d_ms } else { 0.0 };
        crate::log_message(
            1,
            &format!(
                "llm: 性能 prefill={p_ms:.0}ms/{p_n}tok ({p_tps:.1} tok/s) | \
decode={d_ms:.0}ms/{d_n}tok ({d_tps:.1} tok/s)"
            ),
        );
        Ok(json!({
            "text": text,
            "tokens": produced,
            "ms": ms,
            "tokens_per_sec": if ms > 0 { (produced as f64) * 1000.0 / ms as f64 } else { 0.0 },
            "prefill_ms": p_ms,
            "prefill_tokens": p_n,
            "prefill_tps": p_tps,
            "decode_ms": d_ms,
            "decode_tokens": d_n,
            "decode_tps": d_tps,
            "backend": self.backend_name(),
        }))
    }
}

/// 整段解码 token 序列为文本。
///
/// **不要直接用 `tokens_to_str`**：它内部固定 `buffer_size=8` 且失败不重试，
/// 中文等较长片段会返回 `InsufficientBufferSpace`；早期代码把它 `unwrap_or_default()`
/// 静默成空串，表现为"生成了 token 却没有文本"。
/// 此处按 `token_to_piece` 的成熟做法**按提示大小重试**，并用 lossy 兜底，
/// 避免个别坏 token 让整段回答变空。
/// 把单个 token 的字节追加到缓冲区（带重试；失败仅记日志，不中断流式）
fn collect_token_bytes(model: &LlamaModel, token: LlamaToken, out: &mut Vec<u8>) {
    match model.token_to_piece_bytes(token, 8, false, None) {
        Ok(piece) => out.extend_from_slice(&piece),
        Err(TokenToStringError::InsufficientBufferSpace(needed)) => {
            let need = usize::try_from(-needed).unwrap_or(256);
            match model.token_to_piece_bytes(token, need, false, None) {
                Ok(piece) => out.extend_from_slice(&piece),
                Err(e) => {
                    crate::log_message(2, &format!("llm: 流式 token {} 解码失败 - {e:?}", token.0))
                }
            }
        }
        Err(e) => {
            crate::log_message(2, &format!("llm: 流式 token {} 解码失败 - {e:?}", token.0))
        }
    }
}

fn decode_tokens(model: &LlamaModel, tokens: &[LlamaToken]) -> String {
    let mut bytes: Vec<u8> = Vec::with_capacity(tokens.len() * 4);
    let mut failed = 0usize;
    for &t in tokens {
        match model.token_to_piece_bytes(t, 8, false, None) {
            Ok(piece) => bytes.extend_from_slice(&piece),
            Err(TokenToStringError::InsufficientBufferSpace(needed)) => {
                // 错误值带负数，取反即为所需字节数
                let need = usize::try_from(-needed).unwrap_or(256);
                match model.token_to_piece_bytes(t, need, false, None) {
                    Ok(piece) => bytes.extend_from_slice(&piece),
                    Err(e) => {
                        failed += 1;
                        crate::log_message(2, &format!("llm: token {} 解码失败(重试) - {e:?}", t.0));
                    }
                }
            }
            Err(e) => {
                failed += 1;
                crate::log_message(2, &format!("llm: token {} 解码失败 - {e:?}", t.0));
            }
        }
    }
    if failed > 0 {
        crate::log_message(2, &format!("llm: 共 {failed}/{} 个 token 解码失败（已 lossy 兜底）", tokens.len()));
    }
    String::from_utf8_lossy(&bytes).to_string()
}

/// 用模型自带 chat 模板把 messages 拼成 prompt（模板缺失时调用方回退通用格式）
pub fn apply_chat_template(engine: &LlamaEngine, messages: &[Value]) -> Result<String, String> {
    let tmpl = engine
        .model
        .chat_template(None)
        .map_err(|e| format!("chat template missing: {e}"))?;
    let mut chat = Vec::with_capacity(messages.len());
    for m in messages {
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("user").to_string();
        let content = m.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
        chat.push(LlamaChatMessage::new(role, content).map_err(|e| format!("chat msg: {e}"))?);
    }
    engine
        .model
        .apply_chat_template(&tmpl, &chat, true)
        .map_err(|e| format!("apply template: {e}"))
}
