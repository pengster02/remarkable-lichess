use super::rules::{resolve_uci_move, starting_position, supports_variant};
use crate::protocol::OpeningExplorerData;
use anyhow::{Context, Result};
use shakmaty::{fen::Fen, san::SanPlus, uci::UciMove, Chess, EnPassantMode, Move, Position};
use std::collections::HashMap;

#[derive(Debug)]
pub struct ExportReplay {
    pub fens: Vec<String>,
    pub initial_in_check: bool,
}

pub fn fens_for_moves(moves: &[String]) -> Result<Vec<String>> {
    fens_for_export(None, None, moves)
}

pub fn fens_for_export(
    variant: Option<&str>,
    initial_fen: Option<&str>,
    moves: &[String],
) -> Result<Vec<String>> {
    replay_export(variant, initial_fen, moves).map(|replay| replay.fens)
}

/// Pure, stateless replay of a *finished* game's SAN move list -- deliberately
/// separate from `game::session::GameSession`, which models live, mutable
/// game state (position/legal-moves cache that changes as new moves arrive
/// over the board stream). A finished game's move list never changes once
/// exported, so there's no session to maintain here, just a one-shot replay.
///
/// `GET /api/game/export/{id}` (JSON) returns moves as a space-separated SAN
/// string (confirmed against lichess-org/api's own
/// `games-exportOneGame.json.yaml` example, e.g. `"d4 d5 c4 c6 Nc3 ..."`) --
/// SAN, not UCI, unlike the live board stream's `GameState.moves`. That's why
/// this doesn't reuse `game::rules`'s `replay_uci_moves_with_history`: that
/// helper parses UCI (`e2e4`), which this input never is.
///
/// Returns `fens[0]` as the starting position and `fens[i]` as the position
/// after SAN move `moves[i-1]`, so `fens.len() == moves.len() + 1` -- lets a
/// review screen index directly into this array for Prev/Next/jump-to-move,
/// no re-simulation per step.
///
pub fn replay_export(
    variant: Option<&str>,
    initial_fen: Option<&str>,
    moves: &[String],
) -> Result<ExportReplay> {
    if let Some(variant) = variant {
        anyhow::ensure!(supports_variant(variant), "Review is unavailable for {variant} games");
    }
    // Trust the export's initial position. The normal opening can render a legal
    // but wrong line, and parsing a separate PGN duplicates the JSON export.
    let initial = match initial_fen {
        Some(fen) => starting_position(fen)?,
        None if variant == Some("fromPosition") => anyhow::bail!("The game export is missing its starting position"),
        None => Chess::default(),
    };
    replay_from_position(initial, moves)
}

fn replay_from_position(mut pos: Chess, moves: &[String]) -> Result<ExportReplay> {
    // Capture this while the starting position is parsed. SAN has no preceding
    // move here, and reparsing the first FEN would duplicate validation.
    let initial_in_check = pos.is_check();
    let mut fens = Vec::with_capacity(moves.len() + 1);
    fens.push(fen_string(&pos));
    for san_str in moves {
        let m = resolve_san(&pos, san_str)?;
        pos.play_unchecked(m);
        fens.push(fen_string(&pos));
    }
    Ok(ExportReplay { fens, initial_in_check })
}

fn resolve_san(pos: &Chess, san: &str) -> Result<Move> {
    SanPlus::from_ascii(san.as_bytes())
        .with_context(|| format!("parsing SAN move {san:?}"))?
        .san.to_move(pos)
        .with_context(|| format!("resolving SAN move {san:?} against the current position"))
}

pub struct OpeningExplorerPosition {
    pub root_fen: String,
    pub play: Vec<String>,
    position: Chess,
}

impl OpeningExplorerPosition {
    pub fn from_replay(root_fen: &str, played_san: &[String], shown_fen: &str) -> Result<Self> {
        let mut position = starting_position(root_fen)?;
        let root_fen = fen_string(&position);
        let mut play = Vec::with_capacity(played_san.len());
        for san in played_san {
            let chess_move = resolve_san(&position, san)?;
            play.push(UciMove::from_standard(chess_move).to_string());
            position.play_unchecked(chess_move);
        }
        anyhow::ensure!(
            fen_string(&position) == fen_string(&starting_position(shown_fen)?),
            "opening line does not match the displayed position",
        );
        Ok(Self { root_fen, play, position })
    }

