use anyhow::Result;

/// Voice Activity Detection using Silero VAD.
///
/// Silero is a tiny (~1MB) ONNX model that classifies audio frames
/// as speech or non-speech with high accuracy.
pub struct VoiceActivityDetector {
    threshold: f32,
    // TODO: ONNX runtime session for Silero VAD model
}

impl VoiceActivityDetector {
    pub fn new(threshold: f32) -> Result<Self> {
        // TODO: Load Silero VAD ONNX model
        Ok(Self { threshold })
    }

    /// Returns segments of the audio that contain speech.
    ///
    /// Input must be 16kHz mono f32 samples.
    pub fn detect_speech(&self, samples: &[f32], sample_rate: u32) -> Result<Vec<SpeechSegment>> {
        debug_assert_eq!(sample_rate, 16_000, "VAD expects 16kHz input");

        // TODO: Run Silero VAD inference on 30ms frames
        // For now, return the entire buffer as a single speech segment
        // (i.e., no filtering — transcribe everything)
        Ok(vec![SpeechSegment {
            start_sample: 0,
            end_sample: samples.len(),
            confidence: 1.0,
        }])
    }

    /// Filter audio to only speech segments.
    pub fn filter_speech(&self, samples: &[f32], sample_rate: u32) -> Result<Vec<f32>> {
        let segments = self.detect_speech(samples, sample_rate)?;
        let mut speech = Vec::new();
        for seg in segments {
            if seg.confidence >= self.threshold {
                speech.extend_from_slice(&samples[seg.start_sample..seg.end_sample]);
            }
        }
        Ok(speech)
    }
}

#[derive(Debug, Clone)]
pub struct SpeechSegment {
    pub start_sample: usize,
    pub end_sample: usize,
    pub confidence: f32,
}
