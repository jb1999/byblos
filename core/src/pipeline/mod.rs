pub mod stream;

use std::path::Path;

use anyhow::Result;

use crate::audio::capture::AudioCapture;
use crate::audio::denoise::Denoiser;
use crate::audio::resample;
use crate::audio::vad::VoiceActivityDetector;
use crate::audio::AudioConfig;
use crate::models::whisper::WhisperModel;
use crate::models::SpeechModel;
use crate::text;

/// Pipeline configuration.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct PipelineConfig {
    /// Enable post-processing (punctuation, formatting).
    #[serde(default = "default_true")]
    pub post_process: bool,
    /// Enable voice commands ("delete that", "new line", etc.).
    #[serde(default = "default_true")]
    pub voice_commands: bool,
}

fn default_true() -> bool {
    true
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            post_process: true,
            voice_commands: true,
        }
    }
}

/// The main orchestrator: audio in → text out.
pub struct Pipeline {
    capture: AudioCapture,
    model: Box<dyn SpeechModel>,
    vad: Option<VoiceActivityDetector>,
    denoiser: Option<Denoiser>,
    config: PipelineConfig,
}

impl Pipeline {
    pub fn new(model_path: &Path) -> Result<Self> {
        let audio_config = AudioConfig::default();
        let capture = AudioCapture::new(audio_config.device.as_deref())?;

        let model = WhisperModel::load(model_path, "en")?;

        let vad = if audio_config.vad {
            Some(VoiceActivityDetector::new(audio_config.vad_threshold)?)
        } else {
            None
        };

        let denoiser = if audio_config.denoise {
            Some(Denoiser::new()?)
        } else {
            None
        };

        Ok(Self {
            capture,
            model: Box::new(model),
            vad,
            denoiser,
            config: PipelineConfig::default(),
        })
    }

    pub fn start_recording(&mut self) -> Result<()> {
        self.capture.start()
    }

    pub fn stop_and_transcribe(&mut self) -> Result<String> {
        let raw_audio = self.capture.stop()?;

        // Resample to 16kHz mono.
        let mut audio = resample::to_16khz_mono(&raw_audio)?;

        // Denoise.
        if let Some(ref denoiser) = self.denoiser {
            denoiser.process(&mut audio.samples)?;
        }

        // VAD: filter to speech-only segments.
        let samples = if let Some(ref vad) = self.vad {
            vad.filter_speech(&audio.samples, audio.sample_rate)?
        } else {
            audio.samples
        };

        if samples.is_empty() {
            return Ok(String::new());
        }

        // Transcribe.
        let result = self.model.transcribe(&samples)?;
        let mut output = result.text;

        // Post-process.
        if self.config.post_process {
            output = text::format::post_process(&output);
        }

        // Handle voice commands.
        if self.config.voice_commands {
            output = text::commands::process_commands(&output);
        }

        log::info!(
            "Transcribed {:.1}s audio in {}ms: {:?}",
            samples.len() as f32 / 16000.0,
            result.duration_ms,
            output
        );

        Ok(output)
    }
}
