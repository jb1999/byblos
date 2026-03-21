use std::path::Path;

use anyhow::{Context, Result};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState};

use super::{SpeechModel, TranscriptionResult, TranscriptionSegment};

pub struct WhisperModel {
    ctx: WhisperContext,
    state: WhisperState,
    language: String,
    model_name: String,
}

impl WhisperModel {
    pub fn load(model_path: &Path, language: &str) -> Result<Self> {
        let model_name = model_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("whisper")
            .to_string();

        let mut params = WhisperContextParameters::default();
        params.use_gpu(true);

        let ctx = WhisperContext::new_with_params(
            model_path.to_str().context("Invalid model path")?,
            params,
        )
        .map_err(|e| anyhow::anyhow!("Failed to load whisper model: {e}"))?;

        let state = ctx.create_state().map_err(|e| anyhow::anyhow!("Failed to create state: {e}"))?;

        Ok(Self {
            ctx,
            state,
            language: language.to_string(),
            model_name,
        })
    }
}

impl SpeechModel for WhisperModel {
    fn transcribe(&mut self, samples: &[f32]) -> Result<TranscriptionResult> {
        let start = std::time::Instant::now();

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(Some(&self.language));
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        params.set_suppress_non_speech_tokens(true);

        self.state
            .full(params, samples)
            .map_err(|e| anyhow::anyhow!("Whisper inference failed: {e}"))?;

        let num_segments = self.state.full_n_segments().map_err(|e| anyhow::anyhow!("{e}"))?;
        let mut segments = Vec::new();
        let mut full_text = String::new();

        for i in 0..num_segments {
            let text = self.state
                .full_get_segment_text(i)
                .map_err(|e| anyhow::anyhow!("{e}"))?;
            let start_ts = self.state
                .full_get_segment_t0(i)
                .map_err(|e| anyhow::anyhow!("{e}"))? as u64
                * 10;
            let end_ts = self.state
                .full_get_segment_t1(i)
                .map_err(|e| anyhow::anyhow!("{e}"))? as u64
                * 10;

            full_text.push_str(&text);
            segments.push(TranscriptionSegment {
                start_ms: start_ts,
                end_ms: end_ts,
                text,
                confidence: 1.0,
            });
        }

        let duration_ms = start.elapsed().as_millis() as u64;
        log::info!(
            "Whisper transcribed {:.1}s audio in {}ms",
            samples.len() as f32 / 16000.0,
            duration_ms
        );

        Ok(TranscriptionResult {
            text: full_text.trim().to_string(),
            segments,
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
