use std::path::Path;

use anyhow::Result;
use parakeet_rs::Nemotron;

use super::{SpeechModel, TranscriptionResult};

/// NeMo Parakeet speech model via ONNX Runtime.
///
/// Uses the Nemotron/FastConformer-TDT architecture.
/// Very fast, non-autoregressive inference.
/// Requires model directory with: model.onnx, tokenizer.json
pub struct ParakeetModel {
    model: Nemotron,
    model_name: String,
}

impl ParakeetModel {
    /// Load from a directory containing model.onnx and tokenizer.json.
    pub fn load(model_dir: &Path) -> Result<Self> {
        let model_name = model_dir
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("parakeet")
            .to_string();

        let model = Nemotron::from_pretrained(model_dir, None)
            .map_err(|e| anyhow::anyhow!("Failed to load Parakeet model: {e}"))?;

        log::info!("Parakeet model loaded from {:?}", model_dir);
        Ok(Self { model, model_name })
    }
}

impl SpeechModel for ParakeetModel {
    fn transcribe(&mut self, samples: &[f32]) -> Result<TranscriptionResult> {
        let start = std::time::Instant::now();

        let text = self
            .model
            .transcribe_audio(samples)
            .map_err(|e| anyhow::anyhow!("Parakeet transcription failed: {e}"))?;

        let duration_ms = start.elapsed().as_millis() as u64;

        log::info!(
            "Parakeet transcribed {:.1}s audio in {}ms",
            samples.len() as f32 / 16000.0,
            duration_ms
        );

        Ok(TranscriptionResult {
            text: text.trim().to_string(),
            segments: vec![],
            duration_ms,
        })
    }

    fn name(&self) -> &str {
        &self.model_name
    }

    fn memory_usage(&self) -> u64 {
        0
    }
}
