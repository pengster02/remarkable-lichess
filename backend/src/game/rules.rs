use crate::protocol::LegalMove;
use anyhow::{Context, Result};
use shakmaty::{fen::Fen, san::SanPlus, uci::UciMove, CastlingMode, Chess, Position};

pub fn legal_moves(pos: &Chess) -> Vec<LegalMove> {
    pos.legal_moves()
        .iter()
        .map(|m| {
            let uci = UciMove::from_standard(*m);
            let s = uci.to_string();
            // UCI squares are always the first four characters, e.g. "e2e4" or "e7e8q"
            let from = s[0..2].to_string();
            let to = s[2..4].to_string();
            let promotion = if s.len() > 4 { Some(s[4..5].to_string()) } else { None };
            LegalMove { from, to, promotion }
        })
        .collect()
}

pub fn starting_position(initial_fen: &str) -> Result<Chess> {
    if initial_fen == "startpos" {
        return Ok(Chess::default());
    }
    let fen: Fen = initial_fen.parse().context("parsing initial FEN")?;
    fen.into_position(CastlingMode::Standard).context("building position from FEN")
}

pub fn replay_uci_moves(initial_fen: &str, moves: &str) -> Result<Chess> {
    let mut pos = starting_position(initial_fen)?;
    if moves.trim().is_empty() {
        return Ok(pos);
    }
    for uci_str in moves.split_whitespace() {
        pos = apply_uci_move(&pos, uci_str)?;
    }
    Ok(pos)
}

/// Same replay as `replay_uci_moves`, but also collects each move's SAN (e.g.
/// "Nf3", "O-O", "Qxh4#") -- computed once here rather than twice (once to reach
/// the final position, once more to re-derive notation), matching a move list
/// found in trevorbayless/cli-chess (a real terminal Lichess Board API client,
/// the closest reference point for this project's own resource constraints) as
/// a genuinely useful, cheap-on-redraws feature: it's appended to once per move,
/// not something recomputed or ticking every frame.
pub fn replay_uci_moves_with_history(initial_fen: &str, moves: &str) -> Result<(Chess, Vec<String>)> {
    let mut pos = starting_position(initial_fen)?;
    let mut history = Vec::new();
    if moves.trim().is_empty() {
        return Ok((pos, history));
    }
    for uci_str in moves.split_whitespace() {
        let uci: UciMove = uci_str.parse().context("parsing UCI move")?;
        let m = uci.to_move(&pos).context("resolving UCI move against position")?;
        history.push(SanPlus::from_move(pos.clone(), m).to_string());
        pos.play_unchecked(m);
    }
    Ok((pos, history))
}

pub fn apply_uci_move(pos: &Chess, uci_str: &str) -> Result<Chess> {
    let uci: UciMove = uci_str.parse().context("parsing UCI move")?;
    let m = uci.to_move(pos).context("resolving UCI move against position")?;
    let mut new_pos = pos.clone();
    new_pos.play_unchecked(m);
    Ok(new_pos)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starting_position_has_twenty_legal_moves() {
        let pos = starting_position("startpos").unwrap();
        assert_eq!(legal_moves(&pos).len(), 20);
    }

    #[test]
    fn replaying_two_moves_produces_expected_position() {
        let pos = replay_uci_moves("startpos", "e2e4 e7e5").unwrap();
        // After 1. e4 e5, it's White to move again with 29 legal replies (known good position).
        assert_eq!(legal_moves(&pos).len(), 29);
    }

    #[test]
    fn illegal_uci_move_is_rejected() {
        let pos = starting_position("startpos").unwrap();
        assert!(apply_uci_move(&pos, "e2e5").is_err());
    }

    #[test]
    fn history_collects_san_for_each_move_in_order() {
        let (_pos, history) = replay_uci_moves_with_history("startpos", "e2e4 e7e5 g1f3").unwrap();
        assert_eq!(history, vec!["e4".to_string(), "e5".to_string(), "Nf3".to_string()]);
    }

    #[test]
    fn history_marks_checkmate_with_hash_suffix() {
        // Fool's Mate: 1. f3 e5 2. g4 Qh4#
        let (_pos, history) =
            replay_uci_moves_with_history("startpos", "f2f3 e7e5 g2g4 d8h4").unwrap();
        assert_eq!(history.last().unwrap(), "Qh4#");
    }
}
