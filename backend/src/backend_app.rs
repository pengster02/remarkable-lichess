use crate::credentials;
use crate::game::outcome::outcome;
use crate::game::replay::OpeningExplorerPosition;
use crate::game::session::GameSession;
use crate::game::rules::{analysis_position, apply_analysis_move, replay_uci_game_from_position, starting_position, supports_variant};
use crate::lichess::client::{
    board_stream_rejection, is_auth_rejection, is_challenge_read_denial, is_rate_limited, is_unauthorized, LichessClient,
    LICHESS_BASE_URL,
};
use crate::lichess::oauth;
use crate::lichess::models::{
    ChallengeResolution, ChallengeResult, ChallengeTerms, EventGame, EventStreamMessage, GameStreamMessage,
    Account, ArchivedScore, IncomingChallenge, ParticipantPerspective, PlayingGame, PlayingOpponent, Variant,
};
use crate::lichess::stream::parse_ndjson_line;
use crate::lichess::models::{GameHistoryFilters, HistoryGame, Perfs};
use crate::pgn_export::PgnGameId;
use crate::protocol::{
    BackendMessage, CachedHomeGames, ChallengeInfo, CloudEvaluationLine, FrontendMessage, FrontendRequest, GameAnalysisSummary,
    GameAction, GameActionRequest, HistoryCursor, HistoryGameSummary, MoveAnalysis, OngoingGameSummary,
    OpeningExplorerRequest, RatingSummary,
    MoveRequest, OfferRequest, OpenChallengeQrCodes, OpponentDeparture, PlayerStatusSummary,
    MSG_TYPE_BACKEND_TO_FRONTEND,
};
use crate::qr::QrMatrix;
use crate::variations::{self, ReviewVariations};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR, MSG_SYSTEM_TERMINATE};
use async_trait::async_trait;
use shakmaty::Position;
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, Mutex, Notify};

type LineStream = Pin<Box<dyn futures_util::Stream<Item = String> + Send>>;
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MOVE_RECONCILIATION_TIMEOUT: Duration = Duration::from_secs(2);
const FINAL_POSITION_REFRESH_INTERVAL: Duration = Duration::from_secs(5);
const START_SNAPSHOT_REFRESH_INTERVAL: Duration = Duration::from_secs(5);
const INITIAL_RECONNECT_DELAY: Duration = Duration::from_secs(1);
const CLOUD_QUEUE_CAPACITY: usize = 4;
const LICHESS_RATE_LIMIT_DELAY: Duration = Duration::from_secs(60);
const CLOUD_RATE_LIMIT_MESSAGE: &str = "Lichess is limiting cloud evaluations. Try again shortly.";
const HISTORY_RATE_LIMIT_MESSAGE: &str = "Lichess limited game history requests.";
const OPENING_RATE_LIMIT_MESSAGE: &str = "Lichess limited opening statistics requests.";
const GAME_EXPORT_RATE_LIMIT_MESSAGE: &str = "Lichess limited game export requests.";
// AppLoad sends JSON as one Unix socket record after the size header. Its
// 10 MiB protocol limit exceeds the measured Linux socket capacity (208 KiB).
// Reject before sending the header, since a failed body cannot be retried in place.
const MAX_REVIEW_REPLY_BYTES: usize = 192 * 1024;
const MOVE_RATE_LIMIT_MESSAGE: &str = "Lichess is limiting moves. Wait before trying again.";
const GAME_ACTION_RATE_LIMIT_MESSAGE: &str = "Lichess is limiting game actions. Wait before trying again.";
const BOARD_BLITZ_MIN_ESTIMATE_SECONDS: u64 = 180;
const BOARD_RAPID_MIN_ESTIMATE_SECONDS: u64 = 480;

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

#[derive(Clone, Default)]
struct RateLimitCooldown(Arc<std::sync::Mutex<Option<Instant>>>);

impl RateLimitCooldown {
    fn start(&self) -> Instant {
        let deadline = Instant::now() + LICHESS_RATE_LIMIT_DELAY;
        *self.0.lock().expect("rate-limit lock poisoned") = Some(deadline);
        deadline
    }

    fn pending_deadline(&self) -> Option<Instant> {
        self.0.lock().expect("rate-limit lock poisoned")
            .filter(|deadline| *deadline > Instant::now())
    }

    fn remaining_ms(&self) -> Option<u32> {
        self.pending_deadline().map(|deadline| {
            deadline.saturating_duration_since(Instant::now()).as_millis().max(1) as u32
        })
    }
}

// Keep the optional lookup's wait across Boards. A per-Board wait lets a switch
// repeat the 429, and sharing the stream's wait could delay live updates.
#[derive(Clone, Default)]
struct BoardReadCooldowns {
    stream: RateLimitCooldown,
    player_statuses: RateLimitCooldown,
}

// Home and sign-in share the same profile route. Independent waits let one
// repeat the other's 429, and a global gate would also interrupt Board work.
#[derive(Default)]
struct AccountProfile {
    read_lock: Mutex<()>,
    cooldown: RateLimitCooldown,
}

enum AccountProfileError {
    RateLimited(Instant),
    Read(anyhow::Error),
}

impl AccountProfile {
    async fn read(&self, client: &LichessClient) -> Result<Account, AccountProfileError> {
        let _guard = self.read_lock.lock().await;
        if let Some(deadline) = self.cooldown.pending_deadline() {
            return Err(AccountProfileError::RateLimited(deadline));
        }
        match client.get_account().await {
            Ok(account) => Ok(account),
            Err(error) if is_rate_limited(&error) => Err(AccountProfileError::RateLimited(self.cooldown.start())),
            Err(error) => Err(AccountProfileError::Read(error)),
        }
    }
}

struct GameStream {
    game_id: String,
    task: tokio::task::JoinHandle<()>,
}

// An idle timeout restarts on keepalives. Applying deltas before gameFull would reuse a previous connection's board.
enum GameStreamReadiness {
    AwaitingSnapshot(Instant),
    Ready(Option<Instant>),
}

impl GameStreamReadiness {
    fn read_timeout(&self, now: Instant) -> Duration {
        let deadline = match *self {
            Self::AwaitingSnapshot(deadline) => Some(deadline),
            Self::Ready(deadline) => deadline,
        };
        deadline.map_or(STREAM_IDLE_TIMEOUT, |deadline| deadline.saturating_duration_since(now))
    }

    fn schedule_resync(&mut self, now: Instant) {
        // Waiting for socket expiry stalls stale boards. Reopening immediately interrupts recoverable streams.
        if let Self::Ready(deadline) = self {
            deadline.get_or_insert(now + MOVE_RECONCILIATION_TIMEOUT);
        }
    }

    fn accept_state(&mut self, awaiting_start: bool, now: Instant) {
        if awaiting_start {
            // Start can go unannounced on this stream. Waiting for a move
            // blocks White, and reopening immediately can churn the endpoint.
            if !matches!(self, Self::Ready(Some(_))) {
                *self = Self::Ready(Some(now + START_SNAPSHOT_REFRESH_INTERVAL));
            }
        } else {
            *self = Self::Ready(None);
        }
    }
}

struct AccountStream {
    task: tokio::task::JoinHandle<()>,
    challenge_refresh: mpsc::Sender<()>,
    challenge_list: Arc<std::sync::Mutex<ChallengeList>>,
    challenge_read_denied: Arc<AtomicBool>,
    home_games: Arc<AccountGames>,
    ratings: Arc<std::sync::Mutex<Vec<RatingSummary>>>,
    // Each sign-in owns its own flag. A shared flag can invalidate a replacement,
    // and a username cannot distinguish successive sign-ins to the same account.
    credential_rejected: Arc<AtomicBool>,
}

// Capture the sign-in's shared state. Looking up the current account can mutate
// a replacement, and Board-local state cannot update Home or sign out.
struct BoardStreamAccount {
    player_id: String,
    home_games: Arc<AccountGames>,
    credential_rejected: Arc<AtomicBool>,
}

#[derive(Default)]
struct AccountGames {
    list: std::sync::Mutex<HomeGameList>,
    finish_observed: Notify,
}

impl AccountGames {
    fn has_finished(&self, id: &str) -> bool {
        self.list.lock().expect("home game list lock poisoned").has_finished(id)
    }
}

// The account owns the last read. A screen-local cache misses reloads, and
// persisting it on disk would retain game data after sign-out.
#[derive(Default)]
struct HomeGameList {
    snapshot: Option<HomeGameSnapshot>,
    previews: Vec<HomeGamePreview>,
    // Keep recent finishes across successful Home reads for Board attachment.
    // Immediate pruning loses known results, while retaining all IDs grows with the account.
    finished: VecDeque<String>,
}

struct HomeGameSnapshot {
    requested_at: Instant,
    received_at: Instant,
    games: Vec<OngoingGameSummary>,
}

struct HomeGamePreview {
    // Order replays by attachment, and age the clock from receipt. Receipt
    // order can revive older data, while attachment time over-ages delayed clocks.
    replay_requested_at: Option<Instant>,
    received_at: Instant,
    game: OngoingGameSummary,
}

impl HomeGamePreview {
    fn observed_after(&self) -> Instant {
        self.replay_requested_at.unwrap_or(self.received_at)
    }
}

impl HomeGameList {
    fn record(&mut self, requested_at: Instant, received_at: Instant, games: Vec<OngoingGameSummary>) -> Vec<OngoingGameSummary> {
        self.previews.retain(|preview| preview.observed_after() > requested_at
            && (preview.replay_requested_at.is_some()
                || !games.iter().any(|listed| listed.game_id == preview.game.game_id)));
        let games: Vec<_> = games.into_iter().filter(|game| !self.has_finished(&game.game_id)).collect();
        self.snapshot = Some(HomeGameSnapshot { requested_at, received_at, games: games.clone() });
        self.include_previews(games, received_at)
    }

    fn record_preview(&mut self, attachment_requested_at: Instant, received_at: Instant,
        game: &OngoingGameSummary, previously_announced: bool,
    ) -> bool {
        if self.has_finished(&game.game_id) {
            return false;
        }
        let existing = self.previews.iter().position(|preview| preview.game.game_id == game.game_id);
        let listed = self.snapshot.as_ref().is_some_and(|snapshot| {
            snapshot.games.iter().any(|listed| listed.game_id == game.game_id)
        });
        let replay_requested_at = (previously_announced || listed || existing.is_some()).then_some(attachment_requested_at);
        if replay_requested_at.is_some()
            && (self.snapshot.as_ref().is_some_and(|snapshot| snapshot.requested_at >= attachment_requested_at)
                || existing.is_some_and(|index| self.previews[index].observed_after() >= attachment_requested_at))
        {
            return false;
        }
        let preview = HomeGamePreview { replay_requested_at, received_at, game: game.clone() };
        if let Some(index) = existing {
            self.previews[index] = preview;
        } else {
            // Match the list limit. Finish notifications can be missed, while
            // removing every preview on reconnect would discard usable data.
            if self.previews.len() == 50 {
                self.previews.remove(0);
            }
            self.previews.push(preview);
        }
        true
    }

    fn has_finished(&self, id: &str) -> bool {
        self.finished.iter().any(|finished| finished == id)
    }

    fn finish(&mut self, id: &str) -> bool {
        if self.has_finished(id) {
            return false;
        }
        if self.finished.len() == 128 {
            self.finished.pop_front();
        }
        self.finished.push_back(id.to_owned());
        if let Some(snapshot) = self.snapshot.as_mut() {
            snapshot.games.retain(|game| game.game_id != id);
        }
        self.previews.retain(|preview| preview.game.game_id != id);
        true
    }

    fn replay(&self, now: Instant) -> Option<CachedHomeGames> {
        if self.snapshot.is_none() && self.previews.is_empty() {
            return None;
        }
        let (received_at, games) = self.snapshot.as_ref()
            .map_or_else(|| (now, Vec::new()), |snapshot| (snapshot.received_at, snapshot.games.clone()));
        Some(CachedHomeGames {
            games: self.include_previews(games, now),
            // Replaying original times resets clocks. Wall time can jump when Wi-Fi returns.
            age_ms: now.saturating_duration_since(received_at).as_millis() as u64,
        })
    }

    fn include_previews(&self, mut games: Vec<OngoingGameSummary>, now: Instant) -> Vec<OngoingGameSummary> {
        for preview in &self.previews {
            let mut game = preview.game.clone();
            game.correspondence_age_ms = game.correspondence_seconds_left
                .map(|_| now.saturating_duration_since(preview.received_at).as_millis() as u64);
            if let Some(listed) = games.iter_mut().find(|listed| listed.game_id == game.game_id) {
                *listed = game;
            } else {
                games.push(game);
            }
        }
        games
    }
}

// Keep replay and acceptance on the same snapshot. A UI-only copy loses reloads,
// while separate caches can show an invitation that the current terms omit.
#[derive(Default)]
struct ChallengeList {
    snapshot: Option<Vec<ChallengeInfo>>,
    support: HashMap<String, BoardSupport>,
    resolved: HashSet<String>,
}

impl ChallengeList {
    fn resolve(&mut self, id: &str) {
        if let Some(snapshot) = self.snapshot.as_mut() {
            snapshot.retain(|challenge| challenge.id != id);
        }
        self.support.remove(id);
        self.resolved.insert(id.to_owned());
    }
}

// Preserve the reason for both Home and the preflight reply. A bool loses the
// reason, while treating incomplete terms as a rejection would bypass lookup.
#[derive(Clone, Debug, PartialEq, Eq)]
enum BoardSupport {
    Playable,
    Unavailable(String),
    Unknown,
}

impl BoardSupport {
    fn summary_fields(&self) -> (Option<bool>, Option<String>) {
        match self {
            Self::Playable => (Some(true), None),
            Self::Unavailable(reason) => (Some(false), Some(reason.clone())),
            Self::Unknown => (None, None),
        }
    }
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

struct ReviewScope {
    review_id: u32,
    game_id: String,
    // A boolean cannot verify a branch root. A second export can drift from
    // the replay already on screen, so publish that replay's positions once.
    archive_fens: Arc<OnceLock<Vec<String>>>,
    loaded_variations: bool,
}

// Keep the rating lookup and rejection tied to the sign-in that requested
// the review. Reading live state can switch accounts, and an ID alone can't distinguish re-logins.
struct GameReviewRequest {
    game_id: String,
    request_id: Option<u32>,
    player_id: String,
    credential_rejected: Arc<AtomicBool>,
    archive_fens: Option<Arc<OnceLock<Vec<String>>>>,
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
    Computer { level: u8, color: String },
    Open { rated: bool },
}

struct MatchRequest {
    kind: MatchKind,
    minutes: u32,
    increment: u32,
    request_id: Option<u32>,
}

// Match Lichess's speed estimate. Base time alone rejects valid increment
// clocks, and one speed floor cannot cover both public seeks and friend games.
fn board_clock_estimate_seconds(limit_seconds: u64, increment_seconds: u32) -> u64 {
    limit_seconds + 40 * u64::from(increment_seconds)
}

impl MatchRequest {
    fn is_creation(&self) -> bool {
        matches!(self.kind, MatchKind::Computer { .. } | MatchKind::Open { .. })
    }

    fn validate(&self) -> Result<(), &'static str> {
        let (max_increment, min_estimate, speed_error) = match self.kind {
            MatchKind::Seek { .. } => (180, BOARD_RAPID_MIN_ESTIMATE_SECONDS,
                "Choose Rapid or slower for matchmaking, such as 8+0 or 5+5."),
            _ => (60, BOARD_BLITZ_MIN_ESTIMATE_SECONDS,
                "Choose Blitz or slower for tablet play, such as 3+0 or 1+3."),
        };
        if self.minutes > 180 || self.increment > max_increment {
            return Err("Time control is outside the allowed range.");
        }
        if self.minutes == 0 && self.increment == 0 {
            return Err("Choose some starting time or an increment.");
        }
        if let MatchKind::Computer { level, color } = &self.kind {
            if !(1..=8).contains(level) {
                return Err("Computer level must be a whole number from 1 to 8.");
            }
            if !matches!(color.as_str(), "white" | "black" | "random") {
                return Err("Choose White, Black, or Random.");
            }
        }
        if board_clock_estimate_seconds(60 * u64::from(self.minutes), self.increment) < min_estimate {
            return Err(speed_error);
        }
        Ok(())
    }

    fn failure(&self, message: String) -> BackendMessage {
        self.failed_reply(message, None)
    }

