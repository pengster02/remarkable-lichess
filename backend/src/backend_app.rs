use crate::game::session::GameSession;
use crate::game::rules::{analysis_position, apply_analysis_move, replay_uci_moves_with_history};
use crate::lichess::client::{LichessClient, LICHESS_BASE_URL};
use crate::lichess::oauth;
use crate::lichess::models::{EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use crate::lichess::models::{GameHistoryFilters, HistoryGame, Perfs};
use crate::protocol::{
    BackendMessage, CloudEvaluationLine, FrontendMessage, GameAnalysisSummary,
    GameAction, HistoryGameSummary, MoveAnalysis, OngoingGameSummary, RatingSummary,
    PlayerStatusSummary, MSG_TYPE_BACKEND_TO_FRONTEND,
};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

type LineStream = Pin<Box<dyn futures_util::Stream<Item = String> + Send>>;
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const STREAM_RECONNECT_MAX_BACKOFF_SECS: u64 = 5;

fn wifi_link_state_at(network_root: &Path) -> Option<bool> {
    let mut found = false;
    let mut connected = false;
    for entry in std::fs::read_dir(network_root).ok()?.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !path.join("wireless").exists()
            && !name.starts_with("wlan")
            && !name.starts_with("wlp")
        {
            continue;
        }
        found = true;
        let operstate = std::fs::read_to_string(path.join("operstate"))
            .unwrap_or_default();
        let carrier = std::fs::read_to_string(path.join("carrier"))
            .unwrap_or_else(|_| "1".to_string());
        if operstate.trim() == "up" && carrier.trim() != "0" {
            connected = true;
        }
    }
    found.then_some(connected)
}

fn wifi_link_state() -> Option<bool> {
    wifi_link_state_at(Path::new("/sys/class/net"))
}

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
    // Cached so a NEW_COORDINATOR after a frontend reload can re-send
    // TokenVerified without an extra get_account() round trip (see handle_message).
    username: Option<String>,
    session: Arc<Mutex<Option<GameSession>>>,
    // The held-open long-poll connection backing an outstanding seek or outgoing
    // challenge (see spawn_hold_connection_open's comment on why holding it open
    // is what keeps the seek/challenge alive on Lichess's side). Dropping/aborting
    // this task closes that connection, which is exactly how a real Lichess client
    // cancels a pending seek -- there's no separate "cancel" REST endpoint.
    pending_seek: Option<tokio::task::JoinHandle<()>>,
    // The account-wide event stream's own detached reconnect-loop task (see
    // spawn_streams) -- previously never stored anywhere, so handle_log_out
    // had no way to stop it. Left running past logout, it kept reconnecting
    // with the now-revoked token forever (spamming Reconnecting), and every
    // subsequent login spawned yet another one on top of it. Plain field
    // (not Arc<Mutex<>> like game_stream_handle) since only &mut self methods
    // ever touch it -- unlike a game stream, no detached task needs to
    // replace this one out from under spawn_streams itself.
    account_stream_handle: Option<tokio::task::JoinHandle<()>>,
    // The detached task waiting on the OAuth callback (see handle_start_login).
    // Held so CancelLogin -- and any restart of the flow -- can drop it, which
    // closes the listening port with it. Detached rather than awaited inline
    // because handle_message is the backend's only entry point: blocking it for
    // the whole five-minute sign-in window would leave Cancel and the
    // paste-a-token fallback queued behind it, unable to run.
    login_handle: Option<tokio::task::JoinHandle<()>>,
    // Shared (not a plain field) because a new game's stream can be spawned
    // either from handle_resume_game (&mut self) or from the account event
    // stream's own detached task on GameStart (see spawn_streams) -- both
    // need to abort whatever game stream was previously running, or a second
    // concurrent game overwrites `session` out from under the first, which is
    // exactly what caused the board to toggle between games and never
    // register one as over (confirmed live: 4 AI games ended up streaming at
    // once, each clobbering `session` with its own state).
    game_stream_handle: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    // appload-client's own send_message does two unsynchronized raw libc::send()
    // calls (header, then payload) with no locking at all -- confirmed by reading
    // its source. We spawn multiple concurrent tasks that each hold a cloned
    // BackendReplier over the same fd (the account event stream, plus one per
    // in-progress game), so without this, two tasks sending at the same instant
    // can interleave their header/payload writes and corrupt the framing --
    // reproduced live as a real "Message exceeds MAX_MESSAGE_LENGTH" crash.
    // Every outgoing send in this file must go through send_locked() below.
    write_lock: Arc<std::sync::Mutex<()>>,
}

impl LichessBackend {
    pub fn new(token_path: PathBuf) -> Self {
        let settings_path = token_path.with_file_name("settings.json");
        Self {
            token_path,
            settings_path,
            client: None,
            my_id: None,
            username: None,
            session: Arc::new(Mutex::new(None)),
            pending_seek: None,
            account_stream_handle: None,
            login_handle: None,
            game_stream_handle: Arc::new(Mutex::new(None)),
            write_lock: Arc::new(std::sync::Mutex::new(())),
        }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        send_locked(replier, &self.write_lock, msg);
    }

