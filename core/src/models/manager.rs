use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

/// Metadata about an available model.
#[derive(Debug, Clone, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub backend: String,
    pub variant: String,
    pub description: String,
    pub size_bytes: u64,
    pub url: String,
    pub sha256: String,
}

/// Manages model discovery, download, and lifecycle.
pub struct ModelManager {
    models_dir: PathBuf,
    registry: HashMap<String, ModelInfo>,
}

impl ModelManager {
    pub fn new(models_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(models_dir)?;

        Ok(Self {
            models_dir: models_dir.to_path_buf(),
            registry: HashMap::new(),
        })
    }

    /// Load the model registry from bundled TOML configs.
    pub fn load_registry(&mut self, configs_dir: &Path) -> Result<()> {
        for entry in std::fs::read_dir(configs_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "toml") {
                let content = std::fs::read_to_string(&path)?;
                let info: ModelInfo = toml::from_str(&content)
                    .with_context(|| format!("Failed to parse {}", path.display()))?;
                self.registry.insert(info.name.clone(), info);
            }
        }
        Ok(())
    }

    /// List all known models and whether they're downloaded.
    pub fn list_models(&self) -> Vec<(&ModelInfo, bool)> {
        self.registry
            .values()
            .map(|info| {
                let downloaded = self.model_path(info).exists();
                (info, downloaded)
            })
            .collect()
    }

    /// Get the local path for a model's weights file.
    pub fn model_path(&self, info: &ModelInfo) -> PathBuf {
        self.models_dir.join(&info.name)
    }

    /// Check if a model is downloaded and ready.
    pub fn is_downloaded(&self, name: &str) -> bool {
        self.registry
            .get(name)
            .is_some_and(|info| self.model_path(info).exists())
    }

    /// Download a model. Returns the local path on success.
    ///
    /// TODO: Implement actual HTTP download with progress callback.
    pub fn download(
        &self,
        name: &str,
        _progress: impl Fn(u64, u64),
    ) -> Result<PathBuf> {
        let info = self
            .registry
            .get(name)
            .context(format!("Unknown model: {name}"))?;
        let path = self.model_path(info);

        // TODO: Download from info.url, verify sha256, write to path
        anyhow::bail!("Model download not yet implemented — manually place model at {}", path.display());
    }

    /// Delete a downloaded model to free disk space.
    pub fn delete(&self, name: &str) -> Result<()> {
        let info = self.registry.get(name).context("Unknown model")?;
        let path = self.model_path(info);
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        Ok(())
    }
}
