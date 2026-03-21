use std::path::Path;

use anyhow::Result;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::sampling::LlamaSampler;
use encoding_rs::UTF_8;

/// Local LLM engine for text post-processing.
///
/// Uses llama.cpp via Rust bindings to run GGUF models locally.
/// Designed for small, fast models (1-3B params) that clean up
/// transcription output: fix grammar, remove filler, reformat.
pub struct LlmEngine {
    model: LlamaModel,
    backend: LlamaBackend,
    n_ctx: u32,
}

impl LlmEngine {
    /// Load a GGUF model from disk.
    ///
    /// Recommended models:
    /// - Qwen2.5-1.5B-Instruct (fast, good at text cleanup)
    /// - Phi-3-mini (3.8B, higher quality)
    /// - TinyLlama-1.1B (fastest, basic quality)
    pub fn load(model_path: &Path) -> Result<Self> {
        // Backend may already be initialized by whisper.cpp (both use ggml).
        // That's OK — proceed regardless.
        let backend = match LlamaBackend::init() {
            Ok(b) => b,
            Err(e) => {
                log::warn!("LlamaBackend::init returned error (may be pre-initialized by whisper): {e}");
                // Try to proceed anyway — construct a backend handle.
                // If this fails, the model load will catch it.
                return Err(anyhow::anyhow!("Cannot initialize llama backend: {e}"));
            }
        };

        let model_params = LlamaModelParams::default();

        let model = LlamaModel::load_from_file(&backend, model_path, &model_params)
            .map_err(|e| anyhow::anyhow!("Failed to load LLM model: {e}"))?;

        log::info!("LLM model loaded from {:?}", model_path);

        Ok(Self {
            model,
            backend,
            n_ctx: 2048,
        })
    }

    /// Process text with a system prompt using the local LLM.
    ///
    /// The system prompt defines the transformation (e.g., "Fix grammar and punctuation").
    /// Returns the processed text.
    pub fn process(&self, text: &str, system_prompt: &str) -> Result<String> {
        if text.is_empty() {
            return Ok(String::new());
        }

        let start = std::time::Instant::now();

        // Format as a chat prompt.
        let prompt = format!(
            "<|im_start|>system\n{system_prompt}<|im_end|>\n<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n"
        );

        let ctx_params = LlamaContextParams::default().with_n_ctx(std::num::NonZero::new(self.n_ctx));

        let mut ctx = self
            .model
            .new_context(&self.backend, ctx_params)
            .map_err(|e| anyhow::anyhow!("Failed to create LLM context: {e}"))?;

        // Tokenize the prompt.
        let tokens = self
            .model
            .str_to_token(&prompt, llama_cpp_2::model::AddBos::Always)
            .map_err(|e| anyhow::anyhow!("Tokenization failed: {e}"))?;

        if tokens.len() as u32 >= self.n_ctx {
            anyhow::bail!("Input too long for context window");
        }

        // Create batch and add tokens.
        let mut batch = LlamaBatch::new(self.n_ctx as usize, 1);

        for (i, &token) in tokens.iter().enumerate() {
            let is_last = i == tokens.len() - 1;
            batch.add(token, i as i32, &[0], is_last)
                .map_err(|e| anyhow::anyhow!("Failed to add token to batch: {e}"))?;
        }

        // Run initial prompt through model.
        ctx.decode(&mut batch)
            .map_err(|e| anyhow::anyhow!("LLM decode failed: {e}"))?;

        // Generate response tokens.
        let mut output = String::new();
        let max_tokens = 512u32; // Limit output length.
        let mut n_decoded = tokens.len() as i32;

        // Set up sampler with temperature and top-p.
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::temp(0.1),       // Low temperature for deterministic output.
            LlamaSampler::top_p(0.9, 1),   // Top-p sampling.
            LlamaSampler::dist(42),         // Random seed.
        ]);

        let mut decoder = UTF_8.new_decoder();

        for _ in 0..max_tokens {
            let token = sampler.sample(&ctx, -1);

            // Check for end of generation.
            if self.model.is_eog_token(token) {
                break;
            }

            let piece = self
                .model
                .token_to_piece(token, &mut decoder, true, None)
                .unwrap_or_default();
            output.push_str(&piece);

            // Stop on chat template end markers.
            if output.contains("<|im_end|>") || output.contains("<|endoftext|>") {
                output = output
                    .replace("<|im_end|>", "")
                    .replace("<|endoftext|>", "");
                break;
            }

            // Prepare next batch.
            batch.clear();
            batch.add(token, n_decoded, &[0], true)
                .map_err(|e| anyhow::anyhow!("Failed to add token: {e}"))?;
            n_decoded += 1;

            ctx.decode(&mut batch)
                .map_err(|e| anyhow::anyhow!("LLM decode failed: {e}"))?;
        }

        let duration = start.elapsed();
        log::info!(
            "LLM processed {} chars -> {} chars in {:.1}s",
            text.len(),
            output.len(),
            duration.as_secs_f32()
        );

        Ok(output.trim().to_string())
    }
}

/// Default models directory for LLMs.
pub fn default_llm_models_dir() -> std::path::PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("byblos")
        .join("llm-models")
}
