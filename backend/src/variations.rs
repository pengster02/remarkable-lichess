use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

// AppLoad sends each JSON payload as one Unix socket packet.
const MAX_SNAPSHOT_BYTES: usize = 96 * 1024;

#[derive(Debug, Default, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ReviewVariations {
    pub positions: Vec<VariationPosition>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct VariationPosition {
    pub ply: u32,
    pub fen: String,
    pub nodes: Vec<VariationNode>,
}

// Earlier parent indices share prefixes and rule out cycles. Entire lines
// duplicate prefixes, while FEN keys merge distinct paths and repeated positions.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct VariationNode {
    pub parent: Option<u32>,
    pub san: String,
    pub fen: String,
}

impl ReviewVariations {
    fn validate(&self) -> io::Result<()> {
        let mut plies = HashSet::new();
        for position in &self.positions {
            if !plies.insert((position.ply, &position.fen)) || !valid_fen(&position.fen) {
                return Err(invalid("invalid variation starting position"));
            }
            for (index, node) in position.nodes.iter().enumerate() {
                if node.parent.is_some_and(|parent| parent as usize >= index)
                    || !valid_fen(&node.fen) || node.san.parse::<shakmaty::san::SanPlus>().is_err()
                {
                    return Err(invalid("invalid variation move"));
                }
            }
        }
        Ok(())
    }
}

fn valid_fen(fen: &str) -> bool {
    fen.parse::<shakmaty::fen::Fen>().is_ok()
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn path(config_dir: &Path, account_id: &str, game_id: &str) -> PathBuf {
    // Per-game hashes avoid exposing identifiers in paths or rewriting an account-wide file.
    let mut key = Sha256::new();
    key.update((account_id.len() as u64).to_be_bytes());
    key.update(account_id.as_bytes());
    key.update(game_id.as_bytes());
    config_dir.join("review-variations-v1").join(format!("{:x}.json", key.finalize()))
}

pub fn load(config_dir: &Path, account_id: &str, game_id: &str) -> io::Result<ReviewVariations> {
    let file = match File::open(path(config_dir, account_id, game_id)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(ReviewVariations::default()),
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take((MAX_SNAPSHOT_BYTES + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > MAX_SNAPSHOT_BYTES {
        return Err(invalid("saved variations exceed the supported size"));
    }
    let variations: ReviewVariations = serde_json::from_slice(&bytes)?;
    variations.validate()?;
    Ok(variations)
}

pub fn save(
    config_dir: &Path, account_id: &str, game_id: &str, variations: &ReviewVariations,
) -> io::Result<()> {
    variations.validate()?;
    let bytes = serde_json::to_vec(variations)?;
    if bytes.len() > MAX_SNAPSHOT_BYTES {
        return Err(invalid("saved variations exceed the supported size"));
    }
    let file = path(config_dir, account_id, game_id);
    fs::create_dir_all(file.parent().expect("variation file has a parent"))?;
    crate::storage::replace(&file, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const START: &str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    const E4: &str = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1";
    const E5: &str = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2";
    const D4: &str = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1";

    #[test]
    fn saves_a_fork_by_account_and_game_and_rejects_a_cyclic_replacement() {
        let mut random = [0; 8];
        getrandom::fill(&mut random).unwrap();
        let dir = std::env::temp_dir().join(format!("rm-lichess-variations-{:x}", u64::from_ne_bytes(random)));
        let variations = ReviewVariations { positions: vec![VariationPosition {
            ply: 0, fen: START.to_string(), nodes: vec![
                VariationNode { parent: None, san: "e4".into(), fen: E4.into() },
                VariationNode { parent: Some(0), san: "e5".into(), fen: E5.into() },
                VariationNode { parent: None, san: "d4".into(), fen: D4.into() },
            ],
        }] };
        let account = "alice";
        let game = "example";
        assert_eq!(load(&dir, account, game).unwrap(), ReviewVariations::default());
        save(&dir, account, game, &variations).unwrap();
        assert_eq!(load(&dir, account, game).unwrap(), variations);
        assert_eq!(load(&dir, "bob", game).unwrap(), ReviewVariations::default());
        assert_eq!(load(&dir, account, "another-game").unwrap(), ReviewVariations::default());
        let mut invalid = variations.clone();
        invalid.positions[0].nodes[0].parent = Some(1);
        assert!(save(&dir, account, game, &invalid).is_err());
        assert_eq!(load(&dir, account, game).unwrap(), variations);
        fs::remove_dir_all(dir).unwrap();
    }
}
