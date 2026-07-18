use crate::protocol::LegalMove;
use anyhow::{Context, Result};
use shakmaty::{fen::Fen, uci::UciMove, CastlingMode, Chess, Position};

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
}
