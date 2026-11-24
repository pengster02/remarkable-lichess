use crate::credentials;
use crate::game::outcome::{outcome, termination_label};
use crate::game::session::GameSession;
use crate::game::rules::{analysis_position, apply_analysis_move, replay_uci_moves_with_history};
use crate::lichess::client::{board_stream_rejection, is_auth_rejection, LichessClient, LICHESS_BASE_URL};
use crate::lichess::oauth;
use crate::lichess::models::{ChallengeResolution, ChallengeResult, EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use crate::lichess::models::{GameHistoryFilters, HistoryGame, Perfs};
use crate::protocol::{
    BackendMessage, CloudEvaluationLine, FrontendMessage, FrontendRequest, GameAnalysisSummary,
    GameAction, HistoryGameSummary, MoveAnalysis, OngoingGameSummary, RatingSummary,
    OpponentDeparture, PlayerStatusSummary, MSG_TYPE_BACKEND_TO_FRONTEND,
};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::collections::HashSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};

type LineStream = Pin<Box<dyn futures_util::Stream<Item = String> + Send>>;
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MOVE_RECONCILIATION_TIMEOUT: Duration = Duration::from_secs(2);
const INITIAL_RECONNECT_DELAY: Duration = Duration::from_secs(1);

struct StreamReconnectDelay {
    next: Duration,
    maximum: Duration,
}

impl StreamReconnectDelay {
    fn new(maximum: Duration) -> Self {
        Self { next: INITIAL_RECONNECT_DELAY, maximum }
    }

    fn after_attempt(&mut self, received_for: Duration) -> Duration {
        // A fixed delay retries dead streams too quickly. Resetting at HTTP
        // 200 does the same when the server closes before delivering events.
        let delay = if received_for >= STREAM_IDLE_TIMEOUT {
            INITIAL_RECONNECT_DELAY
        } else {
            self.next
        };
        self.next = (delay * 2).min(self.maximum);
        delay
    }
}

struct GameStream {
    game_id: String,
    task: tokio::task::JoinHandle<()>,
}

struct AccountStream {
    task: tokio::task::JoinHandle<()>,
    challenge_refresh: mpsc::Sender<()>,
}

// Startup retries can reuse the saved sign-in. Sending every failure to OAuth
// forces needless sign-ins, and a second verifier can drift from token activation.
enum TokenCheck {
    Startup,
    SignIn,
}

enum ChallengeAction {
    Accept,
    Decline,
}

