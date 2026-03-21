pub mod capture;
pub mod denoise;
pub mod resample;
pub mod vad;

/// Audio pipeline configuration.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AudioConfig {
    /// Input device name (None = system default).
    pub device: Option<String>,
    /// Sample rate for capture (default: native device rate, resampled to 16kHz for inference).
    pub sample_rate: Option<u32>,
    /// Enable noise suppression via RNNoise.
    #[serde(default = "default_true")]
    pub denoise: bool,
    /// Enable voice activity detection.
    #[serde(default = "default_true")]
    pub vad: bool,
    /// VAD threshold (0.0-1.0). Higher = more aggressive filtering.
    #[serde(default = "default_vad_threshold")]
    pub vad_threshold: f32,
}

fn default_true() -> bool {
    true
}

fn default_vad_threshold() -> f32 {
    0.5
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            device: None,
            sample_rate: None,
            denoise: true,
            vad: true,
            vad_threshold: default_vad_threshold(),
        }
    }
}

/// Raw audio samples at a known sample rate.
#[derive(Debug, Clone)]
pub struct AudioBuffer {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u16,
}

impl AudioBuffer {
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        Self {
            samples: Vec::new(),
            sample_rate,
            channels,
        }
    }

    pub fn duration_secs(&self) -> f32 {
        self.samples.len() as f32 / (self.sample_rate as f32 * self.channels as f32)
    }
}
