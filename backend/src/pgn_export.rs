use anyhow::{Context, Result};
use std::io;
use std::path::{Path, PathBuf};

// The export contract gives the same ID to the URL and filename. A raw ID can
// escape either path. Sanitizing it could map two games to one export.
pub struct PgnGameId(String);

impl PgnGameId {
    pub fn parse(id: String) -> Option<Self> {
        (id.len() == 8 && id.bytes().all(|byte| byte.is_ascii_alphanumeric())).then_some(Self(id))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub struct PgnExport {
    game_id: PgnGameId,
    bytes: Vec<u8>,
}

impl PgnExport {
    pub fn from_response(game_id: PgnGameId, bytes: Vec<u8>) -> Result<Self> {
        let text = std::str::from_utf8(&bytes).context("opening game PGN as UTF-8")?;
        let first = text.trim_start_matches('\u{feff}').trim_start();
        anyhow::ensure!(first.starts_with("[Event "), "Lichess returned an invalid PGN");
        let tag = |name: &str| {
            let prefix = format!("[{name} \"");
            first.lines().take_while(|line| line.starts_with('['))
                .find_map(|line| line.strip_prefix(&prefix)?.strip_suffix("\"]"))
        };
        if let Some(returned_id) = tag("GameId") {
            anyhow::ensure!(returned_id == game_id.as_str(), "Lichess returned a different game");
        }
        let result = tag("Result").context("Lichess PGN is missing the result tag")?;
        anyhow::ensure!(
            matches!(result, "1-0" | "0-1" | "1/2-1/2" | "*") &&
                first.split_whitespace().last() == Some(result),
            "Lichess PGN is missing a matching final result",
        );
        Ok(Self { game_id, bytes })
    }

    pub fn save(&self, config_dir: &Path) -> io::Result<PathBuf> {
        let exports = config_dir.join("exports");
        std::fs::create_dir_all(&exports)?;
        let destination = exports.join(format!("{}.pgn", self.game_id.as_str()));
        crate::storage::replace(&destination, &self.bytes)?;
        Ok(destination)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_canonical_game_ids_can_name_an_export() {
        assert!(PgnGameId::parse("aB03cdEF".into()).is_some());
        for id in ["short", "abcdefgh1234", "xy/12abc", "../abcde", "aBcdef%0"] {
            assert!(PgnGameId::parse(id.into()).is_none(), "{id}");
        }
    }

    #[test]
    fn keeps_pgn_bytes_and_rejects_a_mismatched_game_tag() {
        let game = || PgnGameId::parse("abcd1234".into()).unwrap();
        let valid = b"\xef\xbb\xbf[Event \"Casual game\"]\r\n[GameId \"abcd1234\"]\r\n[Result \"1/2-1/2\"]\r\n\r\n1. e4 { [%clk 0:03:00] } e5 1/2-1/2\r\n";
        assert_eq!(PgnExport::from_response(game(), valid.to_vec()).unwrap().bytes, valid);
        assert!(PgnExport::from_response(game(), br#"[Event "x"]
[GameId "else1234"]"#.to_vec()).is_err());
        assert!(PgnExport::from_response(game(), b"<html>error</html>".to_vec()).is_err());
        assert!(PgnExport::from_response(game(), b"[Event \"x\"]\n[Result \"1-0\"]\n\n1. e4".to_vec()).is_err());
    }
}