    async fn activate_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        log::info!("activate_token: verifying token via get_account");
        let client = LichessClient::new(token.clone());
        match client.get_account().await {
            Ok(account) => {
                log::info!("activate_token: verified, username={}", account.username);
                // Releases the callback port when a token arrives some other
                // way (a pasted token, or a restart picking up the saved file)
                // while a QR sign-in is still waiting on its redirect.
                self.handle_cancel_login();
                let _ = std::fs::write(&self.token_path, &token);
                self.client = Some(client);
                self.my_id = Some(account.id.clone());
                self.username = Some(account.username.clone());
                // Needed so GameSession can work out which color the local account is
                // playing (see game::session::resolve_your_color) and orient the board
                // accordingly, instead of always assuming white.
                self.spawn_streams(replier.clone(), account.id.clone());
                self.send(replier, &BackendMessage::TokenVerified { username: account.username });
            }
            Err(e) => {
                log::warn!("activate_token: rejected: {e}");
                self.send(replier, &BackendMessage::TokenInvalid { reason: e.to_string() });
            }
        }
    }

    async fn handle_save_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        self.activate_token(replier, token).await;
    }

    /// The top status bar is on every screen, but every other connectivity
    /// report comes out of handle_request_home, which returns early without a
    /// token -- so before sign-in nothing ever set it and it sat on
    /// "Connecting..." forever. Detached so the sign-in QR isn't held up behind
    /// a network round trip.
    fn spawn_connectivity_report(&self, replier: &BackendReplier<Self>) {
        let replier = replier.clone();
        let write_lock = Arc::clone(&self.write_lock);
        tokio::spawn(async move {
            let wifi_connected = wifi_link_state();
            // No point probing Lichess when the link itself is down, and the
            // wait would be a timeout rather than an answer.
            let online = wifi_connected != Some(false)
                && crate::lichess::client::is_reachable(LICHESS_BASE_URL).await;
            let message = if online {
                None
            } else if wifi_connected == Some(false) {
                Some("Wi-Fi is disconnected".to_owned())
            } else {
                Some("Can't reach Lichess".to_owned())
            };
            send_locked(
                &replier,
                &write_lock,
                &BackendMessage::ConnectivityState { online, wifi_connected, message },
            );
        });
    }

    async fn handle_start_login(&mut self, replier: &BackendReplier<Self>) {
        self.handle_cancel_login();
        self.spawn_connectivity_report(replier);
        let pending = match oauth::begin(LICHESS_BASE_URL).await {
            Ok(pending) => pending,
            Err(e) => {
                log::warn!("start_login: {e}");
                self.send(replier, &BackendMessage::LoginFailed { reason: e.to_string() });
                return;
            }
        };
        let (qr_size, qr_rows) = match oauth::qr_rows(&pending.authorize_url) {
            Ok(qr) => qr,
            Err(e) => {
                log::warn!("start_login: {e}");
                self.send(replier, &BackendMessage::LoginFailed { reason: e.to_string() });
                return;
            }
        };
        self.send(
            replier,
            &BackendMessage::LoginChallenge {
                authorize_url: pending.authorize_url.clone(),
                qr_size,
                qr_rows,
                expires_in_secs: oauth::LOGIN_TIMEOUT.as_secs(),
            },
        );

        let replier = replier.clone();
        let write_lock = Arc::clone(&self.write_lock);
        let token_path = self.token_path.clone();
        self.login_handle = Some(tokio::spawn(async move {
            let outcome = tokio::time::timeout(oauth::LOGIN_TIMEOUT, pending.complete(LICHESS_BASE_URL)).await;
            let message = match outcome {
                Ok(Ok(token)) => match std::fs::write(&token_path, &token) {
                    Ok(()) => BackendMessage::LoginCompleted,
                    Err(e) => BackendMessage::LoginFailed {
                        reason: format!("couldn't save the token on this device: {e}"),
                    },
                },
                Ok(Err(e)) => BackendMessage::LoginFailed { reason: e.to_string() },
                Err(_) => BackendMessage::LoginFailed {
                    reason: "the sign-in code expired -- start again".to_owned(),
                },
            };
            send_locked(&replier, &write_lock, &message);
        }));
    }

    fn handle_cancel_login(&mut self) {
        if let Some(handle) = self.login_handle.take() {
            handle.abort();
        }
    }

    async fn handle_activate_saved_token(&mut self, replier: &BackendReplier<Self>) {
        let token = std::fs::read_to_string(&self.token_path)
            .map(|t| t.trim().to_owned())
            .unwrap_or_default();
        if token.is_empty() {
            self.send(replier, &BackendMessage::LoginFailed { reason: "no token saved".into() });
            return;
        }
        self.activate_token(replier, token).await;
    }

    async fn handle_request_home(&mut self, replier: &BackendReplier<Self>) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        let (playing_result, account_result) =
            tokio::join!(client.get_playing(), client.get_account());
        let ongoing_games = match playing_result {
            Ok(games) => games
                .into_iter()
                .map(|g| OngoingGameSummary {
                    game_id: g.game_id,
                    // `username` is absent for the built-in AI (only `ai` -- its
                    // level -- is present then, see PlayingOpponent's own comment),
                    // hence the same level-based fallback as game history's AI games.
                    opponent_name: g.opponent.as_ref().and_then(|o| {
                        o.username.clone().or_else(|| o.ai.map(|level| format!("Stockfish level {level}")))
                    }),
                    opponent_rating: g.opponent.as_ref().and_then(|o| o.rating),
                    is_my_turn: g.is_my_turn,
                })
                .collect(),
            Err(e) => {
                let wifi_connected = wifi_link_state();
                let message = if wifi_connected == Some(false) {
                    "Wi-Fi is disconnected"
                } else {
                    "Can't reach Lichess"
                };
                self.send(
                    replier,
                    &BackendMessage::ConnectivityState {
                        online: false,
                        wifi_connected,
                        message: Some(message.to_string()),
                    },
                );
                log::warn!("couldn't load Home: {e}");
                self.send(
                    replier,
                    &BackendMessage::HomeLoadFailed {
                        message: format!("{message}. Check your connection and retry."),
                    },
                );
                return;
            }
        };
        // A fresh snapshot on every Home visit (not just cached from login) --
        // ratings change from games played elsewhere while this app wasn't open.
        // Not fatal if this second call fails: the ongoing-games list above is
        // the part Home actually needs to be useful.
        let ratings = match account_result {
            Ok(account) => ratings_from_perfs(account.perfs),
            Err(_) => Vec::new(),
        };
        self.send(
            replier,
            &BackendMessage::ConnectivityState {
                online: true,
                wifi_connected: wifi_link_state(),
                message: None,
            },
        );
        self.send(replier, &BackendMessage::HomeState { ongoing_games, ratings });
    }

    /// gameStart (see spawn_streams) only fires once, when a game *begins* -- it
    /// never re-announces an already-in-progress game, so resuming any game
    /// listed on Home needs its stream actively (re)attached here first, or
    /// BoardScreen just navigates to an empty board with nothing feeding it.
    /// Replaces the old behavior of RequestHome auto-attaching whichever game
    /// happened to be `now_playing.first()` (see ResumeGame's own comment).
    async fn handle_resume_game(&mut self, replier: &BackendReplier<Self>, game_id: String) {
        let Some(client) = self.client.clone() else { return };
        let cached_state = self
            .session
            .lock()
            .await
            .as_ref()
            .filter(|session| session.game_id == game_id)
            .map(GameSession::board_state);
        if let Some(board_state) = cached_state {
            self.send(replier, &board_state);
            return;
        }
        let Some(my_id) = self.my_id.clone() else { return };
        let handle = spawn_game_stream(client, game_id, replier.clone(), self.session.clone(), my_id, self.write_lock.clone());
        replace_game_stream_handle(&self.game_stream_handle, handle).await;
    }

    async fn handle_request_game_history(
        &mut self,
        replier: &BackendReplier<Self>,
        rated: Option<bool>,
        speed: Option<String>,
        color: Option<String>,
    ) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        let Some(my_id) = self.my_id.clone() else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "not logged in yet".into() });
            return;
        };
        let filters = GameHistoryFilters { rated, speed, color };
        match client.get_game_history(&my_id, 20, &filters).await {
            Ok(games) => {
                let summaries = games.into_iter().map(|g| history_game_to_summary(g, &my_id)).collect();
                self.send(replier, &BackendMessage::GameHistory { games: summaries });
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    /// Fetches a finished game's move list and replays it once via
    /// `game::replay::fens_for_moves` -- a pure, stateless operation
    /// independent of `self.session` (which models the *live*, currently
    /// in-progress game, if any) so reviewing an old game can never disturb
    /// whatever's actually being played right now.
    async fn handle_request_game_moves(&mut self, replier: &BackendReplier<Self>, game_id: String) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        let export = match client.export_game(&game_id).await {
            Ok(export) => export,
            Err(e) => {
                self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                return;
            }
        };
        let moves: Vec<String> = export.moves.split_whitespace().map(str::to_string).collect();
        // Centiseconds (Lichess's own export unit, confirmed against
        // game-export-gameId.yaml) -> ms, matching every other clock field in
        // this protocol (white_time_ms/black_time_ms/initial_clock_ms/...).
        let clock_ms: Vec<u32> = export.clocks.iter().map(|cs| cs * 10).collect();
        let analysis: Vec<MoveAnalysis> = export
            .analysis
            .into_iter()
            .map(|a| MoveAnalysis {
                eval_cp: a.eval,
                mate_in: a.mate,
                judgment: a.judgment.as_ref().map(|j| j.name.clone()),
                judgment_comment: a.judgment.map(|j| j.comment),
            })
            .collect();
        match crate::game::replay::fens_for_moves(&moves) {
            Ok(fens) => self.send(replier, &BackendMessage::GameMoves { moves, fens, clock_ms, analysis }),
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: format!("replaying game moves: {e}") }),
        }
    }

    async fn handle_request_cloud_evaluation(
        &self,
        replier: &BackendReplier<Self>,
        requested_fen: String,
    ) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        match client.get_cloud_evaluation(&requested_fen).await {
            Ok(Some(cloud)) => {
                let Some(pv) = cloud.pvs.into_iter().next() else {
                    self.send(
                        replier,
                        &BackendMessage::CloudEvaluationUnavailable {
                            requested_fen,
                        },
                    );
                    return;
                };
                match replay_uci_moves_with_history(&requested_fen, &pv.moves) {
                    Ok((_, best_line)) => self.send(
                        replier,
                        &BackendMessage::CloudEvaluation {
                            requested_fen,
                            evaluation: CloudEvaluationLine {
                                eval_cp: pv.cp,
                                mate_in: pv.mate,
                                depth: cloud.depth,
                                knodes: cloud.knodes,
                                best_line,
                            },
                        },
                    ),
                    Err(e) => self.send(
                        replier,
                        &BackendMessage::CloudEvaluationFailed {
                            requested_fen,
                            message: format!("couldn't read cloud best line: {e}"),
                        },
                    ),
                }
            }
            Ok(None) => self.send(
                replier,
                &BackendMessage::CloudEvaluationUnavailable { requested_fen },
            ),
            Err(e) => self.send(
                replier,
                &BackendMessage::CloudEvaluationFailed {
                    requested_fen,
                    message: e.to_string(),
                },
            ),
        }
    }

    async fn handle_create_open_challenge(
        &mut self,
        replier: &BackendReplier<Self>,
        minutes: u32,
        increment: u32,
        rated: bool,
    ) {
        let Some(client) = &self.client else { return };
        match client.create_open_challenge(minutes, increment, rated).await {
            Ok(challenge) => self.send(
                replier,
                &BackendMessage::OpenChallengeCreated {
                    url: challenge.url,
                    url_white: challenge.url_white,
                    url_black: challenge.url_black,
                },
            ),
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
                self.replace_pending_seek(spawn_hold_connection_open(lines));
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    fn handle_cancel_seek(&mut self) {
        if let Some(handle) = self.pending_seek.take() {
            handle.abort();
        }
    }

    /// Aborts whatever hold-open task `pending_seek` already held (a seek or
    /// a user challenge -- both use this same field/hold-open mechanism)
    /// before storing the new one. A plain `self.pending_seek = Some(...)`
    /// just drops the old `JoinHandle`, which detaches rather than cancels
    /// the task -- the previous seek/challenge kept running and staying live
    /// on Lichess indefinitely, and `CancelSeek` could then only ever reach
    /// whichever one was newest.
    fn replace_pending_seek(&mut self, handle: tokio::task::JoinHandle<()>) {
        if let Some(old) = self.pending_seek.take() {
            old.abort();
        }
        self.pending_seek = Some(handle);
    }

    fn handle_request_settings(&self, replier: &BackendReplier<Self>) {
        let settings = crate::settings::load(&self.settings_path);
        self.send(
            replier,
            &BackendMessage::SettingsState {
                auto_queen_promotion: settings.auto_queen_promotion,
                move_confirmation: settings.move_confirmation,
                minimal_highlights: settings.minimal_highlights,
                premoves_enabled: settings.premoves_enabled,
                live_clock_enabled: settings.live_clock_enabled,
                board_theme: settings.board_theme,
                piece_set: settings.piece_set,
                show_coordinates: settings.show_coordinates,
                show_captured_pieces: settings.show_captured_pieces,
                highlight_last_move: settings.highlight_last_move,
                confirm_resign: settings.confirm_resign,
            },
        );
    }

    fn handle_request_analysis_position(&self, replier: &BackendReplier<Self>, fen: String) {
        match analysis_position(&fen) {
            Ok((normalized_fen, legal_moves, in_check, status)) => self.send(
                replier,
                &BackendMessage::AnalysisPosition {
                    requested_fen: fen,
                    fen: normalized_fen,
                    legal_moves: legal_moves.into_boxed_slice(),
                    in_check,
                    status,
                },
            ),
            Err(error) => self.send(
                replier,
                &BackendMessage::ErrorMsg { message: format!("invalid analysis position: {error}") },
            ),
        }
    }

    fn handle_make_analysis_move(
        &self,
        replier: &BackendReplier<Self>,
        fen: String,
        from: String,
        to: String,
        promotion: Option<String>,
    ) {
        match apply_analysis_move(&fen, &from, &to, promotion.as_deref()) {
            Ok((next_fen, san, legal_moves, in_check, status)) => self.send(
                replier,
                &BackendMessage::AnalysisMove {
                    from_fen: fen,
                    fen: next_fen,
                    san,
                    legal_moves: legal_moves.into_boxed_slice(),
                    in_check,
                    status,
                },
            ),
            Err(error) => self.send(
                replier,
                &BackendMessage::ErrorMsg { message: format!("analysis move rejected: {error}") },
            ),
        }
    }

    fn handle_save_settings(
        &self,
        replier: &BackendReplier<Self>,
        settings: crate::settings::AppSettings,
    ) {
        let settings = settings.normalized();
        if let Err(e) = crate::settings::save(&self.settings_path, &settings) {
            self.send(replier, &BackendMessage::ErrorMsg { message: format!("failed to save settings: {e}") });
            return;
        }
        // Echoed back rather than assumed -- the frontend already optimistically
        // shows the new toggle state, but this confirms the write actually
        // succeeded instead of silently drifting from what's on disk.
        self.send(
            replier,
            &BackendMessage::SettingsState {
                auto_queen_promotion: settings.auto_queen_promotion,
                move_confirmation: settings.move_confirmation,
                minimal_highlights: settings.minimal_highlights,
                premoves_enabled: settings.premoves_enabled,
                live_clock_enabled: settings.live_clock_enabled,
                board_theme: settings.board_theme,
                piece_set: settings.piece_set,
                show_coordinates: settings.show_coordinates,
                show_captured_pieces: settings.show_captured_pieces,
                highlight_last_move: settings.highlight_last_move,
                confirm_resign: settings.confirm_resign,
            },
        );
    }

    /// There was previously no in-app way to do this at all -- switching
    /// accounts or recovering from a revoked token meant editing files on the
    /// device directly. Reuses TokenInvalid to drive the frontend back to
    /// LoginScreen, same message it already handles for a rejected token.
    fn handle_log_out(&mut self, replier: &BackendReplier<Self>) {
        let _ = std::fs::remove_file(&self.token_path);
        self.client = None;
        self.my_id = None;
        self.handle_cancel_seek();
        // Otherwise the account event stream's reconnect loop keeps running
        // with the now-revoked token, spamming Reconnecting forever (see
        // account_stream_handle's own comment).
        if let Some(handle) = self.account_stream_handle.take() {
            handle.abort();
        }
        self.send(replier, &BackendMessage::TokenInvalid { reason: "logged out".into() });
    }

    /// Shared by every in-game action (resign/draw/takeback/abort/claim-victory) --
    /// they all just need the current game's id, nothing else from the session.
    async fn current_game_id(&self) -> Option<String> {
        let guard = self.session.lock().await;
        guard.as_ref().map(|s| s.game_id.clone())
    }

    async fn execute_game_action<F, Fut>(
        &self,
        replier: &BackendReplier<Self>,
        action: GameAction,
        request: F,
    ) -> Option<String>
    where
        F: FnOnce(LichessClient, String) -> Fut,
        Fut: Future<Output = anyhow::Result<()>>,
    {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "Not connected to Lichess".into() });
            return None;
        };
        let Some(game_id) = self.current_game_id().await else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "No active game".into() });
            return None;
        };
        match request(client, game_id.clone()).await {
            Ok(()) => {
                self.send(replier, &BackendMessage::GameActionCompleted { action });
                Some(game_id)
            }
            Err(error) => {
                self.send(replier, &BackendMessage::ErrorMsg { message: error.to_string() });
                None
            }
        }
    }

    async fn handle_make_move(&mut self, replier: &BackendReplier<Self>, from: String, to: String, promotion: Option<String>) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::MoveRejected { reason: "Not connected to Lichess".into() });
            return;
        };
        let result = {
            let guard = self.session.lock().await;
            let Some(session) = guard.as_ref() else {
                self.send(replier, &BackendMessage::MoveRejected { reason: "No active game".into() });
                return;
            };
            match session.try_move(&from, &to, promotion.as_deref()) {
                Ok(uci) => match session.preview_move(&uci) {
                    Ok(preview) => Ok((
                        uci,
                        session.game_id.clone(),
                        session.state.moves.clone(),
                        preview,
                    )),
                    Err(error) => Err(Box::new(BackendMessage::MoveRejected {
                        reason: error.to_string(),
                    })),
                },
                Err(rejected) => Err(rejected),
            }
        };
        match result {
            Ok((uci, game_id, expected_moves, preview)) => {
                self.send(replier, &preview);
                match client.make_move(&game_id, &uci).await {
                    Ok(()) => {
                        self.send(
                            replier,
                            &BackendMessage::MoveSubmitted {
                                game_id: game_id.clone(),
                                from,
                                to,
                                promotion,
                            },
                        );
                        let predicted = {
                            let mut guard = self.session.lock().await;
                            match guard.as_mut().filter(|session| session.game_id == game_id) {
                                Some(session) => session.apply_accepted_move(&expected_moves, &uci),
                                None => Ok(None),
                            }
                        };
                        match predicted {
                            Ok(Some(board_state)) => self.send(replier, &board_state),
                            Ok(None) => {}
                            Err(error) => log::warn!("couldn't apply accepted move locally: {error}"),
                        }
                    }
                    Err(error) => self.send(
                        replier,
                        &BackendMessage::MoveRejected { reason: error.to_string() },
                    ),
                }
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }

    pub fn spawn_streams(&mut self, replier: BackendReplier<Self>, my_id: String) {
        let Some(client) = self.client.clone() else { return };
        let session_handle = self.session.clone();
        let write_lock = self.write_lock.clone();
        let game_stream_handle = self.game_stream_handle.clone();
        // Abort whatever account event stream was already running before
        // starting a new one -- otherwise a second call here (e.g. logging
        // in again without an intervening logout) would leak the first one
        // exactly like the leak this field exists to prevent on logout.
        if let Some(old) = self.account_stream_handle.take() {
            old.abort();
        }
        let handle = tokio::spawn(async move {
            let mut backoff_secs: u64 = 1;
            loop {
                if let Ok(mut lines) = client.stream_lines("/api/stream/event").await {
                    backoff_secs = 1;
                    while let Ok(Some(line)) =
                        next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await
                    {
                        match parse_ndjson_line::<EventStreamMessage>(&line) {
                                Some(EventStreamMessage::GameStart { game }) => {
                                    log::info!("GameStart: {}", game.id);
                                    let handle = spawn_game_stream(
                                        client.clone(),
                                        game.id,
                                        replier.clone(),
                                        session_handle.clone(),
                                        my_id.clone(),
                                        write_lock.clone(),
                                    );
                                    replace_game_stream_handle(&game_stream_handle, handle).await;
                                }
                                Some(EventStreamMessage::Challenge)
                                | Some(EventStreamMessage::ChallengeCanceled)
                                | Some(EventStreamMessage::ChallengeDeclined) => {
                                    send_pending_challenges(&client, &replier, &write_lock).await;
                                }
                                // Best-effort match against whatever game is currently
                                // tracked, same "not exhaustive, server/session is still
                                // authoritative" posture as e.g. the Abort button's own
                                // comment -- if a new game has already replaced `session`
                                // by the time this arrives (or this event is for some
                                // other game entirely), silently drop it rather than
                                // misattribute a rating change to the wrong game.
                                Some(EventStreamMessage::GameFinish { game }) => {
                                    if let Some(rating_diff) = game.rating_diff {
                                        let is_current_game =
                                            session_handle.lock().await.as_ref().is_some_and(|s| s.game_id == game.id);
                                        if is_current_game {
                                            send_locked(&replier, &write_lock, &BackendMessage::RatingDiff { rating_diff });
                                        }
                                    }
                                }
                            _ => {}
                        }
                    }
                }
                log::warn!(
                    "account event stream ended; retrying in {backoff_secs}s"
                );
                tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
                backoff_secs = (backoff_secs * 2).min(30);
            }
        });
        self.account_stream_handle = Some(handle);
    }
}

