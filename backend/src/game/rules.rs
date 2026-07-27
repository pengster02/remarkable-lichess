use crate::protocol::LegalMove;
use anyhow::{Context, Result};
use shakmaty::{
    fen::Fen, san::SanPlus, uci::UciMove, CastlingMode, Chess, Color, EnPassantMode, Position, Role,
};

pub struct GameReplay {
    pub position: Chess,
    pub move_history: Vec<String>,
    pub position_history: Vec<String>,
    pub captured_by_white: Vec<String>,
    pub captured_by_black: Vec<String>,
}

pub struct GameAdvance {
    pub position: Chess,
    pub san: String,
    pub fen: String,
    pub captured_piece: Option<String>,
    pub mover: Color,
}

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
    let replay = replay_uci_game(initial_fen, moves)?;
    Ok((replay.position, replay.move_history))
}

pub fn replay_uci_game(initial_fen: &str, moves: &str) -> Result<GameReplay> {
    let mut pos = starting_position(initial_fen)?;
    let mut history = Vec::new();
    let mut position_history =
        vec![Fen::from_position(&pos, EnPassantMode::Legal).to_string()];
    let mut captured_by_white = Vec::new();
    let mut captured_by_black = Vec::new();
    if moves.trim().is_empty() {
        return Ok(GameReplay {
            position: pos,
            move_history: history,
            position_history,
            captured_by_white,
            captured_by_black,
        });
    }
    for uci_str in moves.split_whitespace() {
        let advance = advance_uci_game(&pos, uci_str)?;
        history.push(advance.san);
        if let Some(code) = advance.captured_piece {
            if advance.mover == Color::White {
                captured_by_white.push(code);
            } else {
                captured_by_black.push(code);
            }
        }
        pos = advance.position;
        position_history.push(advance.fen);
    }
    Ok(GameReplay {
        position: pos,
        move_history: history,
        position_history,
        captured_by_white,
        captured_by_black,
    })
}

pub fn advance_uci_game(pos: &Chess, uci_str: &str) -> Result<GameAdvance> {
    let uci: UciMove = uci_str.parse().context("parsing UCI move")?;
    let m = uci.to_move(pos).context("resolving UCI move against position")?;
    let mover = pos.turn();
    let san = SanPlus::from_move(pos.clone(), m).to_string();
    let captured_piece = m.capture().map(|role| captured_piece_code(mover.other(), role));
    let mut position = pos.clone();
    position.play_unchecked(m);
    let fen = Fen::from_position(&position, EnPassantMode::Legal).to_string();
    Ok(GameAdvance { position, san, fen, captured_piece, mover })
}

fn captured_piece_code(color: Color, role: Role) -> String {
    format!("{}{}", color.char(), role.upper_char())
}

pub fn apply_uci_move(pos: &Chess, uci_str: &str) -> Result<Chess> {
    let uci: UciMove = uci_str.parse().context("parsing UCI move")?;
    let m = uci.to_move(pos).context("resolving UCI move against position")?;
    let mut new_pos = pos.clone();
    new_pos.play_unchecked(m);
    Ok(new_pos)
}

fn analysis_status(position: &Chess) -> &'static str {
    if position.is_checkmate() {
        "checkmate"
    } else if position.is_stalemate() {
        "stalemate"
    } else if position.is_insufficient_material() {
        "insufficient_material"
    } else if position.is_check() {
        "check"
    } else {
        "playing"
    }
}

pub fn analysis_position(fen: &str) -> Result<(String, Vec<LegalMove>, bool, String)> {
    let position = starting_position(fen)?;
    let normalized = Fen::from_position(&position, EnPassantMode::Legal).to_string();
    let status = analysis_status(&position).to_string();
    Ok((normalized, legal_moves(&position), position.is_check(), status))
}

