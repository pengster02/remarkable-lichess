use crate::credentials;
use crate::game::outcome::{outcome, termination_label};
use crate::game::session::GameSession;
use crate::game::rules::{analysis_position, apply_analysis_move, replay_uci_moves_with_history};
use crate::lichess::client::{board_stream_rejection, is_auth_rejection, is_rate_limited, LichessClient, LICHESS_BASE_URL};
use crate::lichess::oauth;
use crate::lichess::models::{ChallengeResolution, ChallengeResult, EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use crate::lichess::models::{GameHistoryFilters, HistoryGame, Perfs};
use crate::protocol::{
    BackendMessage, CloudEvaluationLine, FrontendMessage, FrontendRequest, GameAnalysisSummary,
    GameAction, GameActionRequest, HistoryGameSummary, MoveAnalysis, OngoingGameSummary, RatingSummary,
    MoveRequest, OfferRequest, OpponentDeparture, PlayerStatusSummary, MSG_TYPE_BACKEND_TO_FRONTEND,
};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR, MSG_SYSTEM_TERMINATE};
use async_trait::async_trait;
use std::collections::HashSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, Mutex};

type LineStream = Pin<Box<dyn futures_util::Stream<Item = String> + Send>>;
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MOVE_RECONCILIATION_TIMEOUT: Duration = Duration::from_secs(2);
const INITIAL_RECONNECT_DELAY: Duration = Duration::from_secs(1);
const CLOUD_QUEUE_CAPACITY: usize = 4;
const LICHESS_RATE_LIMIT_DELAY: Duration = Duration::from_secs(60);
const CLOUD_RATE_LIMIT_MESSAGE: &str = "Lichess is limiting cloud evaluations. Try again shortly.";

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

// Inline waits delay unrelated requests. Detached tasks can outlive the account
// or screen that owns the work.
struct GameRequest {
    request_id: Option<u32>,
    task: tokio::task::JoinHandle<()>,
    // An exclusive POST releases its slot before sending the reply. Joining
    // inline blocks the dispatcher, and is_finished can lag the UI reply.
    completion: Option<oneshot::Receiver<()>>,
}

impl GameRequest {
    fn matches(&self, request_id: Option<u32>) -> bool {
        request_id.is_some() && self.request_id == request_id
    }

    fn in_flight(&mut self) -> bool {
        self.completion.as_mut().is_some_and(|completion| {
            completion.try_recv() == Err(oneshot::error::TryRecvError::Empty)
        })
    }
}

enum MatchKind {
    Seek { rated: bool, color: String },
    Direct { username: String, rated: bool, color: String },
    Computer { level: u8 },
    Open { rated: bool },
}

struct MatchRequest {
    kind: MatchKind,
    minutes: u32,
    increment: u32,
    request_id: Option<u32>,
}

impl MatchRequest {
    fn is_creation(&self) -> bool {
        matches!(self.kind, MatchKind::Computer { .. } | MatchKind::Open { .. })
    }

    fn validate(&self) -> Result<(), &'static str> {
        let max_increment = if matches!(self.kind, MatchKind::Seek { .. }) { 180 } else { 60 };
        if self.minutes > 180 || self.increment > max_increment {
            return Err("Time control is outside the allowed range.");
        }
        if self.minutes == 0 && self.increment == 0 {
            return Err("Choose some starting time or an increment.");
        }
        if let MatchKind::Computer { level } = self.kind {
            if !(1..=8).contains(&level) {
                return Err("Computer level must be a whole number from 1 to 8.");
            }
        }
        Ok(())
    }

    fn failure(&self, message: String) -> BackendMessage {
        match (self.request_id, &self.kind) {
            (Some(request_id), MatchKind::Seek { .. }) => BackendMessage::SeekFailed { request_id, message },
            (Some(request_id), MatchKind::Direct { .. }) => {
                BackendMessage::ChallengeCreateFailed { request_id, message }
            }
            (Some(request_id), _) => BackendMessage::MatchCreationFailed { request_id, message },
            (None, _) => BackendMessage::ErrorMsg { message },
        }
    }
}

struct CloudEvaluationRequest {
    requested_fen: String,
    request_id: Option<u32>,
}

impl CloudEvaluationRequest {
    fn failed(self, message: String) -> BackendMessage {
        BackendMessage::CloudEvaluationFailed {
            request_id: self.request_id,
            requested_fen: self.requested_fen,
            message,
        }
    }
}