    pub fn normalize_moves(&self, mut data: OpeningExplorerData) -> Result<OpeningExplorerData> {
        let had_moves = !data.moves.is_empty();
        let mut counts_by_move = HashMap::new();
        let mut remaining_counts = [data.white, data.draws, data.black];
        let mut moves = Vec::with_capacity(data.moves.len());
        for mut row in data.moves {
            let Ok(chess_move) = resolve_uci_move(&self.position, &row.uci) else {
                continue;
            };
            // Castling aliases resolve to the same move. Summing can double-count
            // games, and keeping the first conflicting row guesses which is right.
            let counts = [row.white, row.draws, row.black];
            if let Some(previous) = counts_by_move.insert(chess_move, counts) {
                anyhow::ensure!(previous == counts, "conflicting statistics for one opening move");
                continue;
            }
            // The server aggregates all moves before truncating the returned list.
            anyhow::ensure!(counts != [0; 3], "opening move has no recorded games");
            for (remaining, count) in remaining_counts.iter_mut().zip(counts) {
                *remaining = remaining.checked_sub(count).context("opening moves exceed the position totals")?;
            }
            row.uci = UciMove::from_standard(chess_move).to_string();
            row.san = SanPlus::from_move(self.position.clone(), chess_move).to_string();
            moves.push(row);
        }
        anyhow::ensure!(!had_moves || !moves.is_empty(), "no opening moves are legal in this position");
        data.moves = moves;
        Ok(data)
    }
}

