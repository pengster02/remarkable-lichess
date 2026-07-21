use crate::game::session::GameSession;
use crate::lichess::client::LichessClient;
use crate::lichess::models::{EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use crate::protocol::{BackendMessage, FrontendMessage, MSG_TYPE_BACKEND_TO_FRONTEND};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

pub struct LichessBackend {
    token_path: PathBuf,
    // Sibling file next to the token (see settings::load/save) -- app-level
    // preferences (see backend/src/settings.rs), not per-account like the token.
    settings_path: PathBuf,
    client: Option<LichessClient>,
    // Needed to re-attach a game stream on RequestHome for an already-in-progress
    // resumable game (see handle_request_home) -- gameStart only fires once, when a
    // game *begins*, so simply reconnecting the account event stream after this
    // backend process restarts (or after any RequestHome navigation) never re-tells
    // us about a game that started earlier in the same session or a prior one.
    my_id: Option<String>,
    session: Arc<Mutex<Option<GameSession>>>,
    // The held-open long-poll connection backing an outstanding seek or outgoing
    // challenge (see spawn_hold_connection_open's comment on why holding it open
    // is what keeps the seek/challenge alive on Lichess's side). Dropping/aborting
    // this task closes that connection, which is exactly how a real Lichess client
    // cancels a pending seek -- there's no separate "cancel" REST endpoint.
    pending_seek: Option<tokio::task::JoinHandle<()>>,
}

impl LichessBackend {
    pub fn new(token_path: PathBuf) -> Self {
        let settings_path = token_path.with_file_name("settings.json");
        Self {
            token_path,
            settings_path,
            client: None,
            my_id: None,
            session: Arc::new(Mutex::new(None)),
            pending_seek: None,
        }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        let json = serde_json::to_string(msg).expect("BackendMessage always serializes");
        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
    }

    async fn activate_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        let client = LichessClient::new(token.clone());
        match client.get_account().await {
            Ok(account) => {
                let _ = std::fs::write(&self.token_path, &token);
                self.client = Some(client);
                self.my_id = Some(account.id.clone());
                // Needed so GameSession can work out which color the local account is
                // playing (see game::session::resolve_your_color) and orient the board
                // accordingly, instead of always assuming white.
                self.spawn_streams(replier.clone(), account.id.clone());
                self.send(replier, &BackendMessage::TokenVerified { username: account.username });
            }
            Err(e) => {
                self.send(replier, &BackendMessage::TokenInvalid { reason: e.to_string() });
            }
        }
    }

    async fn handle_save_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        self.activate_token(replier, token).await;
    }

    async fn handle_request_home(&mut self, replier: &BackendReplier<Self>) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        match client.get_playing().await {
            Ok(games) => {
                let resumable = games.first().map(|g| g.game_id.clone());
                // gameStart (see spawn_streams) only fires once, when a game *begins* --
                // it never re-announces an already-in-progress game, so a resumable game
                // found here needs its own stream actively (re)attached, or "Resume game"
                // just navigates to an empty BoardScreen with nothing feeding it.
                if let Some(game_id) = &resumable {
                    let already_tracking = self.session.lock().await.as_ref().is_some_and(|s| &s.game_id == game_id);
                    if !already_tracking {
                        if let Some(my_id) = self.my_id.clone() {
                            spawn_game_stream(client, game_id.clone(), replier.clone(), self.session.clone(), my_id);
                        }
                    }
                }
                self.send(replier, &BackendMessage::HomeState { resumable_game_id: resumable });
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    async fn handle_create_seek(
        &mut self,
        replier: &BackendReplier<Self>,
        minutes: u32,
        increment: u32,
        rated: bool,
        color: String,
    ) {
        let Some(client) = &self.client else { return };
        match client.create_seek(minutes, increment, rated, &color).await {
            Ok(lines) => {
                self.send(replier, &BackendMessage::SeekCreated);
                self.pending_seek = Some(spawn_hold_connection_open(lines));
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    fn handle_cancel_seek(&mut self) {
        if let Some(handle) = self.pending_seek.take() {
            handle.abort();
        }
    }

    fn handle_request_settings(&self, replier: &BackendReplier<Self>) {
        let settings = crate::settings::load(&self.settings_path);
        self.send(replier, &BackendMessage::SettingsState { auto_queen_promotion: settings.auto_queen_promotion });
    }

    fn handle_save_settings(&self, replier: &BackendReplier<Self>, auto_queen_promotion: bool) {
        let settings = crate::settings::AppSettings { auto_queen_promotion };
        if let Err(e) = crate::settings::save(&self.settings_path, &settings) {
            self.send(replier, &BackendMessage::ErrorMsg { message: format!("failed to save settings: {e}") });
            return;
        }
        // Echoed back rather than assumed -- the frontend already optimistically
        // shows the new toggle state, but this confirms the write actually
        // succeeded instead of silently drifting from what's on disk.
        self.send(replier, &BackendMessage::SettingsState { auto_queen_promotion });
    }

    /// There was previously no in-app way to do this at all -- switching
    /// accounts or recovering from a revoked token meant editing files on the
    /// device directly. Reuses TokenInvalid to drive the frontend back to
    /// SetupScreen, same message it already handles for a rejected token.
    fn handle_log_out(&mut self, replier: &BackendReplier<Self>) {
        let _ = std::fs::remove_file(&self.token_path);
        self.client = None;
        self.handle_cancel_seek();
        self.send(replier, &BackendMessage::TokenInvalid { reason: "logged out".into() });
    }

    /// Shared by every in-game action (resign/draw/takeback/abort/claim-victory) --
    /// they all just need the current game's id, nothing else from the session.
    async fn current_game_id(&self) -> Option<String> {
        let guard = self.session.lock().await;
        guard.as_ref().map(|s| s.game_id.clone())
    }

    async fn handle_make_move(&mut self, replier: &BackendReplier<Self>, from: String, to: String, promotion: Option<String>) {
        let Some(client) = self.client.clone() else { return };
        let result = {
            let guard = self.session.lock().await;
            let Some(session) = guard.as_ref() else { return };
            session
                .try_move(&from, &to, promotion.as_deref())
                .map(|uci| (uci, session.game_id.clone()))
        };
        match result {
            Ok((uci, game_id)) => {
                if let Err(e) = client.make_move(&game_id, &uci).await {
                    self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                }
                // The authoritative BoardState update arrives via the game stream, not here.
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }

    pub fn spawn_streams(&self, replier: BackendReplier<Self>, my_id: String) {
        let Some(client) = self.client.clone() else { return };
        let session_handle = self.session.clone();
        tokio::spawn(async move {
            let mut backoff_secs: u64 = 1;
            loop {
                match client.stream_lines("/api/stream/event").await {
                    Ok(mut lines) => {
                        use futures_util::StreamExt;
                        backoff_secs = 1;
                        while let Some(line) = lines.next().await {
                            match parse_ndjson_line::<EventStreamMessage>(&line) {
                                Some(EventStreamMessage::GameStart { game }) => {
                                    spawn_game_stream(
                                        client.clone(),
                                        game.id,
                                        replier.clone(),
                                        session_handle.clone(),
                                        my_id.clone(),
                                    );
                                }
                                Some(EventStreamMessage::Challenge)
                                | Some(EventStreamMessage::ChallengeCanceled)
                                | Some(EventStreamMessage::ChallengeDeclined) => {
                                    send_pending_challenges(&client, &replier).await;
                                }
                                _ => {}
                            }
                        }
                    }
                    Err(_) => {
                        let json = serde_json::to_string(&BackendMessage::Reconnecting).unwrap();
                        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
                backoff_secs = (backoff_secs * 2).min(30);
            }
        });
    }
}

/// `/api/board/seek` and `/api/challenge/{username}` are long-poll endpoints --
/// confirmed live against production Lichess, not just from reading the plan's own
/// notes: a fire-and-forget POST that didn't drain its response never matched with
/// an opponent, while holding the same request open for ~20s matched immediately.
/// The seek/challenge stays active only while this connection is held. We don't
/// need the stream's *content* (the real `gameStart` arrives separately via the
/// account event stream already wired up in `spawn_streams`) -- just need to keep
/// consuming it in the background so the connection doesn't close early, without
/// blocking `handle_message` on however long it takes to get matched or time out.
/// Shared by the RequestChallenges dispatch and the account event stream's
/// challenge/challengeCanceled/challengeDeclined handling below -- both just need
/// a fresh GET /api/challenge snapshot pushed to the frontend.
async fn send_pending_challenges(client: &LichessClient, replier: &BackendReplier<LichessBackend>) {
    let msg = match client.get_challenges().await {
        Ok(challenges) => BackendMessage::PendingChallenges {
            challenges: challenges
                .into_iter()
                .map(|c| crate::protocol::ChallengeInfo {
                    id: c.id,
                    challenger: c.challenger.name,
                    limit_seconds: c.time_control.limit,
                    increment_seconds: c.time_control.increment,
                })
                .collect(),
        },
        Err(e) => BackendMessage::ErrorMsg { message: e.to_string() },
    };
    let json = serde_json::to_string(&msg).expect("BackendMessage always serializes");
    let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
}

fn spawn_hold_connection_open(
    mut lines: std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        use futures_util::StreamExt;
        while lines.next().await.is_some() {}
    })
}

fn spawn_game_stream(
    client: LichessClient,
    game_id: String,
    replier: BackendReplier<LichessBackend>,
    session_handle: Arc<Mutex<Option<GameSession>>>,
    my_id: String,
) {
    tokio::spawn(async move {
        use futures_util::StreamExt;
        let mut backoff_secs: u64 = 1;
        let mut game_over = false;
        while !game_over {
            match client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await {
                Ok(mut lines) => {
                    backoff_secs = 1;
                    while let Some(line) = lines.next().await {
                        if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                            let mut guard = session_handle.lock().await;
                            let board_msg = match msg {
                                GameStreamMessage::Full(full) => {
                                    match GameSession::from_game_full(&full, &my_id) {
                                        Ok((s, board_msg)) => {
                                            *guard = Some(s);
                                            Some(board_msg)
                                        }
                                        Err(_) => None,
                                    }
                                }
                                GameStreamMessage::State(state) => match guard.as_mut() {
                                    Some(s) => {
                                        let is_over = state.status != "started";
                                        if is_over {
                                            game_over = true;
                                        }
                                        let result = s.apply_state_update(&state).ok();
                                        if is_over {
                                            Some(BackendMessage::GameOver {
                                                result: state.winner.clone().unwrap_or_else(|| "draw".into()),
                                                reason: state.status.clone(),
                                            })
                                        } else {
                                            result
                                        }
                                    }
                                    None => None,
                                },
                                // Doesn't touch `guard` -- opponent-connection status is
                                // orthogonal to the cached position/session state.
                                GameStreamMessage::Gone(gone) => Some(BackendMessage::OpponentGone {
                                    gone: gone.gone,
                                    claim_win_in_seconds: gone.claim_win_in_seconds,
                                }),
                                // Only the "player" room is relevant -- this app has no
                                // spectator mode, so a "spectator" room line has nowhere
                                // meaningful to be shown.
                                GameStreamMessage::Chat(chat) if chat.room == "player" => {
                                    Some(BackendMessage::ChatMessage { username: chat.username, text: chat.text })
                                }
                                GameStreamMessage::Chat(_) => None,
                            };
                            drop(guard);
                            if let Some(m) = board_msg {
                                let json = serde_json::to_string(&m).unwrap();
                                let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                            }
                            if game_over {
                                break;
                            }
                        }
                    }
                }
                Err(_) => {
                    let json = serde_json::to_string(&BackendMessage::Reconnecting).unwrap();
                    let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                }
            }
            if game_over {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
            backoff_secs = (backoff_secs * 2).min(30);
        }
    });
}

#[async_trait]
impl AppLoadBackend for LichessBackend {
    async fn handle_message(&mut self, replier: &BackendReplier<Self>, message: Message) {
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            if self.client.is_none() {
                if let Ok(saved_token) = std::fs::read_to_string(&self.token_path) {
                    let saved_token = saved_token.trim().to_string();
                    if !saved_token.is_empty() {
                        self.activate_token(replier, saved_token).await;
                    }
                }
            }
            return;
        }
        let Ok(frontend_msg) = serde_json::from_str::<FrontendMessage>(&message.contents) else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "malformed message from frontend".into() });
            return;
        };
        match frontend_msg {
            FrontendMessage::SaveToken { token } => self.handle_save_token(replier, token).await,
            FrontendMessage::RequestHome => self.handle_request_home(replier).await,
            FrontendMessage::CreateSeek { minutes, increment, rated, color } => {
                self.handle_create_seek(replier, minutes, increment, rated, color).await
            }
            FrontendMessage::CreateChallenge { username, minutes, increment, rated, color } => {
                let Some(client) = &self.client else { return };
                match client.create_challenge(&username, minutes, increment, rated, &color).await {
                    Ok(lines) => {
                        self.send(replier, &BackendMessage::ChallengeCreated);
                        self.pending_seek = Some(spawn_hold_connection_open(lines));
                    }
                    Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
                }
            }
            FrontendMessage::ChallengeAi { level, minutes, increment } => {
                let Some(client) = &self.client else { return };
                if let Err(e) = client.challenge_ai(level, minutes, increment).await {
                    self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                }
                // No ack sent on success: unlike a seek/challenge there's no waiting
                // step -- the game starts immediately and arrives the same way any
                // other game does, via the account event stream's gameStart (already
                // wired in spawn_streams).
            }
            FrontendMessage::CancelSeek => self.handle_cancel_seek(),
            FrontendMessage::MakeMove { from, to, promotion } => {
                self.handle_make_move(replier, from, to, promotion).await
            }
            FrontendMessage::Resign => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        // Previously discarded the result entirely (`let _ = ...`) --
                        // a failed resign (e.g. game already over) silently told the
                        // player nothing, unlike every other action here.
                        if let Err(e) = client.resign(&game_id).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::DrawAction { accept } => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.draw(&game_id, accept).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::TakebackAction { accept } => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.takeback(&game_id, accept).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::Abort => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.abort(&game_id).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::ClaimVictory => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.claim_victory(&game_id).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::ClaimDraw => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.claim_draw(&game_id).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::RequestChallenges => {
                let Some(client) = self.client.clone() else { return };
                send_pending_challenges(&client, replier).await;
            }
            FrontendMessage::AcceptChallenge { id } => {
                if let Some(client) = &self.client {
                    if let Err(e) = client.accept_challenge(&id).await {
                        self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                    }
                }
            }
            FrontendMessage::DeclineChallenge { id } => {
                if let Some(client) = &self.client {
                    if let Err(e) = client.decline_challenge(&id).await {
                        self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                    }
                }
            }
            FrontendMessage::SendChat { text } => {
                if let Some(client) = self.client.clone() {
                    if let Some(game_id) = self.current_game_id().await {
                        if let Err(e) = client.send_chat(&game_id, &text).await {
                            self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                        }
                    }
                }
            }
            FrontendMessage::RequestSettings => self.handle_request_settings(replier),
            FrontendMessage::SaveSettings { auto_queen_promotion } => {
                self.handle_save_settings(replier, auto_queen_promotion)
            }
            FrontendMessage::LogOut => self.handle_log_out(replier),
        }
    }
}