// One worker per review preserves separate positions. Inline requests delay
// board actions, while concurrent cloud lookups can exhaust API limits.
struct CloudEvaluationQueue {
    review_id: Option<u32>,
    requests: mpsc::Sender<CloudEvaluationRequest>,
    task: tokio::task::JoinHandle<()>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SignInMethod {
    Saved,
    Qr,
    Token,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct SignInRequest {
    method: SignInMethod,
    request_id: Option<u32>,
}

struct VerifiedSignIn {
    token: String,
    client: LichessClient,
    my_id: String,
    username: String,
}

// Keep verified credentials in memory until the screen confirms. Saving first
// can restore an abandoned login; keeping both stages alive retains old secrets.
enum SignInAttempt {
    Working { request: SignInRequest, task: tokio::task::JoinHandle<()> },
    Ready { request: SignInRequest, verified: VerifiedSignIn },
}

impl SignInAttempt {
    fn request(&self) -> SignInRequest {
        match self {
            Self::Working { request, .. } | Self::Ready { request, .. } => *request,
        }
    }
}

enum SignInError {
    Account(anyhow::Error),
    Qr(String),
}

impl SignInRequest {
    fn failure(self, error: SignInError) -> BackendMessage {
        let reason = match error {
            SignInError::Qr(reason) => reason,
            SignInError::Account(error) if is_auth_rejection(&error) => {
                if self.method == SignInMethod::Saved || self.request_id.is_none() {
                    return BackendMessage::TokenInvalid { reason: "Lichess rejected the sign-in.".into() };
                }
                "Lichess rejected this sign-in. Check the token and its permissions.".into()
            }
            SignInError::Account(_) if self.method == SignInMethod::Saved => {
                return BackendMessage::AuthenticationCheckFailed {
                    message: "Could not verify your saved Lichess sign-in. Check your connection and try again.".into(),
                };
            }
            SignInError::Account(_) if self.request_id.is_none() && self.method == SignInMethod::Token => {
                return BackendMessage::TokenInvalid { reason: "Could not verify the token.".into() };
            }
            SignInError::Account(_) => "Could not verify your sign-in. Check your connection and try again.".into(),
        };
        BackendMessage::LoginFailed { reason, request_id: self.request_id }
    }
}

enum ChallengeAction {
    Accept,
    Decline,
}

struct ChallengeRequest {
    challenge_id: String,
    request_id: Option<u32>,
    action: ChallengeAction,
}

impl ChallengeRequest {
    fn failure(&self, message: String) -> BackendMessage {
        match self.request_id {
            Some(request_id) => BackendMessage::ChallengeActionFailed {
                challenge_id: self.challenge_id.clone(), request_id, message,
            },
            None => BackendMessage::ErrorMsg { message },
        }
    }
}

struct MoveSubmission {
    game_id: String,
    expected_moves: String,
    uci: String,
    request: MoveRequest,
    canceled: oneshot::Receiver<()>,
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
    pending_match: Option<GameRequest>,
    account_stream: Option<AccountStream>,
    pending_challenge_action: Option<GameRequest>,
    home_games: Option<tokio::task::JoinHandle<()>>,
    home_ratings: Option<tokio::task::JoinHandle<()>>,
    home_games_retry_after: Arc<Mutex<Option<Instant>>>,
    history_load: Option<GameRequest>,
    review_export: Option<GameRequest>,
    cloud_evaluations: Option<CloudEvaluationQueue>,
    cloud_retry_after: Arc<Mutex<Option<Instant>>>,
    pending_sign_in: Option<SignInAttempt>,
    move_submission: Option<tokio::task::JoinHandle<()>>,
    game_action: Option<tokio::task::JoinHandle<()>>,
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
            pending_match: None,
            account_stream: None,
            pending_challenge_action: None,
            home_games: None,
            home_ratings: None,
            home_games_retry_after: Arc::new(Mutex::new(None)),
            history_load: None,
            review_export: None,
            cloud_evaluations: None,
            cloud_retry_after: Arc::new(Mutex::new(None)),
            pending_sign_in: None,
            move_submission: None,
            game_action: None,
            game_stream: None,
            write_lock: Arc::new(std::sync::Mutex::new(())),
        }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        send_locked(replier, &self.write_lock, msg);
    }

    fn spawn_sign_in(
        &mut self,
        replier: &BackendReplier<Self>,
        request: SignInRequest,
        verify: impl Future<Output = Result<VerifiedSignIn, SignInError>> + Send + 'static,
    ) {
        let replier = replier.clone();
        let task = tokio::spawn(async move {
            let result = verify.await;
            // AppLoad also uses this mutex for incoming commands. A worker
            // waits for it only after network I/O, so stop_sign_in can abort it
            // while it waits, and completion cannot overtake account teardown.
            let mut backend = replier.backend.lock().await;
            backend.sign_in_finished(&replier, request, result).await;
        });
        self.pending_sign_in = Some(SignInAttempt::Working { request, task });
    }

    async fn sign_in_finished(
        &mut self,
        replier: &BackendReplier<Self>,
        request: SignInRequest,
        result: Result<VerifiedSignIn, SignInError>,
    ) {
        if !matches!(&self.pending_sign_in, Some(SignInAttempt::Working { request: active, .. }) if *active == request) {
            return;
        }
        self.pending_sign_in = None;
        match (result, request.request_id) {
            (Ok(verified), Some(request_id)) => {
                self.pending_sign_in = Some(SignInAttempt::Ready { request, verified });
                self.send(replier, &BackendMessage::SignInReady { request_id });
            }
            (Ok(verified), None) => self.install_sign_in(replier, request, verified).await,
            (Err(error), _) => self.send(replier, &request.failure(error)),
        }
    }

    async fn complete_sign_in(&mut self, replier: &BackendReplier<Self>, request_id: u32) {
        if !matches!(&self.pending_sign_in,
            Some(SignInAttempt::Ready { request, .. }) if request.request_id == Some(request_id))
        {
            return;
        }
        if let Some(SignInAttempt::Ready { request, verified }) = self.pending_sign_in.take() {
            self.install_sign_in(replier, request, verified).await;
        }
    }

    async fn install_sign_in(&mut self, replier: &BackendReplier<Self>, request: SignInRequest, verified: VerifiedSignIn) {
        let VerifiedSignIn { token, client, my_id, username } = verified;
        if let Err(error) = credentials::save(&self.token_path, &token) {
            log::warn!("could not persist verified sign-in: {error}");
            if request.request_id.is_some() {
                self.send(replier, &BackendMessage::LoginFailed {
                    request_id: request.request_id,
                    reason: "Could not save the verified sign-in on this device.".into(),
                });
                return;
            }
        }
        self.stop_authenticated_activity().await;
        self.client = Some(client);
        self.my_id = Some(my_id);
        self.username = Some(username.clone());
        self.send(replier, &BackendMessage::TokenVerified {
            username, request_id: request.request_id,
        });
        self.spawn_account_stream(replier.clone());
    }

    fn is_current_sign_in(&self, request: SignInRequest) -> bool {
        self.pending_sign_in.as_ref().is_some_and(|pending| pending.request() == request)
    }

    async fn start_token_sign_in(&mut self, replier: &BackendReplier<Self>, mut token: String, request_id: Option<u32>) {
        let request = SignInRequest { method: SignInMethod::Token, request_id };
        if self.is_current_sign_in(request) {
            return;
        }
        self.stop_sign_in(None).await;
        if token.trim() != token {
            token = token.trim().to_owned();
        }
        if token.is_empty() {
            self.send(replier, &BackendMessage::LoginFailed {
                request_id, reason: "Enter a personal access token.".into(),
            });
            return;
        }
        self.spawn_sign_in(replier, request, verify_sign_in(token));
    }