    fn rate_limited(&self, retry_after_ms: u32) -> BackendMessage {
        let seconds = retry_after_ms.div_ceil(1000);
        self.failed_reply(
            format!("Lichess is limiting game creation. Try again in {seconds}s."), Some(retry_after_ms),
        )
    }

    fn failed_reply(&self, message: String, retry_after_ms: Option<u32>) -> BackendMessage {
        match (self.request_id, &self.kind) {
            (Some(request_id), MatchKind::Seek { .. }) => {
                BackendMessage::SeekFailed { request_id, message, retry_after_ms }
            }
            (Some(request_id), MatchKind::Direct { .. }) => {
                BackendMessage::ChallengeCreateFailed { request_id, message, retry_after_ms }
            }
            (Some(request_id), _) => {
                BackendMessage::MatchCreationFailed { request_id, message, retry_after_ms }
            }
            (None, _) => BackendMessage::ErrorMsg { message },
        }
    }
}

#[cfg(test)]
mod match_clock_tests {
    use super::*;

    #[test]
    fn validates_match_clocks_using_the_selected_action() {
        let seek = MatchKind::Seek { rated: false, color: "random".into() };
        let direct = MatchKind::Direct { username: "opponent".into(), rated: false, color: "black".into() };
        let open = MatchKind::Open { rated: false };
        let computer = MatchKind::Computer { level: 3, color: "white".into() };
        for (kind, minutes, below, valid, speed) in [
            (seek, 0, 11, 12, "Rapid"),
            (direct, 1, 2, 3, "Blitz"),
            (open, 2, 1, 2, "Blitz"),
            (computer, 0, 4, 5, "Blitz"),
        ] {
            let mut request = MatchRequest { kind, minutes, increment: below, request_id: Some(1) };
            assert!(request.validate().unwrap_err().contains(speed));
            request.increment = valid;
            assert_eq!(request.validate(), Ok(()));
        }
    }
}

struct CloudEvaluationRequest {
    requested_fen: String,
    request_id: Option<u32>,
}

impl CloudEvaluationRequest {
    fn unavailable(self) -> BackendMessage {
        BackendMessage::CloudEvaluationUnavailable {
            request_id: self.request_id,
            requested_fen: self.requested_fen,
        }
    }

