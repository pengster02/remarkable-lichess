use crate::game::rules::{apply_uci_move, legal_moves, replay_uci_moves};
use crate::lichess::models::{GameFull, GameState};
use crate::protocol::{BackendMessage, LegalMove};
use shakmaty::Chess;

pub struct GameSession {
    pub game_id: String,
    pub initial_fen: String,
    pub position: Chess,
    pub legal: Vec<LegalMove>,
    pub last_move: Option<(String, String)>,
}

fn turn_name(pos: &Chess) -> String {
    use shakmaty::{Color, Position};
    match pos.turn() {
        Color::White => "white".to_string(),
        Color::Black => "black".to_string(),
    }
}

fn to_board_state(session: &GameSession, state: &GameState) -> BackendMessage {
    BackendMessage::BoardState {
        fen: shakmaty::fen::Fen::from_position(&session.position, shakmaty::EnPassantMode::Legal)
            .to_string(),
        turn: turn_name(&session.position),
        white_time_ms: state.wtime,
        black_time_ms: state.btime,
        legal_moves: session.legal.clone(),
        last_move: session.last_move.clone(),
    }
}

fn last_move_from_uci_list(moves: &str) -> Option<(String, String)> {
    let last = moves.split_whitespace().last()?;
    if last.len() < 4 {
        return None;
    }
    Some((last[0..2].to_string(), last[2..4].to_string()))
}

impl GameSession {
    pub fn from_game_full(full: &GameFull) -> anyhow::Result<(Self, BackendMessage)> {
        let position = replay_uci_moves(&full.initial_fen, &full.state.moves)?;
        let legal = legal_moves(&position);
        let last_move = last_move_from_uci_list(&full.state.moves);
        let session = GameSession {
            game_id: full.id.clone(),
            initial_fen: full.initial_fen.clone(),
            position,
            legal,
            last_move,
        };
        let msg = to_board_state(&session, &full.state);
        Ok((session, msg))
    }

    pub fn apply_state_update(&mut self, state: &GameState) -> anyhow::Result<BackendMessage> {
        self.position = replay_uci_moves(&self.initial_fen, &state.moves)?;
        self.legal = legal_moves(&self.position);
        self.last_move = last_move_from_uci_list(&state.moves);
        Ok(to_board_state(self, state))
    }

    /// Returns the UCI string to submit to Lichess, or a MoveRejected message
    /// if `from`/`to`/`promotion` isn't in the cached legal-move list.
    pub fn try_move(
        &self,
        from: &str,
        to: &str,
        promotion: Option<&str>,
    ) -> Result<String, BackendMessage> {
        let found = self
            .legal
            .iter()
            .find(|m| m.from == from && m.to == to && m.promotion.as_deref() == promotion);
        match found {
            Some(_) => {
                let mut uci = format!("{}{}", from, to);
                if let Some(p) = promotion {
                    uci.push_str(p);
                }
                // Defense in depth: confirm shakmaty still accepts it against our cached position
                // before trusting it, in case of a stale-cache race with an opponent move.
                match apply_uci_move(&self.position, &uci) {
                    Ok(_) => Ok(uci),
                    Err(_) => Err(BackendMessage::MoveRejected {
                        reason: "stale board state, please retry".into(),
                    }),
                }
            }
            None => Err(BackendMessage::MoveRejected {
                reason: "not a legal move".into(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lichess::models::GameFull;

    fn sample_full(moves: &str) -> GameFull {
        serde_json::from_value(serde_json::json!({
            "type": "gameFull",
            "id": "g1",
            "rated": false,
            "initialFen": "startpos",
            "clock": {"initial": 600000, "increment": 0},
            "state": {
                "type": "gameState",
                "moves": moves,
                "wtime": 600000,
                "btime": 600000,
                "winc": 0,
                "binc": 0,
                "status": "started",
                "winner": null
            }
        }))
        .unwrap()
    }

    #[test]
    fn from_game_full_produces_board_state_with_twenty_legal_moves() {
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full).unwrap();
        match msg {
            BackendMessage::BoardState { legal_moves, turn, .. } => {
                assert_eq!(legal_moves.len(), 20);
                assert_eq!(turn, "white");
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn try_move_accepts_a_cached_legal_move() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full).unwrap();
        let uci = session.try_move("e2", "e4", None).unwrap();
        assert_eq!(uci, "e2e4");
    }

    #[test]
    fn try_move_rejects_a_move_not_in_the_legal_cache() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full).unwrap();
        let result = session.try_move("e2", "e5", None);
        assert!(matches!(result, Err(BackendMessage::MoveRejected { .. })));
    }

    #[test]
    fn apply_state_update_advances_position_and_last_move() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full).unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4",
            "wtime": 598000,
            "btime": 600000,
            "winc": 0,
            "binc": 0,
            "status": "started",
            "winner": null
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState { last_move, turn, .. } => {
                assert_eq!(last_move, Some(("e2".to_string(), "e4".to_string())));
                assert_eq!(turn, "black");
            }
            _ => panic!("expected BoardState"),
        }
    }
}
