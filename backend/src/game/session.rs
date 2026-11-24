use crate::game::outcome::outcome;
use crate::game::rules::{advance_uci_game, apply_uci_move, legal_moves, replay_uci_game, supports_variant};
use crate::lichess::models::{GameFull, GameState};
use crate::protocol::{
    BackendMessage, GameAction, GameActionRequest, LegalMove, OfferIntent, OfferRequest,
    OpponentDeparture, PlayerIdentity, PlayerStatusSummary, PositionId,
};
use shakmaty::{Chess, Position};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;
use tokio::sync::oneshot;

struct PendingMove {
    request_id: Option<u32>,
    // Closing this channel cancels the HTTP wait. A flag leaves it running and an IPC cancel can arrive out of order.
    _cancel_on_drop: oneshot::Sender<()>,
}

struct PendingGameAction {
    request: GameActionRequest,
    // Keep the action through reconnects and drop it with the session. A detached POST can reply after teardown; a queue can replay duplicate gestures.
    _cancel_on_drop: oneshot::Sender<()>,
}

pub struct GameSession {
    pub game_id: String,
    pub position_id: PositionId,
    // A POST or cached resume can publish a board while its stream is down.
    // Treating any board as recovery, or sending an independent recovery event,
    // could leave the UI showing a connection that the snapshot did not have.
    game_stream_connected: bool,
    pub opponent_departure: Option<OpponentDeparture>,
    prior_moves_before_prediction: Option<String>,
    pending_move: Option<PendingMove>,
    pending_game_action: Option<PendingGameAction>,
    pub initial_fen: String,
    initial_in_check: bool,
    pub position: Chess,
    pub legal: Vec<LegalMove>,
    pub last_move: Option<(String, String)>,
    pub your_color: String,
    // SAN per move (e.g. "Nf3", "O-O", "Qxh4#"), in play order.
    pub move_history: Vec<String>,
    pub position_history: Vec<String>,
    pub captured_by_white: Vec<String>,
    pub captured_by_black: Vec<String>,
    // Fixed for the life of the game (unlike everything above) -- computed once
    // from gameFull, not re-derived on every gameState update.
    pub your_player: PlayerIdentity,
    pub opponent_player: PlayerIdentity,
    your_rating_diff: Option<i32>,
    // A session snapshot avoids refetching on resume and keeps status out of
    // frequent BoardState updates. None means the lookup has yet to succeed.
    pub player_statuses: Option<Box<[PlayerStatusSummary]>>,
    pub game_description: String,
    pub rated: bool,
    pub is_tournament: bool,
    pub berserked: bool,
    pub opponent_is_human: bool,
    pub state: GameState,
    // Each side's starting allotment in ms, from GameFull.clock.initial -- fixed
    // for the game's lifetime like opponent_player above, unlike
    // the live wtime/btime GameState carries every update. Needed (not just the
    // live remaining time) to compute a "low time" fraction of the *original*
    // allotment (e.g. lichess-org/mobile's own ~1/8-of-total clock warning) --
    // remaining time alone can't tell a 10s-left-out-of-600s game apart from a
    // 10s-left-out-of-30s one. None for the rare case a game has no clock at
    // all (correspondence/untimed) rather than assumed.
    pub initial_clock_ms: Option<u64>,
    state_received_at: Instant,
}

fn next_position_id() -> PositionId {
    // Keep the sequence across attachments. A per-session counter can be
    // reused on reattach, and a history hash repeats when a takeback restores it.
    static NEXT: AtomicU32 = AtomicU32::new(1);
    PositionId(NEXT.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
        .expect("position ID exhausted"))
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

fn you<'a>(full: &'a GameFull, your_color: &str) -> &'a crate::lichess::models::Player {
    if your_color == "black" { &full.black } else { &full.white }
}

struct OfferState {
    by_you: bool,
    by_opponent: bool,
    can_offer: bool,
}

impl OfferState {
    fn new(by_you: bool, by_opponent: bool, eligible: bool) -> Self {
        Self { by_you, by_opponent, can_offer: eligible && !by_you && !by_opponent }
    }
}

struct GameOffers {
    draw: OfferState,
    takeback: OfferState,
}

fn player_identity(player: &crate::lichess::models::Player) -> PlayerIdentity {
    PlayerIdentity {
        id: player.id.clone(),
        name: player.ai_level
            .map(|level| format!("Stockfish level {level}"))
            .or_else(|| player.name.clone()),
        title: player.title.clone(),
        rating: player.rating,
        provisional: player.provisional.unwrap_or(false),
    }
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
            format!("{} min", seconds / 60)
        } else {
            format!("{seconds} sec")
        };
        parts.push(format!("{initial} + {} sec/move", clock.increment / 1_000));
    } else if let Some(days) = full.days_per_turn {
        parts.push(format!("{days} days/move"));
    }
    parts.join(" • ")
}

// How a BoardState delivers move/position history. Full sends both arrays whole
// (game load, resume, reconnect, takeback); Append sends only the one new SAN and
// lets the frontend push it plus this message's fen; Unchanged (a clock/offer-only
// update where the move list didn't move) sends no history. See the wire shape on
// protocol::BackendMessage::BoardState.
enum HistoryDelivery<'a> {
    Full,
    Append(&'a str),
    Unchanged,
}