/// Every outgoing send in this file funnels through here -- see write_lock's own
/// comment on LichessBackend for why a plain, uncoordinated replier.send_message()
/// call is unsafe once more than one task can be sending at once.
fn send_locked(replier: &BackendReplier<LichessBackend>, lock: &Arc<std::sync::Mutex<()>>, msg: &BackendMessage) {
    let json = serde_json::to_string(msg).expect("BackendMessage always serializes");
    let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
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
async fn send_pending_challenges(
    client: &LichessClient,
    replier: &BackendReplier<LichessBackend>,
    write_lock: &Arc<std::sync::Mutex<()>>,
) {
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
        Err(e) => {
            log::warn!("couldn't load challenges: {e}");
            BackendMessage::ChallengesLoadFailed {
                message: "Couldn't load challenges. Retry when connected.".to_string(),
            }
        }
    };
    send_locked(replier, write_lock, &msg);
}

/// Aborts whatever game stream was previously running before storing the new
/// one -- called from both handle_resume_game and the account event stream's
/// GameStart handler (see spawn_streams), the two places a game stream can
/// start, so only one is ever alive regardless of which path triggered it.
async fn replace_game_stream_handle(
    slot: &Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    new_handle: tokio::task::JoinHandle<()>,
) {
    let mut guard = slot.lock().await;
    if let Some(old) = guard.take() {
        old.abort();
    }
    *guard = Some(new_handle);
}