fn game_for_request<'a>(
    active: Option<&'a GameSession>,
    expected_game_id: Option<&str>,
) -> Result<&'a GameSession, &'static str> {
    let game = active.ok_or("No active game")?;
    if expected_game_id.is_some_and(|id| id != game.game_id) {
        return Err("The active game changed before this request could be sent.");
    }
    Ok(game)
}

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
    my_id: Option<String>,
    // Cached so a NEW_COORDINATOR after a frontend reload can re-send
    // TokenVerified without an extra get_account() round trip (see handle_message).
    username: Option<String>,
    session: Arc<Mutex<Option<GameSession>>>,
    // Lichess keeps the seek or direct challenge alive while this task holds
    // its response open. Closing the response cancels the outstanding request.
    pending_seek: Option<tokio::task::JoinHandle<()>>,
    account_stream: Option<AccountStream>,
    // The detached task waiting on the OAuth callback (see handle_start_login).
    // Held so CancelLogin -- and any restart of the flow -- can drop it, which
    // closes the listening port with it. Detached rather than awaited inline
    // because handle_message is the backend's only entry point: blocking it for
    // the whole five-minute sign-in window would leave Cancel and the
    // paste-a-token fallback queued behind it, unable to run.
    login_handle: Option<tokio::task::JoinHandle<()>>,
    game_stream: Option<GameStream>,
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
            account_stream: None,
            login_handle: None,
            game_stream: None,
            write_lock: Arc::new(std::sync::Mutex::new(())),
        }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        send_locked(replier, &self.write_lock, msg);
    }

    async fn activate_token(&mut self, replier: &BackendReplier<Self>, token: String, check: TokenCheck) {
        log::info!("activate_token: verifying token via get_account");
        let client = LichessClient::new(token.clone());
        match client.get_account().await {
            Ok(account) => {
                log::info!("activate_token: verified, username={}", account.username);
                // Releases the callback port when a token arrives some other
                // way (a pasted token, or a restart picking up the saved file)
                // while a QR sign-in is still waiting on its redirect.
                stop_task(&mut self.login_handle).await;
                self.stop_game_activity().await;
                if let Err(error) = credentials::save(&self.token_path, &token) {
                    log::warn!("could not persist verified sign-in: {error}");
                }
                self.client = Some(client);
                self.my_id = Some(account.id.clone());
                self.username = Some(account.username.clone());
                // Needed so GameSession can work out which color the local account is
                // playing (see game::session::resolve_your_color) and orient the board
                // accordingly, instead of always assuming white.
                self.send(replier, &BackendMessage::TokenVerified { username: account.username });
                self.spawn_account_stream(replier.clone());
            }
            Err(e) => {
                log::warn!("activate_token: verification failed: {e}");
                let reply = if matches!(check, TokenCheck::Startup) && !is_auth_rejection(&e) {
                    BackendMessage::AuthenticationCheckFailed {
                        message: "Could not verify your saved Lichess sign-in. Check your connection and try again.".into(),
                    }
                } else {
                    BackendMessage::TokenInvalid { reason: e.to_string() }
                };
                self.send(replier, &reply);
            }
        }
    }

    async fn handle_save_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        self.activate_token(replier, token, TokenCheck::SignIn).await;
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
                Ok(Ok(token)) => match credentials::save(&token_path, &token) {
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
        self.activate_token(replier, token, TokenCheck::SignIn).await;
    }

    async fn check_saved_sign_in(&mut self, replier: &BackendReplier<Self>) {
        match std::fs::read_to_string(&self.token_path) {
            Ok(token) if !token.trim().is_empty() => {
                self.activate_token(replier, token.trim().to_owned(), TokenCheck::Startup).await;
            }
            Ok(_) => self.send(replier, &BackendMessage::AuthenticationRequired),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.send(replier, &BackendMessage::AuthenticationRequired);
            }
            Err(error) => {
                log::warn!("could not read saved sign-in: {error}");
                self.send(replier, &BackendMessage::AuthenticationCheckFailed {
                    message: "Could not read your saved Lichess sign-in.".into(),
                });
            }
        }
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

    async fn handle_resume_game(&mut self, replier: &BackendReplier<Self>, game_id: String) {
        let Some(client) = self.client.clone() else { return };
        let Some(my_id) = self.my_id.clone() else { return };
        {
            let current = self.session.lock().await;
            if let Some(session) = current.as_ref().filter(|session| session.game_id == game_id) {
                // Keep snapshot publication in session order with the stream task.
                self.send(replier, &session.board_state());
                if let Some(players) = &session.player_statuses {
                    self.send(replier, &BackendMessage::PlayerStatuses {
                        game_id,
                        players: players.clone(),
                    });
                }
                return;
            }
        }
        if self.game_stream.as_ref().is_some_and(|stream| {
            stream.game_id == game_id && !stream.task.is_finished()
        }) {
            return;
        }
        self.stop_game_stream().await;
        let task = spawn_game_stream(
            client, game_id.clone(), replier.clone(), self.session.clone(), my_id, self.write_lock.clone(),
        );
        self.game_stream = Some(GameStream { game_id, task });
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
    /// `game::replay::fens_for_export` -- a pure, stateless operation
    /// independent of `self.session` (which models the *live*, currently
    /// in-progress game, if any) so reviewing an old game can never disturb
    /// whatever's actually being played right now.
    async fn handle_request_game_moves(
        &self,
        replier: &BackendReplier<Self>,
        game_id: String,
        request_id: Option<u32>,
    ) {
        let fail = |message| {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameMovesFailed { request_id, message },
                None => BackendMessage::ErrorMsg { message },
            };
            self.send(replier, &reply);
        };
        let Some(client) = self.client.clone() else {
            if request_id.is_some() {
                fail("Not signed in to Lichess".into());
            } else {
                self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            }
            return;
        };
        let export = match client.export_game(&game_id).await {
            Ok(export) => export,
            Err(e) => {
                fail(e.to_string());
                return;
            }
        };
        let moves: Vec<String> = export.moves.split_whitespace().map(str::to_string).collect();
        let fens = match crate::game::replay::fens_for_export(
            export.variant.as_deref(), export.initial_fen.as_deref(), &moves,
        ) {
            Ok(fens) => fens,
            Err(e) => {
                fail(format!("Could not replay this game: {e}"));
                return;
            }
        };
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
        self.send(replier, &BackendMessage::GameMoves { request_id, moves, fens, clock_ms, analysis });
    }

    async fn handle_request_cloud_evaluation(
        &self,
        replier: &BackendReplier<Self>,
        requested_fen: String,
        request_id: Option<u32>,
    ) {
        let Some(client) = self.client.clone() else {
            let reply = if request_id.is_some() {
                BackendMessage::CloudEvaluationFailed {
                    request_id, requested_fen, message: "Not signed in to Lichess".into(),
                }
            } else {
                BackendMessage::TokenInvalid { reason: "no token saved".into() }
            };
            self.send(replier, &reply);
            return;
        };
        match client.get_cloud_evaluation(&requested_fen).await {
            Ok(Some(cloud)) => {
                let Some(pv) = cloud.pvs.into_iter().next() else {
                    self.send(
                        replier,
                        &BackendMessage::CloudEvaluationUnavailable {
                            request_id,
                            requested_fen,
                        },
                    );
                    return;
                };
                match replay_uci_moves_with_history(&requested_fen, &pv.moves) {
                    Ok((_, best_line)) => self.send(
                        replier,
                        &BackendMessage::CloudEvaluation {
                            request_id,
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
                            request_id,
                            requested_fen,
                            message: format!("couldn't read cloud best line: {e}"),
                        },
                    ),
                }
            }
            Ok(None) => self.send(
                replier,
                &BackendMessage::CloudEvaluationUnavailable { request_id, requested_fen },
            ),
            Err(e) => self.send(
                replier,
                &BackendMessage::CloudEvaluationFailed {
                    request_id,
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
                    game_id: challenge.id,
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
        request_id: Option<u32>,
    ) {
        let result = match &self.client {
            Some(client) => client.create_seek(minutes, increment, rated, &color).await,
            None => Err(anyhow::anyhow!("Sign in to Lichess to find an opponent.")),
        };
        match result {
            Ok(lines) => {
                self.send(replier, &BackendMessage::SeekCreated { request_id });
                self.replace_pending_seek(spawn_seek_response(
                    lines, request_id, replier.clone(), self.write_lock.clone(),
                ));
            }
            Err(error) => {
                let message = error.to_string();
                let failure = match request_id {
                    Some(request_id) => BackendMessage::SeekFailed { request_id, message },
                    None => BackendMessage::ErrorMsg { message },
                };
                self.send(replier, &failure);
            }
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

    fn send_analysis_failure(&self, replier: &BackendReplier<Self>, request_id: Option<u32>, message: String) {
        let reply = match request_id {
            Some(request_id) => BackendMessage::AnalysisFailed { request_id, message },
            None => BackendMessage::ErrorMsg { message },
        };
        self.send(replier, &reply);
    }

    fn handle_request_analysis_position(&self, replier: &BackendReplier<Self>, fen: String, request_id: Option<u32>) {
        match analysis_position(&fen) {
            Ok((normalized_fen, legal_moves, in_check, status)) => self.send(
                replier,
                &BackendMessage::AnalysisPosition {
                    request_id,
                    requested_fen: fen,
                    fen: normalized_fen,
                    legal_moves: legal_moves.into_boxed_slice(),
                    in_check,
                    status,
                },
            ),
            Err(error) => self.send_analysis_failure(
                replier,
                request_id,
                format!("Invalid analysis position: {error}"),
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
        request_id: Option<u32>,
    ) {
        match apply_analysis_move(&fen, &from, &to, promotion.as_deref()) {
            Ok((next_fen, san, legal_moves, in_check, status)) => self.send(
                replier,
                &BackendMessage::AnalysisMove {
                    request_id,
                    from_fen: fen,
                    fen: next_fen,
                    san,
                    legal_moves: legal_moves.into_boxed_slice(),
                    in_check,
                    status,
                },
            ),
            Err(error) => self.send_analysis_failure(
                replier,
                request_id,
                format!("Analysis move rejected: {error}"),
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

    async fn handle_log_out(&mut self, replier: &BackendReplier<Self>) {
        stop_task(&mut self.login_handle).await;
        if let Err(error) = std::fs::remove_file(&self.token_path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                self.send(replier, &BackendMessage::LogoutFailed {
                    message: format!("Could not remove the saved sign-in: {error}"),
                });
                return;
            }
        }
        self.stop_game_activity().await;
        self.client = None;
        self.my_id = None;
        self.username = None;
        self.send(replier, &BackendMessage::AuthenticationRequired);
    }

    async fn stop_game_activity(&mut self) {
        stop_task(&mut self.pending_seek).await;
        if let Some(account) = self.account_stream.as_mut() {
            abort_task(&mut account.task).await;
            self.account_stream = None;
        }
        self.stop_game_stream().await;
    }

    async fn stop_game_stream(&mut self) {
        if let Some(stream) = self.game_stream.as_mut() {
            abort_task(&mut stream.task).await;
            self.game_stream = None;
        }
        *self.session.lock().await = None;
    }

    async fn execute_game_action<F, Fut>(
        &self,
        replier: &BackendReplier<Self>,
        action: GameAction,
        expected_game_id: Option<&str>,
        request: F,
    ) -> Option<String>
    where
        F: FnOnce(LichessClient, String) -> Fut,
        Fut: Future<Output = anyhow::Result<()>>,
    {
        let fail = |message| {
            let reply = match expected_game_id {
                Some(id) => BackendMessage::GameActionFailed {
                    game_id: id.to_owned(), action: action.clone(), message,
                },
                None => BackendMessage::ErrorMsg { message },
            };
            self.send(replier, &reply);
        };
        let Some(client) = self.client.clone() else {
            fail("Not connected to Lichess".into());
            return None;
        };
        let game_id = {
            let guard = self.session.lock().await;
            match game_for_request(guard.as_ref(), expected_game_id) {
                Ok(game) => game.game_id.clone(),
                Err(reason) => {
                    fail(reason.into());
                    return None;
                }
            }
        };
        match request(client, game_id.clone()).await {
            Ok(()) => {
                self.send(replier, &BackendMessage::GameActionCompleted { game_id: game_id.clone(), action });
                Some(game_id)
            }
            Err(error) => {
                fail(error.to_string());
                None
            }
        }
    }

    async fn handle_make_move(
        &mut self,
        replier: &BackendReplier<Self>,
        expected_game_id: Option<&str>,
        from: String,
        to: String,
        promotion: Option<String>,
    ) {
        let reject = |reason| BackendMessage::MoveRejected {
            game_id: expected_game_id.map(str::to_owned), reason,
        };
        let Some(client) = self.client.clone() else {
            self.send(replier, &reject("Not connected to Lichess".into()));
            return;
        };
        let result = {
            let guard = self.session.lock().await;
            let session = match game_for_request(guard.as_ref(), expected_game_id) {
                Ok(session) => session,
                Err(reason) => {
                    self.send(replier, &reject(reason.into()));
                    return;
                }
            };
            match session.try_move(&from, &to, promotion.as_deref()) {
                Ok(uci) => match session.preview_move(&uci) {
                    Ok(preview) => {
                        // A streamed update must not overtake the preview of this position.
                        self.send(replier, &preview);
                        Ok((uci, session.game_id.clone(), session.state.moves.clone()))
                    }
                    Err(error) => Err(Box::new(BackendMessage::MoveRejected {
                        game_id: Some(session.game_id.clone()),
                        reason: error.to_string(),
                    })),
                },
                Err(rejected) => Err(rejected),
            }
        };
        match result {
            Ok((uci, game_id, expected_moves)) => {
                let submitted_at = Instant::now();
                let response = client.make_move(&game_id, &uci).await;
                let elapsed = submitted_at.elapsed();
                if elapsed >= Duration::from_millis(750) {
                    log::warn!(
                        "make_move {game_id} {uci} took {}ms",
                        elapsed.as_millis()
                    );
                } else {
                    log::debug!(
                        "make_move {game_id} {uci} took {}ms",
                        elapsed.as_millis()
                    );
                }
                match response {
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
                        let mut guard = self.session.lock().await;
                        if let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) {
                            match session.apply_accepted_move(&expected_moves, &uci) {
                                Ok(Some(board_state)) => self.send(replier, &board_state),
                                Ok(None) => {}
                                Err(error) => log::warn!("couldn't apply accepted move locally: {error}"),
                            }
                        }
                    }
                    Err(error) => self.send(
                        replier,
                        &BackendMessage::MoveRejected { game_id: Some(game_id), reason: error.to_string() },
                    ),
                }
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }

    fn spawn_account_stream(&mut self, replier: BackendReplier<Self>) {
        let Some(client) = self.client.clone() else { return };
        let write_lock = self.write_lock.clone();
        // Keep one refresh queued behind the active fetch. Awaiting it inside the
        // stream blocked game events, and spawning per event overlaps requests.
        let (challenge_refresh, mut refreshes) = mpsc::channel(1);
        let event_refresh = challenge_refresh.clone();
        let task = tokio::spawn(async move {
            // Both futures drop together when the account is replaced or signed out.
            let refresh = async {
                while refreshes.recv().await.is_some() {
                    send_pending_challenges(&client, &replier, &write_lock).await;
                }
            };
            tokio::join!(read_account_events(&client, &replier, &write_lock, &event_refresh), refresh);
        });
        self.account_stream = Some(AccountStream { task, challenge_refresh });
    }

    fn queue_challenge_refresh(&self) {
        if let Some(account) = &self.account_stream {
            let _ = account.challenge_refresh.try_send(());
        }
    }

    async fn handle_challenge_action(
        &self,
        replier: &BackendReplier<Self>,
        id: String,
        request_id: Option<u32>,
        action: ChallengeAction,
    ) {
        let result = match (&self.client, &action) {
            (Some(client), ChallengeAction::Accept) => client.accept_challenge(&id).await,
            (Some(client), ChallengeAction::Decline) => client.decline_challenge(&id).await,
            (None, _) => Err(anyhow::anyhow!("Sign in to Lichess to respond to challenges.")),
        };
        match result {
            Ok(()) => {
                let reply = match action {
                    ChallengeAction::Accept => BackendMessage::ChallengeAccepted { game_id: id, request_id },
                    ChallengeAction::Decline => BackendMessage::ChallengeDeclined { challenge_id: id, request_id },
                };
                self.send(replier, &reply);
                self.queue_challenge_refresh();
            }
            Err(error) => {
                let message = error.to_string();
                let reply = match request_id {
                    Some(request_id) => BackendMessage::ChallengeActionFailed { challenge_id: id, request_id, message },
                    None => BackendMessage::ErrorMsg { message },
                };
                self.send(replier, &reply);
            }
        }
    }
}

async fn read_account_events(
    client: &LichessClient,
    replier: &BackendReplier<LichessBackend>,
    write_lock: &Arc<std::sync::Mutex<()>>,
    refresh_challenges: &mpsc::Sender<()>,
) {
    let mut reconnect = StreamReconnectDelay::new(Duration::from_secs(30));
    // Reconnect replays ongoing games. A per-connection set repeats old
    // starts, and remembering every finished game grows without bound.
    let mut announced_games = HashSet::new();
    loop {
        let mut received_for = Duration::ZERO;
        if let Ok(mut lines) = client.stream_lines("/api/stream/event").await {
            let connected_at = Instant::now();
            while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
                received_for = connected_at.elapsed();
                match parse_ndjson_line::<EventStreamMessage>(&line) {
                    Some(EventStreamMessage::GameStart { game }) => {
                        if !announced_games.insert(game.id.clone()) {
                            continue;
                        }
                        // Real-time seeks return no game ID. Match lobby/pool
                        // events, since using any start can open a challenge
                        // and requiring all seekers to Resume adds a tap.
                        let from_realtime_lobby =
                            matches!(game.source.as_deref(), Some("lobby" | "pool")) &&
                            game.speed.as_deref().is_some_and(|speed| speed != "correspondence");
                        send_locked(replier, write_lock, &BackendMessage::GameStarted {
                            game_id: game.id,
                            from_realtime_lobby,
                        });
                    }
                    Some(EventStreamMessage::Challenge)
                    | Some(EventStreamMessage::ChallengeCanceled)
                    | Some(EventStreamMessage::ChallengeDeclined) => {
                        let _ = refresh_challenges.try_send(());
                    }
                    Some(EventStreamMessage::GameFinish { game }) => {
                        announced_games.remove(&game.id);
                        if let Some(rating_diff) = game.rating_diff {
                            send_locked(replier, write_lock, &BackendMessage::RatingDiff {
                                game_id: game.id,
                                rating_diff,
                            });
                        }
                    }
                    _ => {}
                }
            }
        }
        let delay = reconnect.after_attempt(received_for);
        log::warn!("account event stream ended; retrying in {delay:?}");
        tokio::time::sleep(delay).await;
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

async fn stop_task(slot: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(handle) = slot.as_mut() {
        abort_task(handle).await;
        *slot = None;
    }
}

async fn abort_task(task: &mut tokio::task::JoinHandle<()>) {
    // Borrow across the join so cancellation retains the handle. Abort alone
    // permits a late update, and taking the handle first can lose it mid-wait.
    task.abort();
    let _ = task.await;
}

async fn next_stream_line(
    lines: &mut LineStream,
    idle_timeout: Duration,
) -> Result<Option<String>, tokio::time::error::Elapsed> {
    use futures_util::StreamExt;
    tokio::time::timeout(idle_timeout, lines.next()).await
}

fn spawn_seek_response(
    mut lines: LineStream,
    request_id: Option<u32>,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Ok(Some(_)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {}
        drop(lines);
        send_locked(&replier, &write_lock, &BackendMessage::SeekEnded { request_id });
    })
}

fn spawn_challenge_response(
    mut lines: LineStream,
    game_id: String,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut error = Some("Lost the challenge connection. Check Home if the game started.".into());
        while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
            if let Some(result) = parse_ndjson_line::<ChallengeResult>(&line) {
                error = match result.done {
                    ChallengeResolution::Accepted => None,
                    ChallengeResolution::Declined => Some("Challenge declined.".into()),
                    ChallengeResolution::Canceled => Some("Challenge canceled.".into()),
                };
                break;
            }
        }
        send_locked(&replier, &write_lock, &BackendMessage::ChallengeResolved { game_id, error });
    })
}

async fn refresh_player_statuses(
    client: LichessClient,
    game_id: String,
    user_ids: Vec<String>,
    replier: BackendReplier<LichessBackend>,
    session_handle: Arc<Mutex<Option<GameSession>>>,
    write_lock: Arc<std::sync::Mutex<()>>,
) {
    let rows = match client.get_user_statuses(&user_ids).await {
        Ok(rows) => rows,
        Err(error) => {
            log::debug!("optional player status lookup failed: {error}");
            return;
        }
    };
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
    let mut guard = session_handle.lock().await;
    let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) else {
        return;
    };
    session.player_statuses = Some(players.clone());
    send_locked(&replier, &write_lock, &BackendMessage::PlayerStatuses { game_id, players });
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
        let mut reconnect = StreamReconnectDelay::new(Duration::from_secs(5));
        let mut stream_finished = false;
        // Waiting inline stalls moves. A detached lookup outlives a game switch.
        let mut player_status_requests = tokio::task::JoinSet::new();
        while !stream_finished {
            let mut received_for = Duration::ZERO;
            let response = client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await;
            if let Some(message) = response.as_ref().err().and_then(board_stream_rejection) {
                *session_handle.lock().await = None;
                send_locked(&replier, &write_lock, &BackendMessage::GameStreamFailed {
                    game_id,
                    message: message.into(),
                });
                return;
            }
            if let Ok(mut lines) = response {
                let connected_at = Instant::now();
                let mut resync_deadline: Option<Instant> = None;
                let mut opponent_departure = None;
                loop {
                    let timeout = resync_deadline.map_or(STREAM_IDLE_TIMEOUT, |deadline| {
                        deadline.saturating_duration_since(Instant::now())
                    });
                    if timeout.is_zero() {
                        break;
                    }
                    let Ok(Some(line)) = next_stream_line(&mut lines, timeout).await else { break };
                    received_for = connected_at.elapsed();
                    if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                            let mut status_ids = None;
                            let mut guard = session_handle.lock().await;
                            let board_msg = match msg {
                                // A finished game can send only one Full snapshot
                                // before EOF, which would otherwise trigger a retry.
                                GameStreamMessage::Full(full) => {
                                    match GameSession::from_game_full(&full, &my_id) {
                                        Ok((mut s, mut board_msg)) => {
                                            resync_deadline = None;
                                            if let Some(previous) = guard.as_mut().filter(|session| {
                                                session.game_id == s.game_id
                                            }) {
                                                s.player_statuses = previous.player_statuses.take();
                                                if previous.berserked {
                                                    s.mark_berserked();
                                                }
                                            }
                                            s.opponent_departure = opponent_departure;
                                            if s.berserked || opponent_departure.is_some() {
                                                board_msg = s.board_state();
                                            }
                                            if full.state.status != "started" {
                                                stream_finished = true;
                                                *guard = None;
                                                Some(board_msg)
                                            } else {
                                                let _ = player_status_requests.try_join_next();
                                                if s.player_statuses.is_none() && player_status_requests.is_empty() {
                                                    status_ids = Some([s.your_player.id.clone(), s.opponent_player.id.clone()]
                                                        .into_iter()
                                                        .flatten()
                                                        .collect::<Vec<_>>());
                                                }
                                                *guard = Some(s);
                                                Some(board_msg)
                                            }
                                        }
                                        Err(e) => {
                                            log::warn!("from_game_full failed for game {}: {e}", full.id);
                                            stream_finished = true;
                                            *guard = None;
                                            Some(BackendMessage::GameStreamFailed {
                                                game_id: game_id.clone(),
                                                message: format!("Couldn't load this game: {e}"),
                                            })
                                        }
                                    }
                                }
                                GameStreamMessage::State(state) => match guard.as_mut() {
                                    Some(s) if s.game_id == game_id => {
                                        let is_over = state.status != "started";
                                        let fallback = is_over.then(|| outcome(&state.status, state.winner.as_deref()));
                                        let result = match s.apply_stream_update(state) {
                                            Ok(Some(msg)) => {
                                                resync_deadline = None;
                                                Some(msg)
                                            }
                                            Ok(None) => {
                                                // This may be an old frame or a missed takeback.
                                                // Applying it immediately can undo the accepted move;
                                                // ignoring it indefinitely can leave a stale board.
                                                // If the stream stays ambiguous, reopen for a full snapshot.
                                                resync_deadline.get_or_insert_with(|| Instant::now() + MOVE_RECONCILIATION_TIMEOUT);
                                                None
                                            }
                                            Err(error) => {
                                                log::warn!(
                                                    "couldn't apply gameState for {game_id}: {error}"
                                                );
                                                fallback.map(|outcome| BackendMessage::GameOver {
                                                    game_id: game_id.clone(),
                                                    result: outcome.result,
                                                    reason: outcome.reason,
                                                })
                                            }
                                        };
                                        if is_over {
                                            stream_finished = true;
                                            *guard = None;
                                        }
                                        result
                                    }
                                    _ => None,
                                },
                                GameStreamMessage::Gone(gone) => {
                                    opponent_departure = gone.gone.then_some(OpponentDeparture {
                                        claim_win_in_seconds: gone.claim_win_in_seconds,
                                    });
                                    guard.as_mut()
                                        .filter(|s| s.game_id == game_id && s.is_stream_connected())
                                        .map(|s| {
                                            s.opponent_departure = opponent_departure;
                                            BackendMessage::OpponentGone {
                                                game_id: game_id.clone(),
                                                gone: gone.gone,
                                                claim_win_in_seconds: gone.claim_win_in_seconds,
                                            }
                                        })
                                }
                                GameStreamMessage::Chat => None,
                            };
                            if let Some(m) = board_msg {
                                send_locked(&replier, &write_lock, &m);
                            }
                            drop(guard);
                            if let Some(ids) = status_ids.filter(|ids| !ids.is_empty()) {
                                player_status_requests.spawn(refresh_player_statuses(
                                    client.clone(),
                                    game_id.clone(),
                                    ids,
                                    replier.clone(),
                                    session_handle.clone(),
                                    write_lock.clone(),
                                ));
                            }
                        if stream_finished {
                            break;
                        }
                    }
                }
            }
            if stream_finished {
                break;
            }
            let delay = reconnect.after_attempt(received_for);
            log::warn!("game stream {game_id} ended; retrying in {delay:?}");
            {
                let mut guard = session_handle.lock().await;
                if let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) {
                    session.mark_stream_disconnected();
                }
                send_locked(
                    &replier,
                    &write_lock,
                    &BackendMessage::GameStreamReconnecting { game_id: game_id.clone() },
                );
            }
            tokio::time::sleep(delay).await;
        }
    })
}