    fn failed(self, message: String, retry_after: Option<Duration>) -> BackendMessage {
        BackendMessage::CloudEvaluationFailed {
            request_id: self.request_id,
            requested_fen: self.requested_fen,
            message,
            retry_after_ms: retry_after.map(|remaining| remaining.as_millis().max(1) as u32),
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
    ratings: Vec<RatingSummary>,
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
    Verification,
    Rejected,
    MissingBoardScope,
    RateLimited(Duration),
    ProfileRateLimited(Instant),
    Qr(String),
}

impl From<anyhow::Error> for SignInError {
    fn from(error: anyhow::Error) -> Self {
        if is_rate_limited(&error) {
            Self::RateLimited(LICHESS_RATE_LIMIT_DELAY)
        } else if is_auth_rejection(&error) {
            Self::Rejected
        } else {
            Self::Verification
        }
    }
}

impl SignInRequest {
    fn failure(self, error: SignInError) -> BackendMessage {
        let reason = match error {
            SignInError::Qr(reason) => reason,
            SignInError::ProfileRateLimited(deadline) => return self.failure(SignInError::RateLimited(
                deadline.saturating_duration_since(Instant::now()),
            )),
            SignInError::RateLimited(remaining) => {
                let seconds = remaining.as_secs() + u64::from(remaining.subsec_nanos() > 0);
                let reason = format!("Lichess is limiting sign-in requests. Wait {seconds}s before trying again.");
                if self.method == SignInMethod::Saved {
                    return BackendMessage::AuthenticationCheckFailed { message: reason };
                }
                if self.method == SignInMethod::Token && self.request_id.is_none() {
                    return BackendMessage::TokenInvalid { reason };
                }
                reason
            }
            SignInError::Rejected => {
                if self.method == SignInMethod::Saved || self.request_id.is_none() {
                    return BackendMessage::TokenInvalid { reason: "Lichess rejected the sign-in.".into() };
                }
                "Lichess rejected this sign-in. Check the token and its permissions.".into()
            }
            SignInError::MissingBoardScope => {
                let reason = "Create a Lichess token with Board play (board:play) permission.".into();
                if self.request_id.is_none() {
                    return BackendMessage::TokenInvalid { reason };
                }
                reason
            }
            SignInError::Verification if self.method == SignInMethod::Saved => {
                return BackendMessage::AuthenticationCheckFailed {
                    message: "Could not verify your saved Lichess sign-in. Check your connection and try again.".into(),
                };
            }
            SignInError::Verification if self.request_id.is_none() && self.method == SignInMethod::Token => {
                return BackendMessage::TokenInvalid { reason: "Could not verify the token.".into() };
            }
            SignInError::Verification => "Could not verify your sign-in. Check your connection and try again.".into(),
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
        self.failed_reply(message, None)
    }

    fn rate_limited(&self, retry_after_ms: u32) -> BackendMessage {
        let seconds = retry_after_ms.div_ceil(1000);
        self.failed_reply(
            format!("Lichess is limiting challenge responses. Try again in {seconds}s."), Some(retry_after_ms),
        )
    }

    fn failed_reply(&self, message: String, retry_after_ms: Option<u32>) -> BackendMessage {
        match self.request_id {
            Some(request_id) => BackendMessage::ChallengeActionFailed {
                challenge_id: self.challenge_id.clone(), request_id, message, retry_after_ms,
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

// Keep the typed HTTP failure until the worker decides its scope. Formatting
// it early loses the status, and treating every denial as sign-out loses valid sessions.
enum GameActionFailure {
    Rejected(anyhow::Error),
    RateLimited(u32),
}

impl GameActionFailure {
    fn reply(self, game_id: Option<&str>, request: GameActionRequest) -> BackendMessage {
        let (message, retry_after_ms) = match self {
            Self::Rejected(error) => (error.to_string(), None),
            Self::RateLimited(ms) => (GAME_ACTION_RATE_LIMIT_MESSAGE.into(), Some(ms)),
        };
        match game_id {
            Some(id) => BackendMessage::GameActionFailed {
                game_id: id.to_owned(), request, message, retry_after_ms,
            },
            None => BackendMessage::ErrorMsg { message },
        }
    }
}

fn game_for_request<'a>(
    active: Option<&'a GameSession>,
    expected_game_id: Option<&str>,
) -> Result<&'a GameSession, &'static str> {
    let game = active.ok_or("No active game")?;
    if expected_game_id.is_some_and(|id| id != game.game_id) {
        return Err("The active game changed before this request could be sent.");
    }
    if game.awaiting_final_position() {
        return Err("The game ended. Waiting for the final position.");
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
    qr_sign_in_available: bool,
    sign_in_connectivity: Option<tokio::task::JoinHandle<()>>,
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
    // Per-form state can be bypassed by switching actions. An account-wide
    // deadline would also block requests needed for games already in progress.
    match_creation_cooldown: RateLimitCooldown,
    account_stream: Option<AccountStream>,
    // A task-local deadline is lost on replacement. A shared limit across stream
    // families could block a Board connection when only account events were limited.
    account_stream_cooldown: RateLimitCooldown,
    board_read_cooldowns: BoardReadCooldowns,
    pending_challenge_action: Option<GameRequest>,
    // Per-invitation deadlines let the next response bypass the wait. Sharing
    // this deadline with list reads would also prevent Home from refreshing.
    challenge_action_cooldown: RateLimitCooldown,
    challenge_list_cooldown: RateLimitCooldown,
    home_games: Option<tokio::task::JoinHandle<()>>,
    home_ratings: Option<tokio::task::JoinHandle<()>>,
    home_games_cooldown: RateLimitCooldown,
    account_profile: Arc<AccountProfile>,
    history_load: Option<GameRequest>,
    // Keep the export cooldown across screen visits. A QML-only timer misses
    // reentry, while an API-wide gate could interrupt live play.
    history_retry_after: Arc<Mutex<Option<Instant>>>,
    pgn_export: Option<GameRequest>,
    // Serialize both formats of the same export route. Per-format gates allow
    // bypasses, while an API-wide gate could interrupt live moves.
    game_export_retry_after: Arc<Mutex<Option<Instant>>>,
    review_export: Option<GameRequest>,
    review_scope: Option<ReviewScope>,
    opening_explorer: Option<tokio::task::JoinHandle<()>>,
    opening_retry_after: Arc<Mutex<Option<Instant>>>,
    cloud_evaluations: Option<CloudEvaluationQueue>,
    cloud_retry_after: Arc<Mutex<Option<Instant>>>,
    // A screen timer misses reloads and separate timers let method switches bypass the wait.
    sign_in_retry_after: Arc<std::sync::Mutex<Option<Instant>>>,
    pending_sign_in: Option<SignInAttempt>,
    move_submission: Option<tokio::task::JoinHandle<()>>,
    // Per-game waits let a Board change repeat the limit. Sharing this wait
    // with streams or other actions would block updates or leaving the game.
    move_submission_cooldown: RateLimitCooldown,
    game_action: Option<tokio::task::JoinHandle<()>>,
    // Switching actions or games can repeat a wait scoped to one operation.
    // Sharing the wait with moves would interfere with play during the pause.
    game_action_cooldown: RateLimitCooldown,
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
            qr_sign_in_available: true,
            sign_in_connectivity: None,
            token_path,
            settings_path,
            client: None,
            my_id: None,
            username: None,
            session: Arc::new(Mutex::new(None)),
            pending_match: None,
            match_creation_cooldown: RateLimitCooldown::default(),
            account_stream: None,
            account_stream_cooldown: RateLimitCooldown::default(),
            board_read_cooldowns: BoardReadCooldowns::default(),
            pending_challenge_action: None,
            challenge_action_cooldown: RateLimitCooldown::default(),
            challenge_list_cooldown: RateLimitCooldown::default(),
            home_games: None,
            home_ratings: None,
            home_games_cooldown: RateLimitCooldown::default(),
            account_profile: Arc::new(AccountProfile::default()),
            history_load: None,
            history_retry_after: Arc::new(Mutex::new(None)),
            pgn_export: None,
            game_export_retry_after: Arc::new(Mutex::new(None)),
            review_export: None,
            review_scope: None,
            opening_explorer: None,
            opening_retry_after: Arc::new(Mutex::new(None)),
            cloud_evaluations: None,
            cloud_retry_after: Arc::new(Mutex::new(None)),
            sign_in_retry_after: Arc::new(std::sync::Mutex::new(None)),
            pending_sign_in: None,
            move_submission: None,
            move_submission_cooldown: RateLimitCooldown::default(),
            game_action: None,
            game_action_cooldown: RateLimitCooldown::default(),
            game_stream: None,
            write_lock: Arc::new(std::sync::Mutex::new(())),
        }
    }

    pub fn with_qr_sign_in_available(mut self, available: bool) -> Self {
        self.qr_sign_in_available = available;
        self
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
        let retry_after = self.sign_in_retry_after.clone();
        let task = tokio::spawn(async move {
            let result = verify.await;
            // The worker must record a received limit before a screen switch can abort it at the backend lock.
            if let Err(SignInError::RateLimited(wait)) = &result {
                *retry_after.lock().expect("sign-in retry deadline lock poisoned") = Some(Instant::now() + *wait);
            }
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
        let VerifiedSignIn { token, client, my_id, username, ratings } = verified;
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
        self.stop_account_activity().await;
        self.client = Some(client);
        self.my_id = Some(my_id);
        self.username = Some(username.clone());
        self.send(replier, &BackendMessage::TokenVerified {
            username, request_id: request.request_id,
        });
        self.spawn_account_stream(replier.clone(), ratings);
    }

    fn is_current_sign_in(&self, request: SignInRequest) -> bool {
        self.pending_sign_in.as_ref().is_some_and(|pending| pending.request() == request)
    }

    fn sign_in_allowed(&self, replier: &BackendReplier<Self>, request: SignInRequest) -> bool {
        let deadline = (*self.sign_in_retry_after.lock().expect("sign-in retry deadline lock poisoned"))
            .max(self.account_profile.cooldown.pending_deadline());
        let Some(remaining) = deadline.and_then(|deadline| deadline.checked_duration_since(Instant::now()))
            .filter(|remaining| !remaining.is_zero()) else {
            return true;
        };
        self.send(replier, &request.failure(SignInError::RateLimited(remaining)));
        false
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
        if !self.sign_in_allowed(replier, request) {
            return;
        }
        self.spawn_sign_in(replier, request, verify_sign_in(token, self.account_profile.clone()));
    }

    // Awaiting the probe would hold up sign-in. Detaching it lets an old
    // Offline report arrive after sign-in or frontend replacement.
    fn spawn_connectivity_report(&mut self, replier: &BackendReplier<Self>) {
        if self.client.is_some() || self.sign_in_connectivity.as_ref().is_some_and(|task| !task.is_finished()) {
            return;
        }
        let replier = replier.clone();
        let write_lock = Arc::clone(&self.write_lock);
        self.sign_in_connectivity = Some(tokio::spawn(async move {
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
        }));
    }

    async fn start_qr_sign_in(&mut self, replier: &BackendReplier<Self>, request_id: Option<u32>) {
        if !self.qr_sign_in_available {
            self.send(replier, &BackendMessage::LoginFailed {
                request_id,
                reason: "Use a personal access token to sign in with the emulator.".into(),
            });
            return;
        }
        let request = SignInRequest { method: SignInMethod::Qr, request_id };
        if request_id.is_some() && self.is_current_sign_in(request) {
            return;
        }
        self.stop_sign_in(None).await;
        if !self.sign_in_allowed(replier, request) {
            return;
        }
        self.spawn_connectivity_report(replier);
        let pending = match oauth::begin(LICHESS_BASE_URL).await {
            Ok(pending) => pending,
            Err(e) => {
                log::warn!("start_login: {e}");
                self.send(replier, &BackendMessage::LoginFailed { request_id, reason: e.to_string() });
                return;
            }
        };
        let qr = match QrMatrix::encode(&pending.authorize_url) {
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
                qr_size: qr.size,
                qr_rows: qr.rows,
                expires_in_secs: oauth::LOGIN_TIMEOUT.as_secs(),
                request_id,
            },
        );

        let progress_replier = replier.clone();
        let write_lock = Arc::clone(&self.write_lock);
        let profile = self.account_profile.clone();
        self.spawn_sign_in(replier, request, async move {
            let token = match tokio::time::timeout(oauth::LOGIN_TIMEOUT, pending.complete(LICHESS_BASE_URL)).await {
                Ok(Ok(token)) => token,
                Ok(Err(error)) if is_rate_limited(&error) => {
                    return Err(SignInError::RateLimited(LICHESS_RATE_LIMIT_DELAY));
                }
                Ok(Err(error)) => return Err(SignInError::Qr(error.to_string())),
                Err(_) => return Err(SignInError::Qr("The sign-in code expired. Start again.".into())),
            };
            drop(pending);
            if let Some(request_id) = request_id {
                send_locked(&progress_replier, &write_lock, &BackendMessage::LoginVerifying { request_id });
            }
            verify_sign_in(token, profile).await
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
                if self.sign_in_allowed(replier, request) {
                    self.spawn_sign_in(replier, request, verify_sign_in(token.trim().to_owned(), self.account_profile.clone()));
                }
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
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            // A queued Home refresh must not replace the sign-in message after the account is cleared.
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
        let game_list = account.home_games.clone();
        // A game event replaces just the game-list read. Joining it with ratings
        // can abandon an unrelated read, and fetching ratings again wastes a request.
        stop_task(&mut self.home_games).await;
        self.home_games = Some(tokio::spawn(refresh_home_games(
            client.clone(), replier.clone(), self.write_lock.clone(), self.home_games_cooldown.clone(),
            game_list, credential_rejected.clone(), request_id,
        )));
        if !games_only {
            self.start_home_ratings(replier, request_id).await;
        }
    }

    async fn start_home_ratings(&mut self, replier: &BackendReplier<Self>, request_id: Option<u32>) {
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            return;
        };
        let ratings = account.ratings.clone();
        let credential_rejected = account.credential_rejected.clone();
        stop_task(&mut self.home_ratings).await;
        self.home_ratings = Some(tokio::spawn(refresh_home_ratings(
            client, replier.clone(), self.write_lock.clone(), self.account_profile.clone(),
            ratings, credential_rejected, request_id,
        )));
    }

    async fn handle_resume_game(&mut self, replier: &BackendReplier<Self>, game_id: String) {
        let (Some(client), Some(player_id), Some(account)) =
            (self.client.clone(), self.my_id.clone(), self.account_stream.as_ref())
        else { return };
        let account = BoardStreamAccount {
            player_id,
            home_games: account.home_games.clone(),
            credential_rejected: account.credential_rejected.clone(),
        };
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
            client, game_id.clone(), replier.clone(), self.session.clone(), account, self.write_lock.clone(),
            self.board_read_cooldowns.clone(),
        );
        self.game_stream = Some(GameStream { game_id, task });
    }

    async fn start_game_history(
        &mut self,
        replier: &BackendReplier<Self>,
        request_id: Option<u32>,
        filters: GameHistoryFilters,
        cursor: Option<HistoryCursor>,
    ) {
        let (Some(client), Some(my_id), Some(account)) =
            (self.client.clone(), self.my_id.clone(), self.account_stream.as_ref())
        else {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameHistoryFailed {
                    request_id, message: "Not signed in to Lichess".into(), retry_after_ms: None,
                },
                None => BackendMessage::TokenInvalid { reason: "no token saved".into() },
            };
            self.send(replier, &reply);
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
        stop_game_request(&mut self.history_load).await;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let retry_after = self.history_retry_after.clone();
        let task = tokio::spawn(async move {
            let remaining = retry_after.lock().await
                .and_then(|until| until.checked_duration_since(Instant::now()));
            if let Some(remaining) = remaining {
                let reply = history_rate_limit_reply(request_id, remaining);
                send_locked(&replier, &write_lock, &reply);
                return;
            }
            let reply = match client.get_game_history_page(&my_id, &filters, cursor).await {
                Ok((games, next_cursor)) => BackendMessage::GameHistory {
                    request_id,
                    games: games.into_iter().filter_map(|game| history_game_to_summary(game, &my_id)).collect(),
                    next_cursor,
                },
                Err(error) if is_unauthorized(&error) => {
                    report_account_rejection(&replier, &credential_rejected);
                    return;
                }
                Err(error) if is_rate_limited(&error) => {
                    *retry_after.lock().await = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
                    history_rate_limit_reply(request_id, LICHESS_RATE_LIMIT_DELAY)
                }
                Err(error) => {
                    let message = error.to_string();
                    match request_id {
                        Some(request_id) => BackendMessage::GameHistoryFailed {
                            request_id, message, retry_after_ms: None,
                        },
                        None => BackendMessage::ErrorMsg { message },
                    }
                }
            };
            send_locked(&replier, &write_lock, &reply);
        });
        self.history_load = Some(GameRequest { request_id, task, completion: None });
    }

    async fn start_pgn_export(
        &mut self, replier: &BackendReplier<Self>, game_id: String, request_id: u32,
    ) {
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            self.send(replier, &pgn_export_failure(&game_id, request_id, "Not signed in to Lichess", None));
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
        stop_game_request(&mut self.pgn_export).await;
        let config_dir = self.token_path.parent().unwrap_or_else(|| Path::new(".")).to_owned();
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let retry_after = self.game_export_retry_after.clone();
        let task = tokio::spawn(async move {
            let reply = match export_pgn(&client, &config_dir, &game_id, request_id, &retry_after).await {
                Ok(reply) => reply,
                Err(GameExportFailure::RateLimited(remaining)) => {
                    pgn_export_failure(&game_id, request_id, GAME_EXPORT_RATE_LIMIT_MESSAGE, Some(remaining))
                }
                Err(GameExportFailure::Request(error)) if is_unauthorized(&error) => {
                    report_account_rejection(&replier, &credential_rejected);
                    return;
                }
                Err(GameExportFailure::Request(error)) => {
                    log::warn!("could not download game PGN: {error}");
                    pgn_export_failure(&game_id, request_id, "Could not download the game's PGN from Lichess.", None)
                }
            };
            send_locked(&replier, &write_lock, &reply);
        });
        self.pgn_export = Some(GameRequest { request_id: Some(request_id), task, completion: None });
    }

    async fn start_game_review_export(
        &mut self,
        replier: &BackendReplier<Self>,
        game_id: String,
        request_id: Option<u32>,
    ) {
        let (Some(client), Some(player_id), Some(account)) =
            (self.client.clone(), self.my_id.clone(), self.account_stream.as_ref())
        else {
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameMovesFailed {
                    request_id, message: "Not signed in to Lichess".into(), retry_after_ms: None,
                    review_supported: None,
                },
                None => BackendMessage::TokenInvalid { reason: "no token saved".into() },
            };
            self.send(replier, &reply);
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
        stop_game_request(&mut self.review_export).await;
        stop_task(&mut self.opening_explorer).await;
        // Scope writes to the backend's reviewed game. A front-end game ID can
        // outlive an account change, while a token-derived key breaks on re-login.
        self.review_scope = request_id.map(|review_id| ReviewScope {
            review_id, game_id: game_id.clone(), archive_fens: Arc::new(OnceLock::new()), loaded_variations: false,
        });
        let request = GameReviewRequest {
            game_id, request_id, player_id, credential_rejected,
            archive_fens: self.review_scope.as_ref().map(|scope| scope.archive_fens.clone()),
        };
        let task = tokio::spawn(Self::fetch_game_review(
            client, request, replier.clone(), self.write_lock.clone(), self.game_export_retry_after.clone(),
        ));
        self.review_export = Some(GameRequest { request_id, task, completion: None });
    }

    async fn fetch_game_review(
        client: LichessClient,
        request: GameReviewRequest,
        replier: BackendReplier<Self>,
        write_lock: Arc<std::sync::Mutex<()>>,
        retry_after: Arc<Mutex<Option<Instant>>>,
    ) {
        let GameReviewRequest { game_id, request_id, player_id, credential_rejected, archive_fens } = request;
        let fail = |message: String, delay: Option<Duration>, review_supported| {
            // The parser can include a whole invalid SAN token in its error.
            let message = if message.len() <= 512 { message } else { "Could not replay this game.".into() };
            let reply = match request_id {
                Some(request_id) => BackendMessage::GameMovesFailed {
                    request_id, message, retry_after_ms: delay.map(export_wait_ms), review_supported,
                },
                None => BackendMessage::ErrorMsg { message },
            };
            send_locked(&replier, &write_lock, &reply);
        };
        let export = match request_game_export(&retry_after, client.export_game(&game_id)).await {
            Ok(export) => export,
            Err(GameExportFailure::RateLimited(remaining)) => {
                fail(GAME_EXPORT_RATE_LIMIT_MESSAGE.into(), Some(remaining), None);
                return;
            }
            Err(GameExportFailure::Request(error)) if is_unauthorized(&error) => {
                report_account_rejection(&replier, &credential_rejected);
                return;
            }
            Err(GameExportFailure::Request(error)) => {
                fail(error.to_string(), None, None);
                return;
            }
        };
        let rating_diff = export.players.as_ref().and_then(|players| {
            let ParticipantPerspective::Known(color) = players.perspective(&player_id) else { return None; };
            players.player(color).rating_diff
        });
        let exported_moves: Vec<&str> = export.moves.split_whitespace().collect();
        let replay = match crate::game::replay::replay_export(
            export.variant.as_deref(), export.initial_fen.as_deref(), &exported_moves,
        ) {
            Ok(replay) => replay,
            Err(e) => {
                fail(format!("Could not replay this game: {e}"), None, None);
                return;
            }
        };
        // Widen before scaling. A 32-bit product wraps, and saturating would
        // display the wrong duration. The full result is exact in QML.
        let mut clock_ms: Vec<Option<u64>> = export.clocks.into_iter().take(replay.moves.len())
            .map(|clock| clock.map(|cs| u64::from(cs) * 10)).collect();
        while clock_ms.last() == Some(&None) {
            clock_ms.pop();
        }
        let analysis: Vec<MoveAnalysis> = export.analysis.into_iter().take(replay.moves.len())
            .map(|entry| {
                let (eval_cp, mate_in) = match entry.score {
                    Some(ArchivedScore::Centipawns(cp)) => (Some(cp), None),
                    Some(ArchivedScore::Mate(mate)) => (None, Some(mate)),
                    None => (None, None),
                };
                let (judgment, judgment_comment) = entry.judgment
                    .map_or((None, None), |judgment| (Some(judgment.name), judgment.comment));
                MoveAnalysis { eval_cp, mate_in, judgment, judgment_comment }
            })
            .collect();
        let mut reply = BackendMessage::GameMoves {
            game_id: export.id, request_id, moves: replay.moves, fens: replay.fens, initial_in_check: replay.initial_in_check,
            clock_ms, analysis, rating_diff,
            variation_storage: request_id.map(|_| true),
        };
        let Some(json) = encode_review_reply(&mut reply) else {
            fail("This game is too large for Review. Export its PGN instead.".into(), None, Some(false));
            return;
        };
        if let (Some(archive_fens), BackendMessage::GameMoves { fens, .. }) = (archive_fens, reply) {
            archive_fens.get_or_init(|| fens);
        }
        send_json_locked(&replier, &write_lock, &json);
    }

    fn handle_load_variations(&mut self, replier: &BackendReplier<Self>, review_id: u32) {
        let config_dir = self.token_path.parent().unwrap_or_else(|| Path::new("."));
        let (Some(scope), Some(account_id)) = (&mut self.review_scope, &self.my_id) else {
            return;
        };
        if scope.review_id != review_id {
            return;
        }
        let Some(archive_fens) = scope.archive_fens.get() else {
            self.send(replier, &BackendMessage::ReviewVariationsLoadFailed {
                review_id, message: "Open this game in Review before loading saved variations.".into(),
            });
            return;
        };
        let reply = match variations::load(config_dir, account_id, &scope.game_id, archive_fens) {
            Ok(variations) => {
                scope.loaded_variations = true;
                BackendMessage::ReviewVariations { review_id, variations }
            }
            Err(error) => {
                scope.loaded_variations = false;
                log::warn!("could not read saved review variations: {error}");
                BackendMessage::ReviewVariationsLoadFailed {
                    review_id, message: "Could not load saved variations.".into(),
                }
            }
        };
        self.send(replier, &reply);
    }

    fn handle_save_variations(
        &self, replier: &BackendReplier<Self>, review_id: u32, request_id: u32,
        variations: ReviewVariations,
    ) {
        let config_dir = self.token_path.parent().unwrap_or_else(|| Path::new("."));
        let (Some(scope), Some(account_id)) = (&self.review_scope, &self.my_id) else {
            return;
        };
        if scope.review_id != review_id {
            return;
        }
        let reply = match scope.archive_fens.get().filter(|_| scope.loaded_variations) {
            Some(archive_fens) => match variations::save(config_dir, account_id, &scope.game_id, archive_fens, variations) {
                Ok(()) => BackendMessage::ReviewVariationsSaved { review_id, request_id },
                Err(error) => {
                    log::warn!("could not save review variations: {error}");
                    BackendMessage::ReviewVariationsSaveFailed {
                        review_id, request_id, message: "Could not save variations.".into(),
                    }
                }
            },
            None => BackendMessage::ReviewVariationsSaveFailed {
                review_id, request_id, message: "Reload the review before saving variations.".into(),
            },
        };
        self.send(replier, &reply);
    }

    async fn start_opening_explorer(
        &mut self, replier: &BackendReplier<Self>, request: OpeningExplorerRequest,
    ) {
        if !self.review_scope.as_ref().is_some_and(|scope| {
            scope.review_id == request.review_id && scope.archive_fens.get().is_some()
        }) {
            return;
        }
        let Some(client) = self.client.clone() else { return };
        // One visible lookup owns the slot. A queue can outlast source switches,
        // and parallel calls compete for the same explorer rate limit.
        stop_task(&mut self.opening_explorer).await;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let retry_after = self.opening_retry_after.clone();
        self.opening_explorer = Some(tokio::spawn(async move {
            let reply = fetch_opening_explorer(&client, request, &retry_after).await;
            send_locked(&replier, &write_lock, &reply);
        }));
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
                request.failed("Not signed in to Lichess".into(), None)
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
                    let reply = Self::fetch_cloud_evaluation(&client, request, &retry_after).await;
                    send_locked(&replier, &write_lock, &reply);
                }
            });
            CloudEvaluationQueue { review_id, requests, task }
        });
        if let Err(error) = queue.requests.try_send(request) {
            self.send(replier, &error.into_inner().failed("Cloud evaluation is busy. Try again shortly.".into(), None));
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
        let remaining = retry_after.lock().await
            .and_then(|until| until.checked_duration_since(Instant::now()));
        if let Some(remaining) = remaining {
            return request.failed(CLOUD_RATE_LIMIT_MESSAGE.into(), Some(remaining));
        }
        match client.get_cloud_evaluation(&request.requested_fen).await {
            Ok(Some(cloud)) => {
                let Some(pv) = cloud.pvs.into_iter().next() else {
                    return request.unavailable();
                };
                let Ok(position) = starting_position(&request.requested_fen) else {
                    return request.failed("Could not read this position.".into(), None);
                };
                // The legacy MateGiven score omits both fields. Check the position
                // before rejecting it, without guessing a score or trusting that omission.
                if position.legal_moves().is_empty() {
                    return request.unavailable();
                }
                if pv.cp.is_some() == pv.mate.is_some() || pv.mate == Some(0) {
                    return request.failed("Lichess returned an unusable cloud score. Try again.".into(), None);
                }
                if pv.moves.trim().is_empty() {
                    return request.failed("Lichess returned an empty best line. Try again.".into(), None);
                }
                match replay_uci_game_from_position(position, &pv.moves) {
                    Ok(replay) => BackendMessage::CloudEvaluation {
                        request_id: request.request_id,
                        requested_fen: request.requested_fen,
                        evaluation: CloudEvaluationLine {
                            eval_cp: pv.cp,
                            mate_in: pv.mate,
                            depth: cloud.depth,
                            knodes: cloud.knodes,
                            best_line: replay.move_history,
                        },
                    },
                    Err(e) => request.failed(format!("couldn't read cloud best line: {e}"), None),
                }
            }
            Ok(None) => request.unavailable(),
            Err(error) if is_rate_limited(&error) => {
                *retry_after.lock().await = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
                request.failed(CLOUD_RATE_LIMIT_MESSAGE.into(), Some(LICHESS_RATE_LIMIT_DELAY))
            }
            Err(error) => request.failed(error.to_string(), None),
        }
    }

    async fn start_match_request(
        &mut self,
        replier: &BackendReplier<Self>,
        request: MatchRequest,
    ) {
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            self.send(replier, &request.failure("Sign in to Lichess to find an opponent.".into()));
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
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
        if let Some(retry_after_ms) = self.match_creation_cooldown.remaining_ms() {
            self.send(replier, &request.rate_limited(retry_after_ms));
            return;
        }
        let request_id = request.request_id;
        let (creation_done, completion) = if request.is_creation() {
            let (done, in_flight) = oneshot::channel();
            (Some(done), Some(in_flight))
        } else {
            (None, None)
        };
        let task = tokio::spawn(run_match_request(
            client, replier.clone(), self.write_lock.clone(), request, creation_done,
            self.match_creation_cooldown.clone(), credential_rejected,
        ));
        self.pending_match = Some(GameRequest { request_id, task, completion });
    }

    fn handle_request_settings(&self, replier: &BackendReplier<Self>) {
        let settings = crate::settings::load(&self.settings_path);
        self.send(replier, &BackendMessage::SettingsState { request_id: None, settings });
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
        request_id: Option<u32>,
        settings: crate::settings::AppSettings,
    ) {
        let settings = settings.normalized();
        if let Err(e) = crate::settings::save(&self.settings_path, &settings) {
            let message = format!("failed to save settings: {e}");
            let reply = match request_id {
                Some(request_id) => BackendMessage::SettingsSaveFailed {
                    request_id,
                    message,
                    settings: crate::settings::load(&self.settings_path),
                },
                None => BackendMessage::ErrorMsg { message },
            };
            self.send(replier, &reply);
            return;
        }
        // Echoed back rather than assumed -- the frontend already optimistically
        // shows the new toggle state, but this confirms the write actually
        // succeeded instead of silently drifting from what's on disk.
        self.send(replier, &BackendMessage::SettingsState { request_id, settings });
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
        self.clear_authenticated_account().await;
        self.send(replier, &BackendMessage::AuthenticationRequired);
    }

    async fn reject_authenticated_account(&mut self, replier: &BackendReplier<Self>) {
        self.clear_authenticated_account().await;
        self.send(replier, &BackendMessage::TokenInvalid {
            reason: "Lichess rejected the current sign-in. Sign in again.".into(),
        });
    }

    async fn clear_authenticated_account(&mut self) {
        self.stop_account_activity().await;
        self.client = None;
        self.my_id = None;
        self.username = None;
    }

    async fn stop_account_activity(&mut self) {
        stop_task(&mut self.sign_in_connectivity).await;
        self.review_scope = None;
        stop_task(&mut self.opening_explorer).await;
        stop_game_request(&mut self.pgn_export).await;
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
        let rejected = |reason: &str| GameActionFailure::Rejected(anyhow::anyhow!(reason.to_owned()));
        let fail = |reason| {
            self.send(replier, &rejected(reason).reply(expected_game_id, request));
        };
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            fail("Not connected to Lichess");
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
        if request.seconds.is_some_and(|seconds| !(5..=60).contains(&seconds)) {
            fail("Time gift must be between 5 and 60 seconds");
            return;
        }
        let offer = offer.filter(|offer| offer.offer_intent.is_some() || offer.expected_position_id.is_some());
        let scoped = expected_game_id.is_some() || request.request_id.is_some();
        let (game_id, mut canceled) = {
            let mut guard = self.session.lock().await;
            match game_for_request(guard.as_ref(), expected_game_id) {
                Ok(_) => {}
                Err(reason) => {
                    fail(reason);
                    return;
                }
            }
            let game = guard.as_mut().expect("active game checked above");
            if let Some(offer) = offer {
                if let Err(reason) = game.validate_offer(request.action, offer) {
                    fail(reason);
                    return;
                }
            }
            if let Some(retry_after_ms) = self.game_action_cooldown.remaining_ms() {
                self.send(replier, &GameActionFailure::RateLimited(retry_after_ms)
                    .reply(scoped.then_some(game.game_id.as_str()), request));
                return;
            }
            let Some(canceled) = game.begin_game_action(request) else {
                fail("A board action is already in progress.");
                return;
            };
            (game.game_id.clone(), canceled)
        };
        stop_task(&mut self.game_action).await;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let session = self.session.clone();
        let cooldown = self.game_action_cooldown.clone();
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
                            .map_err(rejected)?;
                        game.validate_offer(request.action, offer).map_err(rejected)?;
                    }
                    if let Some(retry_after_ms) = cooldown.remaining_ms() {
                        return Err(GameActionFailure::RateLimited(retry_after_ms));
                    }
                    post(client, game_id.clone()).await.map_err(|error| {
                        if is_rate_limited(&error) {
                            // Record and publish before the Board can settle this action.
                            cooldown.start();
                            let retry_after_ms = LICHESS_RATE_LIMIT_DELAY.as_millis() as u32;
                            send_locked(&replier, &write_lock, &BackendMessage::GameActionCooldown { retry_after_ms });
                            GameActionFailure::RateLimited(retry_after_ms)
                        } else {
                            GameActionFailure::Rejected(error)
                        }
                    })
                } => result,
            };
            if matches!(&result, Err(GameActionFailure::Rejected(error)) if is_unauthorized(error)) {
                report_account_rejection(&replier, &credential_rejected);
                return;
            }
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
                Err(error) => error.reply(scoped.then_some(game_id.as_str()), request),
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
            game_id, request_id, reason, retry_after_ms: None,
        };
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            self.send(replier, &reject(expected_game_id.map(str::to_owned), "Not connected to Lichess".into()));
            return;
        };
        let credential_rejected = account.credential_rejected.clone();
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
            if let Some(retry_after_ms) = self.move_submission_cooldown.remaining_ms() {
                self.send(replier, &move_rate_limited(&session.game_id, request_id, retry_after_ms));
                return;
            }
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
            self.move_submission_cooldown.clone(), credential_rejected,
        )));
    }

    fn spawn_account_stream(&mut self, replier: BackendReplier<Self>, ratings: Vec<RatingSummary>) {
        let Some(client) = self.client.clone() else { return };
        let write_lock = self.write_lock.clone();
        // Keep one refresh queued behind the active fetch. Awaiting it inside the
        // stream blocked game events, and spawning per event overlaps requests.
        let (challenge_refresh, mut refreshes) = mpsc::channel(1);
        let event_refresh = challenge_refresh.clone();
        let challenge_list = Arc::new(std::sync::Mutex::new(ChallengeList::default()));
        let list = challenge_list.clone();
        let home_games = Arc::new(AccountGames::default());
        let games = home_games.clone();
        let board_session = self.session.clone();
        // Only an explicit server denial proves the list is unavailable.
        // Guessing from scopes can miss alternate grants, and every 403 is too broad.
        let challenge_read_denied = Arc::new(AtomicBool::new(false));
        let denied = challenge_read_denied.clone();
        let credential_rejected = Arc::new(AtomicBool::new(false));
        let rejected = credential_rejected.clone();
        let cooldown = self.account_stream_cooldown.clone();
        let list_cooldown = self.challenge_list_cooldown.clone();
        let task = tokio::spawn(async move {
            // Both futures drop together when the account is replaced or signed out.
            let refresh = async {
                let mut retry_queued = false;
                while retry_queued || refreshes.recv().await.is_some() {
                    let deadline = list_cooldown.pending_deadline();
                    if let Some(deadline) = deadline {
                        tokio::time::sleep_until(deadline.into()).await;
                    }
                    if deadline.is_some() || retry_queued {
                        // The one queued event is covered by this fresh snapshot.
                        let _ = refreshes.try_recv();
                    }
                    let result = client.get_challenges().await;
                    // Report before mapping to a list failure. A generic error
                    // keeps a revoked session active, and treating 403 as global loses Board access.
                    if result.as_ref().err().is_some_and(is_unauthorized) {
                        report_account_rejection(&replier, &rejected);
                        break;
                    }
                    let reply = challenge_list_reply(result, &list);
                    let missing_scope = matches!(reply, BackendMessage::ChallengesLoadFailed { retryable: Some(false), .. });
                    retry_queued = matches!(reply, BackendMessage::ChallengesLoadFailed { retry_after_ms: Some(_), .. });
                    if retry_queued {
                        list_cooldown.start();
                    }
                    if missing_scope {
                        denied.store(true, Ordering::Relaxed);
                    }
                    send_locked(&replier, &write_lock, &reply);
                    if missing_scope {
                        break;
                    }
                }
            };
            tokio::join!(
                read_account_events(&client, &replier, &write_lock, &event_refresh, AccountEventScope {
                    games: &games, board_session: &board_session, credential_rejected: &rejected, cooldown: &cooldown,
                }),
                refresh,
            );
        });
        self.account_stream = Some(AccountStream {
            task, challenge_refresh, challenge_list, challenge_read_denied, home_games,
            // The verified profile can cover a first Home failure. A screen
            // cache misses reloads, and a process cache can leak across accounts.
            ratings: Arc::new(std::sync::Mutex::new(ratings)), credential_rejected,
        });
    }

    fn queue_challenge_refresh(&self, replier: &BackendReplier<Self>) {
        if let Some(account) = &self.account_stream {
            if account.challenge_read_denied.load(Ordering::Relaxed) {
                self.send(replier, &challenge_read_denial());
            } else {
                let list = account.challenge_list.lock().expect("challenge list lock poisoned");
                if let Some(retry_after_ms) = self.challenge_list_cooldown.remaining_ms() {
                    if let Some(challenges) = &list.snapshot {
                        self.send(replier, &BackendMessage::PendingChallenges { challenges: challenges.clone() });
                    }
                    self.send(replier, &challenge_list_rate_limited(retry_after_ms));
                }
                let _ = account.challenge_refresh.try_send(());
            }
        }
    }

    async fn start_challenge_action(
        &mut self,
        replier: &BackendReplier<Self>,
        request: ChallengeRequest,
    ) {
        let (Some(client), Some(account)) = (self.client.clone(), self.account_stream.as_ref()) else {
            self.send(replier, &request.failure("Sign in to Lichess to respond to challenges.".into()));
            return;
        };
        let refresh = account.challenge_refresh.clone();
        let list = account.challenge_list.clone();
        let credential_rejected = account.credential_rejected.clone();
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
        if let Some(retry_after_ms) = self.challenge_action_cooldown.remaining_ms() {
            self.send(replier, &request.rate_limited(retry_after_ms));
            return;
        }
        let request_id = request.request_id;
        let replier = replier.clone();
        let write_lock = self.write_lock.clone();
        let cooldown = self.challenge_action_cooldown.clone();
        let (done, completion) = oneshot::channel();
        let task = tokio::spawn(async move {
            let result = match request.action {
                ChallengeAction::Accept => {
                    accept_playable_challenge(&client, &list, &request.challenge_id).await
                }
                ChallengeAction::Decline => client.decline_challenge(&request.challenge_id).await,
            };
            if result.as_ref().err().is_some_and(is_unauthorized) {
                report_account_rejection(&replier, &credential_rejected);
                return;
            }
            let failure = result.err().map(|error| {
                if is_rate_limited(&error) {
                    cooldown.start();
                    request.rate_limited(LICHESS_RATE_LIMIT_DELAY.as_millis() as u32)
                } else {
                    request.failure(format!("{error:#}"))
                }
            });
            if let Some(reply) = failure {
                drop(done);
                send_locked(&replier, &write_lock, &reply);
                return;
            }
            let challenge_id = request.challenge_id;
            list.lock().expect("challenge list lock poisoned").resolve(&challenge_id);
            drop(done);
            let reply = match request.action {
                ChallengeAction::Accept => BackendMessage::ChallengeAccepted { game_id: challenge_id, request_id },
                ChallengeAction::Decline => BackendMessage::ChallengeDeclined { challenge_id, request_id },
            };
            send_locked(&replier, &write_lock, &reply);
            let _ = refresh.try_send(());
        });
        self.pending_challenge_action = Some(GameRequest { request_id, task, completion: Some(completion) });
    }
}