fn to_board_state(
    session: &GameSession,
    now: Instant,
    history: HistoryDelivery,
) -> BackendMessage {
    use shakmaty::Position;
    let state = &session.state;
    let (move_history, position_history, appended_move) = match history {
        HistoryDelivery::Full => (
            Some(session.move_history.clone().into_boxed_slice()),
            Some(session.position_history.clone().into_boxed_slice()),
            None,
        ),
        HistoryDelivery::Append(san) => (None, None, Some(Box::<str>::from(san))),
        HistoryDelivery::Unchanged => (None, None, None),
    };
    let move_count = state.moves.split_whitespace().count();
    let offers = session.game_offers();
    let has_moved = if session.your_color == "black" {
        move_count >= 2
    } else {
        move_count >= 1
    };
    let elapsed_ms = elapsed_whole_millis(session.state_received_at, now);
    let active = state.status == "started";
    let main_clock_paused = active && state.expiration.is_some();
    let mut white_time_ms = state.wtime;
    let mut black_time_ms = state.btime;
    if active && session.initial_clock_ms.is_some() && !main_clock_paused {
        match session.position.turn() {
            shakmaty::Color::White => white_time_ms = white_time_ms.saturating_sub(elapsed_ms),
            shakmaty::Color::Black => black_time_ms = black_time_ms.saturating_sub(elapsed_ms),
        }
    }
    // A predicted move preserves the confirmed pause. Reusing its deadline
    // assigns it to the next turn, while clearing the pause starts time early.
    let first_move_time_ms = state.expiration.as_ref()
        .filter(|_| active && session.prior_moves_before_prediction.is_none())
        .map(|expiration| expiration.millis_to_move
            .saturating_sub(expiration.idle_millis)
            .saturating_sub(elapsed_ms));
    BackendMessage::BoardState {
        game_id: session.game_id.clone(),
        position_id: session.position_id,
        game_stream_connected: session.game_stream_connected,
        resolved_move_request_id: None,
        pending_game_action: session.pending_game_action.as_ref().filter(|_| active)
            .map(|pending| Box::new(pending.request)),
        opponent_departure: if active { session.opponent_departure.map(Box::new) } else { None },
        fen: shakmaty::fen::Fen::from_position(&session.position, shakmaty::EnPassantMode::Legal)
            .to_string(),
        turn: turn_name(&session.position),
        white_time_ms,
        black_time_ms,
        legal_moves: if active { session.legal.clone().into_boxed_slice() } else { Box::default() },
        last_move: session.last_move.clone().map(Box::new),
        your_color: session.your_color.clone(),
        in_check: session.position.is_check(),
        draw_offered_by_opponent: offers.draw.by_opponent,
        takeback_offered_by_opponent: offers.takeback.by_opponent,
        draw_offered_by_you: offers.draw.by_you,
        takeback_offered_by_you: offers.takeback.by_you,
        can_abort: active && move_count < 2 && !session.is_tournament,
        can_berserk: active && session.is_tournament && !session.berserked && !has_moved,
        can_offer_draw: offers.draw.can_offer,
        can_offer_takeback: offers.takeback.can_offer,
        can_give_time: active && !session.rated
            && !session.is_tournament
            && session.opponent_is_human
            && session.initial_clock_ms.is_some(),
        move_history,
        initial_in_check: position_history.as_ref().map(|_| session.initial_in_check),
        position_history,
        appended_move,
        captured_by_white: session.captured_by_white.clone().into_boxed_slice(),
        captured_by_black: session.captured_by_black.clone().into_boxed_slice(),
        your_player: Box::new(session.your_player.clone()),
        opponent_player: Box::new(session.opponent_player.clone()),
        game_description: session.game_description.clone().into_boxed_str(),
        first_move_time_ms: first_move_time_ms.map(Box::new),
        main_clock_paused,
        initial_clock_ms: session.initial_clock_ms.map(Box::new),
        outcome: (!active).then(|| {
            let mut result = outcome(&state.status, state.winner.as_deref());
            result.rating_diff = session.your_rating_diff;
            Box::new(result)
        }),
    }
}

fn last_move_from_uci_list(moves: &str) -> Option<(String, String)> {
    let last = moves.split_whitespace().last()?;
    if last.len() < 4 {
        return None;
    }
    Some((last[0..2].to_string(), last[2..4].to_string()))
}

fn single_appended_move<'a>(previous: &str, next: &'a str) -> Option<&'a str> {
    let previous = previous.trim();
    let next = next.trim();
    let suffix = if previous.is_empty() {
        next
    } else {
        next.strip_prefix(previous)?.strip_prefix(char::is_whitespace)?.trim()
    };
    if suffix.is_empty() || suffix.split_whitespace().count() != 1 {
        return None;
    }
    Some(suffix)
}

