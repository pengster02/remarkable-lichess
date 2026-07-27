use crate::game::rules::{apply_uci_move, legal_moves, replay_uci_game};
use crate::lichess::models::{GameFull, GameState};
use crate::protocol::{BackendMessage, LegalMove};
use shakmaty::Chess;
use std::time::Instant;

pub struct GameSession {
    pub game_id: String,
    pub initial_fen: String,
    pub position: Chess,
    pub legal: Vec<LegalMove>,
    pub last_move: Option<(String, String)>,
    pub your_color: String,
    // SAN per move (e.g. "Nf3", "O-O", "Qxh4#"), in play order. Recomputed
    // wholesale on every update (same as `position` itself) rather than
    // incrementally, since Lichess's own `moves` field is always the full
    // game-so-far string, not a delta -- see replay_uci_moves_with_history.
    pub move_history: Vec<String>,
    pub position_history: Vec<String>,
    pub captured_by_white: Vec<String>,
    pub captured_by_black: Vec<String>,
    // Fixed for the life of the game (unlike everything above) -- computed once
    // from gameFull, not re-derived on every gameState update.
    pub opponent_name: Option<String>,
    pub opponent_rating: Option<u32>,
    pub game_description: String,
    pub rated: bool,
    pub is_tournament: bool,
    pub berserked: bool,
    pub opponent_is_human: bool,
    pub state: GameState,
    // Each side's starting allotment in ms, from GameFull.clock.initial -- fixed
    // for the game's lifetime like opponent_name/opponent_rating above, unlike
    // the live wtime/btime GameState carries every update. Needed (not just the
    // live remaining time) to compute a "low time" fraction of the *original*
    // allotment (e.g. lichess-org/mobile's own ~1/8-of-total clock warning) --
    // remaining time alone can't tell a 10s-left-out-of-600s game apart from a
    // 10s-left-out-of-30s one. None for the rare case a game has no clock at
    // all (correspondence/untimed) rather than assumed.
    pub initial_clock_ms: Option<u64>,
    state_received_at: Instant,
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

/// Whichever side *isn't* your_color -- deliberately independent of
/// resolve_your_color's own id-matching logic (a Player's name/rating are just
/// read off the other side, not re-derived from an id lookup).
fn opponent<'a>(full: &'a GameFull, your_color: &str) -> &'a crate::lichess::models::Player {
    if your_color == "black" { &full.white } else { &full.black }
}

// GameState carries wdraw/bdraw/wtakeback/btakeback for *both* colors; the frontend
// only cares whether *the opponent* has an offer on the table, so fold the your_color
// lookup in here instead of making every caller re-derive it.
fn draw_offered_by_opponent(state: &GameState, your_color: &str) -> bool {
    if your_color == "black" { state.wdraw } else { state.bdraw }
}

fn takeback_offered_by_opponent(state: &GameState, your_color: &str) -> bool {
    if your_color == "black" { state.wtakeback } else { state.btakeback }
}

fn draw_offered_by_you(state: &GameState, your_color: &str) -> bool {
    if your_color == "black" { state.bdraw } else { state.wdraw }
}

fn takeback_offered_by_you(state: &GameState, your_color: &str) -> bool {
    if your_color == "black" { state.btakeback } else { state.wtakeback }
}

fn player_display_name(player: &crate::lichess::models::Player) -> Option<String> {
    if let Some(level) = player.ai_level {
        return Some(format!("Stockfish level {level}"));
    }
    player.name.as_ref().map(|name| match player.title.as_deref() {
        Some(title) => format!("{title} {name}"),
        None => name.clone(),
    })
}

fn elapsed_whole_millis(since: Instant, now: Instant) -> u64 {
    let elapsed = now.saturating_duration_since(since).as_millis();
    u64::try_from(elapsed / 1000 * 1000).unwrap_or(u64::MAX)
}

