use serde::Deserialize;
#[cfg(feature = "transport")]
use shakmaty::Color;

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

#[cfg(any(feature = "transport", test))]
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TokenGrant {
    pub user_id: String,
    pub scopes: String,
}

// Inline schema confirmed against lichess-org/api's api-account-playing.yaml
// (no standalone NowPlayingGame schema file exists) -- `opponent` is still
// added defensively as fully Option, same posture as Player's fields above,
// rather than assumed to always be present despite that spec marking
// id/username required. `ai` is the built-in AI's level (present instead of
// username/rating for those games, same aiLevel-instead-of-user split as
// GamePlayerUser).
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct PlayingOpponent {
    pub username: Option<String>,
    pub rating: Option<u32>,
    pub ai: Option<u8>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingGame {
    #[serde(rename = "gameId")]
    pub game_id: String,
    #[serde(rename = "isMyTurn")]
    pub is_my_turn: bool,
    pub speed: Option<String>,
    pub source: Option<String>,
    pub variant: Option<Variant>,
    #[serde(rename = "secondsLeft")]
    pub seconds_left: Option<i64>,
    #[serde(default)]
    pub opponent: Option<PlayingOpponent>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingResponse {
    #[serde(rename = "nowPlaying")]
    pub now_playing: Vec<PlayingGame>,
}

// One row from GET /api/users/status. Presence booleans are omitted when false;
// patronColor is the current patron signal while patron remains for older replies.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct UserStatus {
    pub id: String,
    pub name: String,
    pub title: Option<String>,
    pub flair: Option<String>,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub playing: bool,
    #[serde(default)]
    pub streaming: bool,
    #[serde(default)]
    pub patron: bool,
    #[serde(rename = "patronColor")]
    pub patron_color: Option<u8>,
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
    pub expiration: Option<GameExpiration>,
}

impl GameState {
    pub fn awaiting_start(&self) -> bool {
        self.status == "created"
    }

    pub fn is_terminal(&self) -> bool {
        // Created has neither playable moves nor a result. A started-only
        // check ends it early, while a fixed list of results misses new endings.
        self.status != "started" && !self.awaiting_start()
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameExpiration {
    #[serde(rename = "idleMillis")]
    pub idle_millis: u64,
    #[serde(rename = "millisToMove")]
    pub millis_to_move: u64,
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
    #[serde(rename = "ratingDiff")]
    pub rating_diff: Option<i32>,
    #[serde(rename = "aiLevel")]
    pub ai_level: Option<u8>,
    pub title: Option<String>,
    pub provisional: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Variant {
    pub key: String,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameFull {
    pub id: String,
    pub variant: Variant,
    pub speed: Option<String>,
    pub rated: bool,
    #[serde(rename = "tournamentId")]
    pub tournament_id: Option<String>,
    #[serde(rename = "daysPerTurn")]
    pub days_per_turn: Option<u32>,
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
    Full(Box<GameFull>),
    #[serde(rename = "gameState")]
    State(GameState),
    #[serde(rename = "opponentGone")]
    Gone(OpponentGone),
    #[serde(rename = "chatLine")]
    Chat,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct EventGame {
    pub id: String,
    pub source: Option<String>,
    pub speed: Option<String>,
    pub rated: Option<bool>,
    pub color: Option<String>,
    pub variant: Option<Variant>,
    pub opponent: Option<PlayingOpponent>,
    pub compat: Option<GameCompatibility>,
    pub status: Option<EventGameStatus>,
    #[serde(rename = "isMyTurn")]
    pub is_my_turn: Option<bool>,
    #[serde(rename = "secondsLeft")]
    pub seconds_left: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct EventGameStatus {
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameCompatibility {
    pub board: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct CreatedGame {
    pub id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChallengeResolution {
    Accepted,
    Declined,
    Canceled,
}

#[derive(Debug, Deserialize)]
pub struct ChallengeResult {
    pub done: ChallengeResolution,
}

// The `game` payload of the account event stream's `gameFinish` event
// (confirmed against lichess-org/api's GameEventInfo.yaml -- a much larger
// schema shared with `gameStart`, only `id`/`ratingDiff` are modeled here
// since that's all this needs). Deliberately a separate struct from
// `EventGame` rather than adding `rating_diff` there: `gameStart`'s own real
// payload (per that same schema's `stream-gameStart.json.yaml` example) never
// carries a rating change at all (the game just began), so giving `EventGame`
// an always-absent field would be misleading about what `gameStart` can
// actually contain.
//
// IMPORTANT: this is NOT the same stream as the per-game
// `/api/board/game/stream/{id}` this app already reads for live board state
// (see GameState below) -- confirmed by reading GameStateEvent.yaml directly,
// which has no ratingDiff field at all. `ratingDiff` only exists on this
// account-wide event stream's gameFinish, a stream this app already holds
// open (see backend_app.rs's spawn_streams) but previously ignored this
// specific event type on.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameFinishInfo {
    pub id: String,
    // Confirmed against GameEventInfo.yaml: absent on casual (unrated) games,
    // not just omitted-defaults-to-zero -- #[serde(default)] so a missing key
    // deserializes to None rather than failing the whole event to parse.
    #[serde(default, rename = "ratingDiff")]
    pub rating_diff: Option<i32>,
}

// Confirmed against lichess-org/api's ChallengeJson.yaml / ChallengeUser.yaml.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeUser {
    pub id: String,
    pub name: String,
}

// Keep the tag and optional details separate. A strict tagged enum would reject
// future or untagged payloads, and clock display strings omit the other modes.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct ChallengeTimeControl {
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub limit: Option<u32>,
    pub increment: Option<u32>,
    #[serde(rename = "daysPerTurn")]
    pub days_per_turn: Option<i64>,
}

// The list and detail endpoints expose the same terms. Duplicating the fields
// can drift, while using a whole incoming row requires a challenger on details.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ChallengeTerms {
    #[serde(rename = "timeControl")]
    pub time_control: Option<ChallengeTimeControl>,
    pub variant: Option<Variant>,
    pub speed: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct IncomingChallenge {
    pub id: String,
    pub challenger: ChallengeUser,
    #[serde(flatten)]
    pub terms: ChallengeTerms,
    pub rated: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct ChallengeDetails {
    pub id: String,
    #[serde(flatten)]
    pub terms: ChallengeTerms,
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
    GameFinish { game: GameFinishInfo },
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
    #[serde(default, deserialize_with = "deserialize_archive_name")]
    pub name: Option<String>,
}

fn deserialize_archive_name<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(serde_json::Value::deserialize(deserializer)?.as_str()
        .map(str::trim).filter(|name| !name.is_empty()).map(str::to_owned))
}

// Missing counters stay unknown. Defaulting them to zero invents a result,
// and dropping the whole report loses independently valid measurements.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PlayerAnalysisSummary {
    pub inaccuracy: Option<u32>,
    pub mistake: Option<u32>,
    pub blunder: Option<u32>,
    pub acpl: Option<u32>,
    pub accuracy: Option<u32>,
}

fn deserialize_player_analysis<'de, D>(deserializer: D) -> Result<Option<PlayerAnalysisSummary>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let analysis = serde_json::Value::deserialize(deserializer)?;
    let number = |field| analysis.get(field).and_then(serde_json::Value::as_u64)
        .and_then(|value| u32::try_from(value).ok());
    let summary = PlayerAnalysisSummary {
        inaccuracy: number("inaccuracy"),
        mistake: number("mistake"),
        blunder: number("blunder"),
        acpl: number("acpl"),
        accuracy: number("accuracy").filter(|percent| *percent <= 100),
    };
    Ok((summary != PlayerAnalysisSummary::default()).then_some(summary))
}

// Confirmed against lichess-org/api's GamePlayerUser.yaml. `user` is absent for
// an AI opponent (only `aiLevel` is present then), matching Player's AI-opponent
// posture elsewhere in this file. `ratingDiff` is this side's own rating change
// from this one game (rated games only) -- was already in the real payload but
// unmodeled, so history_game_to_summary had no way to surface it. `analysis`
// arrives on this same object in both GET /api/games/user (history list) and
// GET /api/game/export/{id} (single-game export) responses, since both share
// this schema -- no extra request needed to get it for the history list.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GamePlayerUser {
    pub user: Option<LightUser>,
    // Nested-only labels lose guests. Treating a stored name as a user ID
    // could attribute someone else's game to the signed-in player.
    #[serde(default, rename = "name", deserialize_with = "deserialize_archive_name")]
    pub stored_name: Option<String>,
    pub rating: Option<u32>,
    #[serde(rename = "aiLevel")]
    pub ai_level: Option<u8>,
    #[serde(rename = "ratingDiff")]
    pub rating_diff: Option<i32>,
    #[serde(default, deserialize_with = "deserialize_player_analysis")]
    pub analysis: Option<PlayerAnalysisSummary>,
}

// Confirmed against lichess-org/api's GamePlayers.yaml.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GamePlayers {
    pub white: GamePlayerUser,
    pub black: GamePlayerUser,
}

#[cfg(feature = "transport")]
pub(crate) enum ParticipantPerspective {
    Known(Color),
    Unverified,
    Foreign,
}

#[cfg(feature = "transport")]
impl GamePlayers {
    pub(crate) fn perspective(&self, account_id: &str) -> ParticipantPerspective {
        fn user_id(player: &GamePlayerUser) -> Option<&str> {
            player.user.as_ref()?.id.as_deref().filter(|id| !id.is_empty())
        }
        let white = user_id(&self.white);
        let black = user_id(&self.black);
        // An omitted user is weaker evidence than two different IDs. Assuming
        // Black invents a side, while omitting every unmatched game loses old rows.
        match (white == Some(account_id), black == Some(account_id)) {
            (true, false) => ParticipantPerspective::Known(Color::White),
            (false, true) => ParticipantPerspective::Known(Color::Black),
            (false, false) if white.is_some() && black.is_some() => ParticipantPerspective::Foreign,
            _ => ParticipantPerspective::Unverified,
        }
    }

    pub(crate) fn player(&self, color: Color) -> &GamePlayerUser {
        match color {
            Color::White => &self.white,
            Color::Black => &self.black,
        }
    }
}

// Confirmed against lichess-org/api's GameOpening.yaml -- only `name` is shown
// anywhere in this app, `eco`/`ply` aren't modeled.
#[derive(Debug, Clone, PartialEq)]
pub struct GameOpening {
    pub name: String,
}

fn deserialize_history_opening<'de, D>(deserializer: D) -> Result<Option<GameOpening>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // A missing label should neither reject the page nor invent an opening.
    // Allow room beyond the published names without copying arbitrary text to the reply.
    const MAX_OPENING_NAME_BYTES: usize = 256;
    let opening = serde_json::Value::deserialize(deserializer)?;
    Ok(opening.get("name").and_then(serde_json::Value::as_str).map(str::trim)
        .filter(|name| !name.is_empty() && name.len() <= MAX_OPENING_NAME_BYTES)
        .map(|name| GameOpening { name: name.to_owned() }))
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
    pub variant: Option<String>,
    pub speed: Option<String>,
    pub status: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: Option<i64>,
    pub players: GamePlayers,
    pub winner: Option<String>,
    #[serde(default, deserialize_with = "deserialize_history_opening")]
    pub opening: Option<GameOpening>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct GameMoveAnalysis {
    pub score: Option<ArchivedScore>,
    pub judgment: Option<MoveJudgment>,
}

// Independent fields admit conflicting scores. Picking a preferred field
// would assign an evaluation without knowing which one Lichess intended.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ArchivedScore {
    Centipawns(i32),
    Mate(i32),
}

#[derive(Debug, Clone, PartialEq)]
pub struct MoveJudgment {
    pub name: String,
    pub comment: Option<String>,
}

// Generated captions are short. Truncating can change the advice, while
// accepting arbitrary lengths can overwhelm the move sheet and its reply.
const MAX_JUDGMENT_COMMENT_BYTES: usize = 512;

// GET /game/export/{id} (Accept: application/json) response -- confirmed
// against lichess-org/api's games-exportOneGame.json.yaml example and
// game-export-gameId.yaml's own query params. That endpoint returns dozens of
// fields (players, opening, clock, division, ...); only the ones game review
// actually uses are modeled: `moves` to replay (see
// game::replay::replay_export, confirmed space-separated SAN e.g. "d4 d5 c4
// c6 Nc3 ...", not UCI, unlike the live board stream's GameState.moves),
// `clocks` (remaining time in centiseconds after each ply) and `analysis`
// (per-ply eval/judgment) -- both included by default (`clocks`/`evals` query
// params both default to `true` per that endpoint's own spec) whenever
// Lichess actually has that data for this game, so no extra request-side
// flags are needed to ask for them.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameExport {
    // The JSON contract requires an ID. An optional ID leaves the replay
    // unverified, and copying the request ID cannot detect a mismatched reply.
    pub id: String,
    pub variant: Option<String>,
    pub players: Option<GamePlayers>,
    #[serde(rename = "initialFen")]
    pub initial_fen: Option<String>,
    // A missing sequence cannot be replayed. Defaulting it invents a board,
    // while rejecting an explicit empty string loses legitimate no-move games.
    pub moves: String,
    #[serde(default, deserialize_with = "deserialize_export_clocks")]
    pub clocks: Vec<Option<u32>>,
    #[serde(default, deserialize_with = "deserialize_export_analysis")]
    pub analysis: Vec<GameMoveAnalysis>,
}

fn deserialize_export_clocks<'de, D>(deserializer: D) -> Result<Vec<Option<u32>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // An absent clock leaves its ply slot intact. Dropping the slot shifts
    // later clocks onto the wrong moves, while using zero invents a time forfeit.
    let serde_json::Value::Array(clocks) = serde_json::Value::deserialize(deserializer)? else {
        return Ok(Vec::new());
    };
    Ok(clocks.into_iter()
        .map(|clock| clock.as_u64().and_then(|centis| u32::try_from(centis).ok()))
        .collect())
}

