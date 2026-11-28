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
        // Generated exports always have one GameId. Site can refer to the imported
        // original, and trusting the request URL leaves mismatched bodies unchecked.
        let mut lines = first.lines().peekable();
        let (mut returned_id, mut result) = (None, None);
        while let Some(line) = lines.next_if(|line| line.trim_start().starts_with('[')) {
            let tag = line.trim()[1..].trim_start();
            let (name, value) = tag.split_at(tag.find(|c: char| !c.is_ascii_alphanumeric() && c != '_').unwrap_or(tag.len()));
            let (expected_name, slot) = if name.eq_ignore_ascii_case("GameId") {
                ("GameId", &mut returned_id)
            } else if name.eq_ignore_ascii_case("Result") {
                ("Result", &mut result)
            } else {
                continue;
            };
            anyhow::ensure!(slot.is_none(), "Lichess PGN repeats the {expected_name} tag");
            *slot = Some(value.strip_prefix(" \"").and_then(|value| value.strip_suffix("\"]"))
                .filter(|_| name == expected_name)
                .with_context(|| format!("Lichess PGN has an invalid {expected_name} tag"))?);
        }
        let returned_id = returned_id.context("Lichess PGN is missing the GameId tag")?;
        anyhow::ensure!(returned_id == game_id.as_str(), "Lichess returned a different game");
        let result = result.context("Lichess PGN is missing the Result tag")?;
        validate_movetext(lines, result)?;
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

fn validate_movetext<'a>(lines: impl Iterator<Item = &'a str>, result: &str) -> Result<()> {
    // Raw whitespace tokens confuse results with comments. Replaying SAN
    // would make saving the original depend on support for every variant.
    let mut in_comment = false;
    let mut variation_depth = 0_usize;
    let mut saw_result = false;
    for mut line in lines {
        if !in_comment && line.starts_with('%') {
            continue;
        }
        loop {
            if in_comment {
                let Some((_, rest)) = line.split_once('}') else { break };
                line = rest;
                in_comment = false;
            }
            line = line.trim_start();
            let Some(&first) = line.as_bytes().first() else { break };
            match first {
                b';' => break,
                b'{' => {
                    in_comment = true;
                    line = &line[1..];
                    continue;
                }
                b'[' | b']' | b'"' => anyhow::bail!("Lichess PGN has a tag outside the game header"),
                b'}' | b'%' => anyhow::bail!("Lichess PGN has invalid movetext"),
                _ => (),
            }
            anyhow::ensure!(!saw_result, "Lichess PGN has movetext after the final result");
            match first {
                b'(' => variation_depth += 1,
                b')' => {
                    variation_depth = variation_depth.checked_sub(1)
                        .context("Lichess PGN has an unmatched variation")?;
                }
                _ => {
                    let end = if first == b'*' {
                        1
                    } else {
                        line.find(|c: char| c.is_whitespace() || "{}();[]\"%*".contains(c))
                            .unwrap_or(line.len())
                    };
                    let (token, rest) = line.split_at(end);
                    if matches!(token, "1-0" | "0-1" | "1/2-1/2" | "*") {
                        anyhow::ensure!(variation_depth == 0 && token == result,
                            "Lichess PGN is missing a matching final result");
                        saw_result = true;
                    }
                    line = rest;
                    continue;
                }
            }
            line = &line[1..];
        }
    }
    anyhow::ensure!(saw_result && !in_comment && variation_depth == 0,
        "Lichess PGN is missing a matching final result");
    Ok(())
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
    fn keeps_a_single_verified_pgn_byte_for_byte() {
        let game = || PgnGameId::parse("abcd1234".into()).unwrap();
        let valid = b"\xef\xbb\xbf[Event \"Imported game\"]\r\n[Site \"https://lichess.org/else1234\"]\r\n[GameId \"abcd1234\"]\r\n[Result \"1/2-1/2\"]\r\n\r\n1. e4 { [%clk 0:03:00]\r\n[Event \"annotation\"] } e5 ; [text]\r\n1/2-1/2\r\n";
        assert_eq!(PgnExport::from_response(game(), valid.to_vec()).unwrap().bytes, valid);
        let empty = b"[Event \"Aborted\"]\n[GameId \"abcd1234\"]\n[Result \"*\"]\n\n *";
        assert_eq!(PgnExport::from_response(game(), empty.to_vec()).unwrap().bytes, empty);
    }

    #[test]
    fn rejects_pgn_without_exactly_one_matching_header_identity() {
        let game = || PgnGameId::parse("abcd1234".into()).unwrap();
        for tags in [
            "",
            "[GameId \"else1234\"]\n",
            "[GameId \"Abcd1234\"]\n",
            "[gameId \"abcd1234\"]\n",
            "[GameId \"abcd1234\"]\n[GameId \"else1234\"]\n",
            "[GameId \"abcd1234\"]\n[GameId \"abcd1234\"]\n",
            "[GameId \"abcd1234\"]\n[GameId\"else1234\"]\n",
            "[GameId \"abcd1234\"]\n[Result \"0-1\"]\n",
            "[OtherTag \"[GameId \\\"abcd1234\\\"]\"]\n",
        ] {
            let pgn = format!("[Event \"Fixture\"]\n[Site \"https://lichess.org/abcd1234\"]\n{tags}[Result \"1-0\"]\n\n1. e4 e5 1-0");
            assert!(PgnExport::from_response(game(), pgn.into_bytes()).is_err(), "{tags}");
        }
    }

    #[test]
    fn rejects_truncated_or_concatenated_records() {
        let game = || PgnGameId::parse("abcd1234".into()).unwrap();
        let header = "[Event \"Fixture\"]\n[GameId \"abcd1234\"]\n[Result \"1-0\"]\n\n";
        for moves in [
            "1. e4",
            "1. e4 { running comment 1-0",
            "1. e4 ; only a comment 1-0",
            "1. e4\n% private annotation 1-0",
            "1. e4 (1. d4 1-0",
            "1. e4 (1. d4 1-0) 1-0",
            "1. e4 ) 1-0",
            "1. e4 0-1",
            "1. e4 1-0 1-0",
            "1. e4 1-0 e5",
            "1. e4 1-0 { comment never closed",
            "1. e4 1-0\n\n[Event \"Other\"]\n[GameId \"else1234\"]\n[Result \"1-0\"]\n\n1. d4 1-0",
        ] {
            let pgn = format!("{header}{moves}");
            assert!(PgnExport::from_response(game(), pgn.into_bytes()).is_err(), "{moves}");
        }
        assert!(PgnExport::from_response(game(), b"<html>error</html>".to_vec()).is_err());
    }

    #[test]
    fn keeps_comments_and_balanced_variations_around_the_mainline_result() {
        let game = || PgnGameId::parse("abcd1234".into()).unwrap();
        let header = "[Event \"Fixture\"]\r\n[GameId \"abcd1234\"]\r\n[Result \"1-0\"]\r\n\r\n";
        for moves in [
            "1. e4 (1. d4 (1. c4 {score: 0-1 [%clk 0:01:00]}) d5) e5 1-0{Final note.}",
            "1. e4 ; [comment]\r\n% ignore [metadata]\r\ne5 1-0; final note",
            "1. N@f3 {Variant move.} 1-0\r\n% trailing metadata",
        ] {
            let bytes = format!("{header}{moves}").into_bytes();
            assert_eq!(PgnExport::from_response(game(), bytes.clone()).unwrap().bytes, bytes);
        }
    }
}