    /// The top status bar is on every screen, but every other connectivity
    /// report comes out of Home loading, which returns early without a
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

    async fn start_qr_sign_in(&mut self, replier: &BackendReplier<Self>, request_id: Option<u32>) {
        let request = SignInRequest { method: SignInMethod::Qr, request_id };
        if request_id.is_some() && self.is_current_sign_in(request) {
            return;
        }
        self.stop_sign_in(None).await;
        self.spawn_connectivity_report(replier);
        let pending = match oauth::begin(LICHESS_BASE_URL).await {
            Ok(pending) => pending,
            Err(e) => {
                log::warn!("start_login: {e}");
                self.send(replier, &BackendMessage::LoginFailed { request_id, reason: e.to_string() });
                return;
            }
        };
        let (qr_size, qr_rows) = match oauth::qr_rows(&pending.authorize_url) {
            Ok(qr) => qr,
            Err(e) => {
                log::warn!("start_login: {e}");
                self.send(replier, &BackendMessage::LoginFailed { request_id, reason: e.to_string() });
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
                request_id,
            },
        );

        let progress_replier = replier.clone();
        let write_lock = Arc::clone(&self.write_lock);
        self.spawn_sign_in(replier, request, async move {
            let token = match tokio::time::timeout(oauth::LOGIN_TIMEOUT, pending.complete(LICHESS_BASE_URL)).await {
                Ok(Ok(token)) => token,
                Ok(Err(error)) => return Err(SignInError::Qr(error.to_string())),
                Err(_) => return Err(SignInError::Qr("The sign-in code expired. Start again.".into())),
            };
            drop(pending);
            if let Some(request_id) = request_id {
                send_locked(&progress_replier, &write_lock, &BackendMessage::LoginVerifying { request_id });
            }
            verify_sign_in(token).await
        });
    }

    async fn stop_sign_in(&mut self, request_id: Option<u32>) {
        if request_id.is_some() &&
            !self.pending_sign_in.as_ref().is_some_and(|pending| pending.request().request_id == request_id)
        {
            return;
        }
        if let Some(SignInAttempt::Working { task, .. }) = self.pending_sign_in.as_mut() {
            abort_task(task).await;
        }
        self.pending_sign_in = None;
    }

    fn check_saved_sign_in(&mut self, replier: &BackendReplier<Self>) {
        if self.pending_sign_in.is_some() {
            return;
        }
        match std::fs::read_to_string(&self.token_path) {
            Ok(token) if !token.trim().is_empty() => {
                let request = SignInRequest { method: SignInMethod::Saved, request_id: None };
                self.spawn_sign_in(replier, request, verify_sign_in(token.trim().to_owned()));
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

    async fn start_home_refresh(&mut self, replier: &BackendReplier<Self>, request_id: Option<u32>, games_only: bool) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        // A game event replaces just the game-list read. Joining it with ratings
        // can abandon an unrelated read, and fetching ratings again wastes a request.
        stop_task(&mut self.home_games).await;
        self.home_games = Some(tokio::spawn(refresh_home_games(
            client.clone(), replier.clone(), self.write_lock.clone(), self.home_games_retry_after.clone(), request_id,
        )));
        if !games_only {
            stop_task(&mut self.home_ratings).await;
            let replier = replier.clone();
            let write_lock = self.write_lock.clone();
            self.home_ratings = Some(tokio::spawn(async move {
                if let Ok(account) = client.get_account().await {
                    let ratings = ratings_from_perfs(account.perfs);
                    send_locked(&replier, &write_lock, &BackendMessage::HomeRatings { request_id, ratings });
                }
            }));
        }
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

    async fn start_game_history(
        &mut self,
        replier: &BackendReplier<Self>,
        request_id: Option<u32>,
        filters: GameHistoryFilters,
    ) {
        let (Some(client), Some(my_id)) = (self.client.clone(), self.my_id.clone()) else {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameHistoryFailed {
                    request_id, message: "Not signed in to Lichess".into(),
                },
                None => BackendMessage::TokenInvalid { reason: "no token saved".into() },
            };
            self.send(replier, &reply);
            return;
        };
        stop_game_request(&mut self.history_load).await;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let task = tokio::spawn(async move {
            let reply = match client.get_game_history(&my_id, 20, &filters).await {
                Ok(games) => BackendMessage::GameHistory {
                    request_id,
                    games: games.into_iter().map(|g| history_game_to_summary(g, &my_id)).collect(),
                },
                Err(error) => {
                    let message = error.to_string();
                    match request_id {
                        Some(request_id) => BackendMessage::GameHistoryFailed { request_id, message },
                        None => BackendMessage::ErrorMsg { message },
                    }
                }
            };
            send_locked(&replier, &write_lock, &reply);
        });
        self.history_load = Some(GameRequest { request_id, task, completion: None });
    }

    async fn start_game_review_export(
        &mut self,
        replier: &BackendReplier<Self>,
        game_id: String,
        request_id: Option<u32>,
    ) {
        let Some(client) = self.client.clone() else {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameMovesFailed {
                    request_id, message: "Not signed in to Lichess".into(),
                },
                None => BackendMessage::TokenInvalid { reason: "no token saved".into() },
            };
            self.send(replier, &reply);
            return;
        };
        stop_game_request(&mut self.review_export).await;
        let task = tokio::spawn(Self::fetch_game_review(
            client, self.my_id.clone(), replier.clone(), self.write_lock.clone(),
            game_id, request_id,
        ));
        self.review_export = Some(GameRequest { request_id, task, completion: None });
    }

    async fn fetch_game_review(
        client: LichessClient,
        my_id: Option<String>,
        replier: BackendReplier<Self>,
        write_lock: Arc<std::sync::Mutex<()>>,
        game_id: String,
        request_id: Option<u32>,
    ) {
        let fail = |message| {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameMovesFailed { request_id, message },
                None => BackendMessage::ErrorMsg { message },
            };
            send_locked(&replier, &write_lock, &reply);
        };
        let export = match client.export_game(&game_id).await {
            Ok(export) => export,
            Err(e) => {
                fail(e.to_string());
                return;
            }
        };
        let rating_diff = my_id.as_deref().and_then(|my_id| {
            let players = export.players.as_ref()?;
            [&players.white, &players.black]
                .into_iter()
                .find(|side| side.user.as_ref().is_some_and(|user| user.id.as_deref() == Some(my_id)))
                .and_then(|side| side.rating_diff)
        });
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
        send_locked(&replier, &write_lock, &BackendMessage::GameMoves {
            request_id, moves, fens, clock_ms, analysis, rating_diff,
        });
    }

