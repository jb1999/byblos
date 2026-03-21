use anyhow::Result;

/// Noise suppression using RNNoise.
///
/// RNNoise is a tiny recurrent neural network that performs real-time
/// noise suppression. It runs at <1% CPU and dramatically improves
/// transcription quality in noisy environments.
pub struct Denoiser {
    // TODO: RNNoise state (via rnnoise-c or custom bindings)
}

impl Denoiser {
    pub fn new() -> Result<Self> {
        // TODO: Initialize RNNoise
        Ok(Self {})
    }

    /// Process audio samples in-place, removing background noise.
    ///
    /// Input must be 16kHz mono f32 samples.
    /// RNNoise operates on 480-sample (30ms) frames.
    pub fn process(&self, samples: &mut [f32]) -> Result<()> {
        let _frame_size = 480; // 30ms at 16kHz

        // TODO: Process each 480-sample frame through RNNoise
        // For now, passthrough — no denoising
        let _ = samples;
        Ok(())
    }
}
