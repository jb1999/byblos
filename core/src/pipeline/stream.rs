use crossbeam_channel::{Receiver, Sender};

/// Events emitted by the streaming pipeline.
#[derive(Debug, Clone)]
pub enum StreamEvent {
    /// Partial transcription (updated as more audio arrives).
    Partial(String),
    /// Final transcription for a speech segment.
    Final(String),
    /// Recording started.
    RecordingStarted,
    /// Recording stopped.
    RecordingStopped,
    /// Error during processing.
    Error(String),
}

/// Streaming transcription pipeline for real-time partial results.
///
/// This runs transcription on overlapping audio chunks to provide
/// live feedback while the user is speaking.
///
/// TODO: Implement streaming inference loop:
/// 1. Accumulate audio in a ring buffer
/// 2. Every ~1s, run inference on the full buffer
/// 3. Emit Partial events with updated text
/// 4. On stop, run final inference and emit Final
pub struct StreamingPipeline {
    event_tx: Sender<StreamEvent>,
    event_rx: Receiver<StreamEvent>,
}

impl StreamingPipeline {
    pub fn new() -> Self {
        let (event_tx, event_rx) = crossbeam_channel::unbounded();
        Self { event_tx, event_rx }
    }

    pub fn events(&self) -> &Receiver<StreamEvent> {
        &self.event_rx
    }

    pub fn event_sender(&self) -> Sender<StreamEvent> {
        self.event_tx.clone()
    }
}