pub fn apply_analysis_move(
    fen: &str,
    from: &str,
    to: &str,
    promotion: Option<&str>,
) -> Result<(String, String, Vec<LegalMove>, bool, String)> {
    let position = starting_position(fen)?;
    let uci_text = format!("{from}{to}{}", promotion.unwrap_or(""));
    let uci: UciMove = uci_text.parse().context("parsing analysis move")?;
    let chess_move = uci.to_move(&position).context("resolving analysis move")?;
    anyhow::ensure!(position.legal_moves().contains(&chess_move), "not a legal move");
    let san = SanPlus::from_move(position.clone(), chess_move).to_string();
    let mut next = position;
    next.play_unchecked(chess_move);
    let next_fen = Fen::from_position(&next, EnPassantMode::Legal).to_string();
    let status = analysis_status(&next).to_string();
    Ok((next_fen, san, legal_moves(&next), next.is_check(), status))
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
    fn history_accepts_cloud_evaluation_castling_notation() {
        let (_, history) = replay_uci_moves_with_history(
            "startpos",
            "e2e4 e7e5 g1f3 b8c6 f1c4 g8f6 e1h1",
        )
        .unwrap();
        assert_eq!(history.last().unwrap(), "O-O");
    }

    #[test]
    fn replay_collects_one_position_per_ply_plus_the_start() {
        let replay = replay_uci_game("startpos", "e2e4 e7e5").unwrap();
        assert_eq!(replay.position_history.len(), 3);
        assert!(replay.position_history[0].starts_with("rnbqkbnr/"));
        assert!(replay.position_history[2].contains(" w "));
    }

    #[test]
    fn history_marks_checkmate_with_hash_suffix() {
        // Fool's Mate: 1. f3 e5 2. g4 Qh4#
        let (_pos, history) =
            replay_uci_moves_with_history("startpos", "f2f3 e7e5 g2g4 d8h4").unwrap();
        assert_eq!(history.last().unwrap(), "Qh4#");
    }

    #[test]
    fn replay_tracks_captures_for_both_sides() {
        let replay = replay_uci_game("startpos", "e2e4 d7d5 e4d5 d8d5").unwrap();
        assert_eq!(replay.captured_by_white, vec!["bP"]);
        assert_eq!(replay.captured_by_black, vec!["wP"]);
    }

    #[test]
    fn replay_tracks_en_passant_as_a_pawn_capture() {
        let replay = replay_uci_game("startpos", "e2e4 a7a6 e4e5 d7d5 e5d6").unwrap();
        assert_eq!(replay.captured_by_white, vec!["bP"]);
        assert!(replay.captured_by_black.is_empty());
    }

    #[test]
    fn analysis_position_returns_legal_moves_for_a_fen() {
        let (fen, moves, in_check, status) = analysis_position(
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        )
        .unwrap();
        assert!(fen.starts_with("rnbqkbnr/"));
        assert_eq!(moves.len(), 20);
        assert!(!in_check);
        assert_eq!(status, "playing");
    }

    #[test]
    fn analysis_move_returns_san_next_fen_and_replies() {
        let (fen, san, moves, in_check, status) = apply_analysis_move(
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "e2",
            "e4",
            None,
        )
        .unwrap();
        assert_eq!(san, "e4");
        assert!(fen.contains(" b "));
        assert_eq!(moves.len(), 20);
        assert!(!in_check);
        assert_eq!(status, "playing");
    }

    #[test]
    fn analysis_move_rejects_illegal_moves() {
        assert!(apply_analysis_move(
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "e2",
            "e5",
            None,
        )
        .is_err());
    }

    #[test]
    fn analysis_move_supports_promotion_and_san() {
        let (fen, san, _, in_check, status) =
            apply_analysis_move("7k/4P3/8/8/8/8/8/K7 w - - 0 1", "e7", "e8", Some("q"))
                .unwrap();
        assert!(san.starts_with("e8=Q"));
        assert!(fen.starts_with("4Q2k/"));
        assert!(in_check);
        assert_eq!(status, "check");
    }

    #[test]
    fn analysis_position_distinguishes_checkmate_and_stalemate() {
        let (_, moves, in_check, status) =
            analysis_position("7k/6Q1/5K2/8/8/8/8/8 b - - 0 1").unwrap();
        assert!(moves.is_empty());
        assert!(in_check);
        assert_eq!(status, "checkmate");

        let (_, moves, in_check, status) =
            analysis_position("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").unwrap();
        assert!(moves.is_empty());
        assert!(!in_check);
        assert_eq!(status, "stalemate");
    }
}
