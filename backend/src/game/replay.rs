use super::rules::{starting_position, supports_variant};
use anyhow::{Context, Result};
use shakmaty::{fen::Fen, san::SanPlus, Chess, EnPassantMode, Position};

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
pub fn fens_for_moves(moves: &[String]) -> Result<Vec<String>> {
    fens_from_position(Chess::default(), moves)
}

pub fn fens_for_export(
    variant: Option<&str>,
    initial_fen: Option<&str>,
    moves: &[String],
) -> Result<Vec<String>> {
    if let Some(variant) = variant {
        anyhow::ensure!(supports_variant(variant), "Review is unavailable for {variant} games");
    }
    // Trust the export's initial position. The normal opening can render a legal
    // but wrong line, and parsing a separate PGN duplicates the JSON export.
    match initial_fen {
        Some(fen) => fens_from_position(starting_position(fen)?, moves),
        None if variant == Some("fromPosition") => anyhow::bail!("The game export is missing its starting position"),
        None => fens_for_moves(moves),
    }
}

fn fens_from_position(mut pos: Chess, moves: &[String]) -> Result<Vec<String>> {
    let mut fens = Vec::with_capacity(moves.len() + 1);
    fens.push(fen_string(&pos));
    for san_str in moves {
        let san_plus = SanPlus::from_ascii(san_str.as_bytes())
            .with_context(|| format!("parsing SAN move {san_str:?}"))?;
        let m = san_plus
            .san
            .to_move(&pos)
            .with_context(|| format!("resolving SAN move {san_str:?} against the current position"))?;
        pos.play_unchecked(m);
        fens.push(fen_string(&pos));
    }
    Ok(fens)
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
        let fens = fens_for_export(Some("fromPosition"), Some(initial), &moves).unwrap();
        assert_eq!(fens[0], initial);
        assert_eq!(fens[1], "4k3/8/8/4p3/8/8/P7/4K3 w - - 0 18");
        assert_eq!(fens[2], "4k3/8/8/4p3/P7/8/8/4K3 b - - 0 18");
    }

    #[test]
    fn an_unknown_variant_or_missing_custom_start_cannot_create_a_wrong_board() {
        assert!(fens_for_export(Some("fromPosition"), None, &[]).is_err());
        assert!(fens_for_export(Some("chess960"), Some("startpos"), &[]).is_err());
        assert_eq!(fens_for_export(Some("standard"), None, &[]).unwrap(), fens_for_moves(&[]).unwrap());
    }
}