impl GameSession {
    pub fn from_game_full(full: &GameFull, my_id: &str) -> anyhow::Result<(Self, BackendMessage)> {
        anyhow::ensure!(
            supports_variant(&full.variant.key),
            "{} games are not supported yet",
            full.variant.name
        );
        let replay = replay_uci_game(&full.initial_fen, &full.state.moves)?;
        let position = replay.position;
        let legal = legal_moves(&position);
        let last_move = last_move_from_uci_list(&full.state.moves);
        let your_color = resolve_your_color(full, my_id);
        let local_player = you(full, &your_color);
        let opp = opponent(full, &your_color);
        let session = GameSession {
            game_id: full.id.clone(),
            position_id: next_position_id(),
            game_stream_connected: true,
            opponent_departure: None,
            prior_moves_before_prediction: None,
            pending_move: None,
            pending_game_action: None,
            initial_fen: full.initial_fen.clone(),
            initial_in_check: replay.initial_in_check,
            position,
            legal,
            last_move,
            your_color,
            move_history: replay.move_history,
            position_history: replay.position_history,
            captured_by_white: replay.captured_by_white,
            captured_by_black: replay.captured_by_black,
            your_player: player_identity(local_player),
            opponent_player: player_identity(opp),
            your_rating_diff: local_player.rating_diff.filter(|_| local_player.id.as_deref() == Some(my_id)),
            player_statuses: None,
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

    pub fn mark_stream_disconnected(&mut self) {
        self.game_stream_connected = false;
        self.opponent_departure = None;
    }

    pub fn is_stream_connected(&self) -> bool {
        self.game_stream_connected
    }

    fn game_offers(&self) -> GameOffers {
        let state = &self.state;
        let (draw_yours, draw_theirs, takeback_yours, takeback_theirs) =
            if self.your_color == "black" {
                (state.bdraw, state.wdraw, state.btakeback, state.wtakeback)
            } else {
                (state.wdraw, state.bdraw, state.wtakeback, state.btakeback)
            };
        let eligible = state.status == "started" && self.move_history.len() >= 2 && self.opponent_is_human;
        GameOffers {
            draw: OfferState::new(draw_yours, draw_theirs, eligible),
            takeback: OfferState::new(takeback_yours, takeback_theirs,
                eligible && !self.rated && !self.is_tournament),
        }
    }

    pub fn validate_offer(&self, action: GameAction, request: OfferRequest) -> Result<(), &'static str> {
        if request.expected_position_id.is_some_and(|id| id != self.position_id) {
            return Err("Board changed.");
        }
        let Some(intent) = request.offer_intent else { return Ok(()) };
        if !self.is_stream_connected() {
            return Err("Waiting for the game to reconnect.");
        }
        if request.accept != matches!(intent, OfferIntent::Offer | OfferIntent::Accept) {
            return Err("Invalid offer action.");
        }
        let offers = self.game_offers();
        let current = match action {
            GameAction::Draw => offers.draw,
            GameAction::Takeback => offers.takeback,
            _ => return Err("Invalid offer action."),
        };
        let matching = match intent {
            OfferIntent::Offer => current.can_offer,
            OfferIntent::Accept => current.by_opponent,
            // Lichess prioritizes canceling your own takeback over declining theirs.
            OfferIntent::Decline => current.by_opponent &&
                (action != GameAction::Takeback || !current.by_you),
            OfferIntent::Cancel => action == GameAction::Takeback && current.by_you,
        };
        if !matching {
            return Err("Offer changed.");
        }
        Ok(())
    }

    fn board_state_at(&self, now: Instant) -> BackendMessage {
        // A standalone re-send of the current state (resume, berserk re-derive) --
        // the frontend may be freshly loaded with no history, so sync it in full.
        to_board_state(self, now, HistoryDelivery::Full)
    }

    pub fn apply_state_update(&mut self, state: GameState) -> anyhow::Result<BackendMessage> {
        let changed = state.status != "started" || state.moves != self.state.moves;
        let mut board = self.update_state(state, true, None)?;
        if changed {
            self.resolve_move(&mut board);
        }
        if self.state.status != "started" {
            self.cancel_game_action();
        }
        Ok(board)
    }

    pub fn apply_stream_update(&mut self, state: GameState) -> anyhow::Result<Option<BackendMessage>> {
        if state.status == "started" &&
            self.prior_moves_before_prediction.as_deref() == Some(state.moves.as_str())
        {
            return Ok(None);
        }
        self.apply_state_update(state).map(Some)
    }

    fn update_state(
        &mut self,
        state: GameState,
        game_stream_connected: bool,
        prior_moves_before_prediction: Option<String>,
    ) -> anyhow::Result<BackendMessage> {
        enum Change {
            Appended(String),
            Rebuilt,
            Unchanged,
        }
        let change = if state.moves != self.state.moves {
            if let Some(uci) = single_appended_move(&self.state.moves, &state.moves) {
                let advance = advance_uci_game(&self.position, uci)?;
                let san = advance.san.clone();
                self.move_history.push(advance.san);
                self.position_history.push(advance.fen);
                if let Some(piece) = advance.captured_piece {
                    if advance.mover == shakmaty::Color::White {
                        self.captured_by_white.push(piece);
                    } else {
                        self.captured_by_black.push(piece);
                    }
                }
                self.position = advance.position;
                Change::Appended(san)
            } else {
                let replay = replay_uci_game(&self.initial_fen, &state.moves)?;
                self.position = replay.position;
                self.move_history = replay.move_history;
                self.position_history = replay.position_history;
                self.captured_by_white = replay.captured_by_white;
                self.captured_by_black = replay.captured_by_black;
                Change::Rebuilt
            }
        } else {
            Change::Unchanged
        };
        if !matches!(change, Change::Unchanged) {
            self.position_id = next_position_id();
            self.legal = legal_moves(&self.position);
            self.last_move = last_move_from_uci_list(&state.moves);
        }
        self.state = state;
        self.state_received_at = Instant::now();
        self.game_stream_connected = game_stream_connected;
        self.prior_moves_before_prediction = prior_moves_before_prediction;
        let history = match &change {
            Change::Appended(san) => HistoryDelivery::Append(san),
            Change::Rebuilt => HistoryDelivery::Full,
            Change::Unchanged => HistoryDelivery::Unchanged,
        };
        Ok(to_board_state(self, self.state_received_at, history))
    }

    pub fn apply_accepted_move(
        &mut self,
        expected_moves: &str,
        uci: &str,
    ) -> anyhow::Result<Option<BackendMessage>> {
        if self.state.moves != expected_moves || self.state.status != "started" {
            return Ok(None);
        }
        let mut state = self.state.clone();
        (state.wtime, state.btime) = self.predicted_move_clocks();
        state.moves = if expected_moves.trim().is_empty() {
            uci.to_string()
        } else {
            format!("{} {}", expected_moves.trim(), uci)
        };
        let mut board = self.update_state(
            state, self.game_stream_connected, Some(expected_moves.to_owned()),
        )?;
        self.resolve_move(&mut board);
        Ok(Some(board))
    }

    pub fn begin_move(
        &mut self,
        uci: &str,
        request_id: Option<u32>,
    ) -> anyhow::Result<(BackendMessage, oneshot::Receiver<()>)> {
        anyhow::ensure!(self.pending_move.is_none(), "A move is already being submitted.");
        let preview = self.preview_move(uci, request_id)?;
        let (cancel_on_drop, canceled) = oneshot::channel();
        self.pending_move = Some(PendingMove { request_id, _cancel_on_drop: cancel_on_drop });
        Ok((preview, canceled))
    }

    pub fn cancel_move(&mut self) {
        self.pending_move = None;
    }

    fn resolve_move(&mut self, board: &mut BackendMessage) {
        if let BackendMessage::BoardState { resolved_move_request_id, .. } = board {
            *resolved_move_request_id = self.pending_move.take().and_then(|move_| move_.request_id);
        }
    }

    pub fn inherit_pending_requests(&mut self, previous: &mut Self, board: &mut BackendMessage) {
        let same_position = self.state.moves == previous.state.moves &&
            self.position_history.first() == previous.position_history.first() &&
            self.your_color == previous.your_color;
        if same_position {
            self.position_id = previous.position_id;
            if let BackendMessage::BoardState { position_id, .. } = board {
                *position_id = self.position_id;
            }
        }
        self.pending_move = previous.pending_move.take();
        if self.state.status != "started" || !same_position {
            self.resolve_move(board);
        }
        if self.state.status == "started" {
            self.pending_game_action = previous.pending_game_action.take();
            if let BackendMessage::BoardState { pending_game_action, .. } = board {
                *pending_game_action = self.pending_game_action.as_ref().map(|pending| Box::new(pending.request));
            }
        } else {
            previous.cancel_game_action();
        }
    }

    pub fn begin_game_action(&mut self, request: GameActionRequest) -> Option<oneshot::Receiver<()>> {
        if self.pending_game_action.is_some() || self.state.status != "started" {
            return None;
        }
        let (cancel_on_drop, canceled) = oneshot::channel();
        self.pending_game_action = Some(PendingGameAction { request, _cancel_on_drop: cancel_on_drop });
        Some(canceled)
    }

    pub fn cancel_game_action(&mut self) {
        self.pending_game_action = None;
    }

    fn predicted_move_clocks(&self) -> (u64, u64) {
        let (white, black) = (self.state.wtime, self.state.btime);
        if self.state.expiration.is_some() {
            return (white, black);
        }
        let elapsed_ms = elapsed_whole_millis(self.state_received_at, Instant::now());
        match self.position.turn() {
            shakmaty::Color::White => (
                white.saturating_sub(elapsed_ms).saturating_add(self.state.winc), black,
            ),
            shakmaty::Color::Black => (
                white, black.saturating_sub(elapsed_ms).saturating_add(self.state.binc),
            ),
        }
    }

    fn preview_move(&self, uci: &str, request_id: Option<u32>) -> anyhow::Result<BackendMessage> {
        anyhow::ensure!(self.state.status == "started", "game is not active");
        let position = apply_uci_move(&self.position, uci)?;
        let (white_time_ms, black_time_ms) = self.predicted_move_clocks();
        Ok(BackendMessage::MovePreview {
            game_id: self.game_id.clone(),
            request_id,
            fen: shakmaty::fen::Fen::from_position(
                &position,
                shakmaty::EnPassantMode::Legal,
            )
            .to_string(),
            turn: turn_name(&position),
            white_time_ms,
            black_time_ms,
            last_move: last_move_from_uci_list(uci).map(Box::new),
            in_check: position.is_check(),
        })
    }

    pub fn try_move(
        &self,
        from: &str,
        to: &str,
        promotion: Option<&str>,
    ) -> Result<String, &'static str> {
        if (self.your_color == "white") != self.position.turn().is_white() {
            return Err("It is not your turn.");
        }
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
                    Err(_) => Err("stale board state, please retry"),
                }
            }
            None => Err("not a legal move"),
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
    fn checkmating_move_and_outcome_arrive_in_the_same_board_update() {
        let full = sample_full("f2f3 e7e5 g2g4");
        let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let mut state = full.state;
        state.moves.push_str(" d8h4");
        state.status = "mate".into();
        state.winner = Some("black".into());
        state.btime = 598_240;

        let BackendMessage::BoardState { fen, appended_move, outcome, black_time_ms, .. } =
            session.apply_state_update(state).unwrap() else { panic!("expected a board update") };
        assert!(fen.contains("6Pq"));
        assert_eq!(appended_move.as_deref(), Some("Qh4#"));
        assert_eq!(black_time_ms, 598_240);
        let outcome = outcome.unwrap();
        assert_eq!(outcome.result, "black");
        assert_eq!(outcome.reason, "Checkmate");
    }

    #[test]
    fn finished_game_full_contains_a_board_and_disables_play() {
        let mut full = sample_full("e2e4 e7e5");
        full.state.status = "resign".into();
        full.state.winner = Some("white".into());
        let (_, message) = GameSession::from_game_full(&full, "my-id").unwrap();

        let BackendMessage::BoardState {
            outcome, position_history, legal_moves, can_offer_draw, can_offer_takeback, ..
        } = message else { panic!("expected a full board update") };
        assert_eq!(position_history.unwrap().len(), 3);
        assert!(legal_moves.is_empty());
        assert!(!can_offer_draw);
        assert!(!can_offer_takeback);
        assert_eq!(outcome.unwrap().reason, "Resignation");
    }

    #[test]
    fn finished_board_contains_only_the_signed_in_players_rating_change() {
        let mut full = sample_full("e2e4 e7e5");
        full.rated = true;
        full.white.rating_diff = Some(0);
        full.black.rating_diff = Some(-7);
        full.state.status = "resign".into();
        full.state.winner = Some("white".into());
        for (id, expected) in [("my-id", Some(0)), ("opponent-id", Some(-7)), ("unknown", None)] {
            let (_, message) = GameSession::from_game_full(&full, id).unwrap();
            let BackendMessage::BoardState { outcome: Some(result), .. } = message else {
                panic!("expected a finished board update");
            };
            assert_eq!(result.rating_diff, expected);
        }
    }

    #[test]
    fn history_is_full_on_load_then_appended_one_move_at_a_time() {
        let full = sample_full("e2e4");
        let (mut session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { move_history, position_history, appended_move, .. } => {
                assert_eq!(&*move_history.unwrap(), ["e4".to_string()]);
                assert_eq!(position_history.unwrap().len(), 2);
                assert_eq!(appended_move, None);
            }
            _ => panic!("expected BoardState"),
        }
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4 e7e5", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null
        }))
        .unwrap();
        let msg = session.apply_state_update(state).unwrap();
        match msg {
            // The common one-move advance sends neither array, just the new SAN.
            BackendMessage::BoardState { move_history, position_history, appended_move, .. } => {
                assert_eq!(move_history, None);
                assert_eq!(position_history, None);
                assert_eq!(appended_move.as_deref(), Some("e5"));
            }
            _ => panic!("expected BoardState"),
        }
        // The session still holds the whole line for the next full sync.
        assert_eq!(session.move_history, ["e4", "e5"]);
        assert_eq!(session.position_history.len(), 3);
    }

    #[test]
    fn a_non_appending_move_change_resends_the_whole_line() {
        // A takeback shrinks/diverges the move list rather than appending one move,
        // so it can't be an append -- the frontend gets a full sync instead.
        let full = sample_full("e2e4 e7e5");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4", "wtime": 600000, "btime": 600000, "winc": 0, "binc": 0,
            "status": "started", "winner": null
        }))
        .unwrap();
        match session.apply_state_update(state).unwrap() {
            BackendMessage::BoardState { move_history, position_history, appended_move, .. } => {
                assert_eq!(&*move_history.unwrap(), ["e4".to_string()]);
                assert_eq!(position_history.unwrap().len(), 2);
                assert_eq!(appended_move, None);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn initial_check_travels_with_full_history_on_resume_and_takeback() {
        let mut full = sample_full("g7g6");
        full.variant.key = "fromPosition".into();
        full.initial_fen =
            "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2".into();
        let (mut session, initial) = GameSession::from_game_full(&full, "my-id").unwrap();
        assert!(matches!(initial, BackendMessage::BoardState {
            initial_in_check: Some(true), in_check: false, ..
        }));
        let mut state = full.state;
        state.moves = "g7g6 h5f3".into();
        assert!(matches!(session.apply_state_update(state.clone()).unwrap(), BackendMessage::BoardState {
            initial_in_check: None, appended_move: Some(_), ..
        }));
        state.wtime -= 1_000;
        assert!(matches!(session.apply_state_update(state.clone()).unwrap(), BackendMessage::BoardState {
            initial_in_check: None, position_history: None, appended_move: None, ..
        }));
        assert!(matches!(session.board_state(), BackendMessage::BoardState {
            initial_in_check: Some(true), in_check: false, ..
        }));
        state.moves = "g7g6".into();
        assert!(matches!(session.apply_state_update(state).unwrap(), BackendMessage::BoardState {
            initial_in_check: Some(true), position_history: Some(ref fens), ..
        } if fens.len() == 2 && fens[0] == full.initial_fen));
    }

    #[test]
    fn a_clock_only_update_carries_no_history() {
        let full = sample_full("e2e4");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let mut state = session.state.clone();
        state.btime = 599_000;
        match session.apply_state_update(state).unwrap() {
            BackendMessage::BoardState { move_history, position_history, appended_move, .. } => {
                assert_eq!(move_history, None);
                assert_eq!(position_history, None);
                assert_eq!(appended_move, None);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn identical_move_list_updates_do_not_rebuild_position_history() {
        let full = sample_full("e2e4");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let history_ptr = session.position_history.as_ptr();
        let mut state = session.state.clone();
        state.btime = 599_000;
        session.apply_state_update(state).unwrap();
        assert_eq!(session.position_history.as_ptr(), history_ptr);
        assert_eq!(session.position_history.len(), 2);
    }

    #[test]
    fn accepted_move_advances_before_stream_confirmation_without_duplication() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let predicted = session.apply_accepted_move("", "e2e4").unwrap().unwrap();
        match predicted {
            BackendMessage::BoardState { turn, last_move, .. } => {
                assert_eq!(turn, "black");
                assert_eq!(*last_move.unwrap(), ("e2".to_string(), "e4".to_string()));
            }
            _ => panic!("expected BoardState"),
        }
        assert_eq!(session.move_history, ["e4"]);
        assert_eq!(session.position_history.len(), 2);

        let mut authoritative = session.state.clone();
        authoritative.wtime = 598_000;
        session.apply_state_update(authoritative).unwrap();
        assert_eq!(session.move_history, ["e4"]);
        assert_eq!(session.position_history.len(), 2);
    }

    #[test]
    fn only_an_authoritative_update_recovers_a_disconnected_board() {
        let full = sample_full("");
        let (mut session, initial) = GameSession::from_game_full(&full, "my-id").unwrap();
        assert!(matches!(initial, BackendMessage::BoardState { game_stream_connected: true, .. }));

        session.mark_stream_disconnected();
        let predicted = session.apply_accepted_move("", "e2e4").unwrap().unwrap();
        assert!(matches!(predicted, BackendMessage::BoardState { game_stream_connected: false, .. }));

        let mut invalid = session.state.clone();
        invalid.moves.push_str(" invalid");
        assert!(session.apply_state_update(invalid).is_err());
        assert!(matches!(
            session.board_state(),
            BackendMessage::BoardState { game_stream_connected: false, .. }
        ));

        let recovered = session.apply_state_update(session.state.clone()).unwrap();
        assert!(matches!(recovered, BackendMessage::BoardState { game_stream_connected: true, .. }));
    }

    #[test]
    fn an_old_frame_cannot_undo_a_prediction_but_a_later_takeback_can() {
        let full = sample_full("");
        let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let initial = session.position_id;
        session.apply_accepted_move("", "e2e4").unwrap().unwrap();
        let accepted = session.position_id;
        assert_ne!(accepted, initial);

        assert!(session.apply_stream_update(full.state.clone()).unwrap().is_none());
        assert_eq!(session.state.moves, "e2e4");
        assert!(session.apply_stream_update(session.state.clone()).unwrap().is_some());
        assert_eq!(session.position_id, accepted);
        assert!(session.apply_stream_update(full.state).unwrap().is_some());
        assert!(session.state.moves.is_empty());
        assert_ne!(session.position_id, accepted);
        assert_ne!(session.position_id, initial);
    }

    #[test]
    fn position_id_changes_when_a_line_is_rewritten_to_the_same_fen() {
        let full = sample_full("g1f3 g8f6 b1c3 b8c6");
        let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let original_id = session.position_id;
        let last_fen = session.position_history.last().unwrap().clone();
        let replacement = sample_full("b1c3 b8c6 g1f3 g8f6");
        let updated = session.apply_state_update(replacement.state).unwrap();
        let BackendMessage::BoardState { fen, position_id, .. } = updated else {
            panic!("expected BoardState");
        };
        assert_eq!(fen, last_fen);
        assert_ne!(position_id, original_id);
        assert_eq!(position_id, session.position_id);
    }

    #[test]
    fn a_terminal_stream_frame_is_authoritative_while_a_move_is_predicted() {
        let full = sample_full("");
        let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        session.apply_accepted_move("", "e2e4").unwrap().unwrap();
        let mut terminal = full.state;
        terminal.status = "draw".into();

        let result = session.apply_stream_update(terminal).unwrap().unwrap();
        assert!(matches!(result, BackendMessage::BoardState { outcome: Some(_), .. }));
        assert!(session.state.moves.is_empty());
    }

    #[test]
    fn stream_releases_only_the_pending_move_after_a_valid_board_change() {
        let full = sample_full("");
        let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let initial = session.position_id;
        let (preview, mut first) = session.begin_move("e2e4", Some(21)).unwrap();
        assert!(matches!(preview, BackendMessage::MovePreview { request_id: Some(21), .. }));
        assert!(session.begin_move("d2d4", Some(22)).is_err());
        let mut clock_update = full.state.clone();
        clock_update.wtime -= 1000;
        clock_update.bdraw = true;
        let board = session.apply_stream_update(clock_update).unwrap().unwrap();
        assert!(matches!(board,
            BackendMessage::BoardState { position_id, resolved_move_request_id: None, .. }
            if position_id == initial));
        let mut invalid = full.state.clone();
        invalid.moves = "invalid".into();
        assert!(session.apply_stream_update(invalid).is_err());
        assert_eq!(session.position_id, initial);
        assert_eq!(first.try_recv(), Err(oneshot::error::TryRecvError::Empty));

        let mut played = full.state;
        played.moves = "e2e4 e7e5".into();
        let board = session.apply_stream_update(played).unwrap().unwrap();
        assert!(matches!(board, BackendMessage::BoardState { resolved_move_request_id: Some(21), .. }));
        let (_, mut second) = session.begin_move("g1f3", Some(22)).unwrap();
        assert_eq!(first.try_recv(), Err(oneshot::error::TryRecvError::Closed));
        assert_eq!(second.try_recv(), Err(oneshot::error::TryRecvError::Empty));
        let accepted = session.apply_accepted_move("e2e4 e7e5", "g1f3").unwrap().unwrap();
        assert!(matches!(accepted, BackendMessage::BoardState { resolved_move_request_id: Some(22), .. }));
        assert_eq!(second.try_recv(), Err(oneshot::error::TryRecvError::Closed));
    }

    #[test]
    fn reconnect_keeps_pending_move_only_while_the_submitted_position_is_current() {
        let full = sample_full("");
        let (mut previous, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let (_, mut canceled) = previous.begin_move("e2e4", Some(21)).unwrap();
        let (mut reconnected, mut same) = GameSession::from_game_full(&full, "my-id").unwrap();
        assert_ne!(reconnected.position_id, previous.position_id);
        reconnected.inherit_pending_requests(&mut previous, &mut same);
        assert!(matches!(same,
            BackendMessage::BoardState { position_id, resolved_move_request_id: None, .. }
            if position_id == previous.position_id && position_id == reconnected.position_id));
        assert_eq!(canceled.try_recv(), Err(oneshot::error::TryRecvError::Empty));

        let different = sample_full("d2d4 d7d5");
        let (mut replacement, mut changed) = GameSession::from_game_full(&different, "my-id").unwrap();
        replacement.inherit_pending_requests(&mut reconnected, &mut changed);
        assert!(matches!(changed,
            BackendMessage::BoardState { position_id, resolved_move_request_id: Some(21), .. }
            if position_id == replacement.position_id && position_id != reconnected.position_id));
        assert_eq!(canceled.try_recv(), Err(oneshot::error::TryRecvError::Closed));
    }

    #[test]
    fn active_action_is_shared_with_resumed_boards_until_game_end() {
        use crate::protocol::GameAction;

        let full = sample_full("");
        let (mut previous, _) = GameSession::from_game_full(&full, "my-id").unwrap();
        let request = GameActionRequest { action: GameAction::AddTime, request_id: Some(21), seconds: Some(15) };
        let mut canceled = previous.begin_game_action(request).unwrap();
        assert!(previous.begin_game_action(request).is_none());
        assert!(matches!(previous.board_state(),
            BackendMessage::BoardState { pending_game_action: Some(current), .. } if *current == request));

        let next = sample_full("e2e4");
        let (mut reconnected, mut snapshot) = GameSession::from_game_full(&next, "my-id").unwrap();
        reconnected.inherit_pending_requests(&mut previous, &mut snapshot);
        assert!(matches!(snapshot,
            BackendMessage::BoardState { pending_game_action: Some(current), .. } if *current == request));
        assert_eq!(canceled.try_recv(), Err(oneshot::error::TryRecvError::Empty));

        let mut terminal = next.state;
        terminal.status = "draw".into();
        let snapshot = reconnected.apply_state_update(terminal).unwrap();
        assert!(matches!(snapshot,
            BackendMessage::BoardState { outcome: Some(_), pending_game_action: None, .. }));
        assert_eq!(canceled.try_recv(), Err(oneshot::error::TryRecvError::Closed));
    }

    #[test]
    fn offer_intents_follow_the_current_side_and_kind() {
        let full = sample_full("e2e4 e7e5");
        let (mut session, _) = GameSession::from_game_full(&full, "opponent-id").unwrap();
        let position_id = session.position_id;
        let request = |intent| OfferRequest {
            accept: matches!(intent, OfferIntent::Offer | OfferIntent::Accept),
            request_id: Some(14),
            offer_intent: Some(intent),
            expected_position_id: Some(position_id),
        };
        for action in [GameAction::Draw, GameAction::Takeback] {
            assert_eq!(session.validate_offer(action, request(OfferIntent::Offer)), Ok(()));
            assert_eq!(session.validate_offer(action, request(OfferIntent::Accept)), Err("Offer changed."));
        }

        let mut both = full.state;
        both.wdraw = true;
        both.wtakeback = true;
        session.apply_state_update(both.clone()).unwrap();
        for action in [GameAction::Draw, GameAction::Takeback] {
            assert_eq!(session.validate_offer(action, request(OfferIntent::Accept)), Ok(()));
            assert_eq!(session.validate_offer(action, request(OfferIntent::Decline)), Ok(()));
            assert_eq!(session.validate_offer(action, request(OfferIntent::Offer)), Err("Offer changed."));
        }
        assert_eq!(session.validate_offer(GameAction::Draw, request(OfferIntent::Cancel)), Err("Offer changed."));
        both.btakeback = true;
        session.apply_state_update(both).unwrap();
        assert_eq!(session.validate_offer(GameAction::Takeback, request(OfferIntent::Decline)), Err("Offer changed."));
        assert_eq!(session.validate_offer(GameAction::Takeback, request(OfferIntent::Cancel)), Ok(()));

        let mismatched = OfferRequest { accept: true, ..request(OfferIntent::Cancel) };
        assert_eq!(session.validate_offer(GameAction::Takeback, mismatched), Err("Invalid offer action."));
        session.mark_stream_disconnected();
        assert_eq!(session.validate_offer(GameAction::Takeback, request(OfferIntent::Cancel)),
            Err("Waiting for the game to reconnect."));
        let legacy = OfferRequest { offer_intent: None, expected_position_id: None, ..mismatched };
        assert_eq!(session.validate_offer(GameAction::Takeback, legacy), Ok(()));
    }

    #[test]
    fn move_preview_does_not_mutate_authoritative_session() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        let preview = session.preview_move("e2e4", None).unwrap();
        match preview {
            BackendMessage::MovePreview { turn, last_move, .. } => {
                assert_eq!(turn, "black");
                assert_eq!(*last_move.unwrap(), ("e2".to_string(), "e4".to_string()));
            }
            _ => panic!("expected MovePreview"),
        }
        assert!(session.state.moves.is_empty());
        assert!(session.move_history.is_empty());
        assert_eq!(session.position_history.len(), 1);
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
        assert_eq!(result, Err("not a legal move"));
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
        let msg = session.apply_state_update(state).unwrap();
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
            msg = Some(session.apply_state_update(state).unwrap());
        }
        match msg.unwrap() {
            BackendMessage::BoardState { in_check, .. } => assert!(in_check),
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn both_player_names_and_ratings_are_read_from_their_sides() {
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
            BackendMessage::BoardState {
                your_player,
                opponent_player,
                ..
            } => {
                assert_eq!(your_player.name.as_deref(), Some("MyName"));
                assert_eq!(your_player.rating, Some(1500));
                assert_eq!(your_player.id.as_deref(), Some("my-id"));
                assert_eq!(your_player.title, None);
                assert!(!your_player.provisional);
                assert_eq!(opponent_player.name.as_deref(), Some("OpponentName"));
                assert_eq!(opponent_player.rating, Some(1600));
                assert_eq!(opponent_player.id.as_deref(), Some("opponent-id"));
                assert_eq!(opponent_player.title, None);
                assert!(!opponent_player.provisional);
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
        let msg = session.apply_state_update(state).unwrap();
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
                assert_eq!(game_description.as_ref(), "Casual Rapid • 10 min + 0 sec/move");
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
            BackendMessage::BoardState { opponent_player, .. } => {
                assert_eq!(opponent_player.name, None);
                assert_eq!(opponent_player.rating, None);
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn ai_level_and_player_title_produce_structured_opponent_identity() {
        let mut full = sample_full("");
        full.black.ai_level = Some(3);
        full.black.id = None;
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState { opponent_player, .. } => {
                assert_eq!(opponent_player.name.as_deref(), Some("Stockfish level 3"));
            }
            _ => panic!("expected BoardState"),
        }

        let mut full = sample_full("");
        full.black.name = Some("OpponentName".into());
        full.black.title = Some("GM".into());
        full.black.provisional = Some(true);
        let (_session, msg) = GameSession::from_game_full(&full, "my-id").unwrap();
        match msg {
            BackendMessage::BoardState {
                opponent_player,
                ..
            } => {
                assert_eq!(opponent_player.name.as_deref(), Some("OpponentName"));
                assert_eq!(opponent_player.title.as_deref(), Some("GM"));
                assert!(opponent_player.provisional);
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
    fn cached_first_move_deadline_ages_without_changing_either_main_clock() {
        use std::time::Duration;

        for moves in ["", "e2e4"] {
            let mut full = sample_full(moves);
            full.state.expiration = Some(crate::lichess::models::GameExpiration {
                idle_millis: 4_000,
                millis_to_move: 15_000,
            });
            let (session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
            for (age_ms, expected_deadline) in [(2_400, 9_000), (12_000, 0)] {
                let now = session.state_received_at + Duration::from_millis(age_ms);
                let BackendMessage::BoardState {
                    white_time_ms, black_time_ms, first_move_time_ms, main_clock_paused, ..
                } = session.board_state_at(now) else {
                    panic!("expected BoardState");
                };
                assert_eq!((white_time_ms, black_time_ms), (600_000, 600_000));
                assert_eq!(first_move_time_ms.as_deref(), Some(&expected_deadline));
                assert!(main_clock_paused);
            }
        }
    }

    #[test]
    fn opening_predictions_keep_the_pause_until_the_stream_confirms_the_clocks() {
        use std::time::Duration;

        for (moves, played, confirmed_moves) in [
            ("", "e2e4", "e2e4"),
            ("e2e4", "e7e5", "e2e4 e7e5"),
        ] {
            let mut full = sample_full(moves);
            full.state.winc = 2_000;
            full.state.binc = 2_000;
            full.state.expiration = Some(crate::lichess::models::GameExpiration {
                idle_millis: 4_000,
                millis_to_move: 15_000,
            });
            let (mut session, _) = GameSession::from_game_full(&full, "my-id").unwrap();
            session.state_received_at -= Duration::from_secs(5);
            let (preview, _canceled) = session.begin_move(played, Some(8)).unwrap();
            let BackendMessage::MovePreview { white_time_ms, black_time_ms, .. } = preview else {
                panic!("expected MovePreview");
            };
            assert_eq!((white_time_ms, black_time_ms), (600_000, 600_000));

            let accepted = session.apply_accepted_move(moves, played).unwrap().unwrap();
            assert!(matches!(accepted, BackendMessage::BoardState {
                resolved_move_request_id: Some(8), first_move_time_ms: None,
                main_clock_paused: true, white_time_ms: 600_000, black_time_ms: 600_000, ..
            }));
            assert!(session.apply_stream_update(full.state.clone()).unwrap().is_none());
            let now = session.state_received_at + Duration::from_secs(3);
            assert!(matches!(session.board_state_at(now), BackendMessage::BoardState {
                first_move_time_ms: None, main_clock_paused: true,
                white_time_ms: 600_000, black_time_ms: 600_000, ..
            }));

            let mut confirmed = full.state;
            confirmed.moves = confirmed_moves.to_owned();
            let still_paused = moves.is_empty();
            if still_paused {
                confirmed.expiration.as_mut().unwrap().idle_millis = 1_000;
            } else {
                confirmed.expiration = None;
            }
            session.apply_stream_update(confirmed).unwrap().unwrap();
            let now = session.state_received_at + Duration::from_secs(2);
            let BackendMessage::BoardState {
                white_time_ms, black_time_ms, first_move_time_ms, main_clock_paused, ..
            } = session.board_state_at(now) else {
                panic!("expected confirmed BoardState");
            };
            assert_eq!(main_clock_paused, still_paused);
            assert_eq!(black_time_ms, 600_000);
            if still_paused {
                assert_eq!(white_time_ms, 600_000);
                assert_eq!(first_move_time_ms.as_deref(), Some(&12_000));
            } else {
                assert_eq!(white_time_ms, 598_000);
                assert!(first_move_time_ms.is_none());
            }
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
        let msg = session.apply_state_update(state).unwrap();
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
        let msg = session.apply_state_update(state).unwrap();
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
        let msg = session.apply_state_update(state).unwrap();
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
                ..
            } => {
                assert!(can_abort);
                assert!(!can_offer_draw);
                assert!(!can_offer_takeback);
                assert!(can_give_time);
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
        session.apply_state_update(state).unwrap();
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
                ..
            } => {
                assert!(!can_offer_draw);
                assert!(!can_offer_takeback);
                assert!(!can_give_time);
            }
            _ => panic!("expected BoardState"),
        }
    }
}