    async fn queue_cloud_evaluation(
        &mut self,
        replier: &BackendReplier<Self>,
        requested_fen: String,
        request_id: Option<u32>,
        review_id: Option<u32>,
    ) {
        let request = CloudEvaluationRequest { requested_fen, request_id };
        let Some(client) = self.client.clone() else {
            let reply = if request_id.is_some() {
                request.failed("Not signed in to Lichess".into())
            } else {
                BackendMessage::TokenInvalid { reason: "no token saved".into() }
            };
            self.send(replier, &reply);
            return;
        };
        if self.cloud_evaluations.as_ref().is_some_and(|queue| {
            queue.review_id != review_id || queue.task.is_finished()
        }) {
            self.stop_cloud_evaluations().await;
        }
        let queue = self.cloud_evaluations.get_or_insert_with(|| {
            let (requests, mut pending) = mpsc::channel::<CloudEvaluationRequest>(CLOUD_QUEUE_CAPACITY);
            let replier = replier.clone();
            let write_lock = self.write_lock.clone();
            let retry_after = self.cloud_retry_after.clone();
            let task = tokio::spawn(async move {
                while let Some(request) = pending.recv().await {
                    let limited = retry_after.lock().await.is_some_and(|until| until > Instant::now());
                    let reply = if limited {
                        request.failed(CLOUD_RATE_LIMIT_MESSAGE.into())
                    } else {
                        Self::fetch_cloud_evaluation(&client, request, &retry_after).await
                    };
                    send_locked(&replier, &write_lock, &reply);
                }
            });
            CloudEvaluationQueue { review_id, requests, task }
        });
        if let Err(error) = queue.requests.try_send(request) {
            self.send(replier, &error.into_inner().failed("Cloud evaluation is busy. Try again shortly.".into()));
        }
    }

    async fn stop_cloud_evaluations(&mut self) {
        if let Some(queue) = self.cloud_evaluations.as_mut() {
            abort_task(&mut queue.task).await;
            self.cloud_evaluations = None;
        }
    }

