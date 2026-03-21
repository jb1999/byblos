//! Byblos LLM Helper — separate process for local LLM inference.
//!
//! This runs as a child process spawned by the main Byblos app.
//! Communication is via JSON lines over stdin/stdout.
//!
//! Protocol:
//!   Request:  {"method": "process", "text": "...", "system_prompt": "..."}
//!   Response: {"ok": true, "result": "processed text", "duration_ms": 123}
//!
//!   Request:  {"method": "ping"}
//!   Response: {"ok": true, "result": "pong"}
//!
//!   Request:  {"method": "quit"}
//!   (process exits)

use std::io::{self, BufRead, Write};
use std::path::Path;

use anyhow::{Context, Result};
use encoding_rs::UTF_8;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::sampling::LlamaSampler;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct Request {
    method: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    system_prompt: String,
}

#[derive(Serialize)]
struct Response {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u64>,
}

fn main() {
    env_logger::init();

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: byblos-llm <model.gguf>");
        std::process::exit(1);
    }

    let model_path = &args[1];
    eprintln!("[byblos-llm] Loading model: {model_path}");

    let engine = match LlmEngine::load(Path::new(model_path)) {
        Ok(e) => {
            eprintln!("[byblos-llm] Model loaded successfully");
            e
        }
        Err(e) => {
            eprintln!("[byblos-llm] Failed to load model: {e}");
            // Send error and exit.
            let resp = Response {
                ok: false,
                result: None,
                error: Some(format!("Failed to load model: {e}")),
                duration_ms: None,
            };
            println!("{}", serde_json::to_string(&resp).unwrap());
            std::process::exit(1);
        }
    };

    // Signal readiness.
    let ready = Response {
        ok: true,
        result: Some("ready".to_string()),
        error: None,
        duration_ms: None,
    };
    println!("{}", serde_json::to_string(&ready).unwrap());
    io::stdout().flush().unwrap();

    // Process requests from stdin.
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        if line.trim().is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = Response {
                    ok: false,
                    result: None,
                    error: Some(format!("Invalid JSON: {e}")),
                    duration_ms: None,
                };
                println!("{}", serde_json::to_string(&resp).unwrap());
                io::stdout().flush().unwrap();
                continue;
            }
        };

        let resp = match req.method.as_str() {
            "ping" => Response {
                ok: true,
                result: Some("pong".to_string()),
                error: None,
                duration_ms: None,
            },
            "quit" => {
                eprintln!("[byblos-llm] Quit requested");
                break;
            }
            "process" => {
                let start = std::time::Instant::now();
                match engine.process(&req.text, &req.system_prompt) {
                    Ok(result) => Response {
                        ok: true,
                        result: Some(result),
                        error: None,
                        duration_ms: Some(start.elapsed().as_millis() as u64),
                    },
                    Err(e) => Response {
                        ok: false,
                        result: None,
                        error: Some(format!("{e}")),
                        duration_ms: None,
                    },
                }
            }
            other => Response {
                ok: false,
                result: None,
                error: Some(format!("Unknown method: {other}")),
                duration_ms: None,
            },
        };

        println!("{}", serde_json::to_string(&resp).unwrap());
        io::stdout().flush().unwrap();
    }

    eprintln!("[byblos-llm] Shutting down");
}

// ---------------------------------------------------------------------------
// LLM Engine (self-contained, no dependency on byblos-core)
// ---------------------------------------------------------------------------

struct LlmEngine {
    model: LlamaModel,
    backend: LlamaBackend,
}

impl LlmEngine {
    fn load(model_path: &Path) -> Result<Self> {
        let backend = LlamaBackend::init()
            .map_err(|e| anyhow::anyhow!("Failed to init llama backend: {e}"))?;

        let model_params = LlamaModelParams::default();
        let model = LlamaModel::load_from_file(&backend, model_path, &model_params)
            .map_err(|e| anyhow::anyhow!("Failed to load model: {e}"))?;

        Ok(Self { model, backend })
    }

    fn process(&self, text: &str, system_prompt: &str) -> Result<String> {
        if text.is_empty() && system_prompt.is_empty() {
            return Ok(String::new());
        }

        // Format as ChatML prompt (compatible with Qwen2.5, Phi-3, and most models).
        let prompt = if text.is_empty() {
            // System-prompt-only mode (used for follow-up summarization).
            format!(
                "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n\
                 <|im_start|>user\n{system_prompt}<|im_end|>\n\
                 <|im_start|>assistant\n"
            )
        } else {
            format!(
                "<|im_start|>system\n{system_prompt}<|im_end|>\n\
                 <|im_start|>user\n{text}<|im_end|>\n\
                 <|im_start|>assistant\n"
            )
        };

        let n_ctx = 4096u32;
        let ctx_params =
            LlamaContextParams::default().with_n_ctx(std::num::NonZero::new(n_ctx));

        let mut ctx = self
            .model
            .new_context(&self.backend, ctx_params)
            .map_err(|e| anyhow::anyhow!("Context creation failed: {e}"))?;

        let tokens = self
            .model
            .str_to_token(&prompt, llama_cpp_2::model::AddBos::Always)
            .map_err(|e| anyhow::anyhow!("Tokenization failed: {e}"))?;

        if tokens.len() as u32 >= n_ctx {
            anyhow::bail!("Input too long for context window");
        }

        let mut batch = LlamaBatch::new(n_ctx as usize, 1);
        for (i, &token) in tokens.iter().enumerate() {
            batch
                .add(token, i as i32, &[0], i == tokens.len() - 1)
                .map_err(|e| anyhow::anyhow!("Batch add failed: {e}"))?;
        }

        ctx.decode(&mut batch)
            .map_err(|e| anyhow::anyhow!("Decode failed: {e}"))?;

        let mut output = String::new();
        let max_tokens = 512u32;
        let mut n_decoded = tokens.len() as i32;

        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::temp(0.1),
            LlamaSampler::top_p(0.9, 1),
            LlamaSampler::dist(42),
        ]);

        let mut decoder = UTF_8.new_decoder();

        for _ in 0..max_tokens {
            let token = sampler.sample(&ctx, -1);

            if self.model.is_eog_token(token) {
                break;
            }

            let piece = self
                .model
                .token_to_piece(token, &mut decoder, true, None)
                .unwrap_or_default();
            output.push_str(&piece);

            if output.contains("<|im_end|>") || output.contains("<|endoftext|>") {
                output = output
                    .replace("<|im_end|>", "")
                    .replace("<|endoftext|>", "");
                break;
            }

            batch.clear();
            batch
                .add(token, n_decoded, &[0], true)
                .context("Batch add")?;
            n_decoded += 1;

            ctx.decode(&mut batch).context("Decode")?;
        }

        Ok(output.trim().to_string())
    }
}
