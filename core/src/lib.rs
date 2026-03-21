pub mod audio;
pub mod llm;
pub mod models;
pub mod pipeline;
pub mod text;

mod ffi;

use anyhow::Result;

/// Core configuration for a Byblos session.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Config {
    pub model: models::ModelConfig,
    pub audio: audio::AudioConfig,
    pub pipeline: pipeline::PipelineConfig,
}

impl Config {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        Ok(toml::from_str(&content)?)
    }

    pub fn default_config_dir() -> std::path::PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("byblos")
    }

    pub fn default_models_dir() -> std::path::PathBuf {
        dirs::data_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("byblos")
            .join("models")
    }
}
