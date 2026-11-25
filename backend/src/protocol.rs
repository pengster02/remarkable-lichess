use crate::qr::QrMatrix;
use crate::variations::ReviewVariations;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const MSG_TYPE_FRONTEND_TO_BACKEND: u32 = 1;
pub const MSG_TYPE_BACKEND_TO_FRONTEND: u32 = 2;

fn default_true() -> bool {
    true
}

fn default_board_theme() -> String {
    "brown".to_owned()
}

fn default_piece_set() -> String {
    "cburnett".to_owned()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LegalMove {
    pub from: String,
    pub to: String,
    pub promotion: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HistoryCapture {
    pub ply: usize,
    pub piece: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum CaptureHistoryUpdate {
    Full { capture_history: Box<[HistoryCapture]> },
    Append { appended_capture: String },
}

// A compact integer is exact in QML. FEN alone repeats across lines, and
// sending the whole history with each move would duplicate the board snapshot.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct PositionId(pub u32);

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct MoveRequest {
    pub from: String,
    pub to: String,
    pub promotion: Option<String>,
    pub request_id: Option<u32>,
    pub expected_position_id: Option<PositionId>,
}

// These intents keep the user's operation explicit. A bare boolean can change
// meaning in flight, and separate command types would duplicate the reply gate.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OfferIntent {
    Offer,
    Accept,
    Decline,
    Cancel,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
pub struct OfferRequest {
    pub accept: bool,
    pub request_id: Option<u32>,
    pub offer_intent: Option<OfferIntent>,
    pub expected_position_id: Option<PositionId>,
}

// One envelope carries the board identity without duplicating a field across
// commands. Inferring it from the active session can target a different game.
#[cfg(any(feature = "transport", test))]
#[derive(Deserialize)]
pub(crate) struct FrontendRequest {
    pub expected_game_id: Option<String>,
    #[serde(flatten)]
    pub message: FrontendMessage,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum FrontendMessage {
    StartLogin { request_id: Option<u32> },
    CancelLogin { request_id: Option<u32> },
    // Confirm only the current screen's verified result. Installing from the
    // worker can race a method switch; returning the token exposes a credential.
    CompleteSignIn { request_id: u32 },
    #[serde(alias = "ActivateSavedToken")]
    RetryAuthentication,
    // Still reachable behind "Enter a token instead" on the sign-in screen, for
    // networks where the phone can't reach this tablet (see LoginScreen.qml).
    SaveToken { token: String, request_id: Option<u32> },
    RequestHome { request_id: Option<u32>, #[serde(default)] games_only: bool },
    // Attaches this specific game's stream if it isn't already being tracked --
    // replaces the old behavior of RequestHome always auto-attaching whichever
    // game happened to be `now_playing.first()`, which only worked because Home
    // only ever surfaced one resumable game to begin with. Now that Home lists
    // every ongoing game (see HomeState's ongoing_games), the frontend has to
    // say which one the user actually picked.
    ResumeGame { game_id: String },
    LeaveGame { game_id: String },
    // `color` is "white"/"black"/"random" -- same enum Lichess's own
    // ChallengeColor.yaml uses for both /api/board/seek and /api/challenge/{username}.
    CreateSeek {
        minutes: u32,
        increment: u32,
        rated: bool,
        color: String,
        request_id: Option<u32>,
    },
    CreateChallenge {
        username: String, minutes: u32, increment: u32, rated: bool, color: String,
        request_id: Option<u32>,
    },
    ChallengeAi {
        level: u8,
        minutes: u32,
        increment: u32,
        // Omission keeps the legacy random choice. A required field breaks older clients, and a wire enum drops invalid choices before the scoped reply.
        color: Option<String>,
        request_id: Option<u32>,
    },
    #[serde(alias = "CancelSeek")]
    CancelMatch { request_id: Option<u32> },
    MakeMove { #[serde(flatten)] request: MoveRequest },
    Resign { request_id: Option<u32> },
    DrawAction { #[serde(flatten)] request: OfferRequest },
    TakebackAction { #[serde(flatten)] request: OfferRequest },
    Abort { request_id: Option<u32> },
    Berserk { request_id: Option<u32> },
    AddTime { seconds: u32, request_id: Option<u32> },
    ClaimVictory { request_id: Option<u32> },
    ClaimDraw { request_id: Option<u32> },
    RequestChallenges,
    AcceptChallenge { id: String, request_id: Option<u32> },
    DeclineChallenge { id: String, request_id: Option<u32> },
    RequestSettings,
    SaveSettings {
        // Match each whole-settings write. Untagged echoes can undo newer edits, while waiting for each reply can strand edits on exit.
        #[serde(default)]
        request_id: Option<u32>,
        // Omission preserves an existing choice. Defaulting to light would erase it, while a required field would reject older clients.
        #[serde(default)]
        dark_mode: Option<bool>,
        auto_queen_promotion: bool,
        #[serde(default)]
        move_confirmation: bool,
        #[serde(default)]
        minimal_highlights: bool,
        #[serde(default)]
        premoves_enabled: bool,
        #[serde(default = "default_true")]
        live_clock_enabled: bool,
        #[serde(default = "default_board_theme")]
        board_theme: String,
        #[serde(default = "default_piece_set")]
        piece_set: String,
        #[serde(default = "default_true")]
        show_coordinates: bool,
        #[serde(default = "default_true")]
        show_captured_pieces: bool,
        #[serde(default = "default_true")]
        highlight_last_move: bool,
        #[serde(default)]
        confirm_resign: bool,
    },
    // Clears the saved token (see backend/src/settings.rs's sibling token file)
    // and resets to the logged-out state -- there was previously no in-app way
    // to do this at all short of editing files on the device directly.
    LogOut,
    // Match replies to one filter request. Comparing filter values fails
    // when a filter is reused, while FIFO replies can expose stale rows.
    RequestGameHistory {
        request_id: Option<u32>,
        #[serde(default)]
        rated: Option<bool>,
        #[serde(default)]
        speed: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        cursor: Option<HistoryCursor>,
    },
    CancelGameHistory { request_id: u32 },
    RequestPgnExport { game_id: String, request_id: u32 },
    CancelPgnExport { request_id: u32 },
    // POST /api/challenge/open -- a shareable link either side can open to start
    // the game, no destination username needed (unlike CreateChallenge). Uses
    // the same minutes/increment/rated fields as CreateSeek/CreateChallenge; no
    // `color` field since the *joiner* picks color by which of urlWhite/urlBlack
    // they open, not the creator (see BackendMessage::OpenChallengeCreated).
    CreateOpenChallenge { minutes: u32, increment: u32, rated: bool, request_id: Option<u32> },
    // Sent when GameHistoryScreen's user taps a finished game's row -- backend
    // fetches its full move list and replays it once (see game::replay), so
    // GameReviewScreen can navigate purely by array indexing, no chess logic
    // or network round-trip per step (see the game-review design spec).
    RequestGameMoves {
        game_id: String,
        #[serde(default)]
        request_id: Option<u32>,
    },
    CancelGameReview { request_id: u32 },
    RequestReviewVariations { review_id: u32 },
    SaveReviewVariations { review_id: u32, request_id: u32, variations: ReviewVariations },
    RequestCloudEvaluation { fen: String, request_id: Option<u32>, review_id: Option<u32> },
    CancelCloudEvaluations { review_id: u32 },
    RequestOpeningExplorer {
        #[serde(flatten)]
        request: OpeningExplorerRequest,
    },
    CancelOpeningExplorer { review_id: u32 },
    RequestAnalysisPosition { fen: String, request_id: Option<u32> },
    MakeAnalysisMove {
        fen: String,
        from: String,
        to: String,
        promotion: Option<String>,
        request_id: Option<u32>,
    },
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum GameAction {
    Resign,
    Draw,
    Takeback,
    Abort,
    Berserk,
    AddTime,
    ClaimVictory,
    ClaimDraw,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct GameActionRequest {
    pub action: GameAction,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u32>,
}

impl GameActionRequest {
    pub fn new(action: GameAction, request_id: Option<u32>) -> Self {
        Self { action, request_id, seconds: None }
    }
}

// Wire-format for an incoming challenge, decoupled from lichess::models::IncomingChallenge
// (protocol.rs stays independent of the Lichess API's own shapes, same as everywhere else
// in this file). limit/increment stay in raw seconds -- same units Lichess's own API uses --
// rather than converting to minutes, so the frontend does its own display formatting.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ChallengeInfo {
    pub id: String,
    pub challenger: String,
    pub limit_seconds: Option<u32>,
    pub increment_seconds: Option<u32>,
}

// One of a real account's rated speed categories (bullet/blitz/rapid/classical/
// correspondence) with at least one game played -- built from Account's `perfs`
// map (confirmed against lichess-org/api's Perfs.yaml/Perf.yaml schemas). A perf
// with zero games played is left out entirely rather than shown as "0", same as
// every reference client's own profile page.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct RatingSummary {
    pub speed: String,
    pub rating: u32,
}

// A single now-playing game from GET /api/account/playing, as shown on Home --
// replaces the old singular `resumable_game_id`, which silently dropped every
// game past the first for anyone with more than one correspondence game going.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct OngoingGameSummary {
    pub game_id: String,
    pub opponent_name: Option<String>,
    pub opponent_rating: Option<u32>,
    pub is_my_turn: bool,
}

// Boxed inside BoardState so rich identity stays one typed value without making
// the whole message enum large. Alternatives were ten flat optional fields
// (simpler JSON, larger enum) or an untyped map (smaller API, weaker guarantees).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PlayerIdentity {
    pub id: Option<String>,
    pub name: Option<String>,
    pub title: Option<String>,
    pub rating: Option<u32>,
    pub provisional: bool,
}

// Delivered separately so optional profile enrichment can never delay or enlarge
// BoardState. Alternatives were nesting it in every BoardState (repeated bytes and
// UI churn) or a generic JSON map (less protocol churn, but no compile-time shape).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PlayerStatusSummary {
    pub id: String,
    pub title: Option<String>,
    pub online: bool,
    pub playing: bool,
    pub streaming: bool,
    pub patron: bool,
    pub flair: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub struct OpponentDeparture {
    pub claim_win_in_seconds: Option<u64>,
}

// This account's own whole-game accuracy stats from Lichess's computer
// analysis (see lichess::models::PlayerAnalysisSummary) -- present only once
// this specific game has actually been analyzed there, which most games
// never are unless the player opened them for review.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct GameAnalysisSummary {
    pub inaccuracies: u32,
    pub mistakes: u32,
    pub blunders: u32,
    pub acpl: Option<u32>,
    pub accuracy: Option<u32>,
}

// One past game from GET /api/games/user/{username} (confirmed against
// lichess-org/api's GameJson.yaml/GamePlayers.yaml/GamePlayerUser.yaml schemas),
// already reduced to this account's point of view server-side (your_color/result)
// so the frontend never needs to know its own username to render this list.
// Lichess can cut between games created in the same millisecond. A bare
// timestamp drops ties, and a row offset assumes a stable order within ties.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct HistoryCursor {
    pub until_ms: i64,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub seen_at_cutoff: BTreeSet<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct HistoryGameSummary {
    pub game_id: String,
    pub opponent_name: Option<String>,
    pub opponent_rating: Option<u32>,
    pub your_color: String,
    // "win"/"loss"/"draw", or the raw Lichess game status (e.g. "aborted",
    // "noStart") for the rare case where there's no winner and it wasn't a draw.
    pub result: String,
    // How the game actually ended -- "Checkmate"/"Resignation"/"Time forfeit"/
    // etc. (see game::outcome::outcome), distinct from `result`
    // above: two "win"s can still differ in how they happened, which
    // win/loss/draw alone can't convey.
    pub termination: String,
    // This account's own rating change from this one game (None for a casual
    // game, which Lichess never rates at all) -- was already present in the
    // GET /api/games/user payload (GamePlayerUser.ratingDiff) but previously
    // unmodeled/unused.
    pub rating_diff: Option<i32>,
    pub your_analysis: Option<GameAnalysisSummary>,
    pub rated: bool,
    pub variant: Option<String>,
    // Missing metadata still goes to export validation. Assuming Standard can
    // hide the variant, and a second rules table in QML can drift.
    pub review_supported: Option<bool>,
    pub speed: Option<String>,
    pub opening_name: Option<String>,
    pub created_at_ms: Option<i64>,
}

// This game's own per-move computer analysis (see
// lichess::models::GameMoveAnalysis) -- one entry per ply, aligned with
// GameMoves' own `moves` array. `eval_cp`/`mate_in` are mutually exclusive
// (Lichess sends exactly one of the two per analyzed ply, see
// GameMoveAnalysis's own comment); both None means this ply just wasn't
// flagged as notable (no `judgment` either) even though the game overall was
// analyzed.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct MoveAnalysis {
    // Centipawns, from White's perspective (positive favors White).
    pub eval_cp: Option<i32>,
    // Plies to forced mate, same White-perspective sign as eval_cp.
    pub mate_in: Option<i32>,
    // "Inaccuracy"/"Mistake"/"Blunder", or None for an unremarkable move.
    pub judgment: Option<String>,
    // e.g. "Blunder. Nxg6 was best." -- Lichess's own ready-made caption,
    // shown as-is rather than reconstructed from separate best-move/variation
    // fields this app doesn't otherwise model.
    pub judgment_comment: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GameOutcome {
    pub result: String,
    pub reason: String,
    // A finished snapshot can recover a missed account event. Replaying an
    // event requires a cache, and a separate lookup adds a request on reopen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating_diff: Option<i32>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CloudEvaluationLine {
    pub eval_cp: Option<i32>,
    pub mate_in: Option<i32>,
    pub depth: u32,
    pub knodes: u64,
    pub best_line: Vec<String>,
}

// A typed database selects a fixed API route. A free-form path can leave the
// expected host, and one database omits either master or rated-game statistics.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OpeningDatabase {
    Masters,
    Lichess,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct OpeningExplorerRequest {
    pub request_id: u32,
    pub review_id: u32,
    pub database: OpeningDatabase,
    pub fen: String,
    pub root_fen: String,
    pub played_san: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct OpeningExplorerName {
    pub eco: String,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct OpeningExplorerMove {
    pub uci: String,
    pub san: String,
    pub white: u64,
    pub draws: u64,
    pub black: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct OpeningExplorerData {
    pub white: u64,
    pub draws: u64,
    pub black: u64,
    pub opening: Option<OpeningExplorerName>,
    pub moves: Vec<OpeningExplorerMove>,
}

// Optional matrices preserve the links if encoding fails. Rejecting the
// creation hides a usable invite, and encoding on demand adds an IPC round trip.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct OpenChallengeQrCodes {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub join: Option<QrMatrix>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub white: Option<QrMatrix>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub black: Option<QrMatrix>,
}

impl OpenChallengeQrCodes {
    pub fn from_links(join: &str, white: &str, black: &str) -> Self {
        Self {
            join: QrMatrix::encode(join).ok(),
            white: QrMatrix::encode(white).ok(),
            black: QrMatrix::encode(black).ok(),
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum BackendMessage {
    // Send the QR capability before authentication replies. Repeating it in
    // each reply risks drift, and guessing from connection status is unreliable.
    SignInOptions { qr_available: bool },
    // Makes startup authentication an explicit state instead of using LoginScreen
    // as a placeholder while a saved token is still being checked. Alternatives:
    // infer this from LoginFailed, or let the frontend start OAuth immediately.
    AuthenticationRequired,
    AuthenticationCheckFailed { message: String },
    LogoutFailed { message: String },
    TokenVerified {
        username: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    TokenInvalid { reason: String },
    // Everything the sign-in screen needs to draw itself. `authorize_url` is
    // shown as text too, not just encoded in the QR -- it's the only way in for
    // someone with a laptop and no camera.
    LoginChallenge {
        authorize_url: String,
        qr_size: u32,
        qr_rows: Vec<String>,
        expires_in_secs: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    LoginVerifying { request_id: u32 },
    SignInReady { request_id: u32 },
    LoginFailed {
        reason: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    // Separate replies let the game list appear while ratings load. One
    // combined reply blocks resume, and unscoped replies can replace newer data.
    HomeState {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        ongoing_games: Vec<OngoingGameSummary>,
        wifi_connected: Option<bool>,
    },
    HomeRatings {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        ratings: Vec<RatingSummary>,
    },
    ConnectivityState {
        online: bool,
        wifi_connected: Option<bool>,
        message: Option<String>,
    },
    HomeLoadFailed {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        message: String,
        wifi_connected: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    ChallengesLoadFailed { message: String },
    SeekCreated {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    SeekFailed { request_id: u32, message: String },
    SeekEnded {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    ChallengeCreated {
        game_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    ChallengeCreateFailed { request_id: u32, message: String },
    ChallengeResolved {
        game_id: String,
        error: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    ChallengeAccepted {
        game_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    ChallengeDeclined {
        challenge_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    ChallengeActionFailed { challenge_id: String, request_id: u32, message: String },
    ComputerGameCreated {
        game_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    MatchCreationFailed { request_id: u32, message: String },
    // An account event cannot select a board. Alternatives were one stream per
    // account game, or silently replacing the current stream on every gameStart.
    GameStarted { game_id: String, from_realtime_lobby: bool },
    GameFinished { game_id: String },
    AccountEventsResumed,
    BoardState {
        game_id: String,
        position_id: PositionId,
        game_stream_connected: bool,
        // Keep startup in the board snapshot. A separate event can race a
        // reconnect, and missing legal moves also describe a finished position.
        #[serde(skip_serializing_if = "Option::is_none")]
        awaiting_game_start: Option<bool>,
        // Pair release with its position. A separate acknowledgement can race premoves; last-move squares can match another line.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        resolved_move_request_id: Option<u32>,
        // A resumed board needs the current action. Local-only state forgets it on remount and a separate event can race the snapshot.
        #[serde(skip_serializing_if = "Option::is_none")]
        pending_game_action: Option<Box<GameActionRequest>>,
        // Include the latest departure in the same snapshot as the position.
        // A separate resume event can arrive late, while inferring it from
        // profile presence can expose claim buttons without a game event.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        opponent_departure: Option<Box<OpponentDeparture>>,
        fen: String,
        turn: String,
        white_time_ms: u64,
        black_time_ms: u64,
        legal_moves: Box<[LegalMove]>,
        last_move: Option<Box<(String, String)>>,
        // Which color the local account is playing in this game -- needed so the
        // frontend can flip board orientation (every reference client does this;
        // ours didn't parse enough of the Lichess payload to know until now).
        your_color: String,
        // Whether the side to move is currently in check. The frontend derives
        // *which* square (scanning the FEN for the king matching `turn`) rather
        // than us sending a square, since it already has that FEN-scanning logic.
        in_check: bool,
        // Derived from GameState's wdraw/bdraw/wtakeback/btakeback (confirmed field
        // names against lichess-org/api's GameStateEvent.yaml) relative to your_color,
        // so the frontend only needs one bool each instead of tracking both colors.
        draw_offered_by_opponent: bool,
        takeback_offered_by_opponent: bool,
        draw_offered_by_you: bool,
        takeback_offered_by_you: bool,
        can_abort: bool,
        can_berserk: bool,
        can_offer_draw: bool,
        can_offer_takeback: bool,
        can_give_time: bool,
        // Move/position history, delivered incrementally. On a full sync (game
        // load, resume, reconnect, or a takeback that rewrote the line) both
        // arrays are sent whole and the frontend replaces its copy. On a normal
        // one-move advance both are absent and `appended_move` carries just the
        // new SAN -- the frontend pushes it plus this message's `fen`, so an
        // N-move game sends O(N) history bytes total instead of re-sending the
        // whole (growing) line every move. That re-send was O(N^2) and trended a
        // long correspondence game toward the SEQPACKET size cap.
        // Alternatives: (1) keep sending both whole every message -- simplest, but
        // it's the actual perf bug being fixed; (2) a distinct BoardAppend message
        // type rather than optional fields -- cleaner types, but doubles the
        // frontend's board-message handling and main.qml routing for no real gain
        // over three skip-if-None fields.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        move_history: Option<Box<[String]>>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        position_history: Option<Box<[String]>>,
        // Part of the full history snapshot. Later plies already carry SAN,
        // and re-sending this flag on every move or deriving it in QML is unnecessary.
        #[serde(skip_serializing_if = "Option::is_none", default)]
        initial_in_check: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        appended_move: Option<Box<str>>,
        // Sparse capture events come from replay. FEN counts cannot distinguish
        // captures from promotions, and per-ply trays duplicate earlier events.
        // Box the update together. Separate fields enlarge every message, and
        // boxing unrelated fields would change existing callers.
        #[serde(flatten, skip_serializing_if = "Option::is_none")]
        capture_update: Option<Box<CaptureHistoryUpdate>>,
        captured_by_white: Box<[String]>,
        captured_by_black: Box<[String]>,
        // Confirmed against lichess-org/api's GameEventPlayer.yaml. Fixed for the
        // game's lifetime (see game::session::GameSession), unlike every field
        // above -- an AI opponent has no rating, only a name/level, hence Option.
        your_player: Box<PlayerIdentity>,
        opponent_player: Box<PlayerIdentity>,
        game_description: Box<str>,
        first_move_time_ms: Option<Box<u64>>,
        #[serde(default)]
        main_clock_paused: bool,
        // Each side's starting clock allotment in ms (see
        // game::session::GameSession's own field for why the frontend needs
        // this alongside the live white_time_ms/black_time_ms -- a low-time
        // warning threshold is a fraction of the *original* time, not just a
        // fixed number of seconds remaining). None for an untimed/correspondence
        // game.
        initial_clock_ms: Option<Box<u64>>,
        // Pair the outcome with the final position and clocks. Separate messages can
        // execute a queued premove between updates, while a second snapshot type duplicates board data.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        outcome: Option<Box<GameOutcome>>,
    },
    GameOver { game_id: String, result: String, reason: String },
    GameActionCompleted { game_id: String, #[serde(flatten)] request: GameActionRequest },
    GameActionFailed { game_id: String, #[serde(flatten)] request: GameActionRequest, message: String },
    MovePreview {
        game_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        fen: String,
        turn: String,
        white_time_ms: u64,
        black_time_ms: u64,
        last_move: Option<Box<(String, String)>>,
        in_check: bool,
        // A single victim fits one pending move. Full trays repeat confirmed totals, while FEN diffs need special-move rules.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        captured_piece: Option<String>,
    },
    MoveSubmitted {
        game_id: String,
        from: String,
        to: String,
        promotion: Option<String>,
    },
    MoveRejected {
        #[serde(skip_serializing_if = "Option::is_none")]
        game_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        reason: String,
    },
    GameStreamReconnecting { game_id: String },
    GameStreamFailed { game_id: String, message: String },
    ErrorMsg { message: String },
    // Lichess refreshes the countdown in these events. Zero enables the claim
    // controls without a local timer, and the endpoint still verifies the claim.
    OpponentGone { game_id: String, gone: bool, claim_win_in_seconds: Option<u64> },
    PlayerStatuses { game_id: String, players: Box<[PlayerStatusSummary]> },
    PendingChallenges { challenges: Vec<ChallengeInfo> },
    SettingsState {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        // A flat snapshot preserves the wire format. A nested field would break readers, and duplicate fields can drift from the store.
        #[serde(flatten)]
        settings: crate::settings::AppSettings,
    },
    SettingsSaveFailed {
        request_id: u32,
        message: String,
        #[serde(flatten)]
        settings: crate::settings::AppSettings,
    },
    GameHistory {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        games: Vec<HistoryGameSummary>,
        #[serde(skip_serializing_if = "Option::is_none")]
        next_cursor: Option<HistoryCursor>,
    },
    GameHistoryFailed {
        request_id: u32,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    PgnExported { game_id: String, request_id: u32, path: String },
    PgnExportFailed {
        game_id: String,
        request_id: u32,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    OpenChallengeCreated {
        game_id: String,
        url: String,
        url_white: String,
        url_black: String,
        qr_codes: Box<OpenChallengeQrCodes>,
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
    },
    // `fens[0]` is the starting position, `fens[i]` is the position after SAN
    // move `moves[i-1]` -- always `fens.len() == moves.len() + 1` (see
    // game::replay::replay_export). Sent once per RequestGameMoves, not
    // streamed -- a finished game's move list never changes. `clock_ms`/
    // `analysis` are each aligned with `moves` (not `fens` -- no entry for the
    // starting position) and may be shorter than `moves` or empty entirely:
    // Lichess only has clock data for timed games and only has analysis for a
    // game that's actually been through its computer review, so the frontend
    // must index defensively rather than assume equal length.
    GameMoves {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        moves: Vec<String>,
        fens: Vec<String>,
        initial_in_check: bool,
        clock_ms: Vec<u32>,
        analysis: Vec<MoveAnalysis>,
        // The same export can recover a rating after a missed account event.
        // Waiting for that event can leave it blank, and a separate lookup adds latency.
        #[serde(skip_serializing_if = "Option::is_none")]
        rating_diff: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        variation_storage: Option<bool>,
    },
    GameMovesFailed {
        request_id: u32,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    ReviewVariations { review_id: u32, variations: ReviewVariations },
    ReviewVariationsLoadFailed { review_id: u32, message: String },
    ReviewVariationsSaved { review_id: u32, request_id: u32 },
    ReviewVariationsSaveFailed { review_id: u32, request_id: u32, message: String },
    CloudEvaluation {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        requested_fen: String,
        evaluation: CloudEvaluationLine,
    },
    CloudEvaluationUnavailable {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        requested_fen: String,
    },
    CloudEvaluationFailed {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        requested_fen: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    OpeningExplorer {
        review_id: u32,
        request_id: u32,
        database: OpeningDatabase,
        fen: String,
        data: OpeningExplorerData,
    },
    OpeningExplorerFailed {
        review_id: u32,
        request_id: u32,
        database: OpeningDatabase,
        fen: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u32>,
    },
    AnalysisPosition {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        requested_fen: String,
        fen: String,
        legal_moves: Box<[LegalMove]>,
        in_check: bool,
        status: String,
    },
    AnalysisMove {
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u32>,
        from_fen: String,
        fen: String,
        san: String,
        legal_moves: Box<[LegalMove]>,
        in_check: bool,
        status: String,
    },
    AnalysisFailed { request_id: u32, message: String },
    // Sent when the account event stream's `gameFinish` (see
    // lichess::models::GameFinishInfo) can arrive before or after the final board,
    // whose stream carries no rating change.
    RatingDiff { game_id: String, rating_diff: i32 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontend_message_round_trips_through_json() {
        let json = r#"{"type":"MakeMove","from":"e2","to":"e4","promotion":null}"#;
        let parsed: FrontendMessage = serde_json::from_str(json).unwrap();
        assert_eq!(
            parsed,
            FrontendMessage::MakeMove { request: MoveRequest {
                from: "e2".into(), to: "e4".into(), promotion: None,
                request_id: None, expected_position_id: None,
            }}
        );
        let json = serde_json::to_string(&BackendMessage::MoveSubmitted {
            game_id: "g1".into(),
            from: "e7".into(),
            to: "e8".into(),
            promotion: Some("q".into()),
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"MoveSubmitted","game_id":"g1","from":"e7","to":"e8","promotion":"q"}"#
        );
    }

    #[test]
    fn interactive_sign_in_confirms_a_verified_request_without_returning_the_token() {
        let reply = serde_json::to_string(&BackendMessage::SignInReady { request_id: 31 }).unwrap();
        assert_eq!(reply, r#"{"type":"SignInReady","request_id":31}"#);
        let request = serde_json::from_str::<FrontendMessage>(
            r#"{"type":"CompleteSignIn","request_id":31}"#,
        ).unwrap();
        assert_eq!(request, FrontendMessage::CompleteSignIn { request_id: 31 });
        assert!(serde_json::from_str::<FrontendMessage>(r#"{"type":"CompleteSignIn"}"#).is_err());
    }

    #[test]
    fn home_games_can_refresh_without_starting_another_rating_read() {
        for (json, games_only) in [
            (r#"{"type":"RequestHome","request_id":3}"#, false),
            (r#"{"type":"RequestHome","request_id":3,"games_only":true}"#, true),
        ] {
            assert_eq!(
                serde_json::from_str::<FrontendMessage>(json).unwrap(),
                FrontendMessage::RequestHome { request_id: Some(3), games_only },
            );
        }
    }

    #[test]
    fn analysis_messages_round_trip() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestCloudEvaluation","fen":"startpos","request_id":8,"review_id":2}"#
            )
            .unwrap(),
            FrontendMessage::RequestCloudEvaluation {
                fen: "startpos".into(), request_id: Some(8), review_id: Some(2)
            }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestAnalysisPosition","fen":"startpos"}"#
            )
            .unwrap(),
            FrontendMessage::RequestAnalysisPosition { fen: "startpos".into(), request_id: None }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"MakeAnalysisMove","fen":"startpos","from":"e2","to":"e4","promotion":null,"request_id":7}"#
            )
            .unwrap(),
            FrontendMessage::MakeAnalysisMove {
                fen: "startpos".into(),
                from: "e2".into(),
                to: "e4".into(),
                promotion: None,
                request_id: Some(7),
            }
        );
        let json = serde_json::to_string(&BackendMessage::AnalysisMove {
            request_id: Some(7),
            from_fen: "startpos".into(),
            fen: "after-e4".into(),
            san: "e4".into(),
            legal_moves: vec![LegalMove {
                from: "e7".into(),
                to: "e5".into(),
                promotion: None,
            }]
            .into_boxed_slice(),
            in_check: false,
            status: "playing".into(),
        })
        .unwrap();
        assert!(json.contains(r#""type":"AnalysisMove""#));
        assert!(json.contains(r#""request_id":7"#));
        assert!(json.contains(r#""san":"e4""#));
        let position_json = serde_json::to_string(&BackendMessage::AnalysisPosition {
            request_id: None,
            requested_fen: "startpos".into(),
            fen: "normalized".into(),
            legal_moves: vec![].into_boxed_slice(),
            in_check: false,
            status: "playing".into(),
        })
        .unwrap();
        assert!(position_json.contains(r#""requested_fen":"startpos""#));

        let cloud_json = serde_json::to_string(&BackendMessage::CloudEvaluation {
            request_id: Some(8),
            requested_fen: "startpos".into(),
            evaluation: CloudEvaluationLine {
                eval_cp: Some(24),
                mate_in: None,
                depth: 31,
                knodes: 123456,
                best_line: vec!["e4".into(), "e5".into()],
            },
        })
        .unwrap();
        assert!(cloud_json.contains(r#""type":"CloudEvaluation""#));
        assert!(cloud_json.contains(r#""request_id":8"#));
        assert!(cloud_json.contains(r#""best_line":["e4","e5"]"#));
    }

    #[test]
    fn new_game_action_frontend_messages_parse() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"DrawAction","accept":true}"#).unwrap(),
            FrontendMessage::DrawAction { request: OfferRequest {
                accept: true, request_id: None, offer_intent: None, expected_position_id: None,
            }}
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"TakebackAction","accept":false}"#).unwrap(),
            FrontendMessage::TakebackAction { request: OfferRequest {
                accept: false, request_id: None, offer_intent: None, expected_position_id: None,
            }}
        );
        assert_eq!(serde_json::from_str::<FrontendMessage>(r#"{"type":"Abort"}"#).unwrap(), FrontendMessage::Abort { request_id: None });
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"Berserk"}"#).unwrap(),
            FrontendMessage::Berserk { request_id: None }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"AddTime","seconds":15}"#).unwrap(),
            FrontendMessage::AddTime { seconds: 15, request_id: None }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"ClaimVictory"}"#).unwrap(),
            FrontendMessage::ClaimVictory { request_id: None }
        );
        let json = serde_json::to_string(&BackendMessage::GameActionCompleted {
            game_id: "g1".into(),
            request: GameActionRequest { action: GameAction::AddTime, request_id: Some(9), seconds: Some(15) },
        })
        .unwrap();
        assert_eq!(json, r#"{"type":"GameActionCompleted","game_id":"g1","action":"AddTime","request_id":9,"seconds":15}"#);
    }

    #[test]
    fn board_request_envelope_preserves_bound_and_legacy_commands() {
        let bound: FrontendRequest = serde_json::from_str(
            r#"{"type":"Resign","expected_game_id":"g1","request_id":7}"#,
        ).unwrap();
        assert_eq!(bound.message, FrontendMessage::Resign { request_id: Some(7) });
        assert_eq!(bound.expected_game_id.as_deref(), Some("g1"));

        let legacy: FrontendRequest = serde_json::from_str(
            r#"{"type":"ResumeGame","game_id":"g2"}"#,
        ).unwrap();
        assert_eq!(legacy.message, FrontendMessage::ResumeGame { game_id: "g2".into() });
        assert_eq!(legacy.expected_game_id, None);
        assert_eq!(serde_json::from_str::<FrontendMessage>(
            r#"{"type":"LeaveGame","game_id":"g2"}"#,
        ).unwrap(), FrontendMessage::LeaveGame { game_id: "g2".into() });

        let bound_move: FrontendRequest = serde_json::from_str(
            r#"{"type":"MakeMove","from":"e2","to":"e4","promotion":null,"expected_game_id":"g1","expected_position_id":4294967294,"request_id":9}"#,
        ).unwrap();
        assert!(matches!(bound_move.message,
            FrontendMessage::MakeMove { request: MoveRequest {
                expected_position_id: Some(PositionId(4_294_967_294)), request_id: Some(9), ..
            }}));
        assert_eq!(bound_move.expected_game_id.as_deref(), Some("g1"));

        let offer: FrontendRequest = serde_json::from_str(
            r#"{"type":"TakebackAction","accept":false,"offer_intent":"cancel","expected_game_id":"g1","expected_position_id":17,"request_id":10}"#,
        ).unwrap();
        assert_eq!(offer.expected_game_id.as_deref(), Some("g1"));
        assert_eq!(offer.message, FrontendMessage::TakebackAction { request: OfferRequest {
            accept: false, request_id: Some(10), offer_intent: Some(OfferIntent::Cancel),
            expected_position_id: Some(PositionId(17)),
        }});
    }

    #[test]
    fn settings_messages_round_trip() {
        assert_eq!(
            // move_confirmation/minimal_highlights deliberately omitted here
            // -- #[serde(default)] means an older/simpler payload without
            // them still parses, same forward-compat posture as
            // RequestGameHistory's optional filters.
            serde_json::from_str::<FrontendMessage>(r#"{"type":"SaveSettings","auto_queen_promotion":true}"#)
                .unwrap(),
            FrontendMessage::SaveSettings {
                request_id: None,
                dark_mode: None,
                auto_queen_promotion: true,
                move_confirmation: false,
                minimal_highlights: false,
                premoves_enabled: false,
                live_clock_enabled: true,
                board_theme: "brown".to_owned(),
                piece_set: "cburnett".to_owned(),
                show_coordinates: true,
                show_captured_pieces: true,
                highlight_last_move: true,
                confirm_resign: false,
            }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"SaveSettings","request_id":17,"dark_mode":true,"auto_queen_promotion":false,"move_confirmation":true,"minimal_highlights":true,"premoves_enabled":true}"#
            )
            .unwrap(),
            FrontendMessage::SaveSettings {
                request_id: Some(17),
                dark_mode: Some(true),
                auto_queen_promotion: false,
                move_confirmation: true,
                minimal_highlights: true,
                premoves_enabled: true,
                live_clock_enabled: true,
                board_theme: "brown".to_owned(),
                piece_set: "cburnett".to_owned(),
                show_coordinates: true,
                show_captured_pieces: true,
                highlight_last_move: true,
                confirm_resign: false,
            }
        );
        assert_eq!(serde_json::from_str::<FrontendMessage>(r#"{"type":"LogOut"}"#).unwrap(), FrontendMessage::LogOut);
        let json = serde_json::to_string(&BackendMessage::SettingsState {
            request_id: Some(17),
            settings: crate::settings::AppSettings {
                dark_mode: true,
                auto_queen_promotion: true,
                move_confirmation: true,
                premoves_enabled: true,
                live_clock_enabled: false,
                board_theme: "blue".to_owned(),
                piece_set: "merida".to_owned(),
                show_captured_pieces: false,
                confirm_resign: true,
                ..crate::settings::AppSettings::default()
            },
        })
        .unwrap();
        assert!(json.contains(r#""type":"SettingsState""#));
        assert!(json.contains(r#""request_id":17"#));
        assert!(json.contains(r#""dark_mode":true"#));
        assert!(json.contains(r#""auto_queen_promotion":true"#));
        assert!(json.contains(r#""move_confirmation":true"#));
        assert!(json.contains(r#""minimal_highlights":true"#));
        assert!(json.contains(r#""premoves_enabled":true"#));
        assert!(json.contains(r#""live_clock_enabled":false"#));
        assert!(json.contains(r#""board_theme":"blue""#));
        assert!(json.contains(r#""piece_set":"merida""#));
    }

    #[test]
    fn request_game_history_parses_with_and_without_filters() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"RequestGameHistory"}"#).unwrap(),
            FrontendMessage::RequestGameHistory {
                request_id: None, rated: None, speed: None, color: None, cursor: None
            }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestGameHistory","request_id":8,"rated":true,"speed":"rapid","color":"white"}"#
            )
            .unwrap(),
            FrontendMessage::RequestGameHistory {
                request_id: Some(8),
                rated: Some(true),
                speed: Some("rapid".into()),
                color: Some("white".into()),
                cursor: None,
            }
        );
    }

    #[test]
    fn request_game_history_accepts_the_returned_cursor() {
        let cursor = HistoryCursor { until_ms: 1_765_526_400_000, seen_at_cutoff: BTreeSet::from(["arch0001".into()]) };
        let response = serde_json::to_value(BackendMessage::GameHistory {
            request_id: Some(1), games: vec![], next_cursor: Some(cursor.clone()),
        }).unwrap();
        let request = serde_json::from_value::<FrontendMessage>(serde_json::json!({
            "type": "RequestGameHistory", "request_id": 2, "cursor": response["next_cursor"],
        })).unwrap();
        assert!(matches!(request, FrontendMessage::RequestGameHistory { cursor: Some(value), .. } if value == cursor));
    }

    #[test]
    fn computer_challenge_accepts_explicit_and_legacy_color_choices() {
        for color in [None, Some("white"), Some("black"), Some("random")] {
            let mut payload = serde_json::json!({
                "type": "ChallengeAi", "level": 3, "minutes": 10,
                "increment": 2, "request_id": 7,
            });
            if let Some(color) = color {
                payload["color"] = serde_json::json!(color);
            }
            assert_eq!(
                serde_json::from_value::<FrontendMessage>(payload).unwrap(),
                FrontendMessage::ChallengeAi {
                    level: 3,
                    minutes: 10,
                    increment: 2,
                    color: color.map(str::to_owned),
                    request_id: Some(7),
                },
            );
        }
    }

    #[test]
    fn create_open_challenge_parses_and_open_challenge_created_serializes() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"CreateOpenChallenge","minutes":10,"increment":0,"rated":false}"#
            )
            .unwrap(),
            FrontendMessage::CreateOpenChallenge { minutes: 10, increment: 0, rated: false, request_id: None }
        );
        let json = serde_json::to_string(&BackendMessage::OpenChallengeCreated {
            game_id: "ovdODEHx".into(),
            url: "https://lichess.org/abc".into(),
            url_white: "https://lichess.org/abc?color=white".into(),
            url_black: "https://lichess.org/abc?color=black".into(),
            qr_codes: Box::new(OpenChallengeQrCodes::from_links(
                "https://lichess.org/abc",
                "https://lichess.org/abc?color=white",
                &"x".repeat(5000),
            )),
            request_id: Some(12),
        })
        .unwrap();
        assert!(json.contains(r#""type":"OpenChallengeCreated""#));
        assert!(json.contains("color=white"));
        assert!(json.contains(r#""request_id":12"#));
        let qr_codes = &serde_json::from_str::<serde_json::Value>(&json).unwrap()["qr_codes"];
        assert!(qr_codes["join"]["size"].as_u64().unwrap() > 0);
        assert!(qr_codes["join"]["rows"].is_array());
        assert!(qr_codes["white"]["rows"].is_array());
        assert_ne!(qr_codes["join"], qr_codes["white"]);
        assert!(qr_codes.get("black").is_none());
    }

    #[test]
    fn request_game_moves_parses_and_game_moves_serializes_with_type_tag() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"RequestGameMoves","game_id":"abcd1234"}"#).unwrap(),
            FrontendMessage::RequestGameMoves { game_id: "abcd1234".into(), request_id: None }
        );
        assert_eq!(
            serde_json::from_value::<FrontendMessage>(serde_json::json!({
                "type": "RequestGameMoves", "game_id": "abcd1234", "request_id": 7,
            })).unwrap(),
            FrontendMessage::RequestGameMoves { game_id: "abcd1234".into(), request_id: Some(7) }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"CancelGameReview","request_id":7}"#
            ).unwrap(),
            FrontendMessage::CancelGameReview { request_id: 7 }
        );
        let json = serde_json::to_string(&BackendMessage::GameMoves {
            request_id: Some(7),
            moves: vec!["e4".into(), "e5".into()],
            fens: vec!["startpos".into(), "after-e4".into(), "after-e5".into()],
            initial_in_check: false,
            clock_ms: vec![],
            analysis: vec![],
            rating_diff: Some(0),
            variation_storage: None,
        })
        .unwrap();
        assert!(json.contains(r#""type":"GameMoves""#));
        assert!(json.contains(r#""request_id":7"#));
        assert!(json.contains(r#""moves":["e4","e5"]"#));
        assert!(json.contains(r#""initial_in_check":false"#));
        assert!(json.contains(r#""rating_diff":0"#));

        let failure = serde_json::to_value(BackendMessage::GameMovesFailed {
            request_id: 7,
            message: "unavailable".into(),
            retry_after_ms: None,
        }).unwrap();
        assert_eq!(failure, serde_json::json!({
            "type": "GameMovesFailed", "request_id": 7, "message": "unavailable",
        }));
        let limited = serde_json::to_value(BackendMessage::GameMovesFailed {
            request_id: 8,
            message: "limited".into(),
            retry_after_ms: Some(60000),
        }).unwrap();
        assert_eq!(limited, serde_json::json!({
            "type": "GameMovesFailed", "request_id": 8, "message": "limited", "retry_after_ms": 60000,
        }));
    }

    #[test]
    fn game_moves_serializes_clock_and_analysis_when_present() {
        let json = serde_json::to_string(&BackendMessage::GameMoves {
            request_id: None,
            moves: vec!["e4".into()],
            fens: vec!["startpos".into(), "after-e4".into()],
            initial_in_check: true,
            variation_storage: None,
            clock_ms: vec![29900],
            analysis: vec![MoveAnalysis {
                eval_cp: None,
                mate_in: Some(3),
                judgment: Some("Blunder".into()),
                judgment_comment: Some("Blunder. Nxg6 was best.".into()),
            }],
            rating_diff: None,
        })
        .unwrap();
        assert!(!json.contains("request_id"));
        assert!(json.contains(r#""initial_in_check":true"#));
        assert!(json.contains(r#""clock_ms":[29900]"#));
        assert!(json.contains(r#""mate_in":3"#));
        assert!(json.contains(r#""judgment":"Blunder""#));
    }

    #[test]
    fn rating_diff_serializes_with_type_tag_including_negative_values() {
        let json = serde_json::to_string(&BackendMessage::RatingDiff {
            game_id: "g1".into(),
            rating_diff: -9,
        }).unwrap();
        assert!(json.contains(r#""type":"RatingDiff""#));
        assert!(json.contains(r#""game_id":"g1""#));
        assert!(json.contains(r#""rating_diff":-9"#));
    }

    #[test]
    fn opponent_gone_serializes_with_type_tag() {
        let msg = BackendMessage::OpponentGone { game_id: "g1".into(), gone: true, claim_win_in_seconds: Some(8) };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"OpponentGone""#));
        assert!(json.contains(r#""claim_win_in_seconds":8"#));
    }

    #[test]
    fn reconnect_signal_is_scoped_to_the_game_stream() {
        let json = serde_json::to_string(&BackendMessage::GameStreamReconnecting { game_id: "g1".into() }).unwrap();
        assert_eq!(json, r#"{"type":"GameStreamReconnecting","game_id":"g1"}"#);
    }

    #[test]
    fn connectivity_state_preserves_unknown_wifi_link_state() {
        let json = serde_json::to_string(&BackendMessage::ConnectivityState {
            online: false,
            wifi_connected: None,
            message: Some("Can't reach Lichess".into()),
        })
        .unwrap();
        assert!(json.contains(r#""online":false"#));
        assert!(json.contains(r#""wifi_connected":null"#));
    }

    #[test]
    fn backend_message_serializes_with_type_tag() {
        let msg = BackendMessage::BoardState {
            game_id: "g1".into(),
            position_id: PositionId(4_294_967_294),
            game_stream_connected: false,
            awaiting_game_start: None,
            resolved_move_request_id: None,
            pending_game_action: None,
            opponent_departure: None,
            fen: "startpos".into(),
            turn: "white".into(),
            white_time_ms: 600_000,
            black_time_ms: 600_000,
            legal_moves: vec![LegalMove { from: "e2".into(), to: "e4".into(), promotion: None }].into_boxed_slice(),
            last_move: None,
            your_color: "white".into(),
            in_check: false,
            draw_offered_by_opponent: false,
            takeback_offered_by_opponent: false,
            draw_offered_by_you: false,
            takeback_offered_by_you: false,
            can_abort: true,
            can_berserk: false,
            can_offer_draw: false,
            can_offer_takeback: false,
            can_give_time: true,
            move_history: Some(vec![].into_boxed_slice()),
            position_history: Some(vec!["startpos".into()].into_boxed_slice()),
            initial_in_check: Some(false),
            appended_move: None,
            capture_update: Some(Box::new(CaptureHistoryUpdate::Full { capture_history: Box::default() })),
            captured_by_white: vec!["bP".into()].into_boxed_slice(),
            captured_by_black: vec![].into_boxed_slice(),
            your_player: Box::new(PlayerIdentity {
                id: Some("alice".into()),
                name: Some("Alice".into()),
                title: Some("IM".into()),
                rating: Some(1700),
                provisional: true,
            }),
            opponent_player: Box::new(PlayerIdentity {
                id: None,
                name: None,
                title: None,
                rating: None,
                provisional: false,
            }),
            game_description: "Casual Rapid • 10 min + 0 sec/move".into(),
            first_move_time_ms: None,
            main_clock_paused: false,
            initial_clock_ms: Some(Box::new(600_000)),
            outcome: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"BoardState""#));
        assert!(json.contains(r#""game_id":"g1""#));
        assert!(json.contains(r#""position_id":4294967294"#));
        assert!(json.contains(r#""game_stream_connected":false"#));
        assert!(json.contains(r#""captured_by_white":["bP"]"#));
        assert!(json.contains(r#""capture_history":[]"#));
        assert!(!json.contains("appended_capture"));
        assert!(json.contains(r#""fen":"startpos""#));
        assert!(json.contains(r#""initial_in_check":false"#));
        assert!(json.contains(r#""your_player":{"id":"alice","name":"Alice","title":"IM","rating":1700,"provisional":true}"#));
    }

    #[test]
    fn authentication_required_is_an_explicit_startup_state() {
        let json = serde_json::to_string(&BackendMessage::AuthenticationRequired).unwrap();
        assert_eq!(json, r#"{"type":"AuthenticationRequired"}"#);
        let request = serde_json::from_str::<FrontendMessage>(r#"{"type":"RetryAuthentication"}"#).unwrap();
        assert_eq!(request, FrontendMessage::RetryAuthentication);
    }

    #[test]
    fn sign_in_options_describes_the_available_method() {
        let message = BackendMessage::SignInOptions { qr_available: false };
        let json = serde_json::to_string(&message).unwrap();
        assert_eq!(json, r#"{"type":"SignInOptions","qr_available":false}"#);
    }

    #[test]
    fn player_statuses_are_scoped_to_the_open_game() {
        let msg = BackendMessage::PlayerStatuses {
            game_id: "g1".into(),
            players: vec![PlayerStatusSummary {
                id: "alice".into(),
                title: Some("IM".into()),
                online: true,
                playing: true,
                streaming: false,
                patron: true,
                flair: Some("symbols.white-heart".into()),
            }]
            .into_boxed_slice(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"PlayerStatuses""#));
        assert!(json.contains(r#""game_id":"g1""#));
        assert!(json.contains(r#""patron":true"#));
    }
}
