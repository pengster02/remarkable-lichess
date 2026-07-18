use serde::de::DeserializeOwned;

/// Lichess NDJSON streams send a blank line periodically as a keep-alive.
/// Returns `None` for blank lines and lines that fail to parse as `T`.
pub fn parse_ndjson_line<T: DeserializeOwned>(line: &str) -> Option<T> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    serde_json::from_str(trimmed).ok()
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
}
