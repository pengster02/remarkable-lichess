use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub username: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingGame {
    #[serde(rename = "gameId")]
    pub game_id: String,
    #[serde(rename = "isMyTurn")]
    pub is_my_turn: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingResponse {
    #[serde(rename = "nowPlaying")]
    pub now_playing: Vec<PlayingGame>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Clock {
    pub initial: u64,
    pub increment: u64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameState {
    pub moves: String,
    pub wtime: u64,
    pub btime: u64,
    pub winc: u64,
    pub binc: u64,
    pub status: String,
    pub winner: Option<String>,
    // Confirmed against lichess-org/api's GameStateEvent.yaml schema: all four are
    // `omitted, else false`, i.e. absent on most updates -- #[serde(default)] so a
    // missing key deserializes to `false` instead of failing the whole message.
    #[serde(default)]
    pub wdraw: bool,
    #[serde(default)]
    pub bdraw: bool,
    #[serde(default)]
    pub wtakeback: bool,
    #[serde(default)]
    pub btakeback: bool,
}

// Confirmed against lichess-org/api's OpponentGoneEvent.yaml schema. Sent as its own
// stream event (not folded into GameState) whenever the opponent's connection status
// changes; `claim_win_in_seconds` is only meaningful while `gone` is true.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct OpponentGone {
    pub gone: bool,
    #[serde(rename = "claimWinInSeconds")]
    pub claim_win_in_seconds: Option<u64>,
}

// Real Lichess `gameFull` payloads carry much more per-player data (rating, title,
// provisional flag, etc.) -- only modeling `id` since that's all this app needs to
// work out which color the local account is playing. `id` is optional because an
// AI opponent (see backend/src/lichess/client.rs's create-seek-adjacent testing in
// this project's history) has no Lichess account id, only a name/level.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Player {
    pub id: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameFull {
    pub id: String,
    pub rated: bool,
    #[serde(rename = "initialFen")]
    pub initial_fen: String,
    pub clock: Option<Clock>,
    pub white: Player,
    pub black: Player,
    pub state: GameState,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum GameStreamMessage {
    #[serde(rename = "gameFull")]
    Full(GameFull),
    #[serde(rename = "gameState")]
    State(GameState),
    #[serde(rename = "opponentGone")]
    Gone(OpponentGone),
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct EventGame {
    pub id: String,
}

// Confirmed against lichess-org/api's ChallengeJson.yaml / ChallengeUser.yaml.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeUser {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeTimeControl {
    pub limit: Option<u32>,
    pub increment: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct IncomingChallenge {
    pub id: String,
    pub challenger: ChallengeUser,
    #[serde(rename = "timeControl")]
    pub time_control: ChallengeTimeControl,
}

// GET /api/challenge's real response shape: {"in": [...], "out": [...]} -- only
// modeling "in" (challenges targeted at you), matching what this app surfaces.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeListResponse {
    #[serde(rename = "in")]
    pub incoming: Vec<IncomingChallenge>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum EventStreamMessage {
    #[serde(rename = "gameStart")]
    GameStart { game: EventGame },
    #[serde(rename = "gameFinish")]
    GameFinish { game: EventGame },
    #[serde(other)]
    Other,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_game_full_then_game_state() {
        let full_json = r#"{"type":"gameFull","id":"abcd1234","rated":false,"initialFen":"startpos","clock":{"initial":600000,"increment":0},"white":{"id":"myid"},"black":{"id":"oppid"},"state":{"type":"gameState","moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}}"#;
        let msg: GameStreamMessage = serde_json::from_str(full_json).unwrap();
        match msg {
            GameStreamMessage::Full(full) => {
                assert_eq!(full.id, "abcd1234");
                assert_eq!(full.state.status, "started");
            }
            _ => panic!("expected Full variant"),
        }

        let state_json = r#"{"type":"gameState","moves":"e2e4","wtime":598000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}"#;
        let msg: GameStreamMessage = serde_json::from_str(state_json).unwrap();
        match msg {
            GameStreamMessage::State(state) => assert_eq!(state.moves, "e2e4"),
            _ => panic!("expected State variant"),
        }
    }

    #[test]
    fn parses_game_start_event() {
        let json = r#"{"type":"gameStart","game":{"id":"abcd1234"}}"#;
        let msg: EventStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg, EventStreamMessage::GameStart { game: EventGame { id: "abcd1234".into() } });
    }

    #[test]
    fn parses_playing_response() {
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":true}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.now_playing.len(), 1);
        assert_eq!(parsed.now_playing[0].game_id, "abcd1234");
        assert!(parsed.now_playing[0].is_my_turn);
    }

    #[test]
    fn game_state_defaults_draw_and_takeback_flags_to_false_when_absent() {
        let json = r#"{"moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}"#;
        let state: GameState = serde_json::from_str(json).unwrap();
        assert!(!state.wdraw && !state.bdraw && !state.wtakeback && !state.btakeback);
    }

    #[test]
    fn game_state_parses_draw_and_takeback_offer_flags() {
        let json = r#"{"moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null,"wdraw":false,"bdraw":true,"wtakeback":true,"btakeback":false}"#;
        let state: GameState = serde_json::from_str(json).unwrap();
        assert!(!state.wdraw);
        assert!(state.bdraw);
        assert!(state.wtakeback);
        assert!(!state.btakeback);
    }

    #[test]
    fn parses_opponent_gone_event() {
        let json = r#"{"type":"opponentGone","gone":true,"claimWinInSeconds":8}"#;
        let msg: GameStreamMessage = serde_json::from_str(json).unwrap();
        match msg {
            GameStreamMessage::Gone(gone) => {
                assert!(gone.gone);
                assert_eq!(gone.claim_win_in_seconds, Some(8));
            }
            _ => panic!("expected Gone variant"),
        }
    }
}
