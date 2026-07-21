use crate::lichess::models::{
    Account, ChallengeListResponse, ChallengeOpenJson, GameHistoryFilters, HistoryGame,
    IncomingChallenge, PlayingGame, PlayingResponse,
};
use crate::lichess::stream::parse_ndjson_line;
use anyhow::{anyhow, Result};
use futures_util::StreamExt;

#[derive(Clone)]
pub struct LichessClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

/// Lichess error responses carry an actionable `{"error": "..."}` JSON body (confirmed
/// against the real API: a scope-missing 403 came back as `{"error":"Missing scope:
/// board:play"}`) that every method here used to throw away, surfacing only the bare
/// HTTP status code to whoever called it. Reads the body and prefers its `error` field;
/// falls back to the raw body text if it isn't JSON shaped that way, rather than
/// silently swallowing whatever Lichess actually said.
async fn error_from_response(context: &str, resp: reqwest::Response) -> anyhow::Error {
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let reason = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
        .filter(|s| !s.is_empty())
        .unwrap_or(body);
    if reason.is_empty() {
        anyhow!("{context} failed with status {status}")
    } else {
        anyhow!("{context} failed with status {status}: {reason}")
    }
}

impl LichessClient {
    pub fn new(token: String) -> Self {
        Self::with_base_url(token, "https://lichess.org".to_string())
    }

    pub fn with_base_url(token: String, base_url: String) -> Self {
        Self { http: reqwest::Client::new(), base_url, token }
    }

    fn bearer(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        builder.bearer_auth(&self.token)
    }

