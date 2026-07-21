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
    CreateSeek { minutes: u32, increment: u32 },
    CreateChallenge { username: String, minutes: u32, increment: u32 },
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

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum BackendMessage {
    TokenVerified { username: String },
    TokenInvalid { reason: String },
    HomeState { resumable_game_id: Option<String> },
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
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"BoardState""#));
        assert!(json.contains(r#""fen":"startpos""#));
    }
}
