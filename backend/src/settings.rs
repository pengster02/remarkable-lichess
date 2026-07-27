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
    // Confirmed shipped in the official lichess-org/mobile app (its own
    // `moveToConfirm`/`confirmMove()`/`cancelMove()`, default off there too --
    // see docs/ui-strategy-2026-07-21.md's P2), not a made-up setting. Default
    // off here for the same reason: a forced second tap on every single move
    // is a real cost, not just a safety net.
    #[serde(default)]
    pub move_confirmation: bool,
    // E-ink-specific, not a mainstream-chess-client setting like the two
    // above -- tap-to-select highlights every legal destination square (up
    // to ~28 of them scattered across the board) in addition to the
    // selected square itself, each one real redraw damage on a display
    // where that's a slower, more visible cost than on an LCD. Default off
    // (full highlighting is the more helpful default; this trades some of
    // that away for speed once someone actually wants the tradeoff).
    #[serde(default)]
    pub minimal_highlights: bool,
    #[serde(default)]
    pub premoves_enabled: bool,
    #[serde(default = "default_true")]
    pub live_clock_enabled: bool,
}

fn default_true() -> bool {
    true
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            auto_queen_promotion: false,
            move_confirmation: false,
            minimal_highlights: false,
            premoves_enabled: false,
            live_clock_enabled: true,
        }
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
    fn defaults_to_move_confirmation_off() {
        assert!(!AppSettings::default().move_confirmation);
    }

    #[test]
    fn defaults_to_minimal_highlights_off() {
        assert!(!AppSettings::default().minimal_highlights);
    }

    #[test]
    fn defaults_to_premoves_off() {
        assert!(!AppSettings::default().premoves_enabled);
    }

    #[test]
    fn defaults_to_live_clock_on() {
        assert!(AppSettings::default().live_clock_enabled);
    }

    #[test]
    fn older_settings_default_live_clock_on() {
        let settings: AppSettings =
            serde_json::from_str(r#"{"auto_queen_promotion":true}"#).unwrap();
        assert!(settings.live_clock_enabled);
    }

    #[test]
    fn save_then_load_round_trips_move_confirmation() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-move-confirmation.json");
        let settings = AppSettings {
            auto_queen_promotion: false,
            move_confirmation: true,
            minimal_highlights: false,
            premoves_enabled: false,
            live_clock_enabled: true,
        };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), settings);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn save_then_load_round_trips_minimal_highlights() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-minimal-highlights.json");
        let settings = AppSettings {
            auto_queen_promotion: false,
            move_confirmation: false,
            minimal_highlights: true,
            premoves_enabled: false,
            live_clock_enabled: true,
        };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), settings);
        let _ = std::fs::remove_file(&path);
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
        let settings = AppSettings {
            auto_queen_promotion: true,
            move_confirmation: false,
            minimal_highlights: false,
            premoves_enabled: true,
            live_clock_enabled: false,
        };
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