#[cfg(test)]
mod stream_watchdog_tests {
    use super::{
        game_for_request, next_stream_line, GameSession, GameStream, LichessBackend, LineStream,
        StreamReconnectDelay, STREAM_IDLE_TIMEOUT,
    };
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn reconnect_backs_off_until_a_stream_delivers_sustained_progress() {
        let mut reconnect = StreamReconnectDelay::new(Duration::from_secs(5));
        for expected in [1, 2, 4, 5, 5] {
            assert_eq!(reconnect.after_attempt(Duration::ZERO), Duration::from_secs(expected));
        }
        assert_eq!(
            reconnect.after_attempt(STREAM_IDLE_TIMEOUT - Duration::from_millis(1)),
            Duration::from_secs(5),
        );
        assert_eq!(reconnect.after_attempt(STREAM_IDLE_TIMEOUT), Duration::from_secs(1));
        assert_eq!(reconnect.after_attempt(Duration::ZERO), Duration::from_secs(2));
    }

    #[test]
    fn a_command_cannot_target_the_replacement_game() {
        let full = serde_json::from_value(serde_json::json!({
            "id": "current", "rated": false, "initialFen": "startpos",
            "variant": {"key": "standard", "name": "Standard"},
            "white": {"id": "player"}, "black": {"id": "opponent"},
            "state": {"moves": "", "wtime": 0, "btime": 0, "winc": 0, "binc": 0, "status": "started"}
        })).unwrap();
        let (active, _) = GameSession::from_game_full(&full, "player").unwrap();

        assert!(game_for_request(Some(&active), Some("previous")).is_err());
        assert!(game_for_request(None, Some("previous")).is_err());
        assert_eq!(game_for_request(Some(&active), Some("current")).unwrap().game_id, "current");
        assert_eq!(game_for_request(Some(&active), None).unwrap().game_id, "current");
    }

