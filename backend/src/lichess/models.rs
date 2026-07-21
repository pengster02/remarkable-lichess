use serde::Deserialize;

// Confirmed against lichess-org/api's Perf.yaml (games/rating/rd/prog required,
// prov/rank only appear conditionally). Only the four fields this app actually
// displays are modeled -- prov/rank aren't shown anywhere yet.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Perf {
    pub games: u32,
    pub rating: u32,
    pub rd: u32,
    #[serde(default)]
    pub prog: i32,
}

// Confirmed against lichess-org/api's Perfs.yaml -- only the 5 standard (non-variant,
// non-puzzle) speed categories are modeled, matching what Home actually shows.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct Perfs {
    pub bullet: Option<Perf>,
    pub blitz: Option<Perf>,
    pub rapid: Option<Perf>,
    pub classical: Option<Perf>,
    pub correspondence: Option<Perf>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub username: String,
    #[serde(default)]
    pub perfs: Option<Perfs>,
}

// The exact NowPlayingGame schema file couldn't be located in lichess-org/api's
// spec repo during this pass (only the `nowPlaying` wrapper's shape was
// confirmed) -- `opponent` is added defensively as fully Option, same posture
// as Player's fields above, rather than assumed to always be present.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct PlayingOpponent {
    pub username: Option<String>,
    pub rating: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingGame {
    #[serde(rename = "gameId")]
    pub game_id: String,
    #[serde(rename = "isMyTurn")]
    pub is_my_turn: bool,
    #[serde(default)]
    pub opponent: Option<PlayingOpponent>,
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

// Confirmed against lichess-org/api's GameEventPlayer.yaml. That schema marks `id`
// and `name` both required, but this project's own live testing already found `id`
// absent for AI opponents (see backend/src/lichess/client.rs's create-seek-adjacent
// testing history) -- specs can overstate what's *actually* always present, so
// `name` gets the same defensive Option treatment rather than trusting the spec's
// "required" at face value. `rating` is genuinely optional per the schema (an AI
// opponent has a level, not a rating).
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Player {
    pub id: Option<String>,
    pub name: Option<String>,
    pub rating: Option<u32>,
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

// Confirmed against lichess-org/api's ChatLineEvent.yaml.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChatLine {
    pub room: String,
    pub username: String,
    pub text: String,
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
    #[serde(rename = "chatLine")]
    Chat(ChatLine),
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

// Challenge/ChallengeCanceled/ChallengeDeclined confirmed against lichess-org/api's
// ChallengeEvent.yaml / ChallengeCanceledEvent.yaml / ChallengeDeclinedEvent.yaml --
// unit variants since we only need to know *that* the pending list changed, then
// re-fetch it via GET /api/challenge rather than tracking the full ChallengeJson here.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum EventStreamMessage {
    #[serde(rename = "gameStart")]
    GameStart { game: EventGame },
    #[serde(rename = "gameFinish")]
    GameFinish { game: EventGame },
    #[serde(rename = "challenge")]
    Challenge,
    #[serde(rename = "challengeCanceled")]
    ChallengeCanceled,
    #[serde(rename = "challengeDeclined")]
    ChallengeDeclined,
    #[serde(other)]
    Other,
}

// Confirmed against lichess-org/api's LightUser.yaml. `id` is the canonical
// lowercased username Lichess itself uses for identity comparisons -- used
// server-side to work out your_color for a history entry, rather than `name`
// (display-cased, only used for showing the opponent's name to the user).
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct LightUser {
    pub id: Option<String>,
    pub name: Option<String>,
}

// Confirmed against lichess-org/api's GamePlayerUser.yaml. `user` is absent for
// an AI opponent (only `aiLevel` is present then), matching Player's AI-opponent
// posture elsewhere in this file.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GamePlayerUser {
    pub user: Option<LightUser>,
    pub rating: Option<u32>,
    #[serde(rename = "aiLevel")]
    pub ai_level: Option<u8>,
}

// Confirmed against lichess-org/api's GamePlayers.yaml.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GamePlayers {
    pub white: GamePlayerUser,
    pub black: GamePlayerUser,
}

// Confirmed against lichess-org/api's GameOpening.yaml -- only `name` is shown
// anywhere in this app, `eco`/`ply` aren't modeled.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameOpening {
    pub name: String,
}

// Request-side, not a Lichess response shape -- the subset of GET
// /api/games/user/{username}'s real query params (confirmed against its
// documented Filtering Options: since/until/max/vs/rated/perfType/color/
// analysed/ongoing/finished/sort) that this app's history screen exposes.
// `speed` maps to the endpoint's own `perfType` param name.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GameHistoryFilters {
    pub rated: Option<bool>,
    pub speed: Option<String>,
    pub color: Option<String>,
}

// One row of GET /api/games/user/{username}'s NDJSON response (Accept:
// application/x-ndjson -- without that header this endpoint returns PGN text
// instead, see lichess::client::get_game_history). Confirmed against
// lichess-org/api's GameJson.yaml; only the fields this app's history list
// actually shows are modeled. `winner`/`opening` are genuinely optional per
// the schema (winner absent on a draw; opening absent for some variants).
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct HistoryGame {
    pub id: String,
    #[serde(default)]
    pub rated: bool,
    pub speed: Option<String>,
    pub status: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: Option<i64>,
    pub players: GamePlayers,
    pub winner: Option<String>,
    pub opening: Option<GameOpening>,
}