    async fn fetch_cloud_evaluation(
        client: &LichessClient,
        request: CloudEvaluationRequest,
        retry_after: &Mutex<Option<Instant>>,
    ) -> BackendMessage {
        let CloudEvaluationRequest { requested_fen, request_id } = request;
        match client.get_cloud_evaluation(&requested_fen).await {
            Ok(Some(cloud)) => {
                let Some(pv) = cloud.pvs.into_iter().next() else {
                    return BackendMessage::CloudEvaluationUnavailable { request_id, requested_fen };
                };
                match replay_uci_moves_with_history(&requested_fen, &pv.moves) {
                    Ok((_, best_line)) => BackendMessage::CloudEvaluation {
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
                    Err(e) => BackendMessage::CloudEvaluationFailed {
                        request_id,
                        requested_fen,
                        message: format!("couldn't read cloud best line: {e}"),
                    },
                }
            }
            Ok(None) => BackendMessage::CloudEvaluationUnavailable { request_id, requested_fen },
            Err(e) => {
                let message = if is_rate_limited(&e) {
                    *retry_after.lock().await = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
                    CLOUD_RATE_LIMIT_MESSAGE.into()
                } else {
                    e.to_string()
                };
                BackendMessage::CloudEvaluationFailed {
                    request_id,
                    requested_fen,
                    message,
                }
            }
        }
    }

    async fn start_match_request(
        &mut self,
        replier: &BackendReplier<Self>,
        request: MatchRequest,
    ) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &request.failure("Sign in to Lichess to find an opponent.".into()));
            return;
        };
        if let Err(message) = request.validate() {
            self.send(replier, &request.failure(message.into()));
            return;
        }
        if let Some(pending) = self.pending_match.as_mut() {
            if pending.matches(request.request_id) {
                return;
            }
            if pending.in_flight() {
                self.send(replier, &request.failure("Another game or link is being created.".into()));
                return;
            }
        }
        stop_game_request(&mut self.pending_match).await;
        let request_id = request.request_id;
        let (creation_done, completion) = if request.is_creation() {
            let (done, in_flight) = oneshot::channel();
            (Some(done), Some(in_flight))
        } else {
            (None, None)
        };
        let task = tokio::spawn(run_match_request(
            client, replier.clone(), self.write_lock.clone(), request, creation_done,
        ));
        self.pending_match = Some(GameRequest { request_id, task, completion });
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
        self.stop_sign_in(None).await;
        if let Err(error) = std::fs::remove_file(&self.token_path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                self.send(replier, &BackendMessage::LogoutFailed {
                    message: format!("Could not remove the saved sign-in: {error}"),
                });
                return;
            }
        }
        self.stop_authenticated_activity().await;
        self.client = None;
        self.my_id = None;
        self.username = None;
        self.send(replier, &BackendMessage::AuthenticationRequired);
    }

    async fn stop_authenticated_activity(&mut self) {
        stop_task(&mut self.home_games).await;
        stop_task(&mut self.home_ratings).await;
        stop_game_request(&mut self.history_load).await;
        stop_game_request(&mut self.review_export).await;
        self.stop_cloud_evaluations().await;
        stop_game_request(&mut self.pending_match).await;
        stop_game_request(&mut self.pending_challenge_action).await;
        if let Some(account) = self.account_stream.as_mut() {
            abort_task(&mut account.task).await;
            self.account_stream = None;
        }
        self.stop_game_stream().await;
    }

    async fn stop_game_stream(&mut self) {
        stop_task(&mut self.move_submission).await;
        stop_task(&mut self.game_action).await;
        if let Some(stream) = self.game_stream.as_mut() {
            abort_task(&mut stream.task).await;
            self.game_stream = None;
        }
        *self.session.lock().await = None;
    }

    async fn start_game_action<F, Fut>(
        &mut self,
        replier: &BackendReplier<Self>,
        request: GameActionRequest,
        expected_game_id: Option<&str>,
        offer: Option<OfferRequest>,
        post: F,
    )
    where
        F: FnOnce(LichessClient, String) -> Fut + Send + 'static,
        Fut: Future<Output = anyhow::Result<()>> + Send,
    {
        let fail = |message| {
            let reply = match expected_game_id {
                Some(id) => BackendMessage::GameActionFailed {
                    game_id: id.to_owned(), request, message,
                },
                None => BackendMessage::ErrorMsg { message },
            };
            self.send(replier, &reply);
        };
        let Some(client) = self.client.clone() else {
            fail("Not connected to Lichess".into());
            return;
        };
        if request.seconds.is_some_and(|seconds| !(5..=60).contains(&seconds)) {
            fail("Time gift must be between 5 and 60 seconds".into());
            return;
        }
        let offer = offer.filter(|offer| offer.offer_intent.is_some() || offer.expected_position_id.is_some());
        let (game_id, mut canceled) = {
            let mut guard = self.session.lock().await;
            match game_for_request(guard.as_ref(), expected_game_id) {
                Ok(_) => {}
                Err(reason) => {
                    fail(reason.into());
                    return;
                }
            }
            let game = guard.as_mut().expect("active game checked above");
            if let Some(offer) = offer {
                if let Err(reason) = game.validate_offer(request.action, offer) {
                    fail(reason.into());
                    return;
                }
            }
            let Some(canceled) = game.begin_game_action(request) else {
                fail("A board action is already in progress.".into());
                return;
            };
            (game.game_id.clone(), canceled)
        };
        stop_task(&mut self.game_action).await;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let session = self.session.clone();
        let scoped = expected_game_id.is_some() || request.request_id.is_some();
        self.game_action = Some(tokio::spawn(async move {
            let result = tokio::select! {
                biased;
                _ = &mut canceled => return,
                result = async {
                    if let Some(offer) = offer {
                        // Recheck at dispatch after yielding to the stream.
                        // An enqueue-only check goes stale, and locking through
                        // HTTP would block authoritative board updates.
                        let guard = session.lock().await;
                        let game = game_for_request(guard.as_ref(), Some(&game_id))
                            .map_err(anyhow::Error::msg)?;
                        game.validate_offer(request.action, offer).map_err(anyhow::Error::msg)?;
                    }
                    post(client, game_id.clone()).await
                } => result,
            };
            let mut guard = session.lock().await;
            let Some(game) = guard.as_mut().filter(|game| game.game_id == game_id) else { return };
            if canceled.try_recv() != Err(oneshot::error::TryRecvError::Empty) {
                return;
            }
            game.cancel_game_action();
            let reply = match result {
                Ok(()) => {
                    if request.action == GameAction::Berserk {
                        game.mark_berserked();
                    }
                    BackendMessage::GameActionCompleted { game_id, request }
                }
                Err(error) if scoped => BackendMessage::GameActionFailed {
                    game_id, request, message: error.to_string(),
                },
                Err(error) => BackendMessage::ErrorMsg { message: error.to_string() },
            };
            send_locked(&replier, &write_lock, &reply);
        }));
    }

    async fn handle_make_move(
        &mut self,
        replier: &BackendReplier<Self>,
        expected_game_id: Option<&str>,
        request: MoveRequest,
    ) {
        let request_id = request.request_id;
        let reject = |game_id, reason| BackendMessage::MoveRejected {
            game_id, request_id, reason,
        };
        let Some(client) = self.client.clone() else {
            self.send(replier, &reject(expected_game_id.map(str::to_owned), "Not connected to Lichess".into()));
            return;
        };
        let submission = {
            let mut guard = self.session.lock().await;
            if let Err(reason) = game_for_request(guard.as_ref(), expected_game_id) {
                self.send(replier, &reject(expected_game_id.map(str::to_owned), reason.into()));
                return;
            }
            let session = guard.as_mut().expect("active game checked above");
            // The stream can change positions after the UI sends. Checking
            // there misses queued updates, and checking after preview is too late.
            if request.expected_position_id.is_some_and(|id| id != session.position_id) {
                self.send(replier, &reject(Some(session.game_id.clone()), "Board changed.".into()));
                return;
            }
            let uci = match session.try_move(&request.from, &request.to, request.promotion.as_deref()) {
                Ok(uci) => uci,
                Err(reason) => {
                    self.send(replier, &reject(Some(session.game_id.clone()), reason.into()));
                    return;
                }
            };
            let (preview, canceled) = match session.begin_move(&uci, request_id) {
                Ok(pending) => pending,
                Err(error) => {
                    self.send(replier, &reject(Some(session.game_id.clone()), error.to_string()));
                    return;
                }
            };
            // A streamed update must not overtake the preview of this position.
            self.send(replier, &preview);
            MoveSubmission {
                game_id: session.game_id.clone(),
                expected_moves: session.state.moves.clone(),
                uci,
                request,
                canceled,
            }
        };
        // Only a settled request can reach here with an earlier task still present.
        stop_task(&mut self.move_submission).await;
        self.move_submission = Some(tokio::spawn(submit_move(
            client, submission, self.session.clone(), replier.clone(), self.write_lock.clone(),
        )));
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

    async fn start_challenge_action(
        &mut self,
        replier: &BackendReplier<Self>,
        request: ChallengeRequest,
    ) {
        let Some(client) = self.client.clone() else {
            self.send(replier, &request.failure("Sign in to Lichess to respond to challenges.".into()));
            return;
        };
        if let Some(pending) = self.pending_challenge_action.as_mut() {
            if pending.matches(request.request_id) {
                return;
            }
            if pending.in_flight() {
                self.send(replier, &request.failure("A challenge response is already in progress.".into()));
                return;
            }
        }
        stop_game_request(&mut self.pending_challenge_action).await;
        let request_id = request.request_id;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let refresh = self.account_stream.as_ref().map(|account| account.challenge_refresh.clone());
        let (done, completion) = oneshot::channel();
        let task = tokio::spawn(async move {
            let result = match request.action {
                ChallengeAction::Accept => client.accept_challenge(&request.challenge_id).await,
                ChallengeAction::Decline => client.decline_challenge(&request.challenge_id).await,
            };
            drop(done);
            match result {
                Ok(()) => {
                    let challenge_id = request.challenge_id;
                    let reply = match request.action {
                        ChallengeAction::Accept => BackendMessage::ChallengeAccepted { game_id: challenge_id, request_id },
                        ChallengeAction::Decline => BackendMessage::ChallengeDeclined { challenge_id, request_id },
                    };
                    send_locked(&replier, &write_lock, &reply);
                    if let Some(refresh) = refresh {
                        let _ = refresh.try_send(());
                    }
                }
                Err(error) => send_locked(&replier, &write_lock, &request.failure(error.to_string())),
            }
        });
        self.pending_challenge_action = Some(GameRequest { request_id, task, completion: Some(completion) });
    }
}