    #[tokio::test]
    async fn stopping_a_game_stream_waits_for_the_old_task_to_stop() {
        let owner = Arc::new(());
        let old_stream = tokio::spawn({
            let owner = Arc::clone(&owner);
            async move {
                std::future::pending::<()>().await;
                drop(owner);
            }
        });
        let mut backend = LichessBackend::new("unused-token".into());
        backend.game_stream = Some(GameStream { game_id: "old".into(), task: old_stream });
        backend.stop_game_stream().await;
        assert_eq!(Arc::strong_count(&owner), 1);
        assert!(backend.game_stream.is_none());
    }

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
                self.check_saved_sign_in(replier).await;
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
        let FrontendRequest { message: frontend_msg, expected_game_id } = match serde_json::from_str(&message.contents) {
            Ok(message) => message,
            Err(error) => {
                log::warn!("malformed frontend message at {}:{}", error.line(), error.column());
                self.send(replier, &BackendMessage::ErrorMsg { message: "malformed message from frontend".into() });
                return;
            }
        };
        let expected_game_id = expected_game_id.as_deref();
        if matches!(&frontend_msg, FrontendMessage::SaveToken { .. }) {
            log::debug!("frontend message: SaveToken");
        } else {
            log::debug!("frontend message: {frontend_msg:?}");
        }
        match frontend_msg {
            FrontendMessage::StartLogin => self.handle_start_login(replier).await,
            FrontendMessage::CancelLogin => self.handle_cancel_login(),
            FrontendMessage::ActivateSavedToken => self.handle_activate_saved_token(replier).await,
            FrontendMessage::RetryAuthentication => {
                if self.client.is_none() {
                    self.check_saved_sign_in(replier).await;
                }
            }
            FrontendMessage::SaveToken { token } => self.handle_save_token(replier, token).await,
            FrontendMessage::RequestHome => self.handle_request_home(replier).await,
            FrontendMessage::ResumeGame { game_id } => self.handle_resume_game(replier, game_id).await,
            FrontendMessage::CreateSeek { minutes, increment, rated, color, request_id } => {
                self.handle_create_seek(replier, minutes, increment, rated, color, request_id).await
            }
            FrontendMessage::CreateChallenge { username, minutes, increment, rated, color } => {
                let Some(client) = &self.client else { return };
                match client.create_challenge(&username, minutes, increment, rated, &color).await {
                    Ok((game_id, lines)) => {
                        self.send(replier, &BackendMessage::ChallengeCreated { game_id: game_id.clone() });
                        self.replace_pending_seek(spawn_challenge_response(
                            lines, game_id, replier.clone(), self.write_lock.clone(),
                        ));
                    }
                    Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
                }
            }
            FrontendMessage::ChallengeAi { level, minutes, increment } => {
                let Some(client) = &self.client else { return };
                match client.challenge_ai(level, minutes, increment).await {
                    Ok(game_id) => self.send(replier, &BackendMessage::ComputerGameCreated { game_id }),
                    Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
                }
            }
            FrontendMessage::CancelSeek => self.handle_cancel_seek(),
            FrontendMessage::MakeMove { from, to, promotion } => {
                self.handle_make_move(replier, expected_game_id, from, to, promotion).await
            }
            FrontendMessage::Resign => {
                self.execute_game_action(replier, GameAction::Resign, expected_game_id, |client, game_id| async move {
                    client.resign(&game_id).await
                })
                .await;
            }
            FrontendMessage::DrawAction { accept } => {
                self.execute_game_action(replier, GameAction::Draw, expected_game_id, |client, game_id| async move {
                    client.draw(&game_id, accept).await
                })
                .await;
            }
            FrontendMessage::TakebackAction { accept } => {
                self.execute_game_action(replier, GameAction::Takeback, expected_game_id, |client, game_id| async move {
                    client.takeback(&game_id, accept).await
                })
                .await;
            }
            FrontendMessage::Abort => {
                self.execute_game_action(replier, GameAction::Abort, expected_game_id, |client, game_id| async move {
                    client.abort(&game_id).await
                })
                .await;
            }
            FrontendMessage::Berserk => {
                if let Some(game_id) = self
                    .execute_game_action(replier, GameAction::Berserk, expected_game_id, |client, game_id| async move {
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
                    self.execute_game_action(replier, GameAction::AddTime, expected_game_id, |client, game_id| async move {
                        client.add_time(&game_id, seconds).await
                    })
                    .await;
                }
            }
            FrontendMessage::ClaimVictory => {
                self.execute_game_action(replier, GameAction::ClaimVictory, expected_game_id, |client, game_id| async move {
                    client.claim_victory(&game_id).await
                })
                .await;
            }
            FrontendMessage::ClaimDraw => {
                self.execute_game_action(replier, GameAction::ClaimDraw, expected_game_id, |client, game_id| async move {
                    client.claim_draw(&game_id).await
                })
                .await;
            }
            FrontendMessage::RequestChallenges => self.queue_challenge_refresh(),
            FrontendMessage::AcceptChallenge { id, request_id } => {
                self.handle_challenge_action(replier, id, request_id, ChallengeAction::Accept).await;
            }
            FrontendMessage::DeclineChallenge { id, request_id } => {
                self.handle_challenge_action(replier, id, request_id, ChallengeAction::Decline).await;
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
            FrontendMessage::LogOut => self.handle_log_out(replier).await,
            FrontendMessage::RequestGameHistory { rated, speed, color } => {
                self.handle_request_game_history(replier, rated, speed, color).await
            }
            FrontendMessage::CreateOpenChallenge { minutes, increment, rated } => {
                self.handle_create_open_challenge(replier, minutes, increment, rated).await
            }
            FrontendMessage::RequestGameMoves { game_id, request_id } => {
                self.handle_request_game_moves(replier, game_id, request_id).await
            }
            FrontendMessage::RequestCloudEvaluation { fen, request_id } => {
                self.handle_request_cloud_evaluation(replier, fen, request_id).await
            }
            FrontendMessage::RequestAnalysisPosition { fen, request_id } => {
                self.handle_request_analysis_position(replier, fen, request_id)
            }
            FrontendMessage::MakeAnalysisMove { fen, from, to, promotion, request_id } => {
                self.handle_make_analysis_move(replier, fen, from, to, promotion, request_id)
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
