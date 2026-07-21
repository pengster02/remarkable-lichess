use serde::{Deserialize, Serialize};

pub const MSG_TYPE_FRONTEND_TO_BACKEND: u32 = 1;
pub const MSG_TYPE_BACKEND_TO_FRONTEND: u32 = 2;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LegalMove {
    pub from: String,
    pub to: String,
    pub promotion: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum FrontendMessage {
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
    ClaimVictory,
    ClaimDraw,
    RequestChallenges,
    AcceptChallenge { id: String },
    DeclineChallenge { id: String },
    SendChat { text: String },
    RequestSettings,
    SaveSettings { auto_queen_promotion: bool },
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
    pub rated: bool,
    pub speed: Option<String>,
    pub opening_name: Option<String>,
    pub created_at_ms: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum BackendMessage {
    TokenVerified { username: String },
    TokenInvalid { reason: String },
    HomeState { ongoing_games: Vec<OngoingGameSummary>, ratings: Vec<RatingSummary> },
    SeekCreated,
    ChallengeCreated,
    BoardState {
        fen: String,
        turn: String,
        white_time_ms: u64,
        black_time_ms: u64,
        legal_moves: Vec<LegalMove>,
        last_move: Option<(String, String)>,
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
        // SAN per move so far (e.g. "e4", "Nf3", "O-O", "Qxh4#"). Sent in full each
        // time (matching every other field here, all recomputed from Lichess's own
        // always-whole-game `moves` string) -- the frontend just re-renders the same
        // wrapped Text, no incremental diffing needed.
        move_history: Vec<String>,
        // Confirmed against lichess-org/api's GameEventPlayer.yaml. Fixed for the
        // game's lifetime (see game::session::GameSession), unlike every field
        // above -- an AI opponent has no rating, only a name/level, hence Option.
        opponent_name: Option<String>,
        opponent_rating: Option<u32>,
    },
    GameOver { result: String, reason: String },
    MoveRejected { reason: String },
    Reconnecting,
    ErrorMsg { message: String },
    // Sent whenever Lichess's own `opponentGone` stream event fires (confirmed
    // against OpponentGoneEvent.yaml). `claim_win_in_seconds` is only meaningful
    // while `gone` is true. We don't run a local countdown off this -- same
    // no-idle-redraw reasoning as the clock (see BoardScreen.qml) -- the frontend
    // just shows/hides a "Claim victory" action and lets Lichess's own endpoint
    // reject an early claim, same as every other server-authoritative action here.
    OpponentGone { gone: bool, claim_win_in_seconds: Option<u64> },
    PendingChallenges { challenges: Vec<ChallengeInfo> },
    ChatMessage { username: String, text: String },
    SettingsState { auto_queen_promotion: bool },
    GameHistory { games: Vec<HistoryGameSummary> },
    // Confirmed against lichess-org/api's ChallengeOpenJson.yaml -- `url` opens
    // to a color-choice/random assignment, `url_white`/`url_black` claim that
    // color outright. Shown as plain text on SeekScreen for the user to read/
    // share manually (this app has no clipboard/share-sheet integration).
    OpenChallengeCreated { url: String, url_white: String, url_black: String },
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
            serde_json::from_str::<FrontendMessage>(r#"{"type":"ClaimVictory"}"#).unwrap(),
            FrontendMessage::ClaimVictory
        );
    }

    #[test]
    fn settings_messages_round_trip() {
        assert_eq!(
            serde_json::from_str::<FrontendMessage>(r#"{"type":"SaveSettings","auto_queen_promotion":true}"#)
                .unwrap(),
            FrontendMessage::SaveSettings { auto_queen_promotion: true }
        );
        assert_eq!(serde_json::from_str::<FrontendMessage>(r#"{"type":"LogOut"}"#).unwrap(), FrontendMessage::LogOut);
        let json = serde_json::to_string(&BackendMessage::SettingsState { auto_queen_promotion: true }).unwrap();
        assert!(json.contains(r#""type":"SettingsState""#));
        assert!(json.contains(r#""auto_queen_promotion":true"#));
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
    fn opponent_gone_serializes_with_type_tag() {
        let msg = BackendMessage::OpponentGone { gone: true, claim_win_in_seconds: Some(8) };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"OpponentGone""#));
        assert!(json.contains(r#""claim_win_in_seconds":8"#));
    }

    #[test]
    fn backend_message_serializes_with_type_tag() {
        let msg = BackendMessage::BoardState {
            fen: "startpos".into(),
            turn: "white".into(),
            white_time_ms: 600_000,
            black_time_ms: 600_000,
            legal_moves: vec![LegalMove { from: "e2".into(), to: "e4".into(), promotion: None }],
            last_move: None,
            your_color: "white".into(),
            in_check: false,
            draw_offered_by_opponent: false,
            takeback_offered_by_opponent: false,
            move_history: vec![],
            opponent_name: None,
            opponent_rating: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"BoardState""#));
        assert!(json.contains(r#""fen":"startpos""#));
    }
}