fn fen_string(pos: &Chess) -> String {
    Fen::from_position(pos, EnPassantMode::Legal).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_move_list_produces_only_the_starting_position() {
        let fens = fens_for_moves(&[]).unwrap();
        assert_eq!(fens.len(), 1);
        assert!(fens[0].starts_with("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq"));
    }

    #[test]
    fn one_fen_per_ply_plus_the_starting_position() {
        let moves = vec!["e4".to_string(), "e5".to_string(), "Nf3".to_string()];
        let fens = fens_for_moves(&moves).unwrap();
        assert_eq!(fens.len(), 4);
        // After 1. e4, it's Black to move with the e-pawn on e4.
        assert!(fens[1].contains("4P3") && fens[1].contains(" b "));
        // After 1. e4 e5, White to move again.
        assert!(fens[2].contains(" w "));
        // After 1. e4 e5 2. Nf3, Black to move, knight left g1.
        assert!(fens[3].contains(" b "));
    }

    #[test]
    fn opening_explorer_preserves_the_played_path_and_normalizes_castling() {
        let root = "r1bqk2r/ppppbppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1";
        let explorer = OpeningExplorerPosition::from_replay(root, &[], root).unwrap();
        let data: OpeningExplorerData = serde_json::from_value(serde_json::json!({
            "white": 4, "draws": 2, "black": 3,
            "moves": [
                {"san": "O-O", "uci": "e1h1", "white": 4, "draws": 2, "black": 3},
                {"san": "bad", "uci": "a1a8", "white": 0, "draws": 0, "black": 0}
            ]
        })).unwrap();
        let data = explorer.normalize_moves(data).unwrap();
        assert_eq!(data.moves.len(), 1);
        assert_eq!(data.moves[0].uci, "e1g1");
        assert_eq!(data.moves[0].san, "O-O");

        let played = ["O-O".to_owned()];
        let fens = fens_for_export(Some("fromPosition"), Some(root), &played).unwrap();
        let explorer = OpeningExplorerPosition::from_replay(root, &played, &fens[1]).unwrap();
        assert_eq!(explorer.root_fen, root);
        assert_eq!(explorer.play, ["e1g1"]);
        assert!(OpeningExplorerPosition::from_replay(root, &played, root).is_err());
    }

    #[test]
    fn opening_explorer_checks_counts_and_identity_after_resolving_moves() {
        use serde_json::json;

        let root = "r3k2r/ppp1pppp/8/3pP3/8/8/PPPP1PPP/R3K2R w KQkq d6 0 3";
        let explorer = OpeningExplorerPosition::from_replay(root, &[], root).unwrap();
        let data = |moves| serde_json::from_value(json!({"white": 10, "draws": 4, "black": 6, "moves": moves})).unwrap();
        let row = |uci, white, draws, black| json!({"uci": uci, "san": "ignored", "white": white, "draws": draws, "black": black});
        let castle = row("e1h1", 8, 2, 3);
        let en_passant = row("e5d6", 2, 1, 3);
        let illegal = row("h8h7", 0, 0, 0);
        let result = explorer.normalize_moves(data(json!([castle, row("e1g1", 8, 2, 3), illegal, en_passant]))).unwrap();
        assert_eq!(result.moves.iter().map(|row| row.san.as_str()).collect::<Vec<_>>(), ["O-O", "exd6"]);
        assert_eq!(result.moves[0].white, 8);
        assert!(explorer.normalize_moves(data(json!([]))).unwrap().moves.is_empty());
        for (moves, error) in [
            (json!([illegal]), "no opening moves are legal"),
            (json!([castle, row("e1g1", 1, 2, 3)]), "conflicting statistics"),
            (json!([castle, row("e5d6", 3, 2, 3)]), "exceed the position totals"),
            (json!([row("e5d6", u64::MAX, 1, 0)]), "exceed the position totals"),
            (json!([row("e5d6", 0, 0, 0)]), "no recorded games"),
        ] {
            assert!(explorer.normalize_moves(data(moves)).unwrap_err().to_string().contains(error), "{error}");
        }
    }

    #[test]
    fn known_short_game_produces_expected_final_fen() {
        // Scholar's Mate skeleton (not actually mate, just a known short line)
        // used as a fixed-point check against a hand-verified FEN.
        let moves = vec!["e4".to_string(), "e5".to_string(), "Qh5".to_string(), "Nc6".to_string()];
        let fens = fens_for_moves(&moves).unwrap();
        assert_eq!(fens.len(), 5);
        assert_eq!(fens[4], "r1bqkbnr/pppp1ppp/2n5/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 2 3");
    }

    #[test]
    fn checkmate_suffix_in_san_is_accepted() {
        // Fool's Mate: 1. f3 e5 2. g4 Qh4#
        let moves = vec!["f3".to_string(), "e5".to_string(), "g4".to_string(), "Qh4#".to_string()];
        let fens = fens_for_moves(&moves).unwrap();
        assert_eq!(fens.len(), 5);
    }

    #[test]
    fn an_unresolvable_san_move_is_a_clean_error_not_a_panic() {
        let result = fens_for_moves(&["Zz9".to_string()]);
        assert!(result.is_err());
    }

    #[test]
    fn replay_uses_the_exported_black_to_move_position() {
        let initial = "4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17";
        let moves = vec!["e5".into(), "a4".into()];
        let replay = replay_export(Some("fromPosition"), Some(initial), &moves).unwrap();
        assert!(!replay.initial_in_check);
        let fens = replay.fens;
        assert_eq!(fens[0], initial);
        assert_eq!(fens[1], "4k3/8/8/4p3/8/8/P7/4K3 w - - 0 18");
        assert_eq!(fens[2], "4k3/8/8/4p3/P7/8/8/4K3 b - - 0 18");
    }

    #[test]
    fn checked_custom_start_is_reported_before_its_first_reply() {
        let initial = "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2";
        let replay = replay_export(Some("fromPosition"), Some(initial), &["g6".into()]).unwrap();
        assert!(replay.initial_in_check);
        assert_eq!(replay.fens, [
            initial,
            "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3",
        ]);
        assert!(!replay_export(Some("standard"), None, &[]).unwrap().initial_in_check);
    }

    #[test]
    fn an_unknown_variant_or_missing_custom_start_cannot_create_a_wrong_board() {
        assert!(fens_for_export(Some("fromPosition"), None, &[]).is_err());
        assert!(fens_for_export(Some("chess960"), Some("startpos"), &[]).is_err());
        assert_eq!(fens_for_export(Some("standard"), None, &[]).unwrap(), fens_for_moves(&[]).unwrap());
    }
}
