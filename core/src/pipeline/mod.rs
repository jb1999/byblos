pub mod stream;

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};

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

/// C-compatible callback for streaming partial results.
pub type PartialCallback = extern "C" fn(*const std::os::raw::c_char, *mut std::ffi::c_void);

/// The main orchestrator: audio in → text out.
pub struct Pipeline {
    capture: AudioCapture,
    model: Box<dyn SpeechModel>,
    vad: Option<VoiceActivityDetector>,
    denoiser: Option<Denoiser>,
    config: PipelineConfig,
    /// Duration of the last transcription in milliseconds.
    last_transcription_ms: u64,
    /// Flag to signal the streaming thread to stop.
    streaming_stop: Arc<AtomicBool>,
    /// Handle to the streaming thread.
    streaming_thread: Option<std::thread::JoinHandle<()>>,
    /// Whether to translate to English instead of transcribing.
    translate: bool,
}

impl Pipeline {
    pub fn new(model_path: &Path) -> Result<Self> {
        Self::with_language(model_path, "en")
    }

    pub fn with_language(model_path: &Path, language: &str) -> Result<Self> {
        let audio_config = AudioConfig::default();
        let capture = AudioCapture::new(audio_config.device.as_deref())?;

        let model = WhisperModel::load(model_path, language)?;

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
            last_transcription_ms: 0,
            streaming_stop: Arc::new(AtomicBool::new(false)),
            streaming_thread: None,
            translate: false,
        })
    }

    /// Reload the model at runtime, optionally changing language.
    pub fn reload_model(&mut self, model_path: &Path, language: &str) -> Result<()> {
        let new_model = WhisperModel::load(model_path, language)?;
        self.model = Box::new(new_model);
        // Re-apply translate setting to new model.
        self.model.set_translate(self.translate);
        log::info!("Reloaded model from {:?} with language={}", model_path, language);
        Ok(())
    }

    /// Enable or disable translation-to-English mode.
    pub fn set_translate(&mut self, translate: bool) {
        self.translate = translate;
        self.model.set_translate(translate);
        log::info!("Translation mode: {}", if translate { "enabled" } else { "disabled" });
    }

    /// Transcribe an audio file from disk.
    ///
    /// Reads WAV files directly via `hound`. The caller is responsible for
    /// converting non-WAV formats (e.g. using afconvert) before calling this.
    pub fn transcribe_file(&mut self, path: &Path) -> Result<String> {
        let reader = hound::WavReader::open(path)
            .with_context(|| format!("Failed to open WAV file: {:?}", path))?;

        let spec = reader.spec();
        let raw_samples: Vec<f32> = match spec.sample_format {
            hound::SampleFormat::Float => {
                reader.into_samples::<f32>()
                    .collect::<std::result::Result<Vec<f32>, _>>()?
            }
            hound::SampleFormat::Int => {
                let bits = spec.bits_per_sample;
                let max_val = (1u32 << (bits - 1)) as f32;
                reader.into_samples::<i32>()
                    .collect::<std::result::Result<Vec<i32>, _>>()?
                    .into_iter()
                    .map(|s| s as f32 / max_val)
                    .collect()
            }
        };

        let raw_buffer = crate::audio::AudioBuffer {
            samples: raw_samples,
            sample_rate: spec.sample_rate,
            channels: spec.channels,
        };

        let audio = resample::to_16khz_mono(&raw_buffer)?;
        if audio.samples.is_empty() {
            return Ok(String::new());
        }

        let result = self.model.transcribe(&audio.samples)?;
        self.last_transcription_ms = result.duration_ms;
        let mut output = result.text;

        if self.config.post_process {
            output = text::format::post_process(&output);
        }
        if self.config.voice_commands {
            output = text::commands::process_commands(&output);
        }

        log::info!(
            "Transcribed file {:?} ({:.1}s audio) in {}ms",
            path,
            audio.samples.len() as f32 / 16000.0,
            result.duration_ms
        );

        Ok(output)
    }

    /// Get the duration of the last transcription in milliseconds.
    pub fn last_transcription_ms(&self) -> u64 {
        self.last_transcription_ms
    }

    pub fn start_recording(&mut self) -> Result<()> {
        self.streaming_stop.store(false, Ordering::SeqCst);
        self.capture.start()
    }

    /// Start recording with streaming support.
    /// Use `transcribe_snapshot()` to poll for partial results while recording.
    /// Call `stop_and_transcribe()` to stop and get the final result.
    pub fn start_streaming(
        &mut self,
        _callback: PartialCallback,
        _user_data: *mut std::ffi::c_void,
    ) -> Result<()> {
        self.start_recording()
    }

    /// Transcribe a snapshot of the current audio without stopping recording.
    /// Used for streaming partial results from the FFI layer.
    pub fn transcribe_snapshot(&mut self) -> Result<String> {
        let raw_audio = self.capture.snapshot();

        if raw_audio.samples.is_empty() {
            return Ok(String::new());
        }

        let audio = resample::to_16khz_mono(&raw_audio)?;

        if audio.samples.is_empty() {
            return Ok(String::new());
        }

        let result = self.model.transcribe(&audio.samples)?;
        let mut output = result.text;

        if self.config.post_process {
            output = text::format::post_process(&output);
        }

        Ok(output)
    }

    pub fn stop_and_transcribe(&mut self) -> Result<String> {
        // Stop the streaming thread if running.
        self.streaming_stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.streaming_thread.take() {
            let _ = thread.join();
        }

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
        self.last_transcription_ms = result.duration_ms;
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
