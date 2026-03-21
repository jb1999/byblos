use anyhow::Result;

/// Frame duration in milliseconds for energy analysis.
const FRAME_MS: usize = 30;

/// Default RMS energy threshold below which audio is considered silence.
const DEFAULT_ENERGY_THRESHOLD: f32 = 0.01;

/// Default number of consecutive silent frames before considering speech ended.
/// At 30ms per frame, 50 frames = 1.5 seconds.
const DEFAULT_SILENCE_FRAMES: usize = 50;

/// Voice Activity Detection using energy-based analysis.
///
/// Uses RMS energy per 30ms frame to classify speech vs silence.
/// A future version may upgrade to Silero VAD for higher accuracy.
pub struct VoiceActivityDetector {
    /// RMS energy threshold — frames below this are silence.
    threshold: f32,
    /// Number of consecutive silent frames to mark end of speech (~1.5s default).
    silence_frame_count: usize,
}

impl VoiceActivityDetector {
    pub fn new(threshold: f32) -> Result<Self> {
        let threshold = if threshold <= 0.0 {
            DEFAULT_ENERGY_THRESHOLD
        } else {
            threshold
        };
        Ok(Self {
            threshold,
            silence_frame_count: DEFAULT_SILENCE_FRAMES,
        })
    }

    /// Create a VAD with custom silence duration.
    pub fn with_silence_duration(threshold: f32, silence_frames: usize) -> Result<Self> {
        let mut vad = Self::new(threshold)?;
        vad.silence_frame_count = silence_frames;
        Ok(vad)
    }

    /// Calculate RMS energy of a slice of samples.
    fn rms_energy(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
        (sum_sq / samples.len() as f32).sqrt()
    }

    /// Check if a buffer of samples is silent (below energy threshold).
    ///
    /// Useful for auto-stop detection from the UI layer.
    pub fn is_silent(samples: &[f32], threshold: f32) -> bool {
        Self::rms_energy(samples) < threshold
    }

    /// Returns segments of the audio that contain speech based on energy analysis.
    ///
    /// Input must be 16kHz mono f32 samples.
    /// Splits audio into 30ms frames, computes RMS energy per frame,
    /// and groups consecutive speech frames into segments.
    /// Speech ends after `silence_frame_count` consecutive silent frames.
    pub fn detect_speech(&self, samples: &[f32], sample_rate: u32) -> Result<Vec<SpeechSegment>> {
        debug_assert_eq!(sample_rate, 16_000, "VAD expects 16kHz input");

        if samples.is_empty() {
            return Ok(vec![]);
        }

        let frame_size = (sample_rate as usize * FRAME_MS) / 1000; // 480 samples at 16kHz
        let num_frames = samples.len() / frame_size;

        if num_frames == 0 {
            // Buffer too short for even one frame — treat as single segment if energetic.
            let energy = Self::rms_energy(samples);
            if energy >= self.threshold {
                return Ok(vec![SpeechSegment {
                    start_sample: 0,
                    end_sample: samples.len(),
                    confidence: (energy / self.threshold).min(1.0),
                }]);
            }
            return Ok(vec![]);
        }

        // Classify each frame as speech or silence.
        let frame_is_speech: Vec<bool> = (0..num_frames)
            .map(|i| {
                let start = i * frame_size;
                let end = (start + frame_size).min(samples.len());
                Self::rms_energy(&samples[start..end]) >= self.threshold
            })
            .collect();

        // Group into speech segments with silence tolerance.
        let mut segments = Vec::new();
        let mut in_speech = false;
        let mut speech_start: usize = 0;
        let mut consecutive_silence: usize = 0;

        for (i, &is_speech) in frame_is_speech.iter().enumerate() {
            if is_speech {
                if !in_speech {
                    in_speech = true;
                    speech_start = i * frame_size;
                }
                consecutive_silence = 0;
            } else if in_speech {
                consecutive_silence += 1;
                if consecutive_silence >= self.silence_frame_count {
                    // End of speech segment.
                    let speech_end = (i + 1 - self.silence_frame_count) * frame_size;
                    segments.push(SpeechSegment {
                        start_sample: speech_start,
                        end_sample: speech_end.min(samples.len()),
                        confidence: 1.0,
                    });
                    in_speech = false;
                    consecutive_silence = 0;
                }
            }
        }

        // Close any open segment.
        if in_speech {
            // Trim trailing silence frames.
            let end_frame = num_frames - consecutive_silence;
            let speech_end = end_frame * frame_size;
            if speech_end > speech_start {
                segments.push(SpeechSegment {
                    start_sample: speech_start,
                    end_sample: speech_end.min(samples.len()),
                    confidence: 1.0,
                });
            }
        }

        Ok(segments)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_tone(freq: f32, duration_s: f32, sample_rate: u32, amplitude: f32) -> Vec<f32> {
        let num_samples = (sample_rate as f32 * duration_s) as usize;
        (0..num_samples)
            .map(|i| {
                let t = i as f32 / sample_rate as f32;
                amplitude * (2.0 * std::f32::consts::PI * freq * t).sin()
            })
            .collect()
    }

    fn make_silence(duration_s: f32, sample_rate: u32) -> Vec<f32> {
        vec![0.0; (sample_rate as f32 * duration_s) as usize]
    }

    #[test]
    fn test_rms_energy_silence() {
        let silence = vec![0.0f32; 480];
        assert_eq!(VoiceActivityDetector::rms_energy(&silence), 0.0);
    }

    #[test]
    fn test_rms_energy_tone() {
        let tone = make_tone(440.0, 0.03, 16000, 0.5);
        let energy = VoiceActivityDetector::rms_energy(&tone);
        // RMS of a sine wave with amplitude A is A/sqrt(2) ≈ 0.354
        assert!(energy > 0.3, "energy={energy}");
        assert!(energy < 0.4, "energy={energy}");
    }

    #[test]
    fn test_is_silent() {
        let silence = vec![0.001f32; 480];
        assert!(VoiceActivityDetector::is_silent(&silence, 0.01));

        let loud = make_tone(440.0, 0.03, 16000, 0.5);
        assert!(!VoiceActivityDetector::is_silent(&loud, 0.01));
    }

    #[test]
    fn test_detect_speech_all_silence() {
        let vad = VoiceActivityDetector::new(0.01).unwrap();
        let silence = make_silence(2.0, 16000);
        let segments = vad.detect_speech(&silence, 16000).unwrap();
        assert!(segments.is_empty());
    }

    #[test]
    fn test_detect_speech_all_speech() {
        let vad = VoiceActivityDetector::with_silence_duration(0.01, 50).unwrap();
        let tone = make_tone(440.0, 2.0, 16000, 0.5);
        let segments = vad.detect_speech(&tone, 16000).unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].start_sample, 0);
    }

    #[test]
    fn test_detect_speech_with_silence_gap() {
        // Use a short silence tolerance (5 frames = 150ms) so the gap triggers a split.
        let vad = VoiceActivityDetector::with_silence_duration(0.01, 5).unwrap();
        let mut audio = make_tone(440.0, 0.5, 16000, 0.5);
        audio.extend(make_silence(0.5, 16000));
        audio.extend(make_tone(440.0, 0.5, 16000, 0.5));
        let segments = vad.detect_speech(&audio, 16000).unwrap();
        assert_eq!(segments.len(), 2, "Expected 2 segments, got {segments:?}");
    }
}