async fn accept_playable_challenge(
    client: &LichessClient,
    list: &std::sync::Mutex<ChallengeList>,
    id: &str,
) -> anyhow::Result<()> {
    // Challenge IDs keep their terms. Reading every invite again adds latency,
    // while trusting the frontend can accept a game the board cannot open.
    let cached = list.lock().expect("challenge list lock poisoned").support.get(id).cloned();
    let board_support = match cached {
        Some(support) => support,
        None => {
            let terms = client.get_challenge_terms(id).await
                .map_err(|error| error.context("Couldn't verify the challenge details"))?;
            challenge_board_support(&terms)
        }
    };
    match board_support {
        BoardSupport::Playable => client.accept_challenge(id).await,
        BoardSupport::Unavailable(reason) => Err(anyhow::anyhow!(reason)),
        BoardSupport::Unknown => {
            Err(anyhow::anyhow!("Couldn't verify that this invitation can be played on the tablet."))
        }
    }
}

fn board_support(variant: Option<&Variant>, clock: BoardSupport) -> BoardSupport {
    match variant {
        Some(variant) if !supports_variant(&variant.key) => {
            BoardSupport::Unavailable(format!("{} games are not supported on this board.", variant.name))
        }
        None if clock == BoardSupport::Playable => BoardSupport::Unknown,
        _ => clock,
    }
}

fn challenge_board_support(terms: &ChallengeTerms) -> BoardSupport {
    let from_clock = terms.time_control.as_ref().and_then(|time_control| {
        match time_control.kind.as_deref() {
            Some("correspondence" | "unlimited") => Some(true),
            Some("clock") | None => time_control.limit.zip(time_control.increment).map(|(limit, increment)| {
                board_clock_estimate_seconds(u64::from(limit), increment) >= BOARD_BLITZ_MIN_ESTIMATE_SECONDS
            }),
            _ => None,
        }
    });
    let clock_supported = from_clock.or(match terms.speed.as_deref() {
        Some("ultraBullet" | "bullet") => Some(false),
        Some("blitz" | "rapid" | "classical" | "correspondence") => Some(true),
        _ => None,
    });
    let clock = match clock_supported {
        Some(false) => BoardSupport::Unavailable(
            "Lichess allows Blitz or slower for invitations played on the tablet.".into(),
        ),
        Some(true) => BoardSupport::Playable,
        None => BoardSupport::Unknown,
    };
    board_support(terms.variant.as_ref(), clock)
}

#[cfg(test)]
mod challenge_board_support_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn invitation_eligibility_uses_the_friend_clock_and_preserves_unknown_terms() {
        use BoardSupport::{Playable, Unavailable, Unknown};
        let standard = json!({"key": "standard", "name": "Standard"});
        let atomic = json!({"key": "atomic", "name": "Atomic"});
        let too_fast = Unavailable("Lichess allows Blitz or slower for invitations played on the tablet.".into());
        for (terms, expected) in [
            (json!({"variant": standard, "timeControl": {"type": "clock", "limit": 99, "increment": 2}}), too_fast.clone()),
            (json!({"variant": standard, "timeControl": {"limit": 100, "increment": 2}}), Playable),
            (json!({"variant": standard, "timeControl": {"type": "clock", "limit": 0, "increment": 5}}), Playable),
            (json!({"variant": standard, "speed": "ultraBullet"}), too_fast.clone()),
            (json!({"speed": "bullet"}), too_fast),
            (json!({"variant": standard, "speed": "blitz", "timeControl": {"type": "clock", "limit": 60}}), Playable),
            (json!({"variant": standard, "timeControl": {"type": "unlimited"}}), Playable),
            (json!({"variant": standard, "timeControl": {"type": "correspondence", "daysPerTurn": 3}}), Playable),
            (json!({"variant": standard, "speed": "newSpeed"}), Unknown),
            (json!({"variant": standard, "timeControl": {"type": "future", "limit": 600, "increment": 0}}), Unknown),
            (json!({"speed": "rapid"}), Unknown),
            (json!({"variant": atomic}), Unavailable("Atomic games are not supported on this board.".into())),
        ] {
            let actual = challenge_board_support(&serde_json::from_value(terms.clone()).unwrap());
            assert_eq!(actual, expected, "{terms}");
        }
    }
}

async fn verify_sign_in(token: String, profile: Arc<AccountProfile>) -> Result<VerifiedSignIn, SignInError> {
    let client = LichessClient::new(token.clone());
    let account = profile.read(&client).await.map_err(|error| match error {
        AccountProfileError::RateLimited(deadline) => SignInError::ProfileRateLimited(deadline),
        AccountProfileError::Read(error) => error.into(),
    })?;
    // Account access needs no scope. A live Board stream needs a game, and
    // attempting matchmaking to check the scope would change account state.
    let grant = client.get_token_grant().await?.ok_or(SignInError::Rejected)?;
    if grant.user_id != account.id {
        return Err(SignInError::Verification);
    }
    if !grant.scopes.split(',').any(|scope| scope.trim() == "board:play") {
        return Err(SignInError::MissingBoardScope);
    }
    Ok(VerifiedSignIn {
        token, client, my_id: account.id, username: account.username, ratings: ratings_from_perfs(account.perfs),
    })
}

struct AccountEventScope<'a> {
    games: &'a AccountGames,
    board_session: &'a Mutex<Option<GameSession>>,
    credential_rejected: &'a Arc<AtomicBool>,
    cooldown: &'a RateLimitCooldown,
}

