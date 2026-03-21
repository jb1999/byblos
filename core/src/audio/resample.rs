use anyhow::Result;
use rubato::{FftFixedIn, Resampler};

use super::AudioBuffer;

/// Target sample rate for all speech recognition models.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Resample audio to 16kHz mono, the standard input format for speech models.
pub fn to_16khz_mono(buffer: &AudioBuffer) -> Result<AudioBuffer> {
    let samples = if buffer.channels > 1 {
        mix_to_mono(&buffer.samples, buffer.channels)
    } else {
        buffer.samples.clone()
    };

    if buffer.sample_rate == TARGET_SAMPLE_RATE {
        return Ok(AudioBuffer {
            samples,
            sample_rate: TARGET_SAMPLE_RATE,
            channels: 1,
        });
    }

    let mut resampler = FftFixedIn::<f32>::new(
        buffer.sample_rate as usize,
        TARGET_SAMPLE_RATE as usize,
        1024,
        2,
        1,
    )?;

    let mut output = Vec::new();
    for chunk in samples.chunks(1024) {
        let mut padded = chunk.to_vec();
        if padded.len() < 1024 {
            padded.resize(1024, 0.0);
        }
        let result = resampler.process(&[padded], None)?;
        if let Some(channel) = result.first() {
            output.extend_from_slice(channel);
        }
    }

    Ok(AudioBuffer {
        samples: output,
        sample_rate: TARGET_SAMPLE_RATE,
        channels: 1,
    })
}

/// Mix multi-channel audio down to mono by averaging channels.
fn mix_to_mono(samples: &[f32], channels: u16) -> Vec<f32> {
    let ch = channels as usize;
    samples
        .chunks(ch)
        .map(|frame| frame.iter().sum::<f32>() / ch as f32)
        .collect()
}
