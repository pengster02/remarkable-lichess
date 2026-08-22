use serde::{Deserialize, Serialize};

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

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum FrontendMessage {
    // Kicks off the QR sign-in (see lichess::oauth): the backend answers with a
    // LoginChallenge to display, then a LoginCompleted/LoginFailed once the
    // phone comes back. Sent automatically when the sign-in screen appears, and
    // again whenever the user retries.
    StartLogin,
    CancelLogin,
    // The sign-in flow finishes on a detached task, which can't reach the
    // `&mut self` needed to install the client and start the account streams --
    // so it only writes the token file and reports LoginCompleted, and the
    // frontend replies with this to have it activated through the same path a
    // restart already uses. Alternatives: (1) send the token itself back to the
    // frontend and reuse SaveToken -- no new message, but it puts a live
    // credential on the IPC channel for no reason; (2) hand the backend an
    // internal channel to poll -- no round trip, but the AppLoad run loop only
    // ever calls us on an incoming frontend message, so there's nowhere to poll
    // it from.
    ActivateSavedToken,
    // Still reachable behind "Enter a token instead" on the sign-in screen, for
    // networks where the phone can't reach this tablet (see LoginScreen.qml).
    SaveToken { token: String },
    RequestHome,
    // Attaches this specific game's stream if it isn't already being tracked --
    // replaces the old behavior of RequestHome always auto-attaching whichever
    // game happened to be `now_playing.first()`, which only worked because Home
    // only ever surfaced one resumable game to begin with. Now that Home lists
    // every ongoing game (see HomeState's ongoing_games), the frontend has to
    // say which one the user actually picked.
    ResumeGame { game_id: String },
    // `color` is "white"/"black"/"random" -- same enum Lichess's own
    // ChallengeColor.yaml uses for both /api/board/seek and /api/challenge/{username}.
    CreateSeek { minutes: u32, increment: u32, rated: bool, color: String },
    CreateChallenge { username: String, minutes: u32, increment: u32, rated: bool, color: String },
    ChallengeAi { level: u8, minutes: u32, increment: u32 },
    CancelSeek,
    MakeMove { from: String, to: String, promotion: Option<String> },
    Resign,
    // `accept: true` offers a draw/takeback when none is pending, or accepts the
    // opponent's pending offer; `accept: false` declines it -- same split Lichess's
    // own `/draw/{accept}` and `/takeback/{accept}` endpoints use, so the frontend
    // doesn't need to track "did I just offer or am I responding" separately.
    DrawAction { accept: bool },
    TakebackAction { accept: bool },
    Abort,
    Berserk,
    AddTime { seconds: u32 },
    ClaimVictory,
    ClaimDraw,
    RequestChallenges,
    AcceptChallenge { id: String },
    DeclineChallenge { id: String },
    RequestSettings,
    SaveSettings {
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
    // Sent on-demand (from HomeScreen's "Game history" button, and again by
    // GameHistoryScreen itself whenever a filter changes), not pushed
    // automatically on login like RequestHome/RequestSettings -- fetching and
    // replaying up to 20 games' SAN history is real work nobody needs paid up
    // front just to reach the Home screen. Backend fixes the page size
    // server-side (see backend_app.rs's handle_request_game_history); `rated`/
    // `speed`/`color` are optional filters passed straight through to GET
    // /api/games/user's own query params (None = that endpoint's own default
    // of "no filter", not "false"/empty-string).
    RequestGameHistory {
        #[serde(default)]
        rated: Option<bool>,
        #[serde(default)]
        speed: Option<String>,
        #[serde(default)]
        color: Option<String>,
    },
    // POST /api/challenge/open -- a shareable link either side can open to start
    // the game, no destination username needed (unlike CreateChallenge). Uses
    // the same minutes/increment/rated fields as CreateSeek/CreateChallenge; no
    // `color` field since the *joiner* picks color by which of urlWhite/urlBlack
    // they open, not the creator (see BackendMessage::OpenChallengeCreated).
    CreateOpenChallenge { minutes: u32, increment: u32, rated: bool },
    // Sent when GameHistoryScreen's user taps a finished game's row -- backend
    // fetches its full move list and replays it once (see game::replay), so
    // GameReviewScreen can navigate purely by array indexing, no chess logic
    // or network round-trip per step (see the game-review design spec).
    RequestGameMoves { game_id: String },
    RequestCloudEvaluation { fen: String },
    RequestAnalysisPosition { fen: String },
    MakeAnalysisMove {
        fen: String,
        from: String,
        to: String,
        promotion: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
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

// This account's own whole-game accuracy stats from Lichess's computer
// analysis (see lichess::models::PlayerAnalysisSummary) -- present only once
// this specific game has actually been analyzed there, which most games
// never are unless the player opened them for review.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct GameAnalysisSummary {
    pub inaccuracies: u32,
    pub mistakes: u32,
    pub blunders: u32,
    pub acpl: u32,
    pub accuracy: Option<u32>,
}

// One past game from GET /api/games/user/{username} (confirmed against
// lichess-org/api's GameJson.yaml/GamePlayers.yaml/GamePlayerUser.yaml schemas),
// already reduced to this account's point of view server-side (your_color/result)
// so the frontend never needs to know its own username to render this list.
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
    // etc. (see backend_app.rs's termination_label), distinct from `result`
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

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CloudEvaluationLine {
    pub eval_cp: Option<i32>,
    pub mate_in: Option<i32>,
    pub depth: u32,
    pub knodes: u64,
    pub best_line: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum BackendMessage {
    // Makes startup authentication an explicit state instead of using LoginScreen
    // as a placeholder while a saved token is still being checked. Alternatives:
    // infer this from LoginFailed, or let the frontend start OAuth immediately.
    AuthenticationRequired,
    TokenVerified { username: String },
    TokenInvalid { reason: String },
    // Everything the sign-in screen needs to draw itself. `authorize_url` is
    // shown as text too, not just encoded in the QR -- it's the only way in for
    // someone with a laptop and no camera.
    LoginChallenge {
        authorize_url: String,
        qr_size: u32,
        qr_rows: Vec<String>,
        expires_in_secs: u64,
    },
    LoginCompleted,
    LoginFailed { reason: String },
    HomeState { ongoing_games: Vec<OngoingGameSummary>, ratings: Vec<RatingSummary> },
    ConnectivityState {
        online: bool,
        wifi_connected: Option<bool>,
        message: Option<String>,
    },
    HomeLoadFailed { message: String },
    ChallengesLoadFailed { message: String },
    SeekCreated,
    ChallengeCreated,
    BoardState {
        game_id: String,
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
        #[serde(skip_serializing_if = "Option::is_none", default)]
        appended_move: Option<Box<str>>,
        captured_by_white: Box<[String]>,
        captured_by_black: Box<[String]>,
        // Confirmed against lichess-org/api's GameEventPlayer.yaml. Fixed for the
        // game's lifetime (see game::session::GameSession), unlike every field
        // above -- an AI opponent has no rating, only a name/level, hence Option.
        your_player: Box<PlayerIdentity>,
        opponent_player: Box<PlayerIdentity>,
        game_description: Box<str>,
        first_move_time_ms: Option<Box<u64>>,
        // Each side's starting clock allotment in ms (see
        // game::session::GameSession's own field for why the frontend needs
        // this alongside the live white_time_ms/black_time_ms -- a low-time
        // warning threshold is a fraction of the *original* time, not just a
        // fixed number of seconds remaining). None for an untimed/correspondence
        // game.
        initial_clock_ms: Option<Box<u64>>,
    },
    GameOver { result: String, reason: String },
    GameActionCompleted { action: GameAction },
    MovePreview {
        game_id: String,
        fen: String,
        turn: String,
        white_time_ms: u64,
        black_time_ms: u64,
        last_move: Option<Box<(String, String)>>,
        in_check: bool,
    },
    MoveSubmitted {
        game_id: String,
        from: String,
        to: String,
        promotion: Option<String>,
    },
    MoveRejected { reason: String },
    GameStreamReconnecting,
    ErrorMsg { message: String },
    // Sent whenever Lichess's own `opponentGone` stream event fires (confirmed
    // against OpponentGoneEvent.yaml). `claim_win_in_seconds` is only meaningful
    // while `gone` is true. We don't run a local countdown off this -- same
    // no-idle-redraw reasoning as the clock (see BoardScreen.qml) -- the frontend
    // just shows/hides a "Claim victory" action and lets Lichess's own endpoint
    // reject an early claim, same as every other server-authoritative action here.
    OpponentGone { gone: bool, claim_win_in_seconds: Option<u64> },
    PlayerStatuses { game_id: String, players: Box<[PlayerStatusSummary]> },
    PendingChallenges { challenges: Vec<ChallengeInfo> },
    SettingsState {
        auto_queen_promotion: bool,
        move_confirmation: bool,
        minimal_highlights: bool,
        premoves_enabled: bool,
        live_clock_enabled: bool,
        board_theme: String,
        piece_set: String,
        show_coordinates: bool,
        show_captured_pieces: bool,
        highlight_last_move: bool,
        confirm_resign: bool,
    },
    GameHistory { games: Vec<HistoryGameSummary> },
    // Confirmed against lichess-org/api's ChallengeOpenJson.yaml -- `url` opens
    // to a color-choice/random assignment, `url_white`/`url_black` claim that
    // color outright. Shown as plain text on SeekScreen for the user to read/
    // share manually (this app has no clipboard/share-sheet integration).
    OpenChallengeCreated { url: String, url_white: String, url_black: String },
    // `fens[0]` is the starting position, `fens[i]` is the position after SAN
    // move `moves[i-1]` -- always `fens.len() == moves.len() + 1` (see
    // game::replay::fens_for_moves). Sent once per RequestGameMoves, not
    // streamed -- a finished game's move list never changes. `clock_ms`/
    // `analysis` are each aligned with `moves` (not `fens` -- no entry for the
    // starting position) and may be shorter than `moves` or empty entirely:
    // Lichess only has clock data for timed games and only has analysis for a
    // game that's actually been through its computer review, so the frontend
    // must index defensively rather than assume equal length.
    GameMoves { moves: Vec<String>, fens: Vec<String>, clock_ms: Vec<u32>, analysis: Vec<MoveAnalysis> },
    CloudEvaluation {
        requested_fen: String,
        evaluation: CloudEvaluationLine,
    },
    CloudEvaluationUnavailable { requested_fen: String },
    CloudEvaluationFailed { requested_fen: String, message: String },
    AnalysisPosition {
        requested_fen: String,
        fen: String,
        legal_moves: Box<[LegalMove]>,
        in_check: bool,
        status: String,
    },
    AnalysisMove {
        from_fen: String,
        fen: String,
        san: String,
        legal_moves: Box<[LegalMove]>,
        in_check: bool,
        status: String,
    },
    // Sent when the account event stream's `gameFinish` (see
    // lichess::models::GameFinishInfo) arrives for the currently-tracked
    // game and carries a rating change (rated games only -- casual games
    // never send this at all, see backend_app.rs's GameFinish handling).
    // Arrives independently of (and in no guaranteed order relative to)
    // `GameOver`, which comes from a different stream (the per-game board
    // stream's terminal GameState update) that has no rating info at all --
    // deliberately two separate messages rather than trying to force them
    // into one, since one can arrive without the other (e.g. a casual game
    // never gets this one) or in either order.
    RatingDiff { rating_diff: i32 },
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
            FrontendMessage::MakeMove { from: "e2".into(), to: "e4".into(), promotion: None }
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
    fn analysis_messages_round_trip() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestCloudEvaluation","fen":"startpos"}"#
            )
            .unwrap(),
            FrontendMessage::RequestCloudEvaluation { fen: "startpos".into() }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestAnalysisPosition","fen":"startpos"}"#
            )
            .unwrap(),
            FrontendMessage::RequestAnalysisPosition { fen: "startpos".into() }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"MakeAnalysisMove","fen":"startpos","from":"e2","to":"e4","promotion":null}"#
            )
            .unwrap(),
            FrontendMessage::MakeAnalysisMove {
                fen: "startpos".into(),
                from: "e2".into(),
                to: "e4".into(),
                promotion: None,
            }
        );
        let json = serde_json::to_string(&BackendMessage::AnalysisMove {
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
        assert!(json.contains(r#""san":"e4""#));
        let position_json = serde_json::to_string(&BackendMessage::AnalysisPosition {
            requested_fen: "startpos".into(),
            fen: "normalized".into(),
            legal_moves: vec![].into_boxed_slice(),
            in_check: false,
            status: "playing".into(),
        })
        .unwrap();
        assert!(position_json.contains(r#""requested_fen":"startpos""#));

        let cloud_json = serde_json::to_string(&BackendMessage::CloudEvaluation {
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
        assert!(cloud_json.contains(r#""best_line":["e4","e5"]"#));
    }

    #[test]
    fn new_game_action_frontend_messages_parse() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"DrawAction","accept":true}"#).unwrap(),
            FrontendMessage::DrawAction { accept: true }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"TakebackAction","accept":false}"#).unwrap(),
            FrontendMessage::TakebackAction { accept: false }
        );
        assert_eq!(serde_json::from_str::<FrontendMessage>(r#"{"type":"Abort"}"#).unwrap(), FrontendMessage::Abort);
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"Berserk"}"#).unwrap(),
            FrontendMessage::Berserk
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"AddTime","seconds":15}"#).unwrap(),
            FrontendMessage::AddTime { seconds: 15 }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"ClaimVictory"}"#).unwrap(),
            FrontendMessage::ClaimVictory
        );
        let json = serde_json::to_string(&BackendMessage::GameActionCompleted {
            action: GameAction::AddTime,
        })
        .unwrap();
        assert_eq!(json, r#"{"type":"GameActionCompleted","action":"AddTime"}"#);
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
                r#"{"type":"SaveSettings","auto_queen_promotion":false,"move_confirmation":true,"minimal_highlights":true,"premoves_enabled":true}"#
            )
            .unwrap(),
            FrontendMessage::SaveSettings {
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
            auto_queen_promotion: true,
            move_confirmation: true,
            minimal_highlights: true,
            premoves_enabled: true,
            live_clock_enabled: false,
            board_theme: "blue".to_owned(),
            piece_set: "merida".to_owned(),
            show_coordinates: true,
            show_captured_pieces: false,
            highlight_last_move: true,
            confirm_resign: true,
        })
        .unwrap();
        assert!(json.contains(r#""type":"SettingsState""#));
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
            FrontendMessage::RequestGameHistory { rated: None, speed: None, color: None }
        );
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"RequestGameHistory","rated":true,"speed":"rapid","color":"white"}"#
            )
            .unwrap(),
            FrontendMessage::RequestGameHistory {
                rated: Some(true),
                speed: Some("rapid".into()),
                color: Some("white".into())
            }
        );
    }

    #[test]
    fn create_open_challenge_parses_and_open_challenge_created_serializes() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(
                r#"{"type":"CreateOpenChallenge","minutes":10,"increment":0,"rated":false}"#
            )
            .unwrap(),
            FrontendMessage::CreateOpenChallenge { minutes: 10, increment: 0, rated: false }
        );
        let json = serde_json::to_string(&BackendMessage::OpenChallengeCreated {
            url: "https://lichess.org/abc".into(),
            url_white: "https://lichess.org/abc?color=white".into(),
            url_black: "https://lichess.org/abc?color=black".into(),
        })
        .unwrap();
        assert!(json.contains(r#""type":"OpenChallengeCreated""#));
        assert!(json.contains("color=white"));
    }

    #[test]
    fn request_game_moves_parses_and_game_moves_serializes_with_type_tag() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"RequestGameMoves","game_id":"abcd1234"}"#).unwrap(),
            FrontendMessage::RequestGameMoves { game_id: "abcd1234".into() }
        );
        let json = serde_json::to_string(&BackendMessage::GameMoves {
            moves: vec!["e4".into(), "e5".into()],
            fens: vec!["startpos".into(), "after-e4".into(), "after-e5".into()],
            clock_ms: vec![],
            analysis: vec![],
        })
        .unwrap();
        assert!(json.contains(r#""type":"GameMoves""#));
        assert!(json.contains(r#""moves":["e4","e5"]"#));
    }

    #[test]
    fn game_moves_serializes_clock_and_analysis_when_present() {
        let json = serde_json::to_string(&BackendMessage::GameMoves {
            moves: vec!["e4".into()],
            fens: vec!["startpos".into(), "after-e4".into()],
            clock_ms: vec![29900],
            analysis: vec![MoveAnalysis {
                eval_cp: None,
                mate_in: Some(3),
                judgment: Some("Blunder".into()),
                judgment_comment: Some("Blunder. Nxg6 was best.".into()),
            }],
        })
        .unwrap();
        assert!(json.contains(r#""clock_ms":[29900]"#));
        assert!(json.contains(r#""mate_in":3"#));
        assert!(json.contains(r#""judgment":"Blunder""#));
    }

    #[test]
    fn rating_diff_serializes_with_type_tag_including_negative_values() {
        let json = serde_json::to_string(&BackendMessage::RatingDiff { rating_diff: -9 }).unwrap();
        assert!(json.contains(r#""type":"RatingDiff""#));
        assert!(json.contains(r#""rating_diff":-9"#));
    }

    #[test]
    fn opponent_gone_serializes_with_type_tag() {
        let msg = BackendMessage::OpponentGone { gone: true, claim_win_in_seconds: Some(8) };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"OpponentGone""#));
        assert!(json.contains(r#""claim_win_in_seconds":8"#));
    }

    #[test]
    fn reconnect_signal_is_scoped_to_the_game_stream() {
        let json = serde_json::to_string(&BackendMessage::GameStreamReconnecting).unwrap();
        assert_eq!(json, r#"{"type":"GameStreamReconnecting"}"#);
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
            appended_move: None,
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
            initial_clock_ms: Some(Box::new(600_000)),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"BoardState""#));
        assert!(json.contains(r#""game_id":"g1""#));
        assert!(json.contains(r#""captured_by_white":["bP"]"#));
        assert!(json.contains(r#""fen":"startpos""#));
        assert!(json.contains(r#""your_player":{"id":"alice","name":"Alice","title":"IM","rating":1700,"provisional":true}"#));
    }

    #[test]
    fn authentication_required_is_an_explicit_startup_state() {
        let json = serde_json::to_string(&BackendMessage::AuthenticationRequired).unwrap();
        assert_eq!(json, r#"{"type":"AuthenticationRequired"}"#);
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