async fn read_account_events(
    client: &LichessClient,
    replier: &BackendReplier<LichessBackend>,
    write_lock: &Arc<std::sync::Mutex<()>>,
    refresh_challenges: &mpsc::Sender<()>,
    scope: AccountEventScope<'_>,
) {
    let AccountEventScope { games, board_session, credential_rejected, cooldown } = scope;
    let mut reconnect = StreamReconnectDelay::new(Duration::from_secs(30));
    // Reconnect replays ongoing games. A per-connection set repeats old
    // starts, and remembering every finished game grows without bound.
    let mut announced_games = HashSet::new();
    let mut reconnecting = false;
    loop {
        if let Some(deadline) = cooldown.pending_deadline() {
            reconnecting = true;
            tokio::time::sleep_until(deadline.into()).await;
        }
        let mut received_for = Duration::ZERO;
        let attachment_requested_at = Instant::now();
        let response = client.stream_lines("/api/stream/event").await;
        if let Err(error) = &response {
            if is_unauthorized(error) {
                report_account_rejection(replier, credential_rejected);
                return;
            }
            if is_rate_limited(error) {
                cooldown.start();
                continue;
            }
        }
        if let Ok(mut lines) = response {
            let connected_at = Instant::now();
            let mut previewed_games = HashSet::new();
            while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
                received_for = connected_at.elapsed();
                if reconnecting {
                    reconnecting = false;
                    send_locked(replier, write_lock, &BackendMessage::AccountEventsResumed);
                }
                match parse_ndjson_line::<EventStreamMessage>(&line) {
                    Some(EventStreamMessage::GameStart { game }) => {
                        let first_announcement = announced_games.insert(game.id.clone());
                        if !first_announcement && previewed_games.contains(&game.id) {
                            continue;
                        }
                        let board_supported = game_start_board_support(&game);
                        let mut list = games.list.lock().expect("home game list lock poisoned");
                        let home_game = ongoing_game_from_start(&game, board_supported)
                            .filter(|preview| previewed_games.insert(game.id.clone())
                                && list.record_preview(attachment_requested_at, Instant::now(), preview, !first_announcement))
                            .map(Box::new);
                        if !first_announcement {
                            if let Some(game) = home_game {
                                send_locked(replier, write_lock, &BackendMessage::HomeGameUpdated { game });
                            }
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
                            board_supported,
                            speed: game.speed.filter(|speed| matches!(speed.as_str(),
                                "ultraBullet" | "bullet" | "blitz" | "rapid" | "classical" | "correspondence"
                            )),
                            rated: game.rated,
                            color: game.color.filter(|color| matches!(color.as_str(), "white" | "black")),
                            home_game,
                        });
                    }
                    Some(EventStreamMessage::Challenge)
                    | Some(EventStreamMessage::ChallengeCanceled)
                    | Some(EventStreamMessage::ChallengeDeclined) => {
                        let _ = refresh_challenges.try_send(());
                    }
                    Some(EventStreamMessage::GameFinish { game }) => {
                        announced_games.remove(&game.id);
                        let mut board = board_session.lock().await;
                        if let Some(session) = board.as_mut().filter(|session| session.game_id == game.id) {
                            session.wait_for_final_position();
                        }
                        if report_game_finish(replier, write_lock, &games.list, &game.id) {
                            games.finish_observed.notify_one();
                        }
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

fn report_game_finish(
    replier: &BackendReplier<LichessBackend>,
    write_lock: &Arc<std::sync::Mutex<()>>,
    game_list: &std::sync::Mutex<HomeGameList>,
    game_id: &str,
) -> bool {
    // Serialize the first notice with Home snapshots. Sending after unlocking
    // can reorder them, and publishing both stream notices can repeat the read.
    let mut list = game_list.lock().expect("home game list lock poisoned");
    if list.finish(game_id) {
        send_locked(replier, write_lock, &BackendMessage::GameFinished { game_id: game_id.to_owned() });
        true
    } else {
        false
    }
}

fn report_account_rejection(replier: &BackendReplier<LichessBackend>, rejected: &Arc<AtomicBool>) {
    if rejected.swap(true, Ordering::Relaxed) {
        return;
    }
    let replier = replier.clone();
    let rejected = rejected.clone();
    // The reporting worker is on the shutdown list, so it cannot await teardown itself.
    tokio::spawn(async move {
        let mut backend = replier.backend.lock().await;
        if backend.account_stream.as_ref().is_some_and(|account| Arc::ptr_eq(&account.credential_rejected, &rejected)) {
            backend.reject_authenticated_account(&replier).await;
        }
    });
}

/// Every outgoing send in this file funnels through here -- see write_lock's own
/// comment on LichessBackend for why a plain, uncoordinated replier.send_message()
/// call is unsafe once more than one task can be sending at once.
fn send_locked(replier: &BackendReplier<LichessBackend>, lock: &Arc<std::sync::Mutex<()>>, msg: &BackendMessage) {
    let json = serde_json::to_string(msg).expect("BackendMessage always serializes");
    send_json_locked(replier, lock, &json);
}

fn send_json_locked(replier: &BackendReplier<LichessBackend>, lock: &Arc<std::sync::Mutex<()>>, json: &str) {
    let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, json);
}

fn encode_review_reply(reply: &mut BackendMessage) -> Option<String> {
    let encode = |reply: &BackendMessage| {
        let json = serde_json::to_string(reply).expect("BackendMessage always serializes");
        (json.len() <= MAX_REVIEW_REPLY_BYTES).then_some(json)
    };
    if let Some(json) = encode(reply) {
        return Some(json);
    }
    // Dropping optional data keeps every ply. Truncating the replay hides the
    // ending, while splitting it requires a different frontend protocol.
    let BackendMessage::GameMoves { analysis, .. } = reply else { return None; };
    let mut removed_captions = false;
    for entry in analysis {
        removed_captions |= entry.judgment_comment.take().is_some();
    }
    if removed_captions {
        if let Some(json) = encode(reply) {
            return Some(json);
        }
    }
    let BackendMessage::GameMoves { analysis, .. } = reply else { return None; };
    if !analysis.is_empty() {
        analysis.clear();
        if let Some(json) = encode(reply) {
            return Some(json);
        }
    }
    let BackendMessage::GameMoves { clock_ms, .. } = reply else { return None; };
    if clock_ms.is_empty() {
        return None;
    }
    clock_ms.clear();
    encode(reply)
}

fn challenge_list_reply(
    result: anyhow::Result<Vec<IncomingChallenge>>,
    list: &std::sync::Mutex<ChallengeList>,
) -> BackendMessage {
    use crate::protocol::ChallengeTimeControlKind;
    match result {
        Ok(challenges) => {
            let mut known_support = HashMap::new();
            let mut challenges: Vec<_> = challenges
                .into_iter()
                .map(|c| {
                    let decision = challenge_board_support(&c.terms);
                    let (board_supported, board_unavailable_reason) = decision.summary_fields();
                    if board_supported.is_some() {
                        known_support.insert(c.id.clone(), decision);
                    }
                    let clock = c.terms.time_control.unwrap_or_default();
                    let time_control = match clock.kind.as_deref() {
                        Some("clock") => ChallengeTimeControlKind::Clock,
                        Some("correspondence") => ChallengeTimeControlKind::Correspondence,
                        Some("unlimited") => ChallengeTimeControlKind::Unlimited,
                        None if clock.limit.is_some() && clock.increment.is_some() => {
                            ChallengeTimeControlKind::Clock
                        }
                        _ => ChallengeTimeControlKind::Unknown,
                    };
                    let days_per_turn = clock.days_per_turn
                        .filter(|_| time_control == ChallengeTimeControlKind::Correspondence)
                        .and_then(|days| u32::try_from(days).ok())
                        .filter(|days| *days > 0);
                    let variant = c.terms.variant.map(|variant| variant.key);
                    ChallengeInfo {
                        id: c.id,
                        challenger: c.challenger.name,
                        limit_seconds: clock.limit,
                        increment_seconds: clock.increment,
                        time_control,
                        days_per_turn,
                        variant,
                        rated: c.rated,
                        board_supported,
                        board_unavailable_reason,
                    }
                })
                .collect();
            let mut list = list.lock().expect("challenge list lock poisoned");
            list.resolved.retain(|id| challenges.iter().any(|challenge| challenge.id == *id));
            challenges.retain(|challenge| !list.resolved.contains(&challenge.id));
            known_support.retain(|id, _| !list.resolved.contains(id));
            list.support = known_support;
            list.snapshot = Some(challenges.clone());
            BackendMessage::PendingChallenges { challenges }
        }
        Err(error) if is_challenge_read_denial(&error) => {
            *list.lock().expect("challenge list lock poisoned") = ChallengeList::default();
            challenge_read_denial()
        }
        Err(error) if is_rate_limited(&error) => {
            challenge_list_rate_limited(LICHESS_RATE_LIMIT_DELAY.as_millis() as u32)
        }
        Err(e) => {
            log::warn!("couldn't load challenges: {e}");
            BackendMessage::ChallengesLoadFailed {
                message: "Couldn't load challenges. Retry when connected.".to_string(),
                retryable: None,
                retry_after_ms: None,
            }
        }
    }
}

fn challenge_read_denial() -> BackendMessage {
    BackendMessage::ChallengesLoadFailed {
        message: "To see incoming challenges, sign in with a token that has Read challenges (challenge:read) permission.".into(),
        retryable: Some(false),
        retry_after_ms: None,
    }
}

fn challenge_list_rate_limited(retry_after_ms: u32) -> BackendMessage {
    BackendMessage::ChallengesLoadFailed {
        message: "Lichess is limiting challenge updates. The list will refresh shortly.".into(),
        retryable: None,
        retry_after_ms: Some(retry_after_ms),
    }
}

enum GameExportFailure {
    RateLimited(Duration),
    Request(anyhow::Error),
}

async fn request_game_export<T>(
    retry_after: &Mutex<Option<Instant>>, request: impl Future<Output = anyhow::Result<T>>,
) -> Result<T, GameExportFailure> {
    let mut deadline = retry_after.lock().await;
    if let Some(remaining) = deadline.and_then(|until| until.checked_duration_since(Instant::now())) {
        return Err(GameExportFailure::RateLimited(remaining));
    }
    match request.await {
        Err(error) if is_rate_limited(&error) => {
            *deadline = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
            Err(GameExportFailure::RateLimited(LICHESS_RATE_LIMIT_DELAY))
        }
        result => result.map_err(GameExportFailure::Request),
    }
}

fn export_wait_ms(remaining: Duration) -> u32 {
    remaining.as_millis().max(1) as u32
}

fn pgn_export_failure(game_id: &str, request_id: u32, message: &str, delay: Option<Duration>) -> BackendMessage {
    BackendMessage::PgnExportFailed {
        game_id: game_id.to_owned(), request_id, message: message.into(),
        retry_after_ms: delay.map(export_wait_ms),
    }
}

// Let the account worker classify HTTP failures. Formatting them here loses
// the authentication status, and verifying the profile again adds another read.
async fn export_pgn(
    client: &LichessClient, config_dir: &Path, game_id: &str, request_id: u32,
    retry_after: &Mutex<Option<Instant>>,
) -> Result<BackendMessage, GameExportFailure> {
    let Some(valid_id) = PgnGameId::parse(game_id.to_owned()) else {
        return Ok(pgn_export_failure(game_id, request_id, "This game does not have a valid Lichess ID.", None));
    };
    let pgn = request_game_export(retry_after, client.export_pgn(valid_id)).await?;
    Ok(match pgn.save(config_dir) {
        Ok(path) => BackendMessage::PgnExported {
            game_id: game_id.to_owned(), request_id, path: path.to_string_lossy().into_owned(),
        },
        Err(error) => {
            log::warn!("could not save game PGN: {error}");
            pgn_export_failure(game_id, request_id, "Could not save the PGN file.", None)
        }
    })
}

async fn fetch_opening_explorer(
    client: &LichessClient,
    request: OpeningExplorerRequest,
    retry_after: &Mutex<Option<Instant>>,
) -> BackendMessage {
    let OpeningExplorerRequest { request_id, review_id, database, fen, root_fen, played_san } = request;
    let failed = |message: &str, delay: Option<Duration>| BackendMessage::OpeningExplorerFailed {
        review_id, request_id, database, fen: fen.clone(), message: message.into(),
        retry_after_ms: delay.map(|remaining| remaining.as_millis().max(1) as u32),
    };
    let remaining = retry_after.lock().await
        .and_then(|until| until.checked_duration_since(Instant::now()));
    if let Some(remaining) = remaining {
        return failed(OPENING_RATE_LIMIT_MESSAGE, Some(remaining));
    }
    let position = match OpeningExplorerPosition::from_replay(&root_fen, &played_san, &fen) {
        Ok(position) => position,
        Err(error) => {
            log::warn!("could not reconstruct opening explorer position: {error}");
            return failed("Could not reconstruct this position.", None);
        }
    };
    match client.get_opening_explorer(database, &position.root_fen, &position.play).await {
        Ok(data) => match position.normalize_moves(data) {
            Ok(data) => BackendMessage::OpeningExplorer { review_id, request_id, database, fen, data },
            Err(error) => {
                log::warn!("could not use opening explorer statistics: {error}");
                failed("Lichess returned inconsistent opening statistics. Try again.", None)
            }
        },
        Err(error) if is_rate_limited(&error) => {
            *retry_after.lock().await = Some(Instant::now() + LICHESS_RATE_LIMIT_DELAY);
            failed(OPENING_RATE_LIMIT_MESSAGE, Some(LICHESS_RATE_LIMIT_DELAY))
        }
        Err(error) if is_auth_rejection(&error) => {
            failed("Lichess denied access to this opening database.", None)
        }
        Err(error) => {
            log::warn!("could not load opening explorer statistics: {error}");
            failed("Could not load opening statistics.", None)
        }
    }
}

fn history_rate_limit_reply(request_id: Option<u32>, remaining: Duration) -> BackendMessage {
    let message = HISTORY_RATE_LIMIT_MESSAGE.into();
    match request_id {
        Some(request_id) => BackendMessage::GameHistoryFailed {
            request_id,
            message,
            retry_after_ms: Some(remaining.as_millis().max(1) as u32),
        },
        None => BackendMessage::ErrorMsg { message },
    }
}

async fn refresh_home_games(
    client: LichessClient,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
    cooldown: RateLimitCooldown,
    game_list: Arc<AccountGames>,
    credential_rejected: Arc<AtomicBool>,
    request_id: Option<u32>,
) {
    let send_limited = |retry_after_ms| {
        let list = game_list.list.lock().expect("home game list lock poisoned");
        send_locked(&replier, &write_lock, &BackendMessage::HomeLoadFailed {
            request_id,
            message: "Lichess is limiting game-list requests. Trying again shortly.".into(),
            wifi_connected: None,
            retry_after_ms: Some(retry_after_ms),
            cached_games: list.replay(Instant::now()),
        });
    };
    if let Some(retry_after_ms) = cooldown.remaining_ms() {
        send_limited(retry_after_ms);
        return;
    }
    let request_started_at = Instant::now();
    match client.get_playing().await {
        Ok(games) => {
            let received_at = Instant::now();
            let wifi_connected = wifi_link_state();
            let games = games.into_iter().map(ongoing_game_summary).collect();
            let mut list = game_list.list.lock().expect("home game list lock poisoned");
            let ongoing_games = list.record(request_started_at, received_at, games);
            send_locked(&replier, &write_lock, &BackendMessage::HomeState { request_id, wifi_connected, ongoing_games });
        }
        Err(error) if is_rate_limited(&error) => {
            cooldown.start();
            send_limited(LICHESS_RATE_LIMIT_DELAY.as_millis() as u32);
        }
        Err(error) if is_unauthorized(&error) => {
            report_account_rejection(&replier, &credential_rejected);
        }
        Err(error) => {
            log::warn!("couldn't load Home: {error}");
            let wifi_connected = wifi_link_state();
            let message = if wifi_connected == Some(false) {
                "Wi-Fi is disconnected"
            } else {
                "Can't reach Lichess"
            };
            let list = game_list.list.lock().expect("home game list lock poisoned");
            send_locked(&replier, &write_lock, &BackendMessage::HomeLoadFailed {
                request_id,
                message: format!("{message}. Check your connection and retry."),
                wifi_connected,
                retry_after_ms: None,
                cached_games: list.replay(Instant::now()),
            });
        }
    }
}

async fn refresh_home_ratings(
    client: LichessClient,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
    profile: Arc<AccountProfile>,
    cache: Arc<std::sync::Mutex<Vec<RatingSummary>>>,
    credential_rejected: Arc<AtomicBool>,
    request_id: Option<u32>,
) {
    let (ratings, message, retry_after_ms) = match profile.read(&client).await {
        Ok(account) => {
            let ratings = ratings_from_perfs(account.perfs);
            *cache.lock().expect("home ratings lock poisoned") = ratings.clone();
            (ratings, None, None)
        }
        Err(AccountProfileError::RateLimited(deadline)) => {
            let ms = deadline.saturating_duration_since(Instant::now()).as_millis().max(1) as u32;
            (cache.lock().expect("home ratings lock poisoned").clone(),
                Some("Lichess is limiting rating requests. Trying again shortly.".into()), Some(ms))
        }
        Err(AccountProfileError::Read(error)) if is_unauthorized(&error) => {
            report_account_rejection(&replier, &credential_rejected);
            return;
        }
        Err(AccountProfileError::Read(_)) => {
            (cache.lock().expect("home ratings lock poisoned").clone(),
                Some("Couldn't refresh ratings.".into()), None)
        }
    };
    send_locked(&replier, &write_lock, &BackendMessage::HomeRatings { request_id, ratings, message, retry_after_ms });
}

fn game_start_board_support(game: &EventGame) -> Option<bool> {
    let variant = game.variant.as_ref();
    match game.compat.as_ref().and_then(|compat| compat.board) {
        Some(false) => Some(false),
        Some(true) => variant.map(|variant| supports_variant(&variant.key)),
        None => {
            let clock = ongoing_clock_support(game.speed.as_deref(), game.source.as_deref(), game.opponent.as_ref());
            match board_support(variant, clock) {
                BoardSupport::Unknown => None,
                support => Some(support == BoardSupport::Playable),
            }
        }
    }
}

fn ongoing_clock_support(speed: Option<&str>, source: Option<&str>, opponent: Option<&PlayingOpponent>) -> BoardSupport {
    use BoardSupport::{Playable, Unavailable, Unknown};
    match speed {
        Some("rapid" | "classical" | "correspondence") => Playable,
        Some("ultraBullet") => Unavailable("This UltraBullet game is too fast for tablet play.".into()),
        Some("bullet") => Unavailable("This Bullet game is too fast for tablet play.".into()),
        // Lichess allows Blitz for friend, API and built-in AI games. A blanket
        // Blitz ban loses those games, and assuming missing sources are public
        // would hide Resume for older payloads and incomplete position games.
        Some("blitz") if matches!(source, Some("friend" | "api" | "ai"))
            || opponent.is_some_and(|player| player.ai.is_some()) => Playable,
        Some("blitz") if matches!(source, Some("lobby" | "pool" | "arena" | "swiss" | "simul" | "tournament"))
            || source == Some("position") && opponent.is_some_and(|player| {
                player.username.as_ref().is_some_and(|name| !name.is_empty())
            }) => Unavailable("Lichess requires Rapid or slower to play this Blitz game on the tablet.".into()),
        _ => Unknown,
    }
}

fn ongoing_game_summary(game: PlayingGame) -> OngoingGameSummary {
    let opponent = game.opponent.as_ref();
    let clock = ongoing_clock_support(game.speed.as_deref(), game.source.as_deref(), opponent);
    let (board_supported, board_unavailable_reason) = board_support(game.variant.as_ref(), clock).summary_fields();
    OngoingGameSummary {
        game_id: game.game_id,
        // The built-in AI omits the username.
        opponent_name: opponent.and_then(|player| {
            player.username.clone().or_else(|| player.ai.map(|level| format!("Stockfish level {level}")))
        }),
        opponent_rating: opponent.and_then(|player| player.rating),
        is_my_turn: game.is_my_turn,
        correspondence_seconds_left: game.seconds_left
            .filter(|_| game.is_my_turn && game.speed.as_deref() == Some("correspondence"))
            .and_then(|seconds| u32::try_from(seconds).ok()),
        correspondence_age_ms: None,
        variant: game.variant.map(|variant| variant.key),
        board_supported,
        board_unavailable_reason,
    }
}

fn ongoing_game_from_start(event: &EventGame, board_supported: Option<bool>) -> Option<OngoingGameSummary> {
    if event.status.as_ref().is_some_and(|status| !matches!(status.name.as_str(), "created" | "started")) {
        return None;
    }
    let mut game = ongoing_game_summary(PlayingGame {
        game_id: event.id.clone(),
        is_my_turn: event.is_my_turn?,
        speed: Some(event.speed.clone()?),
        source: event.source.clone(),
        variant: Some(event.variant.clone()?),
        seconds_left: event.seconds_left,
        opponent: event.opponent.clone(),
    });
    game.board_supported = board_supported;
    game.board_unavailable_reason = if board_supported == Some(false) {
        game.board_unavailable_reason.or_else(|| Some("Lichess does not allow tablet play for this game.".into()))
    } else {
        None
    };
    Some(game)
}

#[cfg(test)]
mod game_board_support_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn home_replay_keeps_the_snapshot_age_and_removes_finished_games() {
        let mut list = HomeGameList::default();
        let received_at = Instant::now();
        assert!(list.replay(received_at).is_none());
        let game = |id| ongoing_game_summary(serde_json::from_value(json!({
            "gameId": id, "isMyTurn": true, "speed": "correspondence", "secondsLeft": 1200,
        })).unwrap());

        assert!(list.finish("finished"));
        assert!(!list.finish("finished"));
        let active = game("active");
        let finished = game("finished");
        let rows = list.record(received_at, received_at, vec![finished.clone(), active.clone()]);
        assert_eq!(rows, vec![active.clone()]);
        let later = received_at + Duration::from_millis(1234);
        let replay = list.replay(later).unwrap();
        assert_eq!(replay.games, rows);
        assert_eq!(replay.age_ms, 1234);

        assert!(list.finish("active"));
        assert!(list.replay(later).unwrap().games.is_empty());
        assert!(list.record(later, later, vec![finished, active]).is_empty());
        assert!(list.record(later, later, vec![]).is_empty());
        assert!(list.has_finished("active") && list.has_finished("finished"));
        assert_eq!(list.replay(later).unwrap().age_ms, 0);
    }

    #[test]
    fn home_preserves_start_clocks_until_a_newer_list_supersedes_them() {
        let start = |id, turn, compatible| {
            let event = serde_json::from_value(json!({
                "id": id, "isMyTurn": turn, "speed": "correspondence", "secondsLeft": 90,
                "variant": {"key": "standard", "name": "Standard"},
                "opponent": {"username": "Opponent", "rating": 1575},
                "compat": {"board": compatible},
            })).unwrap();
            ongoing_game_from_start(&event, game_start_board_support(&event))
        };
        let mut list = HomeGameList::default();
        let now = Instant::now();
        assert!(start("legacy", None::<bool>, true).is_none());
        let first = start("first", Some(true), true).unwrap();
        let second = start("second", Some(true), false).unwrap();
        assert_eq!(first.opponent_rating, Some(1575));
        assert_eq!(second.board_supported, Some(false));
        assert!(second.board_unavailable_reason.is_some());
        assert!(list.record_preview(now, now, &first, false));
        assert!(list.record_preview(now, now + Duration::from_millis(1000), &second, false));
        assert!(!list.record_preview(now, now + Duration::from_millis(1100), &first, true));

        let received_at = now + Duration::from_millis(1350);
        let replay = list.replay(received_at).unwrap();
        assert_eq!(replay.games[0].correspondence_age_ms, Some(1350));
        assert_eq!(replay.games[1].correspondence_age_ms, Some(350));
        assert!(list.finish("first"));
        assert!(!list.record_preview(received_at, received_at, &first, true));
        let rows = list.record(now + Duration::from_millis(500), received_at, vec![first]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].game_id, "second");
        assert_eq!(rows[0].correspondence_age_ms, Some(350));
        let rows = list.record(received_at, received_at, vec![second.clone()]);
        assert_eq!(rows, vec![second.clone()]);
        assert!(!list.record_preview(received_at, received_at, &second, true));
        assert_eq!(list.replay(received_at).unwrap().games, rows);
    }

    #[test]
    fn home_orders_reconnect_replays_by_request_and_ages_clocks_from_receipt() {
        let game = |id, my_turn| ongoing_game_summary(serde_json::from_value(json!({
            "gameId": id, "isMyTurn": my_turn, "speed": "correspondence", "secondsLeft": 100,
        })).unwrap());
        let mut list = HomeGameList::default();
        let now = Instant::now();
        let at = |ms| now + Duration::from_millis(ms);
        let initial_games = vec![game("other", true), game("target", false)];
        list.record(at(100), at(150), initial_games.clone());
        let ready = game("target", true);
        assert!(!list.record_preview(at(90), at(200), &ready, true));
        assert!(list.record_preview(at(300), at(800), &ready, true));
        assert!(!list.record_preview(at(300), at(900), &game("target", false), true));

        let overlap = list.record(at(200), at(1000), initial_games.clone());
        assert_eq!(overlap[0], initial_games[0]);
        assert_eq!(overlap[1].game_id, "target");
        assert!(overlap[1].is_my_turn);
        assert_eq!(overlap[1].correspondence_age_ms, Some(200));
        let cached = list.replay(at(2100)).unwrap();
        assert_eq!(cached.age_ms, 1100);
        assert_eq!(cached.games[1].correspondence_age_ms, Some(1300));

        let waiting = list.record(at(2200), at(2300), initial_games.clone());
        assert_eq!(waiting, initial_games);
        assert!(!list.record_preview(at(300), at(2400), &ready, true));
        assert!(list.finish("target"));
        assert!(!list.record_preview(at(2500), at(2600), &ready, true));
        assert_eq!(list.replay(at(2700)).unwrap().games, vec![game("other", true)]);
    }

    #[test]
    fn game_start_uses_reported_compatibility_and_the_local_variant() {
        let standard = json!({"key": "standard", "name": "Standard"});
        let atomic = json!({"key": "atomic", "name": "Atomic"});
        for (details, expected) in [
            (json!({"compat": {"board": false}, "speed": "rapid", "variant": standard}), Some(false)),
            (json!({"compat": {"board": true}, "speed": "rapid", "variant": atomic}), Some(false)),
            (json!({"compat": {"board": true}, "speed": "rapid", "variant": standard}), Some(true)),
            (json!({"compat": {"bot": false}, "source": "pool", "speed": "blitz"}), Some(false)),
            (json!({"source": "position", "opponent": {"ai": 4}, "speed": "blitz", "variant": standard}), Some(true)),
            (json!({"source": "pool", "speed": "rapid"}), None),
            (json!({}), None),
        ] {
            let mut game = details;
            game["id"] = json!("game1234");
            let event = serde_json::from_value(game.clone()).unwrap();
            assert_eq!(game_start_board_support(&event), expected, "{game}");
        }
    }

    #[test]
    fn reports_board_eligibility_from_speed_source_and_opponent() {
        let standard = json!({"key": "standard", "name": "Standard"});
        let atomic = json!({"key": "atomic", "name": "Atomic"});
        let human = json!({"username": "Opponent", "rating": 1750});
        let ai = json!({"ai": 4});
        for (speed, source, variant, opponent, supported, reason) in [
            ("bullet", Some("friend"), &standard, &human, Some(false), Some("Bullet game")),
            ("ultraBullet", None, &serde_json::Value::Null, &human, Some(false), Some("UltraBullet game")),
            ("blitz", Some("pool"), &standard, &human, Some(false), Some("requires Rapid")),
            ("blitz", Some("arena"), &standard, &human, Some(false), Some("requires Rapid")),
            ("blitz", Some("position"), &standard, &human, Some(false), Some("requires Rapid")),
            ("blitz", Some("position"), &standard, &ai, Some(true), None),
            ("blitz", Some("position"), &standard, &serde_json::Value::Null, None, None),
            ("blitz", Some("friend"), &standard, &human, Some(true), None),
            ("blitz", Some("api"), &standard, &human, Some(true), None),
            ("blitz", Some("ai"), &standard, &ai, Some(true), None),
            ("blitz", None, &standard, &human, None, None),
            ("blitz", Some("futureSource"), &standard, &human, None, None),
            ("rapid", Some("pool"), &standard, &human, Some(true), None),
            ("correspondence", None, &standard, &human, Some(true), None),
            ("futureSpeed", Some("pool"), &standard, &human, None, None),
            ("bullet", Some("pool"), &atomic, &human, Some(false), Some("Atomic")),
        ] {
            let game = serde_json::from_value(json!({
                "gameId": "game1234", "isMyTurn": true, "speed": speed, "source": source,
                "variant": variant, "opponent": opponent, "secondsLeft": 1200,
            })).unwrap();
            let summary = ongoing_game_summary(game);
            assert_eq!(summary.board_supported, supported, "{speed}, {source:?}, {opponent}");
            assert_eq!(summary.board_unavailable_reason.is_some(), reason.is_some());
            if let Some(reason) = reason {
                assert!(summary.board_unavailable_reason.unwrap().contains(reason));
            }
            assert_eq!(summary.correspondence_seconds_left, (speed == "correspondence").then_some(1200));
        }
    }
}

fn move_rate_limited(game_id: &str, request_id: Option<u32>, retry_after_ms: u32) -> BackendMessage {
    BackendMessage::MoveRejected {
        game_id: Some(game_id.to_owned()), request_id, reason: MOVE_RATE_LIMIT_MESSAGE.into(),
        retry_after_ms: Some(retry_after_ms),
    }
}

async fn submit_move(
    client: LichessClient,
    submission: MoveSubmission,
    session: Arc<Mutex<Option<GameSession>>>,
    replier: BackendReplier<LichessBackend>,
    write_lock: Arc<std::sync::Mutex<()>>,
    cooldown: RateLimitCooldown,
    credential_rejected: Arc<AtomicBool>,
) {
    let MoveSubmission { game_id, expected_moves, uci, request, mut canceled } = submission;
    let MoveRequest { request_id, from, to, promotion, .. } = request;
    let rejection = if let Some(retry_after_ms) = cooldown.remaining_ms() {
        // A settled worker may have received a 429 while the new move was being queued.
        Some(move_rate_limited(&game_id, request_id, retry_after_ms))
    } else {
        let submitted_at = Instant::now();
        let response = tokio::select! {
            biased;
            _ = &mut canceled => return,
            response = client.make_move(&game_id, &uci) => response,
        };
        if response.as_ref().err().is_some_and(is_unauthorized) {
            report_account_rejection(&replier, &credential_rejected);
            return;
        }
        let elapsed = submitted_at.elapsed();
        let rejection = response.err().map(|error| {
            if is_rate_limited(&error) {
                // The Board can settle the move or close before this reply takes the session lock.
                cooldown.start();
                let retry_after_ms = LICHESS_RATE_LIMIT_DELAY.as_millis() as u32;
                send_locked(&replier, &write_lock, &BackendMessage::MoveSubmissionCooldown { retry_after_ms });
                move_rate_limited(&game_id, request_id, retry_after_ms)
            } else {
                BackendMessage::MoveRejected {
                    game_id: Some(game_id.clone()), request_id, reason: error.to_string(), retry_after_ms: None,
                }
            }
        });
        if elapsed >= Duration::from_millis(750) {
            log::warn!("make_move {game_id} {uci} took {}ms", elapsed.as_millis());
        } else {
            log::debug!("make_move {game_id} {uci} took {}ms", elapsed.as_millis());
        }
        rejection
    };
    let mut guard = session.lock().await;
    let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) else { return };
    // An authoritative board can settle the move between HTTP completion and this lock.
    if canceled.try_recv() != Err(oneshot::error::TryRecvError::Empty) {
        return;
    }
    if let Some(reply) = rejection {
        session.cancel_move();
        send_locked(&replier, &write_lock, &reply);
        return;
    }
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
    cooldown: RateLimitCooldown,
    credential_rejected: Arc<AtomicBool>,
) {
    let MatchRequest { minutes, increment, request_id, .. } = request;
    let result = match &request.kind {
        MatchKind::Seek { rated, color } => match client.create_seek(minutes, increment, *rated, color).await {
            Ok(mut lines) => {
                send_locked(&replier, &write_lock, &BackendMessage::SeekCreated { request_id });
                while let Ok(Some(_)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {}
                Ok(BackendMessage::SeekEnded { request_id })
            }
            Err(error) => Err(error),
        },
        MatchKind::Direct { username, rated, color } => match client.create_challenge(
            username, minutes, increment, *rated, color,
        ).await {
            Ok((game_id, lines)) => {
                send_locked(&replier, &write_lock, &BackendMessage::ChallengeCreated {
                    game_id: game_id.clone(), request_id,
                });
                let resolution = read_challenge_result(lines).await;
                let error = match resolution {
                    Some(ChallengeResolution::Accepted) => None,
                    Some(ChallengeResolution::Declined) => Some("Challenge declined.".into()),
                    Some(ChallengeResolution::Canceled) => Some("Challenge canceled.".into()),
                    None => Some("Lost the challenge connection. Check Home if the game started.".into()),
                };
                Ok(BackendMessage::ChallengeResolved {
                    game_id, request_id, error, connection_lost: resolution.is_none().then_some(true),
                })
            }
            Err(error) => Err(error),
        },
        MatchKind::Computer { level, color } => client.challenge_ai(*level, minutes, increment, color).await
            .map(|game_id| BackendMessage::ComputerGameCreated { game_id, request_id }),
        MatchKind::Open { rated } => client.create_open_challenge(minutes, increment, *rated).await
            .map(|challenge| BackendMessage::OpenChallengeCreated {
                game_id: challenge.id,
                qr_codes: Box::new(OpenChallengeQrCodes::from_links(
                    &challenge.url, &challenge.url_white, &challenge.url_black,
                )),
                url: challenge.url,
                url_white: challenge.url_white,
                url_black: challenge.url_black,
                request_id,
            }),
    };
    let reply = match result {
        Ok(reply) => reply,
        Err(error) if is_unauthorized(&error) => {
            report_account_rejection(&replier, &credential_rejected);
            return;
        }
        Err(error) if is_rate_limited(&error) => {
            cooldown.start();
            request.rate_limited(LICHESS_RATE_LIMIT_DELAY.as_millis() as u32)
        }
        Err(error) => request.failure(error.to_string()),
    };
    drop(creation_done);
    send_locked(&replier, &write_lock, &reply);
}

async fn read_challenge_result(mut lines: LineStream) -> Option<ChallengeResolution> {
    while let Ok(Some(line)) = next_stream_line(&mut lines, STREAM_IDLE_TIMEOUT).await {
        if let Some(result) = parse_ndjson_line::<ChallengeResult>(&line) {
            return Some(result.done);
        }
    }
    None
}

async fn refresh_player_statuses(
    client: LichessClient,
    game_id: String,
    replier: BackendReplier<LichessBackend>,
    session_handle: Arc<Mutex<Option<GameSession>>>,
    write_lock: Arc<std::sync::Mutex<()>>,
    cooldown: RateLimitCooldown,
) {
    let rows = loop {
        let user_ids = {
            let guard = session_handle.lock().await;
            let Some(session) = guard.as_ref().filter(|session| session.game_id == game_id) else {
                return;
            };
            [session.your_player.id.clone(), session.opponent_player.id.clone()]
                .into_iter().flatten().collect::<Vec<_>>()
        };
        if user_ids.is_empty() {
            return;
        }
        if let Some(deadline) = cooldown.pending_deadline() {
            tokio::time::sleep_until(deadline.into()).await;
            continue;
        }
        match client.get_user_statuses(&user_ids).await {
            Ok(rows) => break rows,
            Err(error) if is_rate_limited(&error) => { cooldown.start(); }
            Err(error) => {
                log::debug!("optional player status lookup failed: {error}");
                return;
            }
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
    account: BoardStreamAccount,
    write_lock: Arc<std::sync::Mutex<()>>,
    cooldowns: BoardReadCooldowns,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut reconnect = StreamReconnectDelay::new(Duration::from_secs(5));
        let mut stream_finished = false;
        let mut awaiting_final_position = false;
        let finish = || report_game_finish(&replier, &write_lock, &account.home_games.list, &game_id);
        // Waiting inline stalls moves. A detached lookup can retry after the Board closes.
        let mut player_status_requests = tokio::task::JoinSet::new();
        while !stream_finished {
            if let Some(deadline) = cooldowns.stream.pending_deadline() {
                let remaining = deadline.saturating_duration_since(Instant::now());
                announce_game_reconnect(&replier, &write_lock, &session_handle, &game_id,
                    Some(remaining.as_millis().max(1) as u32)).await;
                tokio::time::sleep_until(deadline.into()).await;
                announce_game_reconnect(&replier, &write_lock, &session_handle, &game_id, None).await;
            }
            let mut received_for = Duration::ZERO;
            let response = client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await;
            if response.as_ref().err().is_some_and(is_unauthorized) {
                report_account_rejection(&replier, &account.credential_rejected);
                return;
            }
            if response.as_ref().err().is_some_and(is_rate_limited) {
                cooldowns.stream.start();
                continue;
            }
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
                let mut readiness = GameStreamReadiness::AwaitingSnapshot(connected_at + STREAM_IDLE_TIMEOUT);
                let mut opponent_departure = None;
                awaiting_final_position |= account.home_games.has_finished(&game_id);
                let mut final_deadline = awaiting_final_position.then_some(connected_at + FINAL_POSITION_REFRESH_INTERVAL);
                loop {
                    // Give the existing stream time to deliver its last frame.
                    // Reopening immediately drops that frame, and keepalives
                    // alone can keep a stale position open indefinitely.
                    let now = Instant::now();
                    let mut timeout = readiness.read_timeout(now);
                    if let Some(deadline) = final_deadline {
                        timeout = timeout.min(deadline.saturating_duration_since(now));
                    }
                    if timeout.is_zero() {
                        break;
                    }
                    let read = tokio::select! {
                        _ = account.home_games.finish_observed.notified(), if final_deadline.is_none() => {
                            if account.home_games.has_finished(&game_id)
                                || session_handle.lock().await.as_ref().is_some_and(GameSession::awaiting_final_position)
                            {
                                awaiting_final_position = true;
                                final_deadline = Some(Instant::now() + FINAL_POSITION_REFRESH_INTERVAL);
                            }
                            continue;
                        }
                        read = next_stream_line(&mut lines, timeout) => read,
                    };
                    let Ok(Some(line)) = read else { break };
                    received_for = connected_at.elapsed();
                    if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                            let mut request_statuses = false;
                            let mut guard = session_handle.lock().await;
                            let board_msg = match msg {
                                GameStreamMessage::Full(full) if full.id != game_id => {
                                    log::warn!("game stream {game_id} received a snapshot for a different game");
                                    readiness.schedule_resync(Instant::now());
                                    None
                                }
                                // A finished game can send only one Full snapshot
                                // before EOF, which would otherwise trigger a retry.
                                GameStreamMessage::Full(full) => {
                                    let is_over = full.state.is_terminal();
                                    if is_over {
                                        finish();
                                    }
                                    match GameSession::from_game_full(&full, &account.player_id) {
                                        Ok((mut s, mut board_msg)) => {
                                            readiness.accept_state(full.state.awaiting_start(), Instant::now());
                                            if let Some(previous) = guard.as_mut().filter(|session| {
                                                session.game_id == s.game_id
                                            }) {
                                                s.player_statuses = previous.player_statuses.take();
                                                awaiting_final_position |= previous.awaiting_final_position();
                                                if previous.berserked {
                                                    s.mark_berserked();
                                                }
                                            }
                                            s.opponent_departure = opponent_departure;
                                            if !is_over {
                                                awaiting_final_position |= account.home_games.has_finished(&game_id);
                                                if awaiting_final_position {
                                                    final_deadline.get_or_insert_with(|| Instant::now() + FINAL_POSITION_REFRESH_INTERVAL);
                                                    s.wait_for_final_position();
                                                }
                                            }
                                            if s.berserked || opponent_departure.is_some() || s.awaiting_final_position() {
                                                board_msg = s.board_state();
                                            }
                                            if let Some(previous) = guard.as_mut().filter(|session| {
                                                session.game_id == s.game_id
                                            }) {
                                                s.inherit_pending_requests(previous, &mut board_msg);
                                            }
                                            if is_over {
                                                stream_finished = true;
                                                *guard = None;
                                                Some(board_msg)
                                            } else {
                                                let _ = player_status_requests.try_join_next();
                                                request_statuses = !s.awaiting_final_position() &&
                                                    s.player_statuses.is_none() && player_status_requests.is_empty() &&
                                                    (s.your_player.id.is_some() || s.opponent_player.id.is_some());
                                                *guard = Some(s);
                                                Some(board_msg)
                                            }
                                        }
                                        Err(e) => {
                                            log::warn!("from_game_full failed for game {}: {e}", full.id);
                                            stream_finished = true;
                                            *guard = None;
                                            Some(if is_over {
                                                GameSession::full_outcome_without_position(&full, &account.player_id)
                                            } else {
                                                BackendMessage::GameStreamFailed {
                                                    game_id: game_id.clone(),
                                                    message: format!("Couldn't load this game: {e}"),
                                                }
                                            })
                                        }
                                    }
                                }
                                GameStreamMessage::State(state) => match guard.as_mut() {
                                    Some(s) if matches!(readiness, GameStreamReadiness::Ready(_)) && s.game_id == game_id => {
                                        let is_over = state.is_terminal();
                                        let awaiting_start = state.awaiting_start();
                                        let fallback = is_over.then(|| outcome(&state.status, state.winner.as_deref()));
                                        let result = match s.apply_stream_update(state) {
                                            Ok(Some(msg)) => {
                                                readiness.accept_state(awaiting_start, Instant::now());
                                                Some(msg)
                                            }
                                            Ok(None) => None,
                                            Err(error) => {
                                                log::warn!(
                                                    "couldn't apply gameState for {game_id}: {error}"
                                                );
                                                fallback.map(|outcome| s.outcome_without_position(outcome, &account.player_id))
                                            }
                                        };
                                        if is_over {
                                            finish();
                                            stream_finished = true;
                                            *guard = None;
                                        } else if result.is_none() {
                                            readiness.schedule_resync(Instant::now());
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
                                        .filter(|s| s.game_id == game_id && s.is_stream_connected() && !s.awaiting_final_position())
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
                            if let Some(mut m) = board_msg {
                                if let BackendMessage::BoardState { from_game_stream, .. } = &mut m {
                                    *from_game_stream = Some(true);
                                }
                                send_locked(&replier, &write_lock, &m);
                            }
                            drop(guard);
                            if request_statuses {
                                player_status_requests.spawn(refresh_player_statuses(
                                    client.clone(),
                                    game_id.clone(),
                                    replier.clone(),
                                    session_handle.clone(),
                                    write_lock.clone(),
                                    cooldowns.player_statuses.clone(),
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
            announce_game_reconnect(&replier, &write_lock, &session_handle, &game_id, None).await;
            tokio::time::sleep(delay).await;
        }
    })
}

async fn announce_game_reconnect(
    replier: &BackendReplier<LichessBackend>,
    write_lock: &Arc<std::sync::Mutex<()>>,
    session_handle: &Mutex<Option<GameSession>>,
    game_id: &str,
    retry_after_ms: Option<u32>,
) {
    let mut guard = session_handle.lock().await;
    if let Some(session) = guard.as_mut().filter(|session| session.game_id == game_id) {
        session.mark_stream_disconnected();
    }
    send_locked(replier, write_lock, &BackendMessage::GameStreamReconnecting {
        game_id: game_id.to_owned(), retry_after_ms,
    });
}

#[cfg(test)]
mod stream_watchdog_tests {
    use super::{
        game_for_request, next_stream_line, GameSession, GameStream, GameStreamReadiness,
        LichessBackend, LineStream, StreamReconnectDelay, MOVE_RECONCILIATION_TIMEOUT,
        STREAM_IDLE_TIMEOUT,
    };
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    #[test]
    fn snapshot_wait_has_a_fixed_deadline_and_ready_keeps_its_own_timeouts() {
        let started = Instant::now();
        let awaiting = GameStreamReadiness::AwaitingSnapshot(started + STREAM_IDLE_TIMEOUT);
        for (elapsed, remaining) in [(0, 30), (7, 23), (14, 16), (28, 2), (30, 0), (32, 0)] {
            assert_eq!(
                awaiting.read_timeout(started + Duration::from_secs(elapsed)),
                Duration::from_secs(remaining),
            );
        }
        assert_eq!(
            GameStreamReadiness::Ready(None).read_timeout(started + Duration::from_secs(45)),
            STREAM_IDLE_TIMEOUT,
        );
        let reconciling = GameStreamReadiness::Ready(Some(started + MOVE_RECONCILIATION_TIMEOUT));
        assert_eq!(reconciling.read_timeout(started + Duration::from_secs(1)), Duration::from_secs(1));
        assert_eq!(reconciling.read_timeout(started + Duration::from_secs(2)), Duration::ZERO);
    }

    #[test]
    fn repeated_reconciliation_requests_keep_the_existing_deadline() {
        let started = Instant::now();
        let one_second_later = started + Duration::from_secs(1);
        let mut awaiting = GameStreamReadiness::AwaitingSnapshot(started + STREAM_IDLE_TIMEOUT);
        awaiting.schedule_resync(one_second_later);
        assert_eq!(awaiting.read_timeout(one_second_later), STREAM_IDLE_TIMEOUT - Duration::from_secs(1));

        let mut ready = GameStreamReadiness::Ready(None);
        ready.schedule_resync(started);
        ready.schedule_resync(one_second_later);
        assert_eq!(ready.read_timeout(started + MOVE_RECONCILIATION_TIMEOUT), Duration::ZERO);
    }

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
            self.stop_account_activity().await;
            return;
        }
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            // The new frontend starts its request sequence over.
            stop_task(&mut self.sign_in_connectivity).await;
            self.review_scope = None;
            stop_task(&mut self.opening_explorer).await;
            stop_game_request(&mut self.pgn_export).await;
            self.stop_sign_in(None).await;
            stop_task(&mut self.home_games).await;
            stop_task(&mut self.home_ratings).await;
            stop_game_request(&mut self.history_load).await;
            stop_game_request(&mut self.review_export).await;
            self.stop_cloud_evaluations().await;
            stop_game_request(&mut self.pending_match).await;
            stop_game_request(&mut self.pending_challenge_action).await;
            self.stop_game_stream().await;
            if !self.qr_sign_in_available {
                self.send(replier, &BackendMessage::SignInOptions { qr_available: false });
                if self.client.is_none() {
                    self.spawn_connectivity_report(replier);
                }
            }
            self.handle_request_settings(replier);
            if let Some(retry_after_ms) = self.match_creation_cooldown.remaining_ms() {
                self.send(replier, &BackendMessage::MatchCreationCooldown { retry_after_ms });
            }
            if let Some(retry_after_ms) = self.challenge_action_cooldown.remaining_ms() {
                self.send(replier, &BackendMessage::ChallengeActionCooldown { retry_after_ms });
            }
            if let Some(retry_after_ms) = self.challenge_list_cooldown.remaining_ms() {
                self.send(replier, &challenge_list_rate_limited(retry_after_ms));
            }
            if let Some(retry_after_ms) = self.move_submission_cooldown.remaining_ms() {
                self.send(replier, &BackendMessage::MoveSubmissionCooldown { retry_after_ms });
            }
            if let Some(retry_after_ms) = self.game_action_cooldown.remaining_ms() {
                self.send(replier, &BackendMessage::GameActionCooldown { retry_after_ms });
            }
            if self.account_stream.as_ref().is_some_and(|account| account.credential_rejected.load(Ordering::Relaxed)) {
                self.reject_authenticated_account(replier).await;
            } else if self.client.is_none() {
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
            FrontendMessage::RequestHomeRatings { request_id } => {
                self.start_home_ratings(replier, Some(request_id)).await;
            }
            FrontendMessage::ResumeGame { game_id } => self.handle_resume_game(replier, game_id).await,
            FrontendMessage::LeaveGame { game_id } => {
                if self.game_stream.as_ref().is_some_and(|stream| stream.game_id == game_id) {
                    self.stop_game_stream().await;
                }
            }
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
            FrontendMessage::ChallengeAi { level, minutes, increment, color, request_id } => {
                self.start_match_request(replier, MatchRequest {
                    kind: MatchKind::Computer { level, color: color.unwrap_or_else(|| "random".into()) },
                    minutes, increment, request_id,
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
            FrontendMessage::RequestChallenges => self.queue_challenge_refresh(replier),
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
                request_id,
                dark_mode,
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
                    request_id,
                    crate::settings::AppSettings {
                        dark_mode: dark_mode.unwrap_or_else(|| crate::settings::load(&self.settings_path).dark_mode),
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
            FrontendMessage::RequestGameHistory { request_id, rated, speed, color, cursor } => {
                self.start_game_history(replier, request_id, GameHistoryFilters { rated, speed, color }, cursor).await
            }
            FrontendMessage::CancelGameHistory { request_id } => {
                cancel_game_request(&mut self.history_load, request_id).await;
            }
            FrontendMessage::RequestPgnExport { game_id, request_id } => {
                self.start_pgn_export(replier, game_id, request_id).await;
            }
            FrontendMessage::CancelPgnExport { request_id } => {
                cancel_game_request(&mut self.pgn_export, request_id).await;
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
                if self.review_scope.as_ref().is_some_and(|scope| scope.review_id == request_id) {
                    self.review_scope = None;
                    stop_task(&mut self.opening_explorer).await;
                }
            }
            FrontendMessage::RequestReviewVariations { review_id } => {
                self.handle_load_variations(replier, review_id);
            }
            FrontendMessage::SaveReviewVariations { review_id, request_id, variations } => {
                self.handle_save_variations(replier, review_id, request_id, variations);
            }
            FrontendMessage::RequestCloudEvaluation { fen, request_id, review_id } => {
                self.queue_cloud_evaluation(replier, fen, request_id, review_id).await
            }
            FrontendMessage::CancelCloudEvaluations { review_id } => {
                if self.cloud_evaluations.as_ref().is_some_and(|queue| queue.review_id == Some(review_id)) {
                    self.stop_cloud_evaluations().await;
                }
            }
            FrontendMessage::RequestOpeningExplorer { request } => {
                self.start_opening_explorer(replier, request).await;
            }
            FrontendMessage::CancelOpeningExplorer { review_id } => {
                if self.review_scope.as_ref().is_some_and(|scope| scope.review_id == review_id) {
                    stop_task(&mut self.opening_explorer).await;
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

fn history_game_to_summary(game: HistoryGame, my_id: &str) -> Option<HistoryGameSummary> {
    let color = match game.players.perspective(my_id) {
        ParticipantPerspective::Known(color) => Some(color),
        ParticipantPerspective::Unverified => None,
        ParticipantPerspective::Foreign => return None,
    };
    let your_color = color.map(|color| color.fold_wb("white", "black"));
    let you = color.map(|color| game.players.player(color));
    let opponent = color.map(|color| game.players.player(color.other()));
    let opponent_name = opponent.and_then(|player| {
        let user = player.user.as_ref();
        user.and_then(|user| user.name.clone())
            .or_else(|| player.ai_level.map(|level| format!("Stockfish level {level}")))
            .or_else(|| player.stored_name.clone())
            .or_else(|| user?.id.as_deref().map(str::trim)
                .filter(|id| !id.is_empty()).map(str::to_owned))
    });
    let winner = game.winner.as_deref().filter(|color| matches!(*color, "white" | "black"));
    let settled = outcome(game.status.as_deref().unwrap_or("unknown"), winner);
    let result = match (winner, your_color) {
        (Some(winner), Some(yours)) => if winner == yours { "win" } else { "loss" }.into(),
        (None, _) if game.winner.is_some() => "unknown".into(),
        _ => settled.result,
    };
    let your_analysis = you.and_then(|player| player.analysis.as_ref()).map(|a| GameAnalysisSummary {
        inaccuracies: a.inaccuracy,
        mistakes: a.mistake,
        blunders: a.blunder,
        acpl: a.acpl,
        accuracy: a.accuracy,
    });
    let review_supported = game.variant.as_deref().map(crate::game::rules::supports_variant);
    Some(HistoryGameSummary {
        game_id: game.id,
        opponent_name,
        opponent_rating: opponent.and_then(|player| player.rating),
        your_color,
        result,
        termination: settled.reason,
        rating_diff: you.and_then(|player| player.rating_diff),
        your_analysis,
        rated: game.rated,
        variant: game.variant,
        review_supported,
        speed: game.speed,
        opening_name: game.opening.map(|o| o.name),
        created_at_ms: game.created_at,
    })
}

#[cfg(test)]
mod cloud_evaluation_tests {
    use super::{CloudEvaluationRequest, LichessBackend, LichessClient, Mutex};
    use serde_json::json;
    use std::time::{Duration, Instant};
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn cloud_evaluation_publishes_only_playable_scored_lines() {
        let server = MockServer::start().await;
        let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let cooldown = Mutex::new(None);
        let cases = [
            (json!({"moves": "e2e4"}), "CloudEvaluationFailed"),
            (json!({"cp": 22, "mate": -2, "moves": "e2e4"}), "CloudEvaluationFailed"),
            (json!({"cp": 22, "moves": "  "}), "CloudEvaluationFailed"),
            (json!({"mate": 0, "moves": "e2e4"}), "CloudEvaluationFailed"),
            (json!({"cp": 22, "moves": "e2e5"}), "CloudEvaluationFailed"),
            (json!({"cp": 0, "moves": "e2e4"}), "CloudEvaluation"),
            (json!({"mate": 2, "moves": "e2e4"}), "CloudEvaluation"),
            (json!({"mate": -2, "moves": "e2e4"}), "CloudEvaluation"),
        ];
        for (pv, expected) in cases {
            let _mock = Mock::given(method("GET"))
                .and(path("/api/cloud-eval"))
                .and(query_param("fen", start))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                    "fen": start, "depth": 23, "knodes": 34, "pvs": [pv],
                })))
                .expect(1)
                .mount_as_scoped(&server)
                .await;
            let request = CloudEvaluationRequest { requested_fen: start.into(), request_id: Some(27) };
            let reply = serde_json::to_value(LichessBackend::fetch_cloud_evaluation(&client, request, &cooldown).await).unwrap();
            assert_eq!(reply["type"], expected, "{pv}");
            assert_eq!(reply["request_id"], 27);
            assert_eq!(reply["requested_fen"], start);
            assert!(reply.get("retry_after_ms").is_none());
            if expected == "CloudEvaluation" {
                assert_eq!(reply["evaluation"]["eval_cp"], pv["cp"]);
                assert_eq!(reply["evaluation"]["mate_in"], pv["mate"]);
                assert_eq!(reply["evaluation"]["best_line"], json!(["e4"]));
            } else {
                assert!(reply.get("evaluation").is_none());
            }
        }
    }

    #[tokio::test]
    async fn cloud_evaluation_of_checkmate_or_stalemate_has_no_playable_line() {
        let server = MockServer::start().await;
        let cases = [
            ("7k/6Q1/5K2/8/8/8/8/8 b - - 0 1", json!({"moves": "h8g8"})),
            ("8/8/8/8/8/5k2/6q1/7K w - - 0 1", json!({"mate": 0, "moves": ""})),
            ("7k/5K2/6Q1/8/8/8/8/8 b - - 0 1", json!({"cp": 0, "moves": ""})),
        ];
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let cooldown = Mutex::new(None);
        for (fen, pv) in cases {
            let _mock = Mock::given(method("GET"))
                .and(path("/api/cloud-eval"))
                .and(query_param("fen", fen))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                    "fen": fen, "depth": 23, "knodes": 34, "pvs": [pv],
                })))
                .expect(1)
                .mount_as_scoped(&server)
                .await;
            let request = CloudEvaluationRequest { requested_fen: fen.into(), request_id: Some(28) };
            let reply = serde_json::to_value(LichessBackend::fetch_cloud_evaluation(&client, request, &cooldown).await).unwrap();
            assert_eq!(reply, json!({"type": "CloudEvaluationUnavailable", "request_id": 28, "requested_fen": fen}));
        }
    }

    #[tokio::test]
    async fn cloud_cooldown_reports_the_remaining_wait_and_resumes_after_expiry() {
        let server = MockServer::start().await;
        let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        let after_e4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1";
        for (fen, status) in [(start, 429), (after_e4, 404)] {
            Mock::given(method("GET"))
                .and(path("/api/cloud-eval"))
                .and(query_param("fen", fen))
                .respond_with(ResponseTemplate::new(status))
                .expect(1)
                .mount(&server)
                .await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let cooldown = Mutex::new(None);
        let fetch = |id, fen: &str| {
            LichessBackend::fetch_cloud_evaluation(
                &client,
                CloudEvaluationRequest { requested_fen: fen.to_owned(), request_id: Some(id) },
                &cooldown,
            )
        };

        let limited = serde_json::to_value(fetch(1, start).await).unwrap();
        assert_eq!(limited["type"], "CloudEvaluationFailed");
        assert_eq!(limited["retry_after_ms"], 60_000);

        let blocked = serde_json::to_value(fetch(2, after_e4).await).unwrap();
        assert_eq!(blocked["type"], "CloudEvaluationFailed");
        assert_eq!(blocked["request_id"], 2);
        assert_eq!(blocked["requested_fen"], after_e4);
        assert!((1..=60_000).contains(&blocked["retry_after_ms"].as_u64().unwrap()));

        *cooldown.lock().await = Some(Instant::now() - Duration::from_millis(1));
        let resumed = serde_json::to_value(fetch(3, after_e4).await).unwrap();
        assert_eq!(resumed["type"], "CloudEvaluationUnavailable");
        assert_eq!(resumed["request_id"], 3);
        assert!(resumed.get("retry_after_ms").is_none());
        server.verify().await;
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
mod review_packet_tests {
    use super::{encode_review_reply, BackendMessage, MAX_REVIEW_REPLY_BYTES};

    #[test]
    fn review_packet_checks_the_encoded_byte_boundary() {
        let mut reply = BackendMessage::GameMoves {
            game_id: "scope001".into(), request_id: Some(1), moves: vec![], fens: vec![String::new()],
            initial_in_check: false, clock_ms: vec![], analysis: vec![], rating_diff: None,
            variation_storage: Some(true),
        };
        let overhead = serde_json::to_string(&reply).unwrap().len();
        let BackendMessage::GameMoves { fens, .. } = &mut reply else { unreachable!() };
        fens[0] = "a".repeat(MAX_REVIEW_REPLY_BYTES - overhead);
        assert_eq!(encode_review_reply(&mut reply).unwrap().len(), MAX_REVIEW_REPLY_BYTES);
        let BackendMessage::GameMoves { fens, .. } = &mut reply else { unreachable!() };
        fens[0].push('é');
        assert!(encode_review_reply(&mut reply).is_none());
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
            stored_name: None,
            rating: Some(rating),
            ai_level: None,
            rating_diff,
            analysis: None,
        }
    }

    fn ai(level: u8, rating: u32) -> GamePlayerUser {
        GamePlayerUser {
            user: None, stored_name: None, rating: Some(rating), ai_level: Some(level), rating_diff: None, analysis: None,
        }
    }

    fn human_with_analysis(id: &str, name: &str, rating: u32, summary: PlayerAnalysisSummary) -> GamePlayerUser {
        GamePlayerUser {
            user: Some(LightUser { id: Some(id.to_string()), name: Some(name.to_string()) }),
            stored_name: None,
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
            variant: Some("standard".to_string()),
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
        let summary = history_game_to_summary(game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480)), "myuser").unwrap();
        assert_eq!(summary.opponent_name, Some("Bob".to_string()));
        assert_eq!(summary.opponent_rating, Some(1480));
    }

    #[test]
    fn archive_uses_available_opponent_names_without_changing_perspective() {
        for (opponent, expected) in [
            (r#"{"name":"  Guest Opponent  "}"#, Some("Guest Opponent")),
            (r#"{"name":"Stored Opponent","user":{"id":"opp","name":"   "}}"#, Some("Stored Opponent")),
            (r#"{"name":false,"user":{"id":"opp","name":[]}}"#, Some("opp")),
            (r#"{"name":"Alias","user":{"id":"opp","name":"Account"}}"#, Some("Account")),
            (r#"{"name":"Alias","aiLevel":3}"#, Some("Stockfish level 3")),
            (r#"{"name":null,"user":{"id":" "}}"#, None),
        ] {
            let opponent: GamePlayerUser = serde_json::from_str(opponent).unwrap();
            let archived = game(opponent, human("myuser", "MyUser", 1500));
            let summary = history_game_to_summary(archived, "myuser").unwrap();
            assert_eq!(summary.opponent_name.as_deref(), expected);
            assert_eq!(summary.your_color, Some("black"));
            assert_eq!(summary.result, "loss");
        }
    }

    #[test]
    fn archive_keeps_variant_and_speed_and_reports_known_replay_support() {
        for (variant, supported) in [
            (Some("standard"), Some(true)),
            (Some("fromPosition"), Some(true)),
            (Some("crazyhouse"), Some(false)),
            (Some("futureVariant"), Some(false)),
            (None, None),
        ] {
            let mut archived = game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480));
            archived.variant = variant.map(str::to_owned);
            let summary = history_game_to_summary(archived, "myuser").unwrap();
            assert_eq!(summary.variant.as_deref(), variant);
            assert_eq!(summary.speed.as_deref(), Some("blitz"));
            assert_eq!(summary.review_supported, supported);
        }
    }

    #[test]
    fn an_ai_opponent_with_no_lichess_account_falls_back_to_a_level_based_name() {
        let summary = history_game_to_summary(game(human("myuser", "MyUser", 1500), ai(5, 1400)), "myuser").unwrap();
        assert_eq!(summary.opponent_name, Some("Stockfish level 5".to_string()));
        assert_eq!(summary.opponent_rating, Some(1400));
    }

    #[test]
    fn rating_diff_is_read_from_your_own_side_not_the_opponents() {
        let summary = history_game_to_summary(
            game(human_with_rating_diff("myuser", "MyUser", 1508, Some(8)), human_with_rating_diff("bob", "Bob", 1472, Some(-8))),
            "myuser",
        ).unwrap();
        assert_eq!(summary.rating_diff, Some(8));
    }

    #[test]
    fn termination_distinguishes_how_a_win_happened_from_the_bare_win_loss_draw_result() {
        let by_resignation = history_game_to_summary(
            game_with_status(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480), "resign"),
            "myuser",
        ).unwrap();
        assert_eq!(by_resignation.result, "win");
        assert_eq!(by_resignation.termination, "Resignation");

        let by_timeout = history_game_to_summary(
            game_with_status(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480), "outoftime"),
            "myuser",
        ).unwrap();
        assert_eq!(by_timeout.termination, "Time forfeit");
    }

    #[test]
    fn history_reduces_the_shared_outcome_to_the_accounts_side() {
        for (status, winner, result, reason) in [
            ("outoftime", None, "draw", "Time expired"),
            ("timeout", None, "draw", "Disconnection"),
            ("insufficientMaterialClaim", None, "draw", "Insufficient material"),
            ("outoftime", Some("white"), "win", "Time forfeit"),
            ("timeout", Some("black"), "loss", "Disconnection"),
            ("noStart", Some("black"), "loss", "First move deadline missed"),
            ("aborted", None, "aborted", "Aborted"),
        ] {
            let mut archived = game_with_status(human("myuser", "MyUser", 1500),
                                                human("bob", "Bob", 1480), status);
            archived.winner = winner.map(str::to_owned);
            let summary = history_game_to_summary(archived, "myuser").unwrap();
            assert_eq!(summary.result, result, "{status} {winner:?}");
            assert_eq!(summary.termination, reason, "{status} {winner:?}");
        }
    }

    #[test]
    fn your_analysis_is_read_from_your_own_side_and_none_when_this_game_was_never_analyzed() {
        let summary_stats = PlayerAnalysisSummary {
            inaccuracy: Some(5), mistake: None, blunder: Some(1), acpl: Some(26), accuracy: Some(90),
        };
        let analyzed = history_game_to_summary(
            game(human_with_analysis("myuser", "MyUser", 1500, summary_stats), human("bob", "Bob", 1480)),
            "myuser",
        ).unwrap();
        let your_analysis = analyzed.your_analysis.unwrap();
        assert_eq!(your_analysis.inaccuracies, Some(5));
        assert_eq!(your_analysis.blunders, Some(1));
        assert_eq!(your_analysis.mistakes, None);
        assert_eq!(your_analysis.acpl, Some(26));
        assert_eq!(your_analysis.accuracy, Some(90));

        let unanalyzed =
            history_game_to_summary(game(human("myuser", "MyUser", 1500), human("bob", "Bob", 1480)), "myuser").unwrap();
        assert_eq!(unanalyzed.your_analysis, None);
    }

    #[test]
    fn a_confirmed_foreign_game_has_no_history_card() {
        let archived = game(human("alice", "Alice", 1500), human("bob", "Bob", 1480));
        assert!(history_game_to_summary(archived, "myuser").is_none());
    }

    #[test]
    fn an_unverified_side_keeps_the_neutral_result_without_player_specific_fields() {
        let other = human_with_rating_diff("bob", "Bob", 1480, Some(8));
        let mut name_only = human("", "MyUser", 1500);
        name_only.user.as_mut().unwrap().id = None;
        for archived in [game(name_only, other),
            game(human("myuser", "MyUser", 1500), human("myuser", "MyUser", 1500))] {
            let summary = history_game_to_summary(archived, "myuser").unwrap();
            assert_eq!(summary.result, "white");
            assert_eq!(summary.termination, "Checkmate");
            assert_eq!(summary.your_color, None);
            assert!(summary.rating_diff.is_none() && summary.your_analysis.is_none());
            assert!(summary.opponent_name.is_none() && summary.opponent_rating.is_none());
        }
    }

    #[test]
    fn a_verified_black_side_keeps_its_rating_and_never_loses_to_an_invalid_winner() {
        let mut archived = game(ai(5, 1400), human_with_rating_diff("myuser", "MyUser", 1500, Some(-7)));
        let summary = history_game_to_summary(archived.clone(), "myuser").unwrap();
        assert_eq!(summary.your_color, Some("black"));
        assert_eq!(summary.result, "loss");
        assert_eq!(summary.rating_diff, Some(-7));
        assert_eq!(summary.opponent_name.as_deref(), Some("Stockfish level 5"));
        archived.winner = Some("spectator".into());
        let summary = history_game_to_summary(archived, "myuser").unwrap();
        assert_eq!(summary.result, "unknown");
        assert_eq!(summary.termination, "Checkmate");
    }
}