/// The live board stream's own equivalent of history_game_to_summary's
/// win/loss/draw derivation -- kept as its own function (not inlined at each
/// of GameOver's two call sites below) so both stay in sync. Distinct from
/// that history-side function's exact return shape though: this one has to
/// match BoardScreen.qml's existing GameOver contract, where `result` is
/// either a winning color ("white"/"black") or "draw", not "win"/"loss"/
/// "draw" from your own point of view -- `winner.unwrap_or_else(|| "draw")`
/// (the previous behavior here) mislabeled every no-winner, non-draw ending
/// (aborted, noStart, cheat, ...) as a draw. Falls back to the raw status
/// itself for those, same as history_game_to_summary's own fallback --
/// BoardScreen.qml's outcome text already handles a non-color/non-"draw"
/// result by just capitalizing it.
fn game_over_result(status: &str, winner: &Option<String>) -> String {
    match winner {
        Some(w) => w.clone(),
        None if matches!(status, "draw" | "stalemate") => "draw".to_string(),
        None => status.to_string(),
    }
}

fn game_over_message(status: &str, winner: &Option<String>) -> BackendMessage {
    BackendMessage::GameOver {
        result: game_over_result(status, winner),
        reason: termination_label(Some(status)),
    }
}

async fn next_stream_line(
    lines: &mut LineStream,
    idle_timeout: Duration,
) -> Result<Option<String>, tokio::time::error::Elapsed> {
    use futures_util::StreamExt;
    tokio::time::timeout(idle_timeout, lines.next()).await
}

