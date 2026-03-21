pub mod manager;
pub mod whisper;

/// Configuration for which model to use.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ModelConfig {
    /// Model backend: "whisper", "onnx"
    pub backend: String,
    /// Path to model file (relative to models dir, or absolute).
    pub path: String,
    /// Model variant (e.g., "tiny", "base", "small", "medium", "large-v3").
    pub variant: Option<String>,
    /// Language hint (e.g., "en", "auto").
    #[serde(default = "default_language")]
    pub language: String,
}

fn default_language() -> String {
    "en".to_string()
}

/// Result of a transcription.
#[derive(Debug, Clone)]
pub struct TranscriptionResult {
    pub text: String,
    pub segments: Vec<TranscriptionSegment>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
pub struct TranscriptionSegment {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    pub confidence: f32,
}

/// Trait that all model backends implement.
pub trait SpeechModel: Send {
    /// Transcribe 16kHz mono f32 audio samples.
    fn transcribe(&mut self, samples: &[f32]) -> anyhow::Result<TranscriptionResult>;

    /// Model display name.
    fn name(&self) -> &str;

    /// Estimated memory usage in bytes.
    fn memory_usage(&self) -> u64;
}
