use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::{Receiver, Sender};

use super::AudioBuffer;

/// Captures audio from the system input device.
pub struct AudioCapture {
    stream: Option<cpal::Stream>,
    receiver: Option<Receiver<Vec<f32>>>,
    /// Shared buffer for streaming — audio callback appends here continuously.
    shared_buffer: Arc<Mutex<Vec<f32>>>,
    device_name: Option<String>,
    sample_rate: u32,
    channels: u16,
}

impl AudioCapture {
    pub fn new(device_name: Option<&str>) -> Result<Self> {
        let host = cpal::default_host();

        let device = match device_name {
            Some(name) => host
                .input_devices()?
                .find(|d| d.name().map(|n| n == name).unwrap_or(false))
                .context(format!("Input device '{name}' not found"))?,
            None => host
                .default_input_device()
                .context("No default input device")?,
        };

        let config = device.default_input_config()?;
        let sample_rate = config.sample_rate().0;
        let channels = config.channels();

        Ok(Self {
            stream: None,
            receiver: None,
            shared_buffer: Arc::new(Mutex::new(Vec::new())),
            device_name: device_name.map(|s| s.to_string()),
            sample_rate,
            channels,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    pub fn start(&mut self) -> Result<()> {
        // Stop any existing stream first.
        self.stream = None;

        let host = cpal::default_host();
        let device = match &self.device_name {
            Some(name) => host
                .input_devices()?
                .find(|d| d.name().map(|n| n == *name).unwrap_or(false))
                .context(format!("Input device '{}' not found", name))?,
            None => host
                .default_input_device()
                .context("No default input device")?,
        };

        let config = device.default_input_config()?;
        self.sample_rate = config.sample_rate().0;
        self.channels = config.channels();

        // Fresh channel and buffer for each recording session.
        let (sender, receiver) = crossbeam_channel::unbounded();
        self.receiver = Some(receiver);
        self.shared_buffer = Arc::new(Mutex::new(Vec::new()));
        let shared_buf = self.shared_buffer.clone();

        let stream = device.build_input_stream(
            &config.into(),
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                let _ = sender.send(data.to_vec());
                // Also append to shared buffer for streaming snapshots.
                if let Ok(mut buf) = shared_buf.lock() {
                    buf.extend_from_slice(data);
                }
            },
            |err| {
                log::error!("Audio capture error: {err}");
            },
            None,
        )?;

        stream.play()?;
        self.stream = Some(stream);
        log::info!("Audio capture started: {}Hz, {} channels", self.sample_rate, self.channels);
        Ok(())
    }

    pub fn stop(&mut self) -> Result<AudioBuffer> {
        // Drop the stream to stop capturing.
        self.stream = None;

        let mut buffer = AudioBuffer::new(self.sample_rate, self.channels);
        if let Some(receiver) = self.receiver.take() {
            while let Ok(chunk) = receiver.try_recv() {
                buffer.samples.extend(chunk);
            }
        }

        log::info!(
            "Audio capture stopped: {:.1}s of audio ({} samples)",
            buffer.duration_secs(),
            buffer.samples.len()
        );
        Ok(buffer)
    }

    /// Get a reference to the shared audio buffer for use by streaming threads.
    pub fn snapshot_buffer(&self) -> Arc<Mutex<Vec<f32>>> {
        self.shared_buffer.clone()
    }

    /// Get a snapshot of all audio captured so far without stopping the stream.
    /// Used for streaming partial transcription.
    pub fn snapshot(&self) -> AudioBuffer {
        let samples = self
            .shared_buffer
            .lock()
            .map(|buf| buf.clone())
            .unwrap_or_default();
        AudioBuffer {
            samples,
            sample_rate: self.sample_rate,
            channels: self.channels,
        }
    }

    /// List available input devices.
    pub fn list_devices() -> Result<Vec<String>> {
        let host = cpal::default_host();
        let devices: Vec<String> = host
            .input_devices()?
            .filter_map(|d| d.name().ok())
            .collect();
        Ok(devices)
    }
}