fn spawn_hold_connection_open(
    mut lines: std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        use futures_util::StreamExt;
        while lines.next().await.is_some() {}
    })
}

fn spawn_player_status_request(
    client: LichessClient,
    game_id: String,
    user_ids: Vec<String>,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
) {
    tokio::spawn(async move {
        match client.get_user_statuses(&user_ids).await {
            Ok(rows) => {
                let players = rows
                    .into_iter()
                    .map(|row| PlayerStatusSummary {
                        id: row.id,
                        title: row.title,
                        online: row.online,
                        playing: row.playing,
                        streaming: row.streaming,
                        patron: row.patron || row.patron_color.is_some(),
                        flair: row.flair,
                    })
                    .collect::<Vec<_>>()
                    .into_boxed_slice();
                send_locked(
                    &replier,
                    &write_lock,
                    &BackendMessage::PlayerStatuses { game_id, players },
                );
            }
            Err(error) => log::debug!("optional player status lookup failed: {error}"),
        }
    });
}

fn spawn_game_stream(
    client: LichessClient,
    game_id: String,
    replier: BackendReplier<LichessBackend>,
    session_handle: Arc<Mutex<Option<GameSession>>>,
    my_id: String,
    write_lock: Arc<std::sync::Mutex<()>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut backoff_secs: u64 = 1;
        let mut game_over = false;
        let mut player_status_requested = false;
        while !game_over {
            let stream_started_at = Instant::now();
            if let Ok(mut lines) = client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await {
                while let Ok(Some(line)) =
                    next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await
                {
                    if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                            let mut status_ids = None;
                            let mut guard = session_handle.lock().await;
                            let board_msg = match msg {
                                // Checks `full.state.status` here, not just on a later
                                // State update -- this is also how a *resumed* game's
                                // stream first sees the world (see handle_resume_game),
                                // and Lichess still sends exactly one Full snapshot even
                                // for an already-finished game before closing the
                                // connection. Without this check, `game_over` was never
                                // set for that case (only the State arm below ever set
                                // it), so the outer loop treated the connection closing
                                // as a dropout and reconnected to the same finished game
                                // forever, every ~30s.
                                GameStreamMessage::Full(full) => {
                                    let was_berserked = guard
                                        .as_ref()
                                        .is_some_and(|session| {
                                            session.game_id == full.id && session.berserked
                                        });
                                    match GameSession::from_game_full(&full, &my_id) {
                                        Ok((mut s, mut board_msg)) => {
                                            if was_berserked {
                                                s.mark_berserked();
                                                board_msg = s.board_state();
                                            }
                                            if full.state.status != "started" {
                                                game_over = true;
                                                // Don't bother storing a session for a
                                                // game that's already over -- and clear
                                                // whatever stale one might still be here
                                                // from an earlier finished game (see the
                                                // clearing below, same reasoning).
                                                *guard = None;
                                                Some(game_over_message(
                                                    &full.state.status,
                                                    &full.state.winner,
                                                ))
                                            } else {
                                                if !player_status_requested {
                                                    let ids = [s.your_player.id.clone(), s.opponent_player.id.clone()]
                                                        .into_iter()
                                                        .flatten()
                                                        .collect::<Vec<_>>();
                                                    if !ids.is_empty() {
                                                        player_status_requested = true;
                                                        status_ids = Some(ids);
                                                    }
                                                }
                                                *guard = Some(s);
                                                Some(board_msg)
                                            }
                                        }
                                        // Previously silently `None` here -- a blank,
                                        // unexplained board with zero feedback, and no
                                        // trace of why in the logs either.
                                        Err(e) => {
                                            log::warn!("from_game_full failed for game {}: {e}", full.id);
                                            Some(BackendMessage::ErrorMsg {
                                                message: format!("Couldn't load this game: {e}"),
                                            })
                                        }
                                    }
                                }
                                GameStreamMessage::State(state) => match guard.as_mut() {
                                    Some(s) => {
                                        let is_over = state.status != "started";
                                        if is_over {
                                            game_over = true;
                                        }
                                        // Taken before apply_state_update consumes `state`,
                                        // and only when the game actually ended, so the
                                        // common in-progress update still clones nothing.
                                        let outcome = is_over
                                            .then(|| (state.status.clone(), state.winner.clone()));
                                        let result = match s.apply_state_update(state) {
                                            Ok(msg) => Some(msg),
                                            Err(error) => {
                                                log::warn!(
                                                    "couldn't apply gameState for {game_id}: {error}"
                                                );
                                                None
                                            }
                                        };
                                        if let Some((status, winner)) = outcome {
                                            let msg = Some(game_over_message(&status, &winner));
                                            // Otherwise this finished game's session sits
                                            // here indefinitely: handle_resume_game's
                                            // already_tracking check keys off `session`
                                            // being non-empty for this exact game_id, so a
                                            // stale entry here silently blocked ever
                                            // re-attaching a stream to it (e.g. tapping
                                            // Resume again on a game that just ended),
                                            // and current_game_id() would keep pointing
                                            // in-game actions (resign/draw/takeback) at a
                                            // dead game in the gap before the next one's
                                            // own Full snapshot overwrites this.
                                            *guard = None;
                                            msg
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
                                GameStreamMessage::Chat => None,
                            };
                            drop(guard);
                            if let Some(m) = board_msg {
                                send_locked(&replier, &write_lock, &m);
                            }
                            if let Some(ids) = status_ids {
                                spawn_player_status_request(
                                    client.clone(),
                                    game_id.clone(),
                                    ids,
                                    replier.clone(),
                                    write_lock.clone(),
                                );
                            }
                        if game_over {
                            break;
                        }
                    }
                }
            }
            if game_over {
                break;
            }
            log::warn!(
                "game stream {game_id} ended; retrying in {backoff_secs}s"
            );
            send_locked(
                &replier,
                &write_lock,
                &BackendMessage::GameStreamReconnecting,
            );
            tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
            // A stream that stayed healthy through the idle watchdog deserves a
            // fast retry. Alternatives were resetting after every HTTP 200 (the
            // observed 1s loop) or allowing 30s stale boards during live play.
            backoff_secs = if stream_started_at.elapsed() >= STREAM_IDLE_TIMEOUT {
                1
            } else {
                (backoff_secs * 2).min(STREAM_RECONNECT_MAX_BACKOFF_SECS)
            };
        }
    })
}

