use crate::game::{replay::{fen_string, play_san}, rules::starting_position};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use shakmaty::Chess;
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
    fn normalize_against(&mut self, archive_fens: &[String]) -> io::Result<()> {
        let mut plies = HashSet::new();
        for position in &mut self.positions {
            let expected = archive_fens.get(position.ply as usize)
                .ok_or_else(|| invalid("variation starts outside the archive"))?;
            let root = starting_position(&position.fen)
                .map_err(|_| invalid("invalid variation starting position"))?;
            if !plies.insert(position.ply) || fen_string(&root) != *expected {
                return Err(invalid("invalid variation starting position"));
            }
            position.fen.clone_from(expected);
            // Reuse verified parent positions. Replaying every prefix repeats
            // work, and using the stored board alone can accept unrelated moves.
            let mut boards: Vec<Chess> = Vec::with_capacity(position.nodes.len());
            for node in &mut position.nodes {
                let parent = match node.parent {
                    Some(parent) => boards.get(parent as usize)
                        .ok_or_else(|| invalid("invalid variation parent"))?,
                    None => &root,
                };
                let mut board = parent.clone();
                let san = play_san(&mut board, &node.san).map_err(|_| invalid("illegal variation move"))?;
                let fen = fen_string(&board);
                if node.fen != fen {
                    let stored = starting_position(&node.fen).map_err(|_| invalid("invalid variation position"))?;
                    if fen_string(&stored) != fen {
                        return Err(invalid("variation move does not reach its stored position"));
                    }
                }
                node.san = san;
                node.fen = fen;
                boards.push(board);
            }
        }
        Ok(())
    }
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

pub fn load(
    config_dir: &Path, account_id: &str, game_id: &str, archive_fens: &[String],
) -> io::Result<ReviewVariations> {
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
    let mut variations: ReviewVariations = serde_json::from_slice(&bytes)?;
    variations.normalize_against(archive_fens)?;
    Ok(variations)
}

pub fn save(
    config_dir: &Path, account_id: &str, game_id: &str, archive_fens: &[String], mut variations: ReviewVariations,
) -> io::Result<()> {
    variations.normalize_against(archive_fens)?;
    let bytes = serde_json::to_vec(&variations)?;
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
        let archive = [START.into(), E4.into(), E5.into()];
        assert_eq!(load(&dir, account, game, &archive).unwrap(), ReviewVariations::default());
        save(&dir, account, game, &archive, variations.clone()).unwrap();
        assert_eq!(load(&dir, account, game, &archive).unwrap(), variations);
        assert_eq!(load(&dir, "bob", game, &archive).unwrap(), ReviewVariations::default());
        assert_eq!(load(&dir, account, "another-game", &archive).unwrap(), ReviewVariations::default());
        let mut invalid = variations.clone();
        invalid.positions[0].nodes[0].parent = Some(1);
        assert!(save(&dir, account, game, &archive, invalid).is_err());
        assert_eq!(load(&dir, account, game, &archive).unwrap(), variations);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn validates_each_move_and_its_root_against_the_same_archive_ply() {
        let archive = [START.into(), E4.into(), E5.into()];
        let valid = ReviewVariations { positions: vec![VariationPosition {
            ply: 1,
            fen: E4.replace(" - 0 1", " e3 0 1"),
            nodes: vec![VariationNode {
                parent: None, san: "e5#".into(), fen: E5.replace(" - 0 2", " e6 0 2"),
            }],
        }] };
        let mut normalized = valid.clone();
        normalized.normalize_against(&archive).unwrap();
        assert_eq!(normalized.positions[0].fen, E4);
        assert_eq!(normalized.positions[0].nodes[0].fen, E5);
        assert_eq!(normalized.positions[0].nodes[0].san, "e5");

        let mut wrong_ply = valid.clone();
        wrong_ply.positions[0].ply = 2;
        let mut outside_archive = valid.clone();
        outside_archive.positions[0].ply = 3;
        let mut wrong_fen = valid.clone();
        wrong_fen.positions[0].nodes[0].fen = D4.into();
        let mut wrong_counter = valid.clone();
        wrong_counter.positions[0].nodes[0].fen = E5.replace("0 2", "1 2");
        let mut illegal_move = valid.clone();
        illegal_move.positions[0].nodes[0].san = "e4".into();
        let mut duplicate_root = valid.clone();
        duplicate_root.positions.push(normalized.positions[0].clone());

        for mut invalid_tree in [wrong_ply, outside_archive, wrong_fen, wrong_counter, illegal_move, duplicate_root] {
            assert_eq!(invalid_tree.normalize_against(&archive).unwrap_err().kind(), io::ErrorKind::InvalidData);
        }
    }
}
