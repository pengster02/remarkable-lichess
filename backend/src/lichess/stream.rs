use serde::de::DeserializeOwned;

/// Lichess NDJSON streams send a blank line periodically as a keep-alive.
/// Returns `None` for blank lines and lines that fail to parse as `T`.
pub fn parse_ndjson_line<T: DeserializeOwned>(line: &str) -> Option<T> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    match serde_json::from_str::<T>(trimmed) {
        Ok(value) => Some(value),
        Err(error) => {
            // A dropped line here used to be completely invisible -- on-device the
            // only symptom was a board that quietly stopped updating. Split the two
            // causes so real trouble isn't buried under normal traffic: malformed
            // JSON (a move/game-over event we should have read but can't) warns;
            // well-formed JSON of a type we simply don't model (e.g. a chatLine on
            // the game stream) stays at debug.
            if serde_json::from_str::<serde_json::Value>(trimmed).is_ok() {
                log::debug!("ignoring unmodeled NDJSON line: {trimmed}");
            } else {
                log::warn!("dropping malformed NDJSON line ({error}): {trimmed}");
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lichess::models::{EventStreamMessage, EventGame};

    #[test]
    fn skips_blank_keepalive_lines() {
        assert!(parse_ndjson_line::<EventStreamMessage>("").is_none());
        assert!(parse_ndjson_line::<EventStreamMessage>("   \n").is_none());
    }

    #[test]
    fn parses_a_valid_line() {
        let line = r#"{"type":"gameStart","game":{"id":"abcd1234"}}"#;
        let parsed: EventStreamMessage = parse_ndjson_line(line).unwrap();
        assert_eq!(parsed, EventStreamMessage::GameStart { game: EventGame { id: "abcd1234".into() } });
    }

    #[test]
    fn returns_none_for_malformed_json() {
        assert!(parse_ndjson_line::<EventStreamMessage>("{not json").is_none());
    }

    #[test]
    fn drops_a_well_formed_but_unmodeled_line() {
        // GameStreamMessage has no catch-all variant, so a well-formed line whose
        // "type" it doesn't model is dropped (at debug, not warn -- see
        // parse_ndjson_line).
        use crate::lichess::models::GameStreamMessage;
        let line = r#"{"type":"someFutureEvent","foo":1}"#;
        assert!(parse_ndjson_line::<GameStreamMessage>(line).is_none());
    }
}