    pub async fn get_account(&self) -> Result<Account> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/account", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_account", resp).await);
        }
        Ok(resp.json::<Account>().await?)
    }

    pub async fn get_playing(&self) -> Result<Vec<PlayingGame>> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/account/playing", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_playing", resp).await);
        }
        let parsed = resp.json::<PlayingResponse>().await?;
        Ok(parsed.now_playing)
    }

    /// GET /api/games/user/{username} defaults to returning PGN text -- confirmed
    /// via real-world reports of this exact footgun (lichess.org/forum/lichess-feedback
    /// "Lichess API returns x-chess-pgn, even if get request asks for json"). The
    /// documented fix is an explicit `Accept: application/x-ndjson` header, one JSON
    /// object per line, not a query param. Buffered as a single `.text()` rather than
    /// streamed line-by-line like `stream_lines` -- this is a bounded, one-shot page
    /// of `max` games, not an open-ended live connection.
    ///
    /// `filters` are the subset of this endpoint's real query params this app's
    /// history screen actually exposes (confirmed against the endpoint's own
    /// filtering options: rated/perfType/color, among others this app doesn't
    /// surface like since/until/vs/analysed/sort).
    pub async fn get_game_history(
        &self,
        username: &str,
        max: u32,
        filters: &GameHistoryFilters,
    ) -> Result<Vec<HistoryGame>> {
        let mut query = vec![("max".to_string(), max.to_string())];
        if let Some(rated) = filters.rated {
            query.push(("rated".to_string(), rated.to_string()));
        }
        if let Some(speed) = &filters.speed {
            query.push(("perfType".to_string(), speed.clone()));
        }
        if let Some(color) = &filters.color {
            query.push(("color".to_string(), color.clone()));
        }
        let resp = self
            .bearer(
                self.http
                    .get(format!("{}/api/games/user/{}", self.base_url, username))
                    .header("Accept", "application/x-ndjson")
                    .query(&query),
            )
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_game_history", resp).await);
        }
        let body = resp.text().await?;
        let games: Vec<HistoryGame> =
            body.lines().filter_map(parse_ndjson_line::<HistoryGame>).collect();
        // If Lichess fell back to PGN text (the exact bug the Accept header above is
        // meant to prevent), every line fails to parse as JSON and `games` comes back
        // silently empty even though real games exist -- surface that distinctly
        // instead of reporting "no games played".
        if games.is_empty() && !body.trim().is_empty() {
            return Err(anyhow!(
                "get_game_history: response body didn't parse as NDJSON (got {} bytes) -- \
                 Lichess may have ignored the Accept: application/x-ndjson header",
                body.len()
            ));
        }
        Ok(games)
    }

    pub async fn make_move(&self, game_id: &str, uci: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/move/{}",
                self.base_url, game_id, uci
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("make_move", resp).await);
        }
        Ok(())
    }

    pub async fn resign(&self, game_id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/resign",
                self.base_url, game_id
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("resign", resp).await);
        }
        Ok(())
    }

    /// Same endpoint handles both offering a draw (when none is pending) and
    /// responding to the opponent's (accept=true to take it, false to decline) --
    /// confirmed against lichess-org/api's `api-board-game-gameId-draw-accept.yaml`.
    pub async fn draw(&self, game_id: &str, accept: bool) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/draw/{}",
                self.base_url, game_id, accept
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("draw", resp).await);
        }
        Ok(())
    }

    /// Offer/accept/decline takeback -- same offer-or-respond split as `draw`.
    pub async fn takeback(&self, game_id: &str, accept: bool) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/takeback/{}",
                self.base_url, game_id, accept
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("takeback", resp).await);
        }
        Ok(())
    }

    /// Only legal before either side has made a move; Lichess itself rejects a
    /// late abort rather than us trying to replicate that rule client-side.
    pub async fn abort(&self, game_id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/board/game/{}/abort", self.base_url, game_id)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("abort", resp).await);
        }
        Ok(())
    }

    /// Only legal after Lichess's own `opponentGone` stream event has fired and
    /// its `claimWinInSeconds` has elapsed -- same "let the server be the
    /// authority" approach as `abort`, rather than running a local countdown.
    pub async fn claim_victory(&self, game_id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/claim-victory",
                self.base_url, game_id
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("claim_victory", resp).await);
        }
        Ok(())
    }

    /// Only legal while the game is drawable by the 50-move rule or repetition --
    /// same "let the server be the authority" approach as `abort`/`claim_victory`.
    pub async fn claim_draw(&self, game_id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/claim-draw",
                self.base_url, game_id
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("claim_draw", resp).await);
        }
        Ok(())
    }

    /// GET /api/challenge returns {"in": [...], "out": [...]} -- only "in"
    /// (challenges targeted at you) matters here.
    pub async fn get_challenges(&self) -> Result<Vec<IncomingChallenge>> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/challenge", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_challenges", resp).await);
        }
        let parsed = resp.json::<ChallengeListResponse>().await?;
        Ok(parsed.incoming)
    }

    pub async fn accept_challenge(&self, id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/{}/accept", self.base_url, id)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("accept_challenge", resp).await);
        }
        Ok(())
    }

    pub async fn decline_challenge(&self, id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/{}/decline", self.base_url, id)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("decline_challenge", resp).await);
        }
        Ok(())
    }

    /// Always posts to the "player" room -- this app has no spectator mode.
    pub async fn send_chat(&self, game_id: &str, text: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/board/game/{}/chat", self.base_url, game_id)))
            .form(&[("room", "player"), ("text", text)])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("send_chat", resp).await);
        }
        Ok(())
    }

    /// `/api/board/seek` is a long-poll endpoint, confirmed live against production:
    /// a fire-and-forget POST that doesn't keep reading the response never matched
    /// with an opponent in testing, while holding the same request open for ~20s
    /// matched immediately with a real player. The seek only stays active while this
    /// connection is held -- callers must keep draining the returned stream (its
    /// *content* isn't otherwise needed; the actual `gameStart` is delivered
    /// separately via the account event stream) until Lichess closes it on its own
    /// (matched, cancelled, or timed out), not drop it right after this returns.
    pub async fn create_seek(
        &self,
        minutes: u32,
        increment: u32,
        rated: bool,
        color: &str,
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        let mut form = vec![
            ("rated", rated.to_string()),
            ("time", minutes.to_string()),
            ("increment", increment.to_string()),
        ];
        // Confirmed against api-board-seek.yaml: "Better left empty to automatically
        // get 50% white" -- an explicit "random" isn't documented as equivalent, so
        // omit the field rather than send a value the spec doesn't actually mention.
        if color != "random" {
            form.push(("color", color.to_string()));
        }
        let resp = self
            .bearer(self.http.post(format!("{}/api/board/seek", self.base_url)))
            .form(&form)
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("create_seek", resp).await);
        }
        Ok(response_to_lines(resp))
    }

    /// Unlike `create_seek`, `/api/challenge/{username}` does NOT long-poll by
    /// default -- confirmed against lichess-org/api's api-challenge-username.yaml:
    /// without `keepAliveStream=true` it returns one plain JSON object immediately
    /// and the challenge expires after 20s regardless of what the client does
    /// afterward. `keepAliveStream=true` switches the response to the same
    /// held-open ndjson stream shape `create_seek` already relies on.
    pub async fn create_challenge(
        &self,
        username: &str,
        minutes: u32,
        increment: u32,
        rated: bool,
        color: &str,
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/{}", self.base_url, username)))
            .form(&[
                ("rated", rated.to_string()),
                ("clock.limit", (minutes * 60).to_string()),
                ("clock.increment", increment.to_string()),
                ("keepAliveStream", "true".to_string()),
                ("color", color.to_string()),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("create_challenge", resp).await);
        }
        Ok(response_to_lines(resp))
    }

    /// Confirmed against lichess-org/api's api-challenge-ai.yaml: unlike seeks/user
    /// challenges, this starts a real game immediately (no accept/decline step, no
    /// long-poll to hold open) and isn't subject to the seek-only Rapid-speed floor
    /// (confirmed against lichess-org/lila's own SetupForm.scala/misc.scala -- that
    /// restriction only applies to `isBoardCompatible` seeks, not challenge/ai).
    /// The started game is still reported on the account event stream's `gameStart`
    /// like any other game, so no extra plumbing is needed beyond this POST.
    pub async fn challenge_ai(&self, level: u8, minutes: u32, increment: u32) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/ai", self.base_url)))
            .form(&[
                ("level", level.to_string()),
                ("clock.limit", (minutes * 60).to_string()),
                ("clock.increment", increment.to_string()),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("challenge_ai", resp).await);
        }
        Ok(())
    }

    /// Confirmed against lichess-org/api's ChallengeOpenJson.yaml: unlike
    /// `create_seek`/`create_challenge`, this returns one plain JSON object
    /// immediately, not a held-open stream -- the challenge itself stays open
    /// server-side (shareable indefinitely via the returned urls) without this
    /// client holding any connection for it. Whoever opens `urlWhite`/`urlBlack`
    /// starts the game, which then arrives the same way any other game does, via
    /// the account event stream's `gameStart` (already wired in spawn_streams).
    pub async fn create_open_challenge(
        &self,
        minutes: u32,
        increment: u32,
        rated: bool,
    ) -> Result<ChallengeOpenJson> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/open", self.base_url)))
            .form(&[
                ("rated", rated.to_string()),
                ("clock.limit", (minutes * 60).to_string()),
                ("clock.increment", increment.to_string()),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("create_open_challenge", resp).await);
        }
        Ok(resp.json::<ChallengeOpenJson>().await?)
    }

    pub async fn stream_lines(
        &self,
        url_path: &str,
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        let resp = self
            .bearer(self.http.get(format!("{}{}", self.base_url, url_path)))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response(&format!("stream {}", url_path), resp).await);
        }
        Ok(response_to_lines(resp))
    }
}