// Confirmed against lichess-org/api's ChallengeOpenJson.yaml -- only the fields
// needed to show/share the created link are modeled (variant/perf/timeControl
// etc. aren't shown anywhere in this app).
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeOpenJson {
    pub id: String,
    pub url: String,
    #[serde(rename = "urlWhite")]
    pub url_white: String,
    #[serde(rename = "urlBlack")]
    pub url_black: String,
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
    fn parses_challenge_lifecycle_events_ignoring_extra_fields() {
        let json = r#"{"type":"challenge","challenge":{"id":"H9fIRZUk","challenger":{"id":"bot1","name":"Bot1"}}}"#;
        assert_eq!(serde_json::from_str::<EventStreamMessage>(json).unwrap(), EventStreamMessage::Challenge);

        let json = r#"{"type":"challengeCanceled","challenge":{"id":"H9fIRZUk"}}"#;
        assert_eq!(serde_json::from_str::<EventStreamMessage>(json).unwrap(), EventStreamMessage::ChallengeCanceled);

        let json = r#"{"type":"challengeDeclined","challenge":{"id":"H9fIRZUk"}}"#;
        assert_eq!(serde_json::from_str::<EventStreamMessage>(json).unwrap(), EventStreamMessage::ChallengeDeclined);
    }

    #[test]
    fn parses_playing_response() {
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":true}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.now_playing.len(), 1);
        assert_eq!(parsed.now_playing[0].game_id, "abcd1234");
        assert!(parsed.now_playing[0].is_my_turn);
        assert_eq!(parsed.now_playing[0].opponent, None);
    }

    #[test]
    fn parses_playing_response_with_opponent_info() {
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":false,"opponent":{"username":"Bob","rating":1500}}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        let opponent = parsed.now_playing[0].opponent.as_ref().unwrap();
        assert_eq!(opponent.username.as_deref(), Some("Bob"));
        assert_eq!(opponent.rating, Some(1500));
    }

    #[test]
    fn parses_account_with_perfs() {
        let json = r#"{"id":"myid","username":"MyUser","perfs":{"rapid":{"games":42,"rating":1600,"rd":45,"prog":12},"puzzle":{"games":1,"rating":1000,"rd":300,"prog":0}}}"#;
        let account: Account = serde_json::from_str(json).unwrap();
        let perfs = account.perfs.unwrap();
        assert_eq!(perfs.rapid.unwrap().rating, 1600);
        // bullet wasn't in the payload at all -- must default to None, not error.
        assert_eq!(perfs.bullet, None);
    }

    #[test]
    fn parses_account_without_perfs() {
        let json = r#"{"id":"myid","username":"MyUser"}"#;
        let account: Account = serde_json::from_str(json).unwrap();
        assert_eq!(account.perfs, None);
    }

    #[test]
    fn parses_history_game_ndjson_line() {
        let json = r#"{"id":"abcd1234","rated":true,"variant":"standard","speed":"rapid","perf":"rapid","createdAt":1700000000000,"lastMoveAt":1700000600000,"status":"mate","players":{"white":{"user":{"id":"myuser","name":"MyUser"},"rating":1600},"black":{"user":{"id":"bob","name":"Bob"},"rating":1580}},"winner":"white","opening":{"eco":"C50","name":"Italian Game","ply":4}}"#;
        let game: HistoryGame = serde_json::from_str(json).unwrap();
        assert_eq!(game.id, "abcd1234");
        assert!(game.rated);
        assert_eq!(game.speed.as_deref(), Some("rapid"));
        assert_eq!(game.winner.as_deref(), Some("white"));
        assert_eq!(game.players.white.user.as_ref().unwrap().id.as_deref(), Some("myuser"));
        assert_eq!(game.opening.unwrap().name, "Italian Game");
    }

    #[test]
    fn parses_challenge_open_json_ignoring_unmodeled_fields() {
        let json = r#"{"id":"ovdODEHx","url":"https://lichess.org/ovdODEHx","status":"created","challenger":null,"destUser":null,"variant":{"key":"standard","name":"Standard"},"rated":false,"speed":"rapid","timeControl":{"type":"clock","limit":600,"increment":0,"show":"10+0"},"color":"random","urlWhite":"https://lichess.org/ovdODEHx?color=white","urlBlack":"https://lichess.org/ovdODEHx?color=black"}"#;
        let parsed: ChallengeOpenJson = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.id, "ovdODEHx");
        assert_eq!(parsed.url_white, "https://lichess.org/ovdODEHx?color=white");
        assert_eq!(parsed.url_black, "https://lichess.org/ovdODEHx?color=black");
    }

    #[test]
    fn parses_history_game_with_ai_opponent_and_no_winner() {
        // Draws (and AI opponents) omit `winner`/`user` -- must not fail to parse.
        let json = r#"{"id":"xyz","rated":false,"variant":"standard","speed":"blitz","perf":"blitz","createdAt":1,"lastMoveAt":2,"status":"draw","players":{"white":{"user":{"id":"myuser","name":"MyUser"},"rating":1600},"black":{"aiLevel":5}}}"#;
        let game: HistoryGame = serde_json::from_str(json).unwrap();
        assert_eq!(game.winner, None);
        assert_eq!(game.players.black.user, None);
        assert_eq!(game.players.black.ai_level, Some(5));
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
