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
    pub your_color: String,
}

fn turn_name(pos: &Chess) -> String {
    use shakmaty::{Color, Position};
    match pos.turn() {
        Color::White => "white".to_string(),
        Color::Black => "black".to_string(),
    }
}

/// Which color `my_id` is playing in this game. Defaults to "white" unless `my_id`
/// positively matches the black player's id -- a deliberate fallback (rather than
/// erroring out) so a modeling gap or an unexpected payload shape degrades to the
/// old always-white-orientation behavior instead of breaking the game entirely.
fn resolve_your_color(full: &GameFull, my_id: &str) -> String {
    if full.black.id.as_deref() == Some(my_id) {
        "black".to_string()
    } else {
        "white".to_string()
    }
}

fn to_board_state(session: &GameSession, state: &GameState) -> BackendMessage {
    use shakmaty::Position;
    BackendMessage::BoardState {
        fen: shakmaty::fen::Fen::from_position(&session.position, shakmaty::EnPassantMode::Legal)
            .to_string(),
        turn: turn_name(&session.position),
        white_time_ms: state.wtime,
        black_time_ms: state.btime,
        legal_moves: session.legal.clone(),
        last_move: session.last_move.clone(),
        your_color: session.your_color.clone(),
        in_check: session.position.is_check(),
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
    pub fn from_game_full(full: &GameFull, my_id: &str) -> anyhow::Result<(Self, BackendMessage)> {
        let position = replay_uci_moves(&full.initial_fen, &full.state.moves)?;
        let legal = legal_moves(&position);
        let last_move = last_move_from_uci_list(&full.state.moves);
        let session = GameSession {
            game_id: full.id.clone(),
            initial_fen: full.initial_fen.clone(),
            position,
            legal,
            last_move,
            your_color: resolve_your_color(full, my_id),
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
            "white": {"id": "my-id"},
            "black": {"id": "opponent-id"},
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
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
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
        let (session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let uci = session.try_move("e2", "e4", None).unwrap();
        assert_eq!(uci, "e2e4");
    }

    #[test]
    fn try_move_rejects_a_move_not_in_the_legal_cache() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let result = session.try_move("e2", "e5", None);
        assert!(matches!(result, Err(BackendMessage::MoveRejected { .. })));
    }

    #[test]
    fn apply_state_update_advances_position_and_last_move() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
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

    #[test]
    fn your_color_is_black_when_my_id_matches_the_black_player() {
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full, "opponent-id").unwrap();
        match msg {
            BackendMessage::BoardState { your_color, .. } => assert_eq!(your_color, "black"),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn your_color_defaults_to_white_when_my_id_matches_neither_side() {
        // Deliberate fallback behavior (see resolve_your_color's doc comment):
        // an unrecognized id degrades to the old always-white orientation rather
        // than erroring the whole game out.
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full, "someone-else").unwrap();
        match msg {
            BackendMessage::BoardState { your_color, .. } => assert_eq!(your_color, "white"),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn in_check_is_false_at_game_start() {
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { in_check, .. } => assert!(!in_check),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn in_check_is_true_after_a_checking_move() {
        // Fool's Mate: 1. f3 e5 2. g4 Qh4#. `apply_state_update` replays the full
        // move list from `initial_fen` every time (matching how Lichess's real
        // `gameState.moves` field always carries the whole game so far, not a
        // delta), so the test just builds that running string up itself.
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let mut moves_so_far = String::new();
        let mut msg = None;
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
            if !moves_so_far.is_empty() {
                moves_so_far.push(' ');
            }
            moves_so_far.push_str(uci);
            let state: GameState = serde_json::from_value(serde_json::json!({
                "moves": moves_so_far,
                "wtime": 600000,
                "btime": 600000,
                "winc": 0,
                "binc": 0,
                "status": "started",
                "winner": null
            }))
            .unwrap();
            msg = Some(session.apply_state_update(&state).unwrap());
        }
        match msg.unwrap() {
            BackendMessage::BoardState { in_check, .. } => assert!(in_check),
            _ => panic!("expected BoardState"),
        }
    }
}