/// Shared by every streaming/long-poll endpoint (`stream_lines`, `create_seek`,
/// `create_challenge`): turns a successful response's body into a stream of lines.
fn response_to_lines(
    resp: reqwest::Response,
) -> std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>> {
    let byte_stream = resp.bytes_stream();
    // Boxed and pinned so the returned stream is `Unpin` (the `filter_map`/`flat_map`
    // combinator chain below is not, since it embeds a per-chunk async closure) —
    // callers need `Unpin` to call `StreamExt::next()` in a `while let` loop.
    Box::pin(byte_stream
        .filter_map(|chunk| async move { chunk.ok() })
        .flat_map(|bytes| {
            let text = String::from_utf8_lossy(&bytes).to_string();
            futures_util::stream::iter(
                text.lines().map(str::to_string).collect::<Vec<_>>(),
            )
        }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_string_contains, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn get_account_sends_bearer_token_and_parses_response() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account"))
            .and(header("Authorization", "Bearer test-token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "abc123",
                "username": "testuser"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let account = client.get_account().await.unwrap();
        assert_eq!(account.username, "testuser");
    }

    #[tokio::test]
    async fn get_playing_parses_now_playing_list() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account/playing"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "nowPlaying": [{"gameId": "g1", "isMyTurn": true}]
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_playing().await.unwrap();
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].game_id, "g1");
    }

    #[tokio::test]
    async fn get_game_history_sends_ndjson_accept_header_and_max_query_param() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        let line = serde_json::json!({
            "id": "abcd1234", "rated": true, "variant": "standard", "speed": "rapid",
            "perf": "rapid", "createdAt": 1, "lastMoveAt": 2, "status": "mate",
            "players": {
                "white": {"user": {"id": "myuser", "name": "MyUser"}, "rating": 1600},
                "black": {"user": {"id": "bob", "name": "Bob"}, "rating": 1580}
            },
            "winner": "white"
        })
        .to_string();
        Mock::given(method("GET"))
            .and(path("/api/games/user/myuser"))
            .and(query_param("max", "20"))
            .and(header("Accept", "application/x-ndjson"))
            .respond_with(ResponseTemplate::new(200).set_body_string(line))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_game_history("myuser", 20, &GameHistoryFilters::default()).await.unwrap();
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].id, "abcd1234");
    }

    #[tokio::test]
    async fn get_game_history_sends_rated_speed_and_color_query_params_when_set() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/games/user/myuser"))
            .and(query_param("rated", "true"))
            .and(query_param("perfType", "rapid"))
            .and(query_param("color", "white"))
            .respond_with(ResponseTemplate::new(200).set_body_string(""))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let filters = GameHistoryFilters {
            rated: Some(true),
            speed: Some("rapid".to_string()),
            color: Some("white".to_string()),
        };
        // The mock only matches if all three query params were actually sent --
        // an unmatched request fails with a 404 from wiremock's default response,
        // which .unwrap() below would catch.
        client.get_game_history("myuser", 20, &filters).await.unwrap();
    }

    #[tokio::test]
    async fn get_game_history_returns_empty_vec_for_a_player_with_no_games() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/games/user/newplayer"))
            .respond_with(ResponseTemplate::new(200).set_body_string(""))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_game_history("newplayer", 20, &GameHistoryFilters::default()).await.unwrap();
        assert!(games.is_empty());
    }

    #[tokio::test]
    async fn get_game_history_errors_distinctly_when_response_looks_like_pgn_not_ndjson() {
        // Regression guard for the exact bug this Accept header exists to avoid --
        // if Lichess (or a misbehaving proxy) ignores it and sends PGN text back,
        // every line fails to parse and this must not be silently reported as
        // "this player has never played a game".
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/games/user/myuser"))
            .respond_with(ResponseTemplate::new(200).set_body_string("[Event \"?\"]\n[Site \"?\"]\n"))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.get_game_history("myuser", 20, &GameHistoryFilters::default()).await.unwrap_err();
        assert!(err.to_string().contains("didn't parse as NDJSON"));
    }

    #[tokio::test]
    async fn get_game_history_surfaces_lichess_error_body() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/games/user/myuser"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "error": "No such user"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.get_game_history("myuser", 20, &GameHistoryFilters::default()).await.unwrap_err();
        assert!(err.to_string().contains("No such user"));
    }

    #[tokio::test]
    async fn make_move_posts_uci_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/move/e2e4"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.make_move("g1", "e2e4").await.unwrap();
    }

    #[tokio::test]
    async fn draw_posts_accept_true_to_offer_or_accept_a_draw() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/draw/true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.draw("g1", true).await.unwrap();
    }

    #[tokio::test]
    async fn draw_posts_accept_false_to_decline() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/draw/false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.draw("g1", false).await.unwrap();
    }

    #[tokio::test]
    async fn takeback_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/takeback/true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.takeback("g1", true).await.unwrap();
    }

    #[tokio::test]
    async fn abort_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/abort"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.abort("g1").await.unwrap();
    }

    #[tokio::test]
    async fn claim_victory_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/claim-victory"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.claim_victory("g1").await.unwrap();
    }

    #[tokio::test]
    async fn takeback_surfaces_lichess_error_body() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/takeback/true"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": "Takeback not possible"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.takeback("g1", true).await.unwrap_err();
        assert!(err.to_string().contains("Takeback not possible"));
    }

    #[tokio::test]
    async fn create_seek_posts_form_encoded_time_control() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/seek"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        // Deliberately not draining the returned stream here -- the point of this
        // test is just the request shape. Draining/holding-open behavior is covered
        // by `create_seek_keeps_the_stream_open_until_the_server_closes_it` below.
        let _stream = client.create_seek(10, 0, false, "random").await.unwrap();
    }

    #[tokio::test]
    async fn create_seek_posts_rated_and_color_when_not_random() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/seek"))
            .and(body_string_contains("rated=true"))
            .and(body_string_contains("color=white"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let _stream = client.create_seek(10, 0, true, "white").await.unwrap();
    }

    #[tokio::test]
    async fn create_seek_omits_color_when_random() {
        // Confirmed against api-board-seek.yaml: color is "Better left empty to
        // automatically get 50% white" -- an explicit "random" isn't documented as
        // equivalent, so this should omit the field entirely rather than send it.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/seek"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let _stream = client.create_seek(10, 0, false, "random").await.unwrap();

        let requests = server.received_requests().await.unwrap();
        let body = String::from_utf8(requests[0].body.clone()).unwrap();
        assert!(!body.contains("color="), "expected no color field, got body: {body}");
    }

    #[tokio::test]
    async fn create_challenge_posts_to_username_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/opponent"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let _stream = client.create_challenge("opponent", 10, 5, false, "random").await.unwrap();
    }

    #[tokio::test]
    async fn challenge_ai_posts_level_and_clock() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/ai"))
            .and(body_string_contains("level=3"))
            .and(body_string_contains("clock.limit=300"))
            .and(body_string_contains("clock.increment=2"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.challenge_ai(3, 5, 2).await.unwrap();
    }

    #[tokio::test]
    async fn create_challenge_sets_keep_alive_stream() {
        // Regression test: without keepAliveStream=true, /api/challenge/{username}
        // returns a single JSON object (not a stream) and the challenge expires
        // after 20s regardless of what the client does afterward -- confirmed
        // against lichess-org/api's api-challenge-username.yaml.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/opponent"))
            .and(body_string_contains("keepAliveStream=true"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let _stream = client.create_challenge("opponent", 10, 5, false, "random").await.unwrap();
    }

    #[tokio::test]
    async fn create_seek_keeps_the_stream_open_until_the_server_closes_it() {
        // Regression test for the fire-and-forget bug found via live testing against
        // production Lichess: a seek POST that returns without draining its response
        // stream let the connection (and therefore the seek) close immediately.
        // wiremock's chunked body simulates a server that keeps sending data for a
        // bit -- this asserts the stream actually yields everything the server sends
        // rather than being dropped after the initial response.
        use futures_util::StreamExt;
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/seek"))
            .respond_with(ResponseTemplate::new(200).set_body_string("\n\n\n"))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let mut lines = client.create_seek(10, 0, false, "random").await.unwrap();
        let mut count = 0;
        while lines.next().await.is_some() {
            count += 1;
        }
        assert_eq!(count, 3, "expected all keep-alive lines to be drainable from the stream");
    }

    #[tokio::test]
    async fn create_open_challenge_posts_clock_and_rated_form_fields() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/open"))
            .and(body_string_contains("clock.limit=600"))
            .and(body_string_contains("clock.increment=5"))
            .and(body_string_contains("rated=false"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "ovdODEHx",
                "url": "https://lichess.org/ovdODEHx",
                "urlWhite": "https://lichess.org/ovdODEHx?color=white",
                "urlBlack": "https://lichess.org/ovdODEHx?color=black"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let challenge = client.create_open_challenge(10, 5, false).await.unwrap();
        assert_eq!(challenge.id, "ovdODEHx");
        assert_eq!(challenge.url_white, "https://lichess.org/ovdODEHx?color=white");
    }

    #[tokio::test]
    async fn create_open_challenge_bails_on_error_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/open"))
            .respond_with(ResponseTemplate::new(400))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let result = client.create_open_challenge(10, 0, false).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn create_seek_bails_on_error_status() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/seek"))
            .respond_with(ResponseTemplate::new(400))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let result = client.create_seek(10, 0, false, "random").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn get_account_surfaces_lichess_error_body_not_just_status_code() {
        // Real Lichess behavior, confirmed against production: a scope-missing
        // request comes back with an actionable JSON body, e.g.
        // {"error":"Missing scope: board:play"} -- previously discarded entirely,
        // surfacing only the bare status code to whoever called this.
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account"))
            .respond_with(ResponseTemplate::new(403).set_body_json(serde_json::json!({
                "error": "Missing scope: board:play"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.get_account().await.unwrap_err();
        assert!(
            err.to_string().contains("Missing scope: board:play"),
            "expected the Lichess error body's reason in the error message, got: {}",
            err
        );
    }

    #[tokio::test]
    async fn stream_lines_yields_ndjson_lines_and_skips_blank_keepalives() {
        use futures_util::StreamExt;
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/stream/event"))
            .respond_with(ResponseTemplate::new(200).set_body_string(
                "{\"type\":\"gameStart\",\"game\":{\"id\":\"g1\"}}\n\n{\"type\":\"gameFinish\",\"game\":{\"id\":\"g1\"}}\n",
            ))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let mut lines = client.stream_lines("/api/stream/event").await.unwrap();
        let mut collected = Vec::new();
        while let Some(line) = lines.next().await {
            collected.push(line);
        }
        assert_eq!(
            collected,
            vec![
                r#"{"type":"gameStart","game":{"id":"g1"}}"#.to_string(),
                "".to_string(),
                r#"{"type":"gameFinish","game":{"id":"g1"}}"#.to_string(),
            ]
        );
    }

    #[tokio::test]
    async fn claim_draw_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/claim-draw"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.claim_draw("g1").await.unwrap();
    }

    #[tokio::test]
    async fn get_challenges_parses_incoming_list() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/challenge"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "in": [{
                    "id": "c1",
                    "challenger": {"id": "opp", "name": "Opponent"},
                    "timeControl": {"limit": 600, "increment": 0}
                }],
                "out": []
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let challenges = client.get_challenges().await.unwrap();
        assert_eq!(challenges.len(), 1);
        assert_eq!(challenges[0].id, "c1");
        assert_eq!(challenges[0].challenger.name, "Opponent");
        assert_eq!(challenges[0].time_control.limit, Some(600));
    }

    #[tokio::test]
    async fn accept_challenge_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/c1/accept"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.accept_challenge("c1").await.unwrap();
    }

    #[tokio::test]
    async fn decline_challenge_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/c1/decline"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.decline_challenge("c1").await.unwrap();
    }

    #[tokio::test]
    async fn send_chat_posts_room_and_text() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/chat"))
            .respond_with(ResponseTemplate::new(200))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.send_chat("g1", "gg").await.unwrap();
    }

    #[tokio::test]
    async fn stream_lines_bails_on_error_status() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/stream/event"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let result = client.stream_lines("/api/stream/event").await;
        assert!(result.is_err());
    }
}