fn deserialize_export_analysis<'de, D>(deserializer: D) -> Result<Vec<GameMoveAnalysis>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // Keep empty ply slots. Filtering rows shifts annotations, and strict
    // row parsing can discard otherwise usable annotations and the replay.
    let serde_json::Value::Array(analysis) = serde_json::Value::deserialize(deserializer)? else {
        return Ok(Vec::new());
    };
    Ok(analysis.iter().map(|entry| {
        let integer = |key| entry.get(key).and_then(serde_json::Value::as_i64)
            .and_then(|value| i32::try_from(value).ok());
        let score = match (integer("eval"), integer("mate")) {
            (Some(cp), None) => Some(ArchivedScore::Centipawns(cp)),
            (None, Some(mate)) => Some(ArchivedScore::Mate(mate)),
            _ => None,
        };
        let judgment = entry.get("judgment").and_then(|judgment| {
            let name = judgment.get("name")?.as_str()?;
            if !matches!(name, "Inaccuracy" | "Mistake" | "Blunder") {
                return None;
            }
            let comment = judgment.get("comment").and_then(serde_json::Value::as_str)
                .filter(|comment| comment.len() <= MAX_JUDGMENT_COMMENT_BYTES && !comment.trim().is_empty())
                .map(str::to_owned);
            Some(MoveJudgment { name: name.into(), comment })
        });
        GameMoveAnalysis { score, judgment }
    }).collect())
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct CloudEvaluation {
    pub depth: u32,
    pub fen: String,
    pub knodes: u64,
    pub pvs: Vec<CloudEvaluationPv>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct CloudEvaluationPv {
    pub cp: Option<i32>,
    pub mate: Option<i32>,
    pub moves: String,
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
        let full_json = r#"{"type":"gameFull","id":"abcd1234","variant":{"key":"standard","name":"Standard"},"speed":"rapid","rated":false,"initialFen":"startpos","clock":{"initial":600000,"increment":0},"white":{"id":"myid"},"black":{"id":"oppid"},"state":{"type":"gameState","moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}}"#;
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
        let json = r#"{"type":"gameStart","game":{"id":"abcd1234","gameId":"abcd1234","source":"friend","speed":"correspondence","rated":false,"color":"white","variant":{"key":"standard","name":"Standard"},"compat":{"board":true,"bot":false},"status":{"id":20,"name":"started"},"isMyTurn":true,"secondsLeft":7200}}"#;
        let msg: EventStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg, EventStreamMessage::GameStart {
            game: EventGame {
                id: "abcd1234".into(),
                source: Some("friend".into()),
                speed: Some("correspondence".into()),
                rated: Some(false),
                color: Some("white".into()),
                variant: Some(Variant { key: "standard".into(), name: "Standard".into() }),
                opponent: None,
                compat: Some(GameCompatibility { board: Some(true) }),
                status: Some(EventGameStatus { name: "started".into() }),
                is_my_turn: Some(true),
                seconds_left: Some(7200),
            },
        });
    }

    #[test]
    fn parses_game_finish_event_with_rating_diff_ignoring_extra_fields() {
        // Real payload has dozens more fields (fen/opponent/status/clock/...) --
        // confirmed against lichess-org/api's stream-gameFinish.json.yaml example.
        let json = r#"{"type":"gameFinish","game":{"fullId":"0FgNPGRzhDaW","gameId":"0FgNPGRz","id":"0FgNPGRz","rated":true,"winner":"black","rating":724,"ratingDiff":-9}}"#;
        let msg: EventStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(
            msg,
            EventStreamMessage::GameFinish { game: GameFinishInfo { id: "0FgNPGRz".into(), rating_diff: Some(-9) } }
        );
    }

    #[test]
    fn game_finish_event_defaults_rating_diff_to_none_for_a_casual_game() {
        let json = r#"{"type":"gameFinish","game":{"id":"abcd1234","rated":false}}"#;
        let msg: EventStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(
            msg,
            EventStreamMessage::GameFinish { game: GameFinishInfo { id: "abcd1234".into(), rating_diff: None } }
        );
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
        assert_eq!(parsed.now_playing[0].variant, None);
    }

    #[test]
    fn parses_playing_response_with_opponent_info() {
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":false,"variant":{"key":"atomic","name":"Atomic"},"opponent":{"username":"Bob","rating":1500}}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        let game = &parsed.now_playing[0];
        let opponent = game.opponent.as_ref().unwrap();
        assert_eq!(opponent.username.as_deref(), Some("Bob"));
        assert_eq!(opponent.rating, Some(1500));
        assert_eq!(game.variant.as_ref().unwrap().key, "atomic");
    }

    #[test]
    fn parses_playing_response_with_ai_opponent() {
        // Confirmed against lichess-org/api's api-account-playing.yaml -- the
        // built-in AI has no username, only `ai` (its level).
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":true,"opponent":{"ai":5,"rating":1500}}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        let opponent = parsed.now_playing[0].opponent.as_ref().unwrap();
        assert_eq!(opponent.username, None);
        assert_eq!(opponent.ai, Some(5));
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
    fn parses_sparse_and_enriched_user_status_rows() {
        let json = r#"[
            {"id":"quiet","name":"Quiet"},
            {"id":"ana","name":"Ana","title":"IM","online":true,"playing":true,
             "streaming":true,"flair":"symbols.white-heart","patronColor":3}
        ]"#;
        let statuses: Vec<UserStatus> = serde_json::from_str(json).unwrap();
        assert!(!statuses[0].online);
        assert_eq!(statuses[1].title.as_deref(), Some("IM"));
        assert!(statuses[1].online && statuses[1].playing && statuses[1].streaming);
        assert_eq!(statuses[1].flair.as_deref(), Some("symbols.white-heart"));
        assert_eq!(statuses[1].patron_color, Some(3));
    }

    #[test]
    fn parses_history_game_ndjson_line() {
        let json = r#"{"id":"abcd1234","rated":true,"variant":"standard","speed":"rapid","perf":"rapid","createdAt":1700000000000,"lastMoveAt":1700000600000,"status":"mate","players":{"white":{"user":{"id":"myuser","name":"MyUser"},"rating":1600},"black":{"user":{"id":"bob","name":"Bob"},"rating":1580}},"winner":"white","opening":{"eco":"C50","name":"Italian Game","ply":4}}"#;
        let game: HistoryGame = serde_json::from_str(json).unwrap();
        assert_eq!(game.id, "abcd1234");
        assert!(game.rated);
        assert_eq!(game.variant.as_deref(), Some("standard"));
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
    fn parses_history_game_with_player_analysis_summary() {
        // Present once this specific game has gone through Lichess's computer
        // analysis -- absent (None) otherwise, which must not fail to parse.
        let json = r#"{"id":"abcd1234","rated":true,"variant":"standard","speed":"blitz","perf":"blitz","createdAt":1,"lastMoveAt":2,"status":"mate","players":{"white":{"user":{"id":"myuser","name":"MyUser"},"rating":1600,"analysis":{"inaccuracy":5,"mistake":2,"blunder":1,"acpl":26,"accuracy":90}},"black":{"user":{"id":"bob","name":"Bob"},"rating":1580}},"winner":"white"}"#;
        let game: HistoryGame = serde_json::from_str(json).unwrap();
        let summary = game.players.white.analysis.unwrap();
        assert_eq!(summary.blunder, Some(1));
        assert_eq!(summary.accuracy, Some(90));
        assert_eq!(game.players.black.analysis, None);
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
    fn parses_game_export_moves_as_space_separated_san_ignoring_extra_fields() {
        // Unmodeled export fields never prevent parsing the identity and moves.
        let json = r#"{"id":"abcd1234","rated":true,"variant":"standard","speed":"blitz","perf":"blitz","createdAt":1,"lastMoveAt":2,"status":"mate","players":{"white":{"user":{"name":"A","id":"a"},"rating":1600},"black":{"user":{"name":"B","id":"b"},"rating":1580}},"winner":"white","moves":"e4 e5 Nf3 Nc6"}"#;
        let export: GameExport = serde_json::from_str(json).unwrap();
        assert_eq!(export.id, "abcd1234");
        assert_eq!(export.moves, "e4 e5 Nf3 Nc6");
        // Neither field was in this payload -- must default to empty, not error,
        // for the (common) case of an untimed or never-analyzed game.
        assert!(export.clocks.is_empty());
        assert_eq!(export.analysis, Vec::new());
    }

    #[test]
    fn player_analysis_keeps_available_measurements_without_affecting_identity() {
        for (analysis, expected) in [
            (r#"{"inaccuracy":2,"mistake":0,"accuracy":100,"acpl":"invalid"}"#, Some(PlayerAnalysisSummary {
                inaccuracy: Some(2), mistake: Some(0), accuracy: Some(100), ..PlayerAnalysisSummary::default()
            })),
            (r#"{"accuracy":0,"acpl":0,"blunder":-1,"mistake":1.5}"#, Some(PlayerAnalysisSummary {
                acpl: Some(0), accuracy: Some(0), ..PlayerAnalysisSummary::default()
            })),
            (r#"{"accuracy":101,"blunder":7}"#, Some(PlayerAnalysisSummary {
                blunder: Some(7), ..PlayerAnalysisSummary::default()
            })),
            (r#"{"accuracy":-1,"inaccuracy":4294967296,"blunder":null}"#, None),
            (r#"["invalid"]"#, None),
            ("null", None),
            ("{}", None),
        ] {
            let json = format!(r#"{{"user":{{"id":"player"}},"ratingDiff":-7,"analysis":{analysis}}}"#);
            let player: GamePlayerUser = serde_json::from_str(&json).unwrap();
            assert_eq!(player.user.unwrap().id.as_deref(), Some("player"));
            assert_eq!(player.rating_diff, Some(-7));
            assert_eq!(player.analysis, expected, "{analysis}");
        }
    }

    #[test]
    fn archive_player_names_decode_separately_from_account_id() {
        let player: GamePlayerUser = serde_json::from_str(
            r#"{"name":"  Archived Name  ","user":{"id":"canonical","name":{}}, "rating":1600}"#,
        ).unwrap();
        assert_eq!(player.stored_name.as_deref(), Some("Archived Name"));
        assert_eq!(player.rating, Some(1600));
        let user = player.user.unwrap();
        assert_eq!(user.id.as_deref(), Some("canonical"));
        assert_eq!(user.name, None);
    }

    #[test]
    fn history_keeps_the_game_when_optional_opening_details_are_unusable() {
        let at_limit = "♞".repeat(85) + "!";
        for (opening, expected) in [
            (serde_json::json!({"name": "  Italian Game  "}), Some("Italian Game")),
            (serde_json::json!({"name": at_limit}), Some(at_limit.as_str())),
            (serde_json::json!({"name": format!("{at_limit}!")}), None),
            (serde_json::json!({"name": 123}), None),
            (serde_json::json!({"name": " \t "}), None),
            (serde_json::json!({"eco": "C20"}), None),
            (serde_json::json!("Italian Game"), None),
            (serde_json::json!(["Italian Game"]), None),
            (serde_json::Value::Null, None),
        ] {
            let game: HistoryGame = serde_json::from_value(serde_json::json!({
                "id": "abcd1234", "createdAt": 7, "players": {"white":{"user":{"id":"player"}},"black":{}},
                "winner": "white", "opening": opening,
            })).unwrap();
            assert_eq!(game.id, "abcd1234");
            assert_eq!(game.created_at, Some(7));
            assert_eq!(game.winner.as_deref(), Some("white"));
            assert_eq!(game.opening.as_ref().map(|opening| opening.name.as_str()), expected);
        }
    }

    #[test]
    fn parses_game_export_clocks_and_analysis_when_present() {
        // Trimmed real shape (see games-exportOneGame.json.yaml's own example) --
        // one inaccuracy-judged move, one plain eval, one forced-mate eval.
        let json = r#"{"id":"abcd1234","moves":"e4 e5 Qh5","clocks":[3000,2990,2980],"analysis":[
            {"eval":25},
            {"eval":85,"best":"d5e4","variation":"dxe4","judgment":{"name":"Inaccuracy","comment":"Inaccuracy. dxe4 was best."}},
            {"mate":3}
        ]}"#;
        let export: GameExport = serde_json::from_str(json).unwrap();
        assert_eq!(export.clocks, vec![Some(3000), Some(2990), Some(2980)]);
        assert_eq!(export.analysis.len(), 3);
        assert_eq!(export.analysis[0].score, Some(ArchivedScore::Centipawns(25)));
        assert_eq!(export.analysis[1].judgment.as_ref().unwrap().name, "Inaccuracy");
        assert_eq!(export.analysis[2].score, Some(ArchivedScore::Mate(3)));
    }

    #[test]
    fn game_export_salvages_analysis_by_field_without_reassigning_plies() {
        let export: GameExport = serde_json::from_str(r#"{
            "id":"abcd1234","moves":"e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6",
            "analysis":[
                {"eval":0}, null, 4,
                {"eval":68,"mate":-2,"judgment":{"name":"Mistake"}},
                {"eval":"+0.12","mate":3,"judgment":{"name":"Blunder","comment":false}},
                {"eval":-77,"judgment":{"name":"Unknown","comment":"Ignored"}},
                {"eval":2147483648,"mate":-2147483649},
                {"mate":0,"judgment":{"name":"Inaccuracy","comment":"  "}}
            ]
        }"#).unwrap();
        let scores: Vec<_> = export.analysis.iter().map(|entry| entry.score).collect();
        assert_eq!(scores, [Some(ArchivedScore::Centipawns(0)), None, None, None,
            Some(ArchivedScore::Mate(3)), Some(ArchivedScore::Centipawns(-77)),
            None, Some(ArchivedScore::Mate(0))]);
        for (index, name) in [(3, "Mistake"), (4, "Blunder"), (7, "Inaccuracy")] {
            assert_eq!(export.analysis[index].judgment, Some(MoveJudgment {
                name: name.into(), comment: None,
            }));
        }
        for index in [0, 1, 2, 5, 6] {
            assert_eq!(export.analysis[index].judgment, None);
        }
        for analysis in ["null", "{}", "false"] {
            let body = format!(r#"{{"id":"abcd1234","moves":"e4","analysis":{analysis}}}"#);
            let export: GameExport = serde_json::from_str(&body).unwrap();
            assert_eq!(export.moves, "e4");
            assert!(export.analysis.is_empty());
        }
    }

    #[test]
    fn game_export_bounds_caption_bytes_without_losing_the_judgment() {
        let caption = "♞".repeat(170) + "!!";
        assert_eq!(caption.len(), MAX_JUDGMENT_COMMENT_BYTES);
        let export: GameExport = serde_json::from_value(serde_json::json!({
            "id": "abcd1234", "moves": "e4 e5", "analysis": [
                {"eval": 0, "judgment": {"name": "Mistake", "comment": caption}},
                {"eval": 25, "judgment": {"name": "Blunder", "comment": format!("{caption}!")}}
            ]
        })).unwrap();
        assert_eq!(export.analysis[0].judgment.as_ref().unwrap().comment.as_deref(), Some(caption.as_str()));
        let oversized = &export.analysis[1];
        assert_eq!(oversized.score, Some(ArchivedScore::Centipawns(25)));
        let judgment = oversized.judgment.as_ref().unwrap();
        assert_eq!(judgment.name, "Blunder");
        assert_eq!(judgment.comment, None);
    }

    #[test]
    fn game_export_preserves_clock_positions_when_optional_data_is_bad() {
        let export: GameExport = serde_json::from_str(r#"{
            "id":"abcd1234","moves":"e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6",
            "clocks":[4294967295,-1,2980,null,0,1.5,"2970",4294967296]
        }"#).unwrap();
        assert_eq!(export.clocks, [Some(u32::MAX), None, Some(2980), None, Some(0), None, None, None]);
        for clocks in ["null", "{}", "30"] {
            let body = format!(r#"{{"id":"abcd1234","moves":"e4","clocks":{clocks}}}"#);
            let export: GameExport = serde_json::from_str(&body).unwrap();
            assert_eq!(export.moves, "e4");
            assert!(export.clocks.is_empty());
        }
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

    #[test]
    fn chat_events_parse_as_ignored_stream_messages() {
        let json =
            r#"{"type":"chatLine","room":"player","username":"opponent","text":"gg"}"#;
        let msg: GameStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg, GameStreamMessage::Chat);
    }
}