#[cfg(test)]
mod stream_watchdog_tests {
    use super::{next_stream_line, LineStream};
    use std::time::Duration;

    #[tokio::test]
    async fn idle_stream_times_out_so_the_reconnect_loop_can_run() {
        let mut lines: LineStream = Box::pin(futures_util::stream::pending());
        let result = next_stream_line(&mut lines, Duration::from_millis(10)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn active_stream_line_resets_progress_before_the_deadline() {
        let mut lines: LineStream =
            Box::pin(futures_util::stream::iter(vec!["keepalive".to_string()]));
        let result = next_stream_line(&mut lines, Duration::from_millis(10)).await;
        assert_eq!(result.unwrap(), Some("keepalive".to_string()));
    }
}

#[async_trait]
impl AppLoadBackend for LichessBackend {
    async fn handle_message(&mut self, replier: &BackendReplier<Self>, message: Message) {
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            if self.client.is_none() {
                match std::fs::read_to_string(&self.token_path) {
                    Ok(saved_token) => {
                        let saved_token = saved_token.trim().to_string();
                        if saved_token.is_empty() {
                            log::info!("NEW_COORDINATOR: token file empty, requesting sign-in");
                            self.send(replier, &BackendMessage::AuthenticationRequired);
                        } else {
                            log::info!("NEW_COORDINATOR: no client yet, retrying saved token");
                            self.activate_token(replier, saved_token).await;
                        }
                    }
                    Err(e) => {
                        log::info!("NEW_COORDINATOR: no saved token ({e}), requesting sign-in");
                        self.send(replier, &BackendMessage::AuthenticationRequired);
                    }
                }
            } else if let Some(username) = self.username.clone() {
                // The backend process outlives a frontend reload (see deploy.sh's own
                // note on backend/entry being a long-lived binary): without this, a
                // reload while already logged in re-creates LoginScreen fresh with
                // nothing to move it past the token prompt, since TokenVerified is the
                // only message that navigates it to Home (see main.qml).
                log::info!("NEW_COORDINATOR: already logged in as {username}, resending TokenVerified");
                self.send(replier, &BackendMessage::TokenVerified { username });
            }
            return;
        }
        let Ok(frontend_msg) = serde_json::from_str::<FrontendMessage>(&message.contents) else {
            log::warn!("malformed message from frontend: {}", message.contents);
            self.send(replier, &BackendMessage::ErrorMsg { message: "malformed message from frontend".into() });
            return;
        };
        log::debug!("frontend message: {frontend_msg:?}");
        match frontend_msg {
            FrontendMessage::StartLogin => self.handle_start_login(replier).await,
            FrontendMessage::CancelLogin => self.handle_cancel_login(),
            FrontendMessage::ActivateSavedToken => self.handle_activate_saved_token(replier).await,
            FrontendMessage::SaveToken { token } => self.handle_save_token(replier, token).await,
            FrontendMessage::RequestHome => self.handle_request_home(replier).await,
            FrontendMessage::ResumeGame { game_id } => self.handle_resume_game(replier, game_id).await,
            FrontendMessage::CreateSeek { minutes, increment, rated, color } => {
                self.handle_create_seek(replier, minutes, increment, rated, color).await
            }
            FrontendMessage::CreateChallenge { username, minutes, increment, rated, color } => {
                let Some(client) = &self.client else { return };
                match client.create_challenge(&username, minutes, increment, rated, &color).await {
                    Ok(lines) => {
                        self.send(replier, &BackendMessage::ChallengeCreated);
                        self.replace_pending_seek(spawn_hold_connection_open(lines));
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
                self.execute_game_action(replier, GameAction::Resign, |client, game_id| async move {
                    client.resign(&game_id).await
                })
                .await;
            }
            FrontendMessage::DrawAction { accept } => {
                self.execute_game_action(replier, GameAction::Draw, |client, game_id| async move {
                    client.draw(&game_id, accept).await
                })
                .await;
            }
            FrontendMessage::TakebackAction { accept } => {
                self.execute_game_action(replier, GameAction::Takeback, |client, game_id| async move {
                    client.takeback(&game_id, accept).await
                })
                .await;
            }
            FrontendMessage::Abort => {
                self.execute_game_action(replier, GameAction::Abort, |client, game_id| async move {
                    client.abort(&game_id).await
                })
                .await;
            }
            FrontendMessage::Berserk => {
                if let Some(game_id) = self
                    .execute_game_action(replier, GameAction::Berserk, |client, game_id| async move {
                        client.berserk(&game_id).await
                    })
                    .await
                {
                    let mut guard = self.session.lock().await;
                    if let Some(session) = guard.as_mut() {
                        if session.game_id == game_id {
                            session.mark_berserked();
                        }
                    }
                }
            }
            FrontendMessage::AddTime { seconds } => {
                if !(5..=60).contains(&seconds) {
                    self.send(replier, &BackendMessage::ErrorMsg { message: "Time gift must be between 5 and 60 seconds".into() });
                } else {
                    self.execute_game_action(replier, GameAction::AddTime, |client, game_id| async move {
                        client.add_time(&game_id, seconds).await
                    })
                    .await;
                }
            }
            FrontendMessage::ClaimVictory => {
                self.execute_game_action(replier, GameAction::ClaimVictory, |client, game_id| async move {
                    client.claim_victory(&game_id).await
                })
                .await;
            }
            FrontendMessage::ClaimDraw => {
                self.execute_game_action(replier, GameAction::ClaimDraw, |client, game_id| async move {
                    client.claim_draw(&game_id).await
                })
                .await;
            }
            FrontendMessage::RequestChallenges => {
                let Some(client) = self.client.clone() else { return };
                send_pending_challenges(&client, replier, &self.write_lock).await;
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
            FrontendMessage::RequestSettings => self.handle_request_settings(replier),
            FrontendMessage::SaveSettings {
                auto_queen_promotion,
                move_confirmation,
                minimal_highlights,
                premoves_enabled,
                live_clock_enabled,
                board_theme,
                piece_set,
                show_coordinates,
                show_captured_pieces,
                highlight_last_move,
                confirm_resign,
            } => {
                self.handle_save_settings(
                    replier,
                    crate::settings::AppSettings {
                        auto_queen_promotion,
                        move_confirmation,
                        minimal_highlights,
                        premoves_enabled,
                        live_clock_enabled,
                        board_theme,
                        piece_set,
                        show_coordinates,
                        show_captured_pieces,
                        highlight_last_move,
                        confirm_resign,
                    },
                )
            }
            FrontendMessage::LogOut => self.handle_log_out(replier),
            FrontendMessage::RequestGameHistory { rated, speed, color } => {
                self.handle_request_game_history(replier, rated, speed, color).await
            }
            FrontendMessage::CreateOpenChallenge { minutes, increment, rated } => {
                self.handle_create_open_challenge(replier, minutes, increment, rated).await
            }
            FrontendMessage::RequestGameMoves { game_id } => {
                self.handle_request_game_moves(replier, game_id).await
            }
            FrontendMessage::RequestCloudEvaluation { fen } => {
                self.handle_request_cloud_evaluation(replier, fen).await
            }
            FrontendMessage::RequestAnalysisPosition { fen } => {
                self.handle_request_analysis_position(replier, fen)
            }
            FrontendMessage::MakeAnalysisMove { fen, from, to, promotion } => {
                self.handle_make_analysis_move(replier, fen, from, to, promotion)
            }
        }
    }
}

/// Canonical Lichess display order for the standard speed categories (matches
/// the order their own profile page lists Bullet/Blitz/Rapid/Classical/
/// Correspondence in). A perf the account has never played comes back with
/// `games: 0` rather than being absent entirely -- filtered out here so Home
/// doesn't show a wall of "0" ratings for variants nobody's touched.
fn ratings_from_perfs(perfs: Option<Perfs>) -> Vec<RatingSummary> {
    let Some(perfs) = perfs else { return Vec::new() };
    [
        ("bullet", perfs.bullet),
        ("blitz", perfs.blitz),
        ("rapid", perfs.rapid),
        ("classical", perfs.classical),
        ("correspondence", perfs.correspondence),
    ]
    .into_iter()
    .filter_map(|(speed, perf)| {
        let perf = perf?;
        (perf.games > 0).then_some(RatingSummary { speed: speed.to_string(), rating: perf.rating })
    })
    .collect()
}

/// Reduces one GET /api/games/user row to this account's point of view --
/// your_color/result -- so the frontend never needs to know its own username
/// to render the history list. Matched by `id` (Lichess's canonical lowercased
/// username, confirmed against LightUser.yaml), not `name`, since `my_id` is
/// itself already that same canonical form (see Account.id).
fn history_game_to_summary(game: HistoryGame, my_id: &str) -> HistoryGameSummary {
    let you_are_white = game.players.white.user.as_ref().and_then(|u| u.id.as_deref()).is_some_and(|id| id == my_id);
    let your_color = if you_are_white { "white" } else { "black" };
    let you = if you_are_white { &game.players.white } else { &game.players.black };
    let opponent = if you_are_white { &game.players.black } else { &game.players.white };
    // `user` is None for the built-in AI (only `aiLevel` is present then, see
    // GamePlayerUser's own comment) -- without this fallback the frontend fell
    // back to its own generic "Opponent" placeholder for every AI game.
    let opponent_name = opponent
        .user
        .as_ref()
        .and_then(|u| u.name.clone())
        .or_else(|| opponent.ai_level.map(|level| format!("Stockfish level {level}")));
    let opponent_rating = opponent.rating;
    let result = match &game.winner {
        Some(w) if w == your_color => "win".to_string(),
        Some(_) => "loss".to_string(),
        // No winner and a real draw status -- stalemate is scored as a draw too.
        None if matches!(game.status.as_deref(), Some("draw") | Some("stalemate")) => "draw".to_string(),
        // No winner and *not* a draw status (aborted, noStart, etc.) -- shown
        // as-is rather than mislabeled "draw".
        None => game.status.clone().unwrap_or_else(|| "unknown".into()),
    };
    let termination = termination_label(game.status.as_deref());
    let your_analysis = you.analysis.as_ref().map(|a| GameAnalysisSummary {
        inaccuracies: a.inaccuracy,
        mistakes: a.mistake,
        blunders: a.blunder,
        acpl: a.acpl,
        accuracy: a.accuracy,
    });
    HistoryGameSummary {
        game_id: game.id,
        opponent_name,
        opponent_rating,
        your_color: your_color.to_string(),
        result,
        termination,
        rating_diff: you.rating_diff,
        your_analysis,
        rated: game.rated,
        speed: game.speed,
        opening_name: game.opening.map(|o| o.name),
        created_at_ms: game.created_at,
    }
}

/// Human-readable form of Lichess's own GameStatusName -- distinct from
/// `result` (win/loss/draw) above, since two "win"s can still differ in how
/// they actually happened (checkmate vs. an opponent resigning vs. running
/// out the clock), which win/loss/draw alone can't convey. Falls back to a
/// title-cased copy of the raw status for anything not explicitly listed here
/// (e.g. a future status Lichess adds) rather than hiding it as "unknown".
fn termination_label(status: Option<&str>) -> String {
    match status {
        Some("created") => "Game created".to_string(),
        Some("started") => "In progress".to_string(),
        Some("aborted") => "Aborted".to_string(),
        Some("mate") => "Checkmate".to_string(),
        Some("resign") => "Resignation".to_string(),
        Some("stalemate") => "Stalemate".to_string(),
        Some("timeout") => "Opponent left".to_string(),
        Some("outoftime") => "Time forfeit".to_string(),
        Some("draw") => "Draw".to_string(),
        Some("cheat") => "Cheat detected".to_string(),
        Some("noStart") => "Opponent didn't join".to_string(),
        Some("unknownFinish") => "Unknown finish".to_string(),
        Some("insufficientMaterialClaim") => "Insufficient material".to_string(),
        Some("variantEnd") => "Variant ending".to_string(),
        Some(other) => humanize_identifier(other),
        None => "Unknown".to_string(),
    }
}

fn humanize_identifier(value: &str) -> String {
    let mut spaced = String::new();
    for character in value.chars() {
        if character == '_' || character == '-' {
            if !spaced.ends_with(' ') {
                spaced.push(' ');
            }
        } else {
            if character.is_uppercase() && !spaced.is_empty() && !spaced.ends_with(' ') {
                spaced.push(' ');
            }
            spaced.push(character);
        }
    }

    let mut characters = spaced.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => "Unknown".to_string(),
    }
}

#[cfg(test)]
mod game_over_result_tests {
    use super::{game_over_message, game_over_result, termination_label};
    use crate::protocol::BackendMessage;

    #[test]
    fn a_real_winner_is_reported_as_their_color_regardless_of_status() {
        assert_eq!(game_over_result("mate", &Some("white".to_string())), "white");
        assert_eq!(game_over_result("resign", &Some("black".to_string())), "black");
        assert_eq!(game_over_result("outoftime", &Some("white".to_string())), "white");
    }

    #[test]
    fn a_genuine_no_winner_draw_or_stalemate_is_reported_as_draw() {
        assert_eq!(game_over_result("draw", &None), "draw");
        assert_eq!(game_over_result("stalemate", &None), "draw");
    }

    #[test]
    fn game_over_reason_is_human_readable() {
        assert_eq!(
            game_over_message("outoftime", &Some("black".to_string())),
            BackendMessage::GameOver {
                result: "black".to_string(),
                reason: "Time forfeit".to_string(),
            }
        );
    }

    #[test]
    fn every_official_game_status_has_a_readable_label() {
        let cases = [
            ("created", "Game created"),
            ("started", "In progress"),
            ("aborted", "Aborted"),
            ("mate", "Checkmate"),
            ("resign", "Resignation"),
            ("stalemate", "Stalemate"),
            ("timeout", "Opponent left"),
            ("draw", "Draw"),
            ("outoftime", "Time forfeit"),
            ("cheat", "Cheat detected"),
            ("noStart", "Opponent didn't join"),
            ("unknownFinish", "Unknown finish"),
            ("insufficientMaterialClaim", "Insufficient material"),
            ("variantEnd", "Variant ending"),
        ];

        for (status, label) in cases {
            assert_eq!(termination_label(Some(status)), label);
        }

        assert_eq!(
            termination_label(Some("futureFinishReason")),
            "Future Finish Reason"
        );
    }

    #[test]
    fn a_no_winner_non_draw_status_is_reported_as_itself_not_mislabeled_a_draw() {
        // The E7 regression this guards: an aborted game has no winner but
        // was never a draw either -- BoardScreen previously showed
        // "Game over: Draw (aborted)", which is simply wrong.
        assert_eq!(game_over_result("aborted", &None), "aborted");
        assert_eq!(game_over_result("noStart", &None), "noStart");
        assert_eq!(game_over_result("cheat", &None), "cheat");
    }
}

#[cfg(test)]
mod connectivity_tests {
    use super::wifi_link_state_at;

    #[test]
    fn wifi_link_state_distinguishes_connected_and_disconnected_interfaces() {
        let root = std::env::temp_dir().join(format!(
            "remarkable-lichess-network-test-{}",
            std::process::id()
        ));
        let interface = root.join("wlan0");
        std::fs::create_dir_all(interface.join("wireless")).unwrap();
        std::fs::write(interface.join("operstate"), "down\n").unwrap();
        std::fs::write(interface.join("carrier"), "0\n").unwrap();
        assert_eq!(wifi_link_state_at(&root), Some(false));

        std::fs::write(interface.join("operstate"), "up\n").unwrap();
        std::fs::write(interface.join("carrier"), "1\n").unwrap();
        assert_eq!(wifi_link_state_at(&root), Some(true));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn wifi_link_state_is_unknown_without_a_wireless_interface() {
        let root = std::env::temp_dir().join(format!(
            "remarkable-lichess-network-empty-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(root.join("eth0")).unwrap();
        assert_eq!(wifi_link_state_at(&root), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod pending_seek_tests {
    use super::LichessBackend;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    #[tokio::test]
    async fn replace_pending_seek_aborts_the_previous_handle_instead_of_leaking_it() {
        let mut backend = LichessBackend::new(std::env::temp_dir().join("remarkable-lichess-test-token"));
        let tick_count = Arc::new(AtomicU32::new(0));
        let counting_task = {
            let tick_count = tick_count.clone();
            tokio::spawn(async move {
                loop {
                    tick_count.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
        };
        // Store it as the *current* pending seek first -- this is what a
        // real first CreateSeek does; without this step the test would just
        // be replacing `None` and could never have caught the leak.
        backend.replace_pending_seek(counting_task);
        // Confirm it's actually running before replacing it -- otherwise a
        // tick count that stays at zero would trivially (and wrongly) pass.
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(tick_count.load(Ordering::SeqCst) > 0);

        backend.replace_pending_seek(tokio::spawn(futures_util::future::pending()));

        // Give the aborted task a moment to actually stop, then confirm its
        // tick count is no longer advancing -- a plain `self.pending_seek =
        // Some(new)` (the bug this guards) would leave it running forever.
        tokio::time::sleep(Duration::from_millis(30)).await;
        let count_after_replace = tick_count.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(tick_count.load(Ordering::SeqCst), count_after_replace);
    }
}

#[cfg(test)]
mod history_summary_tests {
    use super::history_game_to_summary;
    use crate::lichess::models::{GameOpening, GamePlayerUser, GamePlayers, HistoryGame, LightUser, PlayerAnalysisSummary};

    fn human(id: &str, name: &str, rating: u32) -> GamePlayerUser {
        human_with_rating_diff(id, name, rating, None)
    }

    fn human_with_rating_diff(id: &str, name: &str, rating: u32, rating_diff: Option<i32>) -> GamePlayerUser {
        GamePlayerUser {
            user: Some(LightUser { id: Some(id.to_string()), name: Some(name.to_string()) }),
            rating: Some(rating),
            ai_level: None,
            rating_diff,
            analysis: None,
        }
    }

    fn ai(level: u8, rating: u32) -> GamePlayerUser {
        GamePlayerUser { user: None, rating: Some(rating), ai_level: Some(level), rating_diff: None, analysis: None }
    }

    fn human_with_analysis(id: &str, name: &str, rating: u32, summary: PlayerAnalysisSummary) -> GamePlayerUser {
        GamePlayerUser {
            user: Some(LightUser { id: Some(id.to_string()), name: Some(name.to_string()) }),
            rating: Some(rating),
            ai_level: None,
            rating_diff: None,
            analysis: Some(summary),
        }
    }

    fn game(white: GamePlayerUser, black: GamePlayerUser) -> HistoryGame {
        game_with_status(white, black, "mate")
    }

    fn game_with_status(white: GamePlayerUser, black: GamePlayerUser, status: &str) -> HistoryGame {
        HistoryGame {
            id: "abcd1234".to_string(),
            rated: false,
            speed: Some("blitz".to_string()),
            status: Some(status.to_string()),
            created_at: Some(1),
            players: GamePlayers { white, black },
            winner: Some("white".to_string()),
            opening: Some(GameOpening { name: "Italian Game".to_string() }),
        }
    }

    #[test]
    fn a_human_opponent_uses_their_lichess_username() {
        let summary = history_game_to_summary(game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480)), "myuser");
        assert_eq!(summary.opponent_name, Some("Bob".to_string()));
        assert_eq!(summary.opponent_rating, Some(1480));
    }

    #[test]
    fn an_ai_opponent_with_no_lichess_account_falls_back_to_a_level_based_name() {
        let summary = history_game_to_summary(game(human("myuser", "MyUser", 1500), ai(5, 1400)), "myuser");
        assert_eq!(summary.opponent_name, Some("Stockfish level 5".to_string()));
        assert_eq!(summary.opponent_rating, Some(1400));
    }

    #[test]
    fn rating_diff_is_read_from_your_own_side_not_the_opponents() {
        let summary = history_game_to_summary(
            game(human_with_rating_diff("myuser", "MyUser", 1508, Some(8)), human_with_rating_diff("bob", "Bob", 1472, Some(-8))),
            "myuser",
        );
        assert_eq!(summary.rating_diff, Some(8));
    }

    #[test]
    fn termination_distinguishes_how_a_win_happened_from_the_bare_win_loss_draw_result() {
        let by_resignation = history_game_to_summary(
            game_with_status(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480), "resign"),
            "myuser",
        );
        assert_eq!(by_resignation.result, "win");
        assert_eq!(by_resignation.termination, "Resignation");

        let by_timeout = history_game_to_summary(
            game_with_status(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480), "outoftime"),
            "myuser",
        );
        assert_eq!(by_timeout.termination, "Time forfeit");
    }

    #[test]
    fn your_analysis_is_read_from_your_own_side_and_none_when_this_game_was_never_analyzed() {
        let summary_stats = PlayerAnalysisSummary { inaccuracy: 5, mistake: 2, blunder: 1, acpl: 26, accuracy: Some(90) };
        let analyzed = history_game_to_summary(
            game(human_with_analysis("myuser", "MyUser", 1500, summary_stats), human("bob", "Bob", 1480)),
            "myuser",
        );
        let your_analysis = analyzed.your_analysis.unwrap();
        assert_eq!(your_analysis.blunders, 1);
        assert_eq!(your_analysis.accuracy, Some(90));

        let unanalyzed =
            history_game_to_summary(game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480)), "myuser");
        assert_eq!(unanalyzed.your_analysis, None);
    }
}
