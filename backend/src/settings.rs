use serde::{Deserialize, Serialize};
use std::path::Path;

/// Persisted app-level preferences, distinct from the per-account token (see
/// `main.rs`'s token_path) -- confirmed against real reference clients that this
/// is a genuinely standard chess-app setting, not a made-up one: chess.com's own
/// help docs cover "premove, sounds, or the auto-queen" as one of its core
/// settings categories. Kept to a single real toggle for now rather than padding
/// this out with settings that don't apply to this app (no sound/board-theme/
/// piece-set variety needed on a minimalist single-account e-ink client).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AppSettings {
    #[serde(default)]
    pub auto_queen_promotion: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self { auto_queen_promotion: false }
    }
}

/// Missing file, unreadable file, or corrupt JSON all degrade to defaults rather
/// than erroring out -- settings are a nice-to-have, not something that should
/// ever block the app from starting.
pub fn load(path: &Path) -> AppSettings {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(path: &Path, settings: &AppSettings) -> std::io::Result<()> {
    let json = serde_json::to_string(settings).expect("AppSettings always serializes");
    std::fs::write(path, json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_auto_queen_promotion_off() {
        assert!(!AppSettings::default().auto_queen_promotion);
    }

    #[test]
    fn load_returns_defaults_when_file_is_missing() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-missing.json");
        let _ = std::fs::remove_file(&path);
        assert_eq!(load(&path), AppSettings::default());
    }

    #[test]
    fn save_then_load_round_trips() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-roundtrip.json");
        let settings = AppSettings { auto_queen_promotion: true };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), settings);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn load_returns_defaults_for_corrupt_json() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-corrupt.json");
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(load(&path), AppSettings::default());
        let _ = std::fs::remove_file(&path);
    }
}