fn game_description(full: &GameFull) -> String {
    let rating = if full.rated { "Rated" } else { "Casual" };
    let speed = match full.speed.as_deref() {
        Some("ultraBullet") => "UltraBullet",
        Some("bullet") => "Bullet",
        Some("blitz") => "Blitz",
        Some("rapid") => "Rapid",
        Some("classical") => "Classical",
        Some("correspondence") => "Correspondence",
        _ => "Game",
    };
    let mut parts = vec![format!("{rating} {speed}")];
    if full.variant.key != "standard" {
        parts.push(full.variant.name.clone());
    }
    if let Some(clock) = &full.clock {
        let seconds = clock.initial / 1_000;
        let initial = if seconds >= 60 && seconds % 60 == 0 {
            (seconds / 60).to_string()
        } else {
            format!("{seconds}s")
        };
        parts.push(format!("{initial}+{}", clock.increment / 1_000));
    } else if let Some(days) = full.days_per_turn {
        parts.push(format!("{days} days/move"));
    }
    parts.join(" • ")
}

fn to_board_state(session: &GameSession, state: &GameState, now: Instant) -> BackendMessage {
    use shakmaty::Position;
    let move_count = state.moves.split_whitespace().count();
    let draw_by_opponent = draw_offered_by_opponent(state, &session.your_color);
    let takeback_by_opponent = takeback_offered_by_opponent(state, &session.your_color);
    let draw_by_you = draw_offered_by_you(state, &session.your_color);
    let takeback_by_you = takeback_offered_by_you(state, &session.your_color);
    let has_played_full_move = move_count >= 2;
    let has_moved = if session.your_color == "black" {
        move_count >= 2
    } else {
        move_count >= 1
    };
    let elapsed_ms = elapsed_whole_millis(session.state_received_at, now);
    let mut white_time_ms = state.wtime;
    let mut black_time_ms = state.btime;
    if state.status == "started" && session.initial_clock_ms.is_some() {
        match session.position.turn() {
            shakmaty::Color::White => white_time_ms = white_time_ms.saturating_sub(elapsed_ms),
            shakmaty::Color::Black => black_time_ms = black_time_ms.saturating_sub(elapsed_ms),
        }
    }
    let first_move_time_ms = state.expiration.as_ref().map(|expiration| {
        expiration
            .millis_to_move
            .saturating_sub(expiration.idle_millis)
            .saturating_sub(elapsed_ms)
    });
    BackendMessage::BoardState {
        game_id: session.game_id.clone(),
        fen: shakmaty::fen::Fen::from_position(&session.position, shakmaty::EnPassantMode::Legal)
            .to_string(),
        turn: turn_name(&session.position),
        white_time_ms,
        black_time_ms,
        legal_moves: session.legal.clone().into_boxed_slice(),
        last_move: session.last_move.clone().map(Box::new),
        your_color: session.your_color.clone(),
        in_check: session.position.is_check(),
        draw_offered_by_opponent: draw_by_opponent,
        takeback_offered_by_opponent: takeback_by_opponent,
        draw_offered_by_you: draw_by_you,
        takeback_offered_by_you: takeback_by_you,
        can_abort: move_count < 2 && !session.is_tournament,
        can_berserk: session.is_tournament && !session.berserked && !has_moved,
        can_offer_draw: has_played_full_move
            && session.opponent_is_human
            && !draw_by_you
            && !draw_by_opponent,
        can_offer_takeback: has_played_full_move
            && !session.rated
            && !session.is_tournament
            && session.opponent_is_human
            && !takeback_by_you
            && !takeback_by_opponent,
        can_give_time: !session.rated
            && !session.is_tournament
            && session.opponent_is_human
            && session.initial_clock_ms.is_some(),
        can_chat: session.opponent_is_human,
        move_history: session.move_history.clone().into_boxed_slice(),
        position_history: session.position_history.clone().into_boxed_slice(),
        captured_by_white: session.captured_by_white.clone().into_boxed_slice(),
        captured_by_black: session.captured_by_black.clone().into_boxed_slice(),
        opponent_name: session.opponent_name.clone(),
        opponent_rating: session.opponent_rating,
        game_description: session.game_description.clone().into_boxed_str(),
        first_move_time_ms: first_move_time_ms.map(Box::new),
        initial_clock_ms: session.initial_clock_ms.map(Box::new),
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
        anyhow::ensure!(
            matches!(full.variant.key.as_str(), "standard" | "fromPosition"),
            "{} games are not supported yet",
            full.variant.name
        );
        let replay = replay_uci_game(&full.initial_fen, &full.state.moves)?;
        let position = replay.position;
        let legal = legal_moves(&position);
        let last_move = last_move_from_uci_list(&full.state.moves);
        let your_color = resolve_your_color(full, my_id);
        let opp = opponent(full, &your_color);
        let session = GameSession {
            game_id: full.id.clone(),
            initial_fen: full.initial_fen.clone(),
            position,
            legal,
            last_move,
            your_color,
            move_history: replay.move_history,
            position_history: replay.position_history,
            captured_by_white: replay.captured_by_white,
            captured_by_black: replay.captured_by_black,
            opponent_name: player_display_name(opp),
            opponent_rating: opp.rating,
            game_description: game_description(full),
            rated: full.rated,
            is_tournament: full.tournament_id.is_some(),
            berserked: false,
            opponent_is_human: opp.ai_level.is_none() && opp.id.is_some(),
            state: full.state.clone(),
            initial_clock_ms: full.clock.as_ref().map(|c| c.initial),
            state_received_at: Instant::now(),
        };
        let msg = session.board_state();
        Ok((session, msg))
    }

    pub fn board_state(&self) -> BackendMessage {
        self.board_state_at(Instant::now())
    }

    pub fn mark_berserked(&mut self) {
        self.berserked = true;
    }

    fn board_state_at(&self, now: Instant) -> BackendMessage {
        to_board_state(self, &self.state, now)
    }

    pub fn apply_state_update(&mut self, state: &GameState) -> anyhow::Result<BackendMessage> {
        let replay = replay_uci_game(&self.initial_fen, &state.moves)?;
        self.position = replay.position;
        self.move_history = replay.move_history;
        self.position_history = replay.position_history;
        self.captured_by_white = replay.captured_by_white;
        self.captured_by_black = replay.captured_by_black;
        self.legal = legal_moves(&self.position);
        self.last_move = last_move_from_uci_list(&state.moves);
        self.state = state.clone();
        self.state_received_at = Instant::now();
        Ok(self.board_state())
    }

    /// Returns the UCI string to submit to Lichess, or a MoveRejected message
    /// if `from`/`to`/`promotion` isn't in the cached legal-move list.
    pub fn try_move(
        &self,
        from: &str,
        to: &str,
        promotion: Option<&str>,
    ) -> Result<String, Box<BackendMessage>> {
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
                    Err(_) => Err(Box::new(BackendMessage::MoveRejected {
                        reason: "stale board state, please retry".into(),
                    })),
                }
            }
            None => Err(Box::new(BackendMessage::MoveRejected {
                reason: "not a legal move".into(),
            })),
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
            "variant": {"key": "standard", "name": "Standard"},
            "speed": "rapid",
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
            BackendMessage::BoardState { game_id, legal_moves, turn, .. } => {
                assert_eq!(game_id, "g1");
                assert_eq!(legal_moves.len(), 20);
                assert_eq!(turn, "white");
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn move_history_flows_through_to_board_state_and_grows_on_updates() {
        let full = sample_full("e2e4");
        let (mut session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { move_history, position_history, .. } => {
                assert_eq!(&*move_history, ["e4".to_string()]);
                assert_eq!(position_history.len(), 2);
            }
            _ => panic!("expected BoardState"),
        }
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4 e7e5", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState { move_history, position_history, .. } => {
                assert_eq!(&*move_history, ["e4".to_string(), "e5".to_string()]);
                assert_eq!(position_history.len(), 3);
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
        assert!(matches!(result.as_ref().map_err(|b| b.as_ref()), Err(BackendMessage::MoveRejected { .. })));
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
                assert_eq!(*last_move.unwrap(), ("e2".to_string(), "e4".to_string()));
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

    #[test]
    fn opponent_name_and_rating_are_read_from_the_side_that_isnt_your_color() {
        let full: GameFull = serde_json::from_value(serde_json::json!({
            "type": "gameFull",
            "id": "g1",
            "variant": {"key": "standard", "name": "Standard"},
            "speed": "rapid",
            "rated": false,
            "initialFen": "startpos",
            "clock": {"initial": 600000, "increment": 0},
            "white": {"id": "my-id", "name": "MyName", "rating": 1500},
            "black": {"id": "opponent-id", "name": "OpponentName", "rating": 1600},
            "state": {
                "type": "gameState", "moves": "", "wtime": 600000, "btime": 600000,
                "winc": 0, "binc": 0, "status": "started", "winner": null
            }
        }))
        .unwrap();
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { opponent_name, opponent_rating, .. } => {
                assert_eq!(opponent_name, Some("OpponentName".to_string()));
                assert_eq!(opponent_rating, Some(1600));
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn initial_clock_ms_is_read_from_game_full_and_stays_fixed_across_updates() {
        let full = sample_full("");
        let (mut session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { initial_clock_ms, .. } => {
                assert_eq!(initial_clock_ms.as_deref(), Some(&600_000));
            }
            _ => panic!("expected BoardState"),
        }
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4", "wtime": 598000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            // Doesn't drift down with the live clock -- it's the fixed starting
            // allotment, not a re-read of the current remaining time.
            BackendMessage::BoardState { initial_clock_ms, .. } => {
                assert_eq!(initial_clock_ms.as_deref(), Some(&600_000));
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn game_description_uses_stream_speed_and_time_control() {
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { game_description, .. } => {
                assert_eq!(game_description.as_ref(), "Casual Rapid • 10+0");
            }
            _ => panic!("expected BoardState"),
        }

        let mut full = sample_full("");
        full.speed = Some("correspondence".into());
        full.clock = None;
        full.days_per_turn = Some(3);
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { game_description, .. } => {
                assert_eq!(
                    game_description.as_ref(),
                    "Casual Correspondence • 3 days/move"
                );
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn opponent_info_is_absent_without_error_when_the_payload_omits_it() {
        // AI opponents (and this crate's own defensive Option handling) may have
        // no name/rating at all -- shouldn't fail to parse or panic, just None.
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { opponent_name, opponent_rating, .. } => {
                assert_eq!(opponent_name, None);
                assert_eq!(opponent_rating, None);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn ai_level_and_player_title_produce_useful_opponent_names() {
        let mut full = sample_full("");
        full.black.ai_level = Some(3);
        full.black.id = None;
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { opponent_name, .. } => {
                assert_eq!(opponent_name.as_deref(), Some("Stockfish level 3"));
            }
            _ => panic!("expected BoardState"),
        }

        let mut full = sample_full("");
        full.black.name = Some("OpponentName".into());
        full.black.title = Some("GM".into());
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { opponent_name, .. } => {
                assert_eq!(opponent_name.as_deref(), Some("GM OpponentName"));
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn cached_board_state_advances_only_the_active_clock() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let msg = session.board_state_at(
            session.state_received_at + std::time::Duration::from_millis(3_900),
        );
        match msg {
            BackendMessage::BoardState { white_time_ms, black_time_ms, .. } => {
                assert_eq!(white_time_ms, 597_000);
                assert_eq!(black_time_ms, 600_000);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn first_move_expiration_accounts_for_cached_elapsed_time() {
        let mut full = sample_full("");
        full.state.expiration = Some(crate::lichess::models::GameExpiration {
            idle_millis: 4_000,
            millis_to_move: 15_000,
        });
        let (session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let msg = session.board_state_at(
            session.state_received_at + std::time::Duration::from_millis(2_400),
        );
        match msg {
            BackendMessage::BoardState { first_move_time_ms, .. } => {
                assert_eq!(first_move_time_ms.as_deref(), Some(&9_000));
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn unsupported_variants_fail_with_the_variant_name() {
        let mut full = sample_full("");
        full.variant = crate::lichess::models::Variant {
            key: "atomic".into(),
            name: "Atomic".into(),
        };
        let error = GameSession::from_game_full(&full, "my-id").err().unwrap();
        assert_eq!(error.to_string(), "Atomic games are not supported yet");
    }

    #[test]
    fn draw_offer_from_black_surfaces_as_opponent_offer_when_you_are_white() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null, "bdraw": true
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState { draw_offered_by_opponent, takeback_offered_by_opponent, .. } => {
                assert!(draw_offered_by_opponent);
                assert!(!takeback_offered_by_opponent);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn own_draw_offer_does_not_surface_as_an_opponent_offer() {
        // wdraw=true means *you* (white here) offered -- shouldn't flip
        // draw_offered_by_opponent, or a client would show "accept/decline"
        // buttons for its own outgoing offer.
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null, "wdraw": true
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState {
                draw_offered_by_opponent,
                draw_offered_by_you,
                can_offer_draw,
                ..
            } => {
                assert!(!draw_offered_by_opponent);
                assert!(draw_offered_by_you);
                assert!(!can_offer_draw);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn takeback_offer_is_relative_to_your_color_when_playing_black() {
        let full = sample_full("");
        // "opponent-id" is black in sample_full(), so playing as "opponent-id" means
        // you're black and white's wtakeback flag is the *opponent's* offer.
        let (mut session, _msg) = GameSession::from_game_full(&full, "opponent-id").unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null, "wtakeback": true
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState { takeback_offered_by_opponent, .. } => assert!(takeback_offered_by_opponent),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn action_availability_tracks_move_count_and_game_kind() {
        let full = sample_full("e2e4");
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState {
                can_abort,
                can_offer_draw,
                can_offer_takeback,
                can_give_time,
                can_chat,
                ..
            } => {
                assert!(can_abort);
                assert!(!can_offer_draw);
                assert!(!can_offer_takeback);
                assert!(can_give_time);
                assert!(can_chat);
            }
            _ => panic!("expected BoardState"),
        }

        let full = sample_full("e2e4 e7e5");
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState {
                can_abort,
                can_offer_draw,
                can_offer_takeback,
                ..
            } => {
                assert!(!can_abort);
                assert!(can_offer_draw);
                assert!(can_offer_takeback);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn berserk_is_available_until_the_local_players_first_move() {
        let mut full = sample_full("");
        full.tournament_id = Some("arena-id".into());
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { can_berserk, .. } => assert!(can_berserk),
            _ => panic!("expected BoardState"),
        }

        let mut full = sample_full("e2e4");
        full.tournament_id = Some("arena-id".into());
        let (_session, white_msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let (mut black_session, black_msg) =
            GameSession::from_game_full(&full, "opponent-id").unwrap();
        match white_msg {
            BackendMessage::BoardState { can_berserk, .. } => assert!(!can_berserk),
            _ => panic!("expected BoardState"),
        }
        match black_msg {
            BackendMessage::BoardState { can_berserk, .. } => assert!(can_berserk),
            _ => panic!("expected BoardState"),
        }

        black_session.mark_berserked();
        match black_session.board_state() {
            BackendMessage::BoardState { can_berserk, .. } => assert!(!can_berserk),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn cached_board_state_tracks_the_latest_stream_update() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4", "wtime": 598000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null
        }))
        .unwrap();
        session.apply_state_update(&state).unwrap();
        match session.board_state() {
            BackendMessage::BoardState { last_move, white_time_ms, turn, .. } => {
                assert_eq!(*last_move.unwrap(), ("e2".into(), "e4".into()));
                assert_eq!(white_time_ms, 598_000);
                assert_eq!(turn, "black");
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn rated_games_hide_takeback_and_time_gifts() {
        let mut full = sample_full("e2e4 e7e5");
        full.rated = true;
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { can_offer_takeback, can_give_time, can_offer_draw, .. } => {
                assert!(!can_offer_takeback);
                assert!(!can_give_time);
                assert!(can_offer_draw);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn ai_games_hide_negotiation_actions() {
        let mut full = sample_full("e2e4 e7e5");
        full.black.id = None;
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState {
                can_offer_draw,
                can_offer_takeback,
                can_give_time,
                can_chat,
                ..
            } => {
                assert!(!can_offer_draw);
                assert!(!can_offer_takeback);
                assert!(!can_give_time);
                assert!(!can_chat);
            }
            _ => panic!("expected BoardState"),
        }
    }
}
