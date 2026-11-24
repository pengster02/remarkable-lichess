use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AppSettings {
    #[serde(default)]
    pub dark_mode: bool,
    #[serde(default)]
    pub auto_queen_promotion: bool,
    // Confirmed shipped in the official lichess-org/mobile app (its own
    // `moveToConfirm`/`confirmMove()`/`cancelMove()`, default off there too),
    // not a made-up setting. Default
    // off here for the same reason: a forced second tap on every single move
    // is a real cost, not just a safety net.
    #[serde(default)]
    pub move_confirmation: bool,
    // E-ink-specific: full legal-destination spray can damage ~28 squares per
    // tap. Default on so selection only refreshes the chosen square; users who
    // want destinations can turn this off in Settings.
    #[serde(default = "default_true")]
    pub minimal_highlights: bool,
    #[serde(default)]
    pub premoves_enabled: bool,
    #[serde(default = "default_true")]
    pub live_clock_enabled: bool,
    #[serde(default = "default_board_theme")]
    pub board_theme: String,
    #[serde(default = "default_piece_set")]
    pub piece_set: String,
    // Board display toggles -- all default on (the app's existing behavior) so an
    // upgrade doesn't silently hide anything; off is opt-in per user.
    #[serde(default = "default_true")]
    pub show_coordinates: bool,
    #[serde(default = "default_true")]
    pub show_captured_pieces: bool,
    #[serde(default = "default_true")]
    pub highlight_last_move: bool,
    // Extra guard on resign/abort, on top of the existing two-tap. Default off:
    // the two-tap already covers the common misfire, this is belt-and-suspenders.
    #[serde(default)]
    pub confirm_resign: bool,
}

fn default_true() -> bool {
    true
}

fn default_board_theme() -> String {
    "brown".to_owned()
}

fn default_piece_set() -> String {
    "cburnett".to_owned()
}

pub fn normalize_board_theme(value: &str) -> String {
    match value {
        "brown" | "blue" | "green" | "mono" => value.to_owned(),
        _ => default_board_theme(),
    }
}

pub fn normalize_piece_set(value: &str) -> String {
    match value {
        "cburnett" | "merida" | "chessnut" => value.to_owned(),
        _ => default_piece_set(),
    }
}

impl AppSettings {
    pub fn normalized(mut self) -> Self {
        self.board_theme = normalize_board_theme(&self.board_theme);
        self.piece_set = normalize_piece_set(&self.piece_set);
        self
    }
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            dark_mode: false,
            auto_queen_promotion: false,
            move_confirmation: false,
            minimal_highlights: true,
            premoves_enabled: false,
            live_clock_enabled: true,
            board_theme: default_board_theme(),
            piece_set: default_piece_set(),
            show_coordinates: true,
            show_captured_pieces: true,
            highlight_last_move: true,
            confirm_resign: false,
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
        .map(AppSettings::normalized)
        .unwrap_or_default()
}

pub fn save(path: &Path, settings: &AppSettings) -> std::io::Result<()> {
    let json = serde_json::to_vec(&settings.clone().normalized()).expect("AppSettings always serializes");
    crate::storage::replace(path, &json)
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
    fn defaults_to_minimal_highlights_on() {
        assert!(AppSettings::default().minimal_highlights);
    }

    #[test]
    fn older_settings_default_minimal_highlights_on() {
        let settings: AppSettings =
            serde_json::from_str(r#"{"auto_queen_promotion":true}"#).unwrap();
        assert!(settings.minimal_highlights);
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
    fn defaults_to_light_brown_cburnett_appearance() {
        let settings = AppSettings::default();
        assert!(!settings.dark_mode);
        assert_eq!(settings.board_theme, "brown");
        assert_eq!(settings.piece_set, "cburnett");
    }

    #[test]
    fn older_appearance_settings_keep_the_light_default() {
        let settings: AppSettings =
            serde_json::from_str(r#"{"board_theme":"green","piece_set":"merida"}"#).unwrap();
        assert!(!settings.dark_mode);
        assert_eq!(settings.board_theme, "green");
        assert_eq!(settings.piece_set, "merida");
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
            move_confirmation: true,
            ..AppSettings::default()
        };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), settings);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn save_then_load_round_trips_minimal_highlights() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-minimal-highlights.json");
        let settings = AppSettings {
            minimal_highlights: true,
            ..AppSettings::default()
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
            dark_mode: true,
            auto_queen_promotion: true,
            premoves_enabled: true,
            live_clock_enabled: false,
            board_theme: "green".to_owned(),
            piece_set: "merida".to_owned(),
            ..AppSettings::default()
        };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), settings);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn an_open_settings_reader_keeps_its_complete_previous_version() {
        let path = std::env::temp_dir().join(format!(
            "remarkable-lichess-settings-atomic-test-{}.json",
            std::process::id()
        ));
        let previous = AppSettings::default();
        save(&path, &previous).unwrap();
        let existing_reader = std::fs::File::open(&path).unwrap();
        let next = AppSettings {
            premoves_enabled: true,
            ..AppSettings::default()
        };

        save(&path, &next).unwrap();

        assert_eq!(serde_json::from_reader::<_, AppSettings>(existing_reader).unwrap(), previous);
        assert_eq!(load(&path), next);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn load_returns_defaults_for_corrupt_json() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-corrupt.json");
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(load(&path), AppSettings::default());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn load_normalizes_unknown_appearance_ids() {
        let path = std::env::temp_dir().join("remarkable-lichess-settings-test-invalid-appearance.json");
        std::fs::write(&path, r#"{"board_theme":"../../bad","piece_set":"unknown"}"#).unwrap();
        assert_eq!(load(&path), AppSettings::default());
        let _ = std::fs::remove_file(&path);
    }
}