async fn verify_sign_in(token: String) -> Result<VerifiedSignIn, SignInError> {
    let client = LichessClient::new(token.clone());
    let account = client.get_account().await.map_err(SignInError::Account)?;
    Ok(VerifiedSignIn { token, client, my_id: account.id, username: account.username })
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
    let mut reconnecting = false;
    loop {
        let mut received_for = Duration::ZERO;
        if let Ok(mut lines) = client.stream_lines("/api/stream/event").await {
            let connected_at = Instant::now();
            while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
                received_for = connected_at.elapsed();
                if reconnecting {
                    reconnecting = false;
                    send_locked(replier, write_lock, &BackendMessage::AccountEventsResumed);
                }
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
                        send_locked(replier, write_lock, &BackendMessage::GameFinished {
                            game_id: game.id.clone(),
                        });
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
        reconnecting = true;
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

async fn refresh_home_games(
    client: LichessClient,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
    retry_after: Arc<Mutex<Option<Instant>>>,
    request_id: Option<u32>,
) {
    let limited_reply = |remaining: Duration| BackendMessage::HomeLoadFailed {
        request_id,
        message: "Lichess is limiting game-list requests. Trying again shortly.".into(),
        wifi_connected: None,
        retry_after_ms: Some(remaining.as_millis().max(1) as u32),
    };
    let remaining = retry_after.lock().await
        .and_then(|until| until.checked_duration_since(Instant::now()));
    if let Some(remaining) = remaining {
        send_locked(&replier, &write_lock, &limited_reply(remaining));
        return;
    }
    let playing = client.get_playing().await;
    let wifi_connected = wifi_link_state();
    let reply = match playing {
        Ok(games) => BackendMessage::HomeState {
            request_id,
            wifi_connected,
            ongoing_games: games.into_iter().map(|g| OngoingGameSummary {
                game_id: g.game_id,
                // The built-in AI omits the username.
                opponent_name: g.opponent.as_ref().and_then(|o| {
                    o.username.clone().or_else(|| o.ai.map(|level| format!("Stockfish level {level}")))
                }),
                opponent_rating: g.opponent.as_ref().and_then(|o| o.rating),
                is_my_turn: g.is_my_turn,
            }).collect(),
        },
        Err(error) if is_rate_limited(&error) => {
            *retry_after.lock().await = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
            limited_reply(LICHESS_RATE_LIMIT_DELAY)
        }
        Err(error) => {
            log::warn!("couldn't load Home: {error}");
            let message = if wifi_connected == Some(false) {
                "Wi-Fi is disconnected"
            } else {
                "Can't reach Lichess"
            };
            BackendMessage::HomeLoadFailed {
                request_id,
                message: format!("{message}. Check your connection and retry."),
                wifi_connected,
                retry_after_ms: None,
            }
        }
    };
    send_locked(&replier, &write_lock, &reply);
}

async fn submit_move(
    client: LichessClient,
    submission: MoveSubmission,
    session: Arc<Mutex<Option<GameSession>>>,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
) {
    let MoveSubmission { game_id, expected_moves, uci, request, mut canceled } = submission;
    let MoveRequest { request_id, from, to, promotion, .. } = request;
    let submitted_at = Instant::now();
    let response = tokio::select! {
        biased;
        _ = &mut canceled => return,
        response = client.make_move(&game_id, &uci) => response,
    };
    let elapsed = submitted_at.elapsed();
    if elapsed >= Duration::from_millis(750) {
        log::warn!("make_move {game_id} {uci} took {}ms", elapsed.as_millis());
    } else {
        log::debug!("make_move {game_id} {uci} took {}ms", elapsed.as_millis());
    }
    let mut guard = session.lock().await;
    let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) else { return };
    // An authoritative board can settle the move between HTTP completion and this lock.
    if canceled.try_recv() != Err(oneshot::error::TryRecvError::Empty) {
        return;
    }
    match response {
        Ok(()) => {
            send_locked(&replier, &write_lock, &BackendMessage::MoveSubmitted {
                game_id, from, to, promotion,
            });
            match session.apply_accepted_move(&expected_moves, &uci) {
                Ok(Some(board)) => send_locked(&replier, &write_lock, &board),
                Ok(None) => session.cancel_move(),
                Err(error) => {
                    session.cancel_move();
                    log::warn!("couldn't apply accepted move locally: {error}");
                }
            }
        }
        Err(error) => {
            session.cancel_move();
            send_locked(&replier, &write_lock, &BackendMessage::MoveRejected {
                game_id: Some(game_id), request_id, reason: error.to_string(),
            });
        }
    }
}

async fn stop_task(slot: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(handle) = slot.as_mut() {
        abort_task(handle).await;
        *slot = None;
    }
}

async fn stop_game_request(slot: &mut Option<GameRequest>) {
    if let Some(pending) = slot.as_mut() {
        abort_task(&mut pending.task).await;
        *slot = None;
    }
}

async fn cancel_game_request(slot: &mut Option<GameRequest>, request_id: u32) {
    if slot.as_ref().is_some_and(|pending| pending.request_id == Some(request_id)) {
        stop_game_request(slot).await;
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

async fn run_match_request(
    client: LichessClient,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
    request: MatchRequest,
    creation_done: Option<oneshot::Sender<()>>,
) {
    let MatchRequest { minutes, increment, request_id, .. } = request;
    let reply = match &request.kind {
        MatchKind::Seek { rated, color } => match client.create_seek(minutes, increment, *rated, color).await {
            Ok(mut lines) => {
                send_locked(&replier, &write_lock, &BackendMessage::SeekCreated { request_id });
                while let Ok(Some(_)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {}
                BackendMessage::SeekEnded { request_id }
            }
            Err(error) => request.failure(error.to_string()),
        },
        MatchKind::Direct { username, rated, color } => match client.create_challenge(
            username, minutes, increment, *rated, color,
        ).await {
            Ok((game_id, lines)) => {
                send_locked(&replier, &write_lock, &BackendMessage::ChallengeCreated {
                    game_id: game_id.clone(), request_id,
                });
                BackendMessage::ChallengeResolved {
                    game_id, request_id, error: read_challenge_result(lines).await,
                }
            }
            Err(error) => request.failure(error.to_string()),
        },
        MatchKind::Computer { level } => match client.challenge_ai(*level, minutes, increment).await {
            Ok(game_id) => BackendMessage::ComputerGameCreated { game_id, request_id },
            Err(error) => request.failure(error.to_string()),
        },
        MatchKind::Open { rated } => match client.create_open_challenge(minutes, increment, *rated).await {
            Ok(challenge) => BackendMessage::OpenChallengeCreated {
                game_id: challenge.id,
                url: challenge.url,
                url_white: challenge.url_white,
                url_black: challenge.url_black,
                request_id,
            },
            Err(error) => request.failure(error.to_string()),
        },
    };
    drop(creation_done);
    send_locked(&replier, &write_lock, &reply);
}

async fn read_challenge_result(mut lines: LineStream) -> Option<String> {
    while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
        if let Some(result) = parse_ndjson_line::<ChallengeResult>(&line) {
            return match result.done {
                ChallengeResolution::Accepted => None,
                ChallengeResolution::Declined => Some("Challenge declined.".into()),
                ChallengeResolution::Canceled => Some("Challenge canceled.".into()),
            };
        }
    }
    Some("Lost the challenge connection. Check Home if the game started.".into())
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
                                            if let Some(previous) = guard.as_mut().filter(|session| {
                                                session.game_id == s.game_id
                                            }) {
                                                s.inherit_pending_requests(previous, &mut board_msg);
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
        if message.msg_type == MSG_SYSTEM_TERMINATE {
            self.stop_sign_in(None).await;
            self.stop_authenticated_activity().await;
            return;
        }
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            // The new frontend starts its request sequence over.
            self.stop_sign_in(None).await;
            stop_task(&mut self.home_games).await;
            stop_task(&mut self.home_ratings).await;
            stop_game_request(&mut self.history_load).await;
            stop_game_request(&mut self.review_export).await;
            self.stop_cloud_evaluations().await;
            stop_game_request(&mut self.pending_match).await;
            stop_game_request(&mut self.pending_challenge_action).await;
            stop_task(&mut self.move_submission).await;
            stop_task(&mut self.game_action).await;
            if let Some(session) = self.session.lock().await.as_mut() {
                session.cancel_move();
                session.cancel_game_action();
            }
            if self.client.is_none() {
                self.check_saved_sign_in(replier);
            } else if let Some(username) = self.username.clone() {
                // The backend process outlives a frontend reload (see deploy.sh's own
                // note on backend/entry being a long-lived binary): without this, a
                // reload while already logged in re-creates LoginScreen fresh with
                // nothing to move it past the token prompt, since TokenVerified is the
                // only message that navigates it to Home (see main.qml).
                log::info!("NEW_COORDINATOR: already logged in as {username}, resending TokenVerified");
                self.send(replier, &BackendMessage::TokenVerified { username, request_id: None });
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
            FrontendMessage::StartLogin { request_id } => self.start_qr_sign_in(replier, request_id).await,
            FrontendMessage::CancelLogin { request_id } => self.stop_sign_in(request_id).await,
            FrontendMessage::CompleteSignIn { request_id } => self.complete_sign_in(replier, request_id).await,
            FrontendMessage::RetryAuthentication => {
                if self.client.is_none() {
                    self.check_saved_sign_in(replier);
                }
            }
            FrontendMessage::SaveToken { token, request_id } => self.start_token_sign_in(replier, token, request_id).await,
            FrontendMessage::RequestHome { request_id, games_only } => {
                self.start_home_refresh(replier, request_id, games_only).await;
            }
            FrontendMessage::ResumeGame { game_id } => self.handle_resume_game(replier, game_id).await,
            FrontendMessage::CreateSeek { minutes, increment, rated, color, request_id } => {
                self.start_match_request(replier, MatchRequest {
                    kind: MatchKind::Seek { rated, color }, minutes, increment, request_id,
                }).await;
            }
            FrontendMessage::CreateChallenge { username, minutes, increment, rated, color, request_id } => {
                self.start_match_request(replier, MatchRequest {
                    kind: MatchKind::Direct { username, rated, color }, minutes, increment, request_id,
                }).await;
            }
            FrontendMessage::ChallengeAi { level, minutes, increment, request_id } => {
                self.start_match_request(replier, MatchRequest {
                    kind: MatchKind::Computer { level }, minutes, increment, request_id,
                }).await;
            }
            FrontendMessage::CancelMatch { request_id: Some(request_id) } => {
                cancel_game_request(&mut self.pending_match, request_id).await;
            }
            FrontendMessage::CancelMatch { request_id: None } => {
                stop_game_request(&mut self.pending_match).await;
            }
            FrontendMessage::MakeMove { request } => {
                self.handle_make_move(replier, expected_game_id, request).await
            }
            FrontendMessage::Resign { request_id } => {
                let request = GameActionRequest::new(GameAction::Resign, request_id);
                self.start_game_action(replier, request, expected_game_id, None, |client, game_id| async move {
                    client.resign(&game_id).await
                })
                .await;
            }
            FrontendMessage::DrawAction { request: offer } => {
                let request = GameActionRequest::new(GameAction::Draw, offer.request_id);
                self.start_game_action(replier, request, expected_game_id, Some(offer), move |client, game_id| async move {
                    client.draw(&game_id, offer.accept).await
                })
                .await;
            }
            FrontendMessage::TakebackAction { request: offer } => {
                let request = GameActionRequest::new(GameAction::Takeback, offer.request_id);
                self.start_game_action(replier, request, expected_game_id, Some(offer), move |client, game_id| async move {
                    client.takeback(&game_id, offer.accept).await
                })
                .await;
            }
            FrontendMessage::Abort { request_id } => {
                let request = GameActionRequest::new(GameAction::Abort, request_id);
                self.start_game_action(replier, request, expected_game_id, None, |client, game_id| async move {
                    client.abort(&game_id).await
                })
                .await;
            }
            FrontendMessage::Berserk { request_id } => {
                let request = GameActionRequest::new(GameAction::Berserk, request_id);
                self.start_game_action(replier, request, expected_game_id, None, |client, game_id| async move {
                    client.berserk(&game_id).await
                })
                .await;
            }
            FrontendMessage::AddTime { seconds, request_id } => {
                let request = GameActionRequest { action: GameAction::AddTime, request_id, seconds: Some(seconds) };
                self.start_game_action(replier, request, expected_game_id, None, move |client, game_id| async move {
                    client.add_time(&game_id, seconds).await
                })
                .await;
            }
            FrontendMessage::ClaimVictory { request_id } => {
                let request = GameActionRequest::new(GameAction::ClaimVictory, request_id);
                self.start_game_action(replier, request, expected_game_id, None, |client, game_id| async move {
                    client.claim_victory(&game_id).await
                })
                .await;
            }
            FrontendMessage::ClaimDraw { request_id } => {
                let request = GameActionRequest::new(GameAction::ClaimDraw, request_id);
                self.start_game_action(replier, request, expected_game_id, None, |client, game_id| async move {
                    client.claim_draw(&game_id).await
                })
                .await;
            }
            FrontendMessage::RequestChallenges => self.queue_challenge_refresh(),
            FrontendMessage::AcceptChallenge { id, request_id } => {
                self.start_challenge_action(replier, ChallengeRequest {
                    challenge_id: id, request_id, action: ChallengeAction::Accept,
                }).await;
            }
            FrontendMessage::DeclineChallenge { id, request_id } => {
                self.start_challenge_action(replier, ChallengeRequest {
                    challenge_id: id, request_id, action: ChallengeAction::Decline,
                }).await;
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
            FrontendMessage::RequestGameHistory { request_id, rated, speed, color } => {
                self.start_game_history(replier, request_id, GameHistoryFilters { rated, speed, color }).await
            }
            FrontendMessage::CancelGameHistory { request_id } => {
                cancel_game_request(&mut self.history_load, request_id).await;
            }
            FrontendMessage::CreateOpenChallenge { minutes, increment, rated, request_id } => {
                self.start_match_request(replier, MatchRequest {
                    kind: MatchKind::Open { rated }, minutes, increment, request_id,
                }).await;
            }
            FrontendMessage::RequestGameMoves { game_id, request_id } => {
                self.start_game_review_export(replier, game_id, request_id).await
            }
            FrontendMessage::CancelGameReview { request_id } => {
                cancel_game_request(&mut self.review_export, request_id).await;
            }
            FrontendMessage::RequestCloudEvaluation { fen, request_id, review_id } => {
                self.queue_cloud_evaluation(replier, fen, request_id, review_id).await
            }
            FrontendMessage::CancelCloudEvaluations { review_id } => {
                if self.cloud_evaluations.as_ref().is_some_and(|queue| queue.review_id == Some(review_id)) {
                    self.stop_cloud_evaluations().await;
                }
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
    use super::{cancel_game_request, GameRequest};
    use std::sync::Arc;
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn cancellation_releases_only_the_matching_seek() {
        let owner = Arc::new(());
        let task_owner = owner.clone();
        let (started, ready) = oneshot::channel();
        let mut pending = Some(GameRequest {
            request_id: Some(7),
            completion: None,
            task: tokio::spawn(async move {
                let _keep_alive = task_owner;
                started.send(()).unwrap();
                futures_util::future::pending::<()>().await;
            }),
        });
        ready.await.unwrap();
        cancel_game_request(&mut pending, 6).await;
        assert!(pending.is_some());
        assert_eq!(Arc::strong_count(&owner), 2);
        cancel_game_request(&mut pending, 7).await;
        assert!(pending.is_none());
        assert_eq!(Arc::strong_count(&owner), 1);
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
        let summary_stats = PlayerAnalysisSummary { inaccuracy: 5, mistake: 2, blunder: 1, acpl: Some(26), accuracy: Some(90) };
        let analyzed = history_game_to_summary(
            game(human_with_analysis("myuser", "MyUser", 1500, summary_stats), human("bob", "Bob", 1480)),
            "myuser",
        );
        let your_analysis = analyzed.your_analysis.unwrap();
        assert_eq!(your_analysis.blunders, 1);
        assert_eq!(your_analysis.acpl, Some(26));
        assert_eq!(your_analysis.accuracy, Some(90));

        let unanalyzed =
            history_game_to_summary(game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480)), "myuser");
        assert_eq!(unanalyzed.your_analysis, None);
    }
}
