use crate::lichess::models::{
    Account, ChallengeDetails, ChallengeListResponse, ChallengeOpenJson, ChallengeTerms, CloudEvaluation, CreatedGame, GameExport,
    GameHistoryFilters, HistoryGame, IncomingChallenge, PlayingGame,
    PlayingResponse, UserStatus,
};
#[cfg(any(feature = "transport", test))]
use crate::lichess::models::TokenGrant;
use crate::lichess::stream::parse_ndjson_line;
use crate::pgn_export::{PgnExport, PgnGameId};
use crate::protocol::{HistoryCursor, OpeningDatabase, OpeningExplorerData};
use anyhow::{anyhow, Result};
use futures_util::StreamExt;

#[derive(Clone)]
pub struct LichessClient {
    http: reqwest::Client,
    no_redirect_http: reqwest::Client,
    base_url: String,
    token: String,
    request_timeout: std::time::Duration,
}

const ONE_SHOT_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const HISTORY_PAGE_SIZE: usize = 20;

#[derive(Debug)]
struct HttpResponseError {
    status: reqwest::StatusCode,
    context: String,
    reason: Option<String>,
}

impl std::fmt::Display for HttpResponseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} failed with status {}", self.context, self.status)?;
        if let Some(reason) = &self.reason {
            write!(formatter, ": {reason}")?;
        }
        Ok(())
    }
}

impl std::error::Error for HttpResponseError {}

#[cfg(any(feature = "transport", test))]
pub(crate) fn is_auth_rejection(error: &anyhow::Error) -> bool {
    error.downcast_ref::<HttpResponseError>().is_some_and(|error| {
        matches!(error.status, reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN)
    })
}

#[cfg(any(feature = "transport", test))]
pub(crate) fn is_unauthorized(error: &anyhow::Error) -> bool {
    error.downcast_ref::<HttpResponseError>()
        .is_some_and(|error| error.status == reqwest::StatusCode::UNAUTHORIZED)
}

#[cfg(any(feature = "transport", test))]
pub(crate) fn is_challenge_read_denial(error: &anyhow::Error) -> bool {
    error.downcast_ref::<HttpResponseError>().is_some_and(|error| {
        error.status == reqwest::StatusCode::FORBIDDEN &&
            error.reason.as_deref() == Some("Missing scope: challenge:read")
    })
}

#[cfg(any(feature = "transport", test))]
pub(crate) fn board_stream_rejection(error: &anyhow::Error) -> Option<&str> {
    let error = error.downcast_ref::<HttpResponseError>()?;
    let fallback = match error.status {
        reqwest::StatusCode::BAD_REQUEST => "This game is unavailable in the Board API.",
        reqwest::StatusCode::FORBIDDEN => "Lichess denied access to this board.",
        reqwest::StatusCode::NOT_FOUND => "Lichess couldn't find this game.",
        _ => return None,
    };
    Some(error.reason.as_deref().unwrap_or(fallback))
}

#[cfg(feature = "transport")]
pub(crate) fn is_rate_limited(error: &anyhow::Error) -> bool {
    error.downcast_ref::<HttpResponseError>()
        .is_some_and(|error| error.status == reqwest::StatusCode::TOO_MANY_REQUESTS)
}

/// Shared with the OAuth sign-in flow (see lichess::oauth), which talks to the
/// same host before any client exists to hold it.
pub const LICHESS_BASE_URL: &str = "https://lichess.org";
pub(super) const LICHESS_USER_AGENT: &str = "remarkable-lichess";
const OPENING_EXPLORER_URL: &str = "https://explorer.lichess.org";

/// Unauthenticated "is Lichess there at all" check, for the sign-in screen --
/// every other connectivity report comes from a real API call that needs a
/// token (see backend_app's handle_request_home), which is exactly what a
/// not-yet-signed-in user doesn't have.
///
/// Any HTTP reply counts, including an error status: this is testing the
/// network path, not the API. Only a transport failure (DNS, refused, timeout)
/// means unreachable.
pub async fn is_reachable(base_url: &str) -> bool {
    let Ok(http) = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(8))
        .timeout(std::time::Duration::from_secs(10))
        .user_agent(LICHESS_USER_AGENT)
        .build()
    else {
        return false;
    };
    match http.head(base_url).send().await {
        Ok(_) => true,
        Err(e) => {
            log::warn!("lichess reachability check failed: {e}");
            false
        }
    }
}

/// Lichess error responses carry an actionable `{"error": "..."}` JSON body (confirmed
/// against the real API: a scope-missing 403 came back as `{"error":"Missing scope:
/// board:play"}`) that every method here used to throw away, surfacing only the bare
/// HTTP status code to whoever called it. Reads the body and prefers its `error` field;
/// falls back to a bounded plain-text reason and ignores HTML error pages.
async fn error_from_response(context: &str, resp: reqwest::Response) -> anyhow::Error {
    let status = resp.status();
    // Record the rate limit even if the body stalls and the caller cancels.
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return http_response_error(context, status, None);
    }
    let body = resp.text().await.unwrap_or_default();
    let json_reason = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
        .filter(|s| !s.is_empty());
    let reason = json_reason.or_else(|| {
        let compact = body.split_whitespace().collect::<Vec<_>>().join(" ");
        if compact.starts_with("<!DOCTYPE") || compact.starts_with("<html") {
            return None;
        }
        let mut chars = compact.chars();
        let shortened: String = chars.by_ref().take(240).collect();
        if chars.next().is_some() {
            Some(format!("{shortened}..."))
        } else if shortened.is_empty() {
            None
        } else {
            Some(shortened)
        }
    });
    http_response_error(context, status, reason)
}

pub(super) fn http_response_error(
    context: &str,
    status: reqwest::StatusCode,
    reason: Option<String>,
) -> anyhow::Error {
    let error = HttpResponseError { status, context: context.to_owned(), reason };
    log::warn!("{error}");
    error.into()
}

impl LichessClient {
    pub fn new(token: String) -> Self {
        Self::with_base_url(token, LICHESS_BASE_URL.to_string())
    }

    pub fn with_base_url(token: String, base_url: String) -> Self {
        // connect_timeout only bounds the TCP/TLS handshake, not the whole
        // request -- confirmed live that a dropped/blackholed route otherwise
        // hangs forever with no error. A blanket `.timeout()` would be wrong
        // here: create_seek/create_challenge/stream_lines deliberately hold
        // their connection open for minutes (or a whole game), so timing out
        // the full request would kill those by design, not just dead connects.
        let http = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(15))
            .user_agent(LICHESS_USER_AGENT)
            .build()
            .expect("reqwest client with a timeout always builds");
        Self {
            http,
            // Token metadata carries the credential in the body. Header stripping
            // cannot protect that body, and rated explorer reads need authentication.
            no_redirect_http: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(15))
                .redirect(reqwest::redirect::Policy::none())
                .user_agent(LICHESS_USER_AGENT)
                .build()
                .expect("nonredirecting HTTP client always builds"),
            base_url,
            token,
            request_timeout: ONE_SHOT_REQUEST_TIMEOUT,
        }
    }

    fn bearer(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        builder.bearer_auth(&self.token)
    }

    /// Every one-shot (non-streaming) request funnels through here so a hang or
    /// transport failure (timeout, DNS, connection refused/reset) is logged with
    /// the same `context` label used for HTTP-status errors (see
    /// `error_from_response`), instead of only showing up as a bare `anyhow`
    /// message with no indication of which endpoint failed.
    async fn send_logged(&self, context: &str, builder: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        self.send_with_logging(context, builder.timeout(self.request_timeout)).await
    }

    // Following redirects can drop the bearer or replay a write. Reading a
    // direct 401's body can delay sign-out, so only other failures need details.
    async fn send_direct_authenticated(
        &self,
        context: &str,
        request: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        let response = self.send_logged(context, self.bearer(request)).await?;
        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(http_response_error(context, status, None));
        }
        if !status.is_success() {
            return Err(error_from_response(context, response).await);
        }
        Ok(response)
    }

    async fn send_direct_authenticated_stream(
        &self,
        context: &str,
        builder: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        // Bound stream setup only. A connect timeout leaves headers unbounded,
        // while a request-wide timeout also cuts off a healthy streaming body.
        let deadline = tokio::time::Instant::now() + self.request_timeout;
        let response = match tokio::time::timeout_at(deadline, self.send_with_logging(context, self.bearer(builder))).await {
            Ok(result) => result?,
            Err(_) => {
                log::warn!("{context}: timed out waiting for Lichess response headers");
                return Err(anyhow!("{context} timed out waiting for Lichess"));
            }
        };
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(http_response_error(context, status, None));
        }

        let error = tokio::time::timeout_at(deadline, error_from_response(context, response))
            .await
            .unwrap_or_else(|_| http_response_error(context, status, None));
        Err(error)
    }

    async fn send_with_logging(
        &self,
        context: &str,
        builder: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        log::debug!("{context}: sending request");
        match builder.send().await {
            Ok(resp) => {
                log::debug!("{context}: got response {}", resp.status());
                Ok(resp)
            }
            Err(e) => {
                log::warn!("{context}: request failed: {e}");
                Err(e.into())
            }
        }
    }

    pub async fn get_account(&self) -> Result<Account> {
        let resp = self
            .send_logged("get_account", self.bearer(self.no_redirect_http.get(format!("{}/api/account", self.base_url))))
            .await?;
        if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(http_response_error("get_account", resp.status(), None));
        }
        if !resp.status().is_success() {
            return Err(error_from_response("get_account", resp).await);
        }
        Ok(resp.json::<Account>().await?)
    }

    #[cfg(any(feature = "transport", test))]
    pub(crate) async fn get_token_grant(&self) -> Result<Option<TokenGrant>> {
        let resp = self.send_logged(
            "get_token_grant",
            self.no_redirect_http.post(format!("{}/api/token/test", self.base_url))
                .header(reqwest::header::CONTENT_TYPE, "text/plain")
                .body(self.token.clone()),
        ).await?;
        if !resp.status().is_success() {
            // The endpoint can echo the token in its response.
            return Err(http_response_error("get_token_grant", resp.status(), None));
        }
        let mut grants = resp.json::<std::collections::HashMap<String, Option<TokenGrant>>>().await
            .map_err(|_| anyhow!("Lichess returned invalid token metadata"))?;
        grants.remove(&self.token).ok_or_else(|| anyhow!("Lichess returned no metadata for this token"))
    }

    pub async fn get_playing(&self) -> Result<Vec<PlayingGame>> {
        // One maximal read keeps Lichess's urgent order. The default truncates
        // at nine, and additional reads repeat the list without a cursor.
        let resp = self
            .send_logged("get_playing", self.bearer(self.no_redirect_http
                .get(format!("{}/api/account/playing", self.base_url))
                .query(&[("nb", 50)])))
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_playing", resp).await);
        }
        let parsed = resp.json::<PlayingResponse>().await?;
        Ok(parsed.now_playing)
    }

    pub async fn get_user_statuses(&self, user_ids: &[String]) -> Result<Vec<UserStatus>> {
        if user_ids.is_empty() {
            return Ok(Vec::new());
        }
        let resp = self
            .send_logged(
                "get_user_statuses",
                self.http
                    .get(format!("{}/api/users/status", self.base_url))
                    .query(&[("ids", user_ids.join(","))]),
            )
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("get_user_statuses", resp).await);
        }
        Ok(resp.json::<Vec<UserStatus>>().await?)
    }

    /// GET /api/games/user/{username} defaults to returning PGN text -- confirmed
    /// via real-world reports of this exact footgun (lichess.org/forum/lichess-feedback
    /// "Lichess API returns x-chess-pgn, even if get request asks for json"). The
    /// documented fix is an explicit `Accept: application/x-ndjson` header, one JSON
    /// object per line, not a query param. Buffered as a single `.text()` rather than
    /// streamed line-by-line like `stream_lines` -- this is a bounded, one-shot page
    /// of `max` games, not an open-ended live connection.
    ///
    /// The filters and exclusive creation-time cutoff are sent to Lichess.
    pub async fn get_game_history(
        &self,
        username: &str,
        max: u32,
        filters: &GameHistoryFilters,
        until_ms: Option<i64>,
    ) -> Result<Vec<HistoryGame>> {
        // Get the card summaries in one read. Per-move evaluations add unused
        // data here, and exports for individual games require more requests.
        let mut query = vec![
            ("max".to_string(), max.to_string()),
            ("opening".to_string(), "true".to_string()),
            ("accuracy".to_string(), "true".to_string()),
            ("moves".to_string(), "false".to_string()),
        ];
        if let Some(rated) = filters.rated {
            query.push(("rated".to_string(), rated.to_string()));
        }
        if let Some(speed) = &filters.speed {
            query.push(("perfType".to_string(), speed.clone()));
        }
        if let Some(color) = &filters.color {
            query.push(("color".to_string(), color.clone()));
        }
        if let Some(until_ms) = until_ms {
            query.push(("until".to_string(), until_ms.to_string()));
        }
        let resp = self
            .send_direct_authenticated(
                "get_game_history",
                self.no_redirect_http
                    .get(format!("{}/api/games/user/{}", self.base_url, username))
                    .header("Accept", "application/x-ndjson")
                    .query(&query),
            )
            .await?;
        let body = resp.text().await?;
        // Dropping a broken row can hide the lookahead, while treating the
        // response as empty can misreport an entire archive as exhausted.
        body.lines()
            .filter(|line| !line.trim().is_empty())
            .map(parse_ndjson_line::<HistoryGame>)
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| anyhow!(
                "get_game_history: response body didn't parse as NDJSON (got {} bytes) -- \
                 Lichess may have ignored the Accept: application/x-ndjson header",
                body.len()
            ))
    }

    pub async fn get_game_history_page(
        &self,
        username: &str,
        filters: &GameHistoryFilters,
        cursor: Option<HistoryCursor>,
    ) -> Result<(Vec<HistoryGame>, Option<HistoryCursor>)> {
        // Fetch one extra game to prove there is another page. Always showing
        // a load button causes empty requests, and fetching the archive is unbounded.
        let overlap = cursor.as_ref().map_or(0, |cursor| cursor.seen_at_cutoff.len());
        let max = u32::try_from(HISTORY_PAGE_SIZE + 1 + overlap)?;
        let until_ms = cursor.as_ref().map(|cursor| cursor.until_ms);
        let mut games = self.get_game_history(username, max, filters, until_ms).await?;
        if let Some(cursor) = &cursor {
            games.retain(|game| !cursor.seen_at_cutoff.contains(&game.id));
        }
        let next_cursor = if let Some(lookahead) = games.get(HISTORY_PAGE_SIZE) {
            let cutoff = lookahead.created_at
                .ok_or_else(|| anyhow!("Lichess did not provide a date for the next history page"))?;
            let until_ms = cutoff.checked_add(1)
                .ok_or_else(|| anyhow!("Lichess provided an invalid history date"))?;
            let mut seen_at_cutoff = match cursor {
                Some(previous) if previous.until_ms == until_ms => previous.seen_at_cutoff,
                _ => Default::default(),
            };
            seen_at_cutoff.extend(games[..HISTORY_PAGE_SIZE].iter()
                .filter(|game| game.created_at == Some(cutoff))
                .map(|game| game.id.clone()));
            Some(HistoryCursor { until_ms, seen_at_cutoff })
        } else {
            None
        };
        games.truncate(HISTORY_PAGE_SIZE);
        Ok((games, next_cursor))
    }

    /// GET /game/export/{id} defaults to PGN text -- same footgun
    /// `get_game_history` already works around for a different endpoint
    /// (confirmed against lichess-org/api's game-export-gameId.yaml
    /// `AcceptPgnOrJson` header parameter), so this sets an explicit
    /// `Accept: application/json` rather than relying on a query param.
    /// Lichess offers extended export flags to authenticated requests.
    pub async fn export_game(&self, game_id: &str) -> Result<GameExport> {
        let resp = self.send_direct_authenticated("export_game", self.no_redirect_http
            .get(format!("{}/game/export/{}", self.base_url, game_id))
            .header(reqwest::header::ACCEPT, "application/json"))
            .await?;
        Ok(resp.json::<GameExport>().await?)
    }

    pub async fn export_pgn(&self, game_id: PgnGameId) -> Result<PgnExport> {
        // Raw PGN preserves Lichess annotations byte for byte. Rebuilding it
        // loses metadata, and pgnInJson adds bytes to every review load.
        const MEDIA_TYPE: &str = "application/x-chess-pgn";
        let response = self.send_direct_authenticated("export PGN", self.no_redirect_http
            .get(format!("{}/game/export/{}", self.base_url, game_id.as_str()))
            .header(reqwest::header::ACCEPT, MEDIA_TYPE)
            .query(&[("clocks", "true"), ("evals", "true"), ("opening", "true"), ("literate", "true")]))
            .await?;
        let media_type = response.headers().get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next());
        anyhow::ensure!(media_type.is_some_and(|value| value.trim().eq_ignore_ascii_case(MEDIA_TYPE)),
            "Lichess did not return PGN");
        PgnExport::from_response(game_id, response.bytes().await?.to_vec())
    }

    pub async fn get_cloud_evaluation(&self, fen: &str) -> Result<Option<CloudEvaluation>> {
        let resp = self
            .send_logged(
                "get_cloud_evaluation",
                self.http
                    .get(format!("{}/api/cloud-eval", self.base_url))
                    .query(&[("fen", fen), ("multiPv", "1")]),
            )
            .await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !resp.status().is_success() {
            return Err(error_from_response("get_cloud_evaluation", resp).await);
        }
        Ok(Some(resp.json::<CloudEvaluation>().await?))
    }

    pub async fn get_opening_explorer(
        &self, database: OpeningDatabase, root_fen: &str, play: &[String],
    ) -> Result<OpeningExplorerData> {
        self.get_opening_explorer_at(OPENING_EXPLORER_URL, database, root_fen, play).await
    }

    async fn get_opening_explorer_at(
        &self, base_url: &str, database: OpeningDatabase, root_fen: &str, play: &[String],
    ) -> Result<OpeningExplorerData> {
        let route = match database {
            OpeningDatabase::Masters => "masters",
            OpeningDatabase::Lichess => "lichess",
        };
        let mut request = self.no_redirect_http.get(format!("{base_url}/{route}"))
            .query(&[("fen", root_fen), ("moves", "12"), ("topGames", "0")]);
        if !play.is_empty() {
            request = request.query(&[("play", play.join(","))]);
        }
        if database == OpeningDatabase::Lichess {
            request = self.bearer(request.query(&[("recentGames", "0")]));
        }
        let response = self.send_logged("opening explorer", request).await?;
        if !response.status().is_success() {
            return Err(error_from_response("opening explorer", response).await);
        }
        Ok(response.json().await?)
    }

    async fn post_direct_authenticated(&self, context: &str, path: &str) -> Result<()> {
        self.send_direct_authenticated(context, self.no_redirect_http.post(format!("{}{path}", self.base_url)))
            .await.map(drop)
    }

    pub async fn make_move(&self, game_id: &str, uci: &str) -> Result<()> {
        self.post_direct_authenticated("make_move", &format!("/api/board/game/{game_id}/move/{uci}")).await
    }

    pub async fn resign(&self, game_id: &str) -> Result<()> {
        self.post_direct_authenticated("resign", &format!("/api/board/game/{game_id}/resign")).await
    }

    /// Same endpoint handles both offering a draw (when none is pending) and
    /// responding to the opponent's (accept=true to take it, false to decline) --
    /// confirmed against lichess-org/api's `api-board-game-gameId-draw-accept.yaml`.
    pub async fn draw(&self, game_id: &str, accept: bool) -> Result<()> {
        self.post_direct_authenticated("draw", &format!("/api/board/game/{game_id}/draw/{accept}")).await
    }

    /// Offer/accept/decline takeback -- same offer-or-respond split as `draw`.
    pub async fn takeback(&self, game_id: &str, accept: bool) -> Result<()> {
        self.post_direct_authenticated("takeback", &format!("/api/board/game/{game_id}/takeback/{accept}")).await
    }

    /// Only legal before either side has made a move; Lichess itself rejects a
    /// late abort rather than us trying to replicate that rule client-side.
    pub async fn abort(&self, game_id: &str) -> Result<()> {
        self.post_direct_authenticated("abort", &format!("/api/board/game/{game_id}/abort")).await
    }

    pub async fn berserk(&self, game_id: &str) -> Result<()> {
        self.post_direct_authenticated("berserk", &format!("/api/board/game/{game_id}/berserk")).await
    }

    pub async fn add_time(&self, game_id: &str, seconds: u32) -> Result<()> {
        self.post_direct_authenticated("add_time", &format!("/api/round/{game_id}/add-time/{seconds}")).await
    }

    /// Only legal after Lichess's own `opponentGone` stream event has fired and
    /// its `claimWinInSeconds` has elapsed -- same "let the server be the
    /// authority" approach as `abort`, rather than running a local countdown.
    pub async fn claim_victory(&self, game_id: &str) -> Result<()> {
        self.post_direct_authenticated("claim_victory", &format!("/api/board/game/{game_id}/claim-victory")).await
    }

    /// Only legal after Lichess reports that the opponent has left.
    pub async fn claim_draw(&self, game_id: &str) -> Result<()> {
        self.post_direct_authenticated("claim_draw", &format!("/api/board/game/{game_id}/claim-draw")).await
    }

    /// GET /api/challenge returns {"in": [...], "out": [...]} -- only "in"
    /// (challenges targeted at you) matters here.
    pub async fn get_challenges(&self) -> Result<Vec<IncomingChallenge>> {
        let resp = self
            .send_direct_authenticated("get_challenges", self.no_redirect_http.get(format!("{}/api/challenge", self.base_url)))
            .await?;
        let parsed = resp.json::<ChallengeListResponse>().await?;
        Ok(parsed.incoming)
    }

    pub async fn get_challenge_terms(&self, id: &str) -> Result<ChallengeTerms> {
        let mut url = reqwest::Url::parse(&self.base_url)?;
        url.path_segments_mut().map_err(|_| anyhow!("Invalid Lichess URL"))?
            .pop_if_empty().extend(["api", "challenge", id, "show"]);
        let resp = self.send_direct_authenticated("get_challenge_terms", self.no_redirect_http.get(url)).await?;
        let detail = resp.json::<ChallengeDetails>().await?;
        anyhow::ensure!(detail.id == id, "Lichess returned details for another challenge");
        Ok(detail.terms)
    }

    pub async fn accept_challenge(&self, id: &str) -> Result<()> {
        self.post_direct_authenticated("accept_challenge", &format!("/api/challenge/{id}/accept")).await
    }

    pub async fn decline_challenge(&self, id: &str) -> Result<()> {
        self.post_direct_authenticated("decline_challenge", &format!("/api/challenge/{id}/decline")).await
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
            .send_direct_authenticated_stream("create_seek", self.no_redirect_http.post(format!("{}/api/board/seek", self.base_url))
                .form(&form))
            .await?;
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
    ) -> Result<(String, std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>)> {
        let username = username.trim();
        // Lichess uses its historical syntax for existing names. Signup
        // rules reject some legacy names, and URL encoding allows invalid ones.
        anyhow::ensure!(
            (2..=30).contains(&username.len()) &&
                username.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')),
            "Enter a Lichess username with 2–30 letters, digits, underscores, or hyphens."
        );
        // The literal routes are case-sensitive and user lookup is not.
        // Blocking both names loses valid targets, while URL escapes may be normalized.
        let username = match username {
            "ai" => "AI",
            "open" => "Open",
            _ => username,
        };
        let resp = self
            .send_direct_authenticated_stream("create_challenge", self.no_redirect_http.post(format!("{}/api/challenge/{}", self.base_url, username))
                .form(&[
                    ("rated", rated.to_string()),
                    ("clock.limit", (minutes * 60).to_string()),
                    ("clock.increment", increment.to_string()),
                    ("keepAliveStream", "true".to_string()),
                    ("color", color.to_string()),
                ]))
            .await?;
        let mut lines = response_to_lines(resp);
        let first_line = tokio::time::timeout(self.request_timeout, async {
            while let Some(line) = lines.next().await {
                if !line.trim().is_empty() {
                    return Ok(line);
                }
            }
            Err(anyhow!("Lichess closed the challenge before returning its ID"))
        })
        .await
        .map_err(|_| anyhow!("Timed out waiting for the Lichess challenge ID"))??;
        let challenge: CreatedGame = serde_json::from_str(&first_line)?;
        Ok((challenge.id, lines))
    }

    /// Confirmed against lichess-org/api's api-challenge-ai.yaml: unlike seeks/user
    /// challenges, this starts a real game immediately (no accept/decline step, no
    /// long-poll to hold open) and isn't subject to the seek-only Rapid-speed floor
    /// (confirmed against lichess-org/lila's own SetupForm.scala/misc.scala -- that
    /// restriction only applies to `isBoardCompatible` seeks, not challenge/ai).
    pub async fn challenge_ai(&self, level: u8, minutes: u32, increment: u32, color: &str) -> Result<String> {
        let resp = self
            .send_direct_authenticated("challenge_ai", self.no_redirect_http.post(format!("{}/api/challenge/ai", self.base_url))
                .form(&[
                    ("level", level.to_string()),
                    ("clock.limit", (minutes * 60).to_string()),
                    ("clock.increment", increment.to_string()),
                    ("color", color.to_owned()),
                ]))
            .await?;
        Ok(resp.json::<CreatedGame>().await?.id)
    }

    /// Confirmed against lichess-org/api's ChallengeOpenJson.yaml: unlike
    /// `create_seek`/`create_challenge`, this returns one plain JSON object
    /// immediately. The links stay valid for 24 hours and two players must
    /// join. If the authenticated player joins, `gameStart` arrives on the
    /// account event stream.
    pub async fn create_open_challenge(
        &self,
        minutes: u32,
        increment: u32,
        rated: bool,
    ) -> Result<ChallengeOpenJson> {
        let resp = self
            .send_direct_authenticated("create_open_challenge", self.no_redirect_http.post(format!("{}/api/challenge/open", self.base_url))
                .form(&[
                    ("rated", rated.to_string()),
                    ("clock.limit", (minutes * 60).to_string()),
                    ("clock.increment", increment.to_string()),
                ]))
            .await?;
        Ok(resp.json::<ChallengeOpenJson>().await?)
    }

    pub async fn stream_lines(
        &self,
        url_path: &str,
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        // A redirected request could drop its bearer and make a valid account look unauthorized.
        let resp = self
            .send_direct_authenticated_stream(
                &format!("stream {url_path}"),
                self.no_redirect_http.get(format!("{}{}", self.base_url, url_path)),
            )
            .await?;
        Ok(response_to_lines(resp))
    }
}

/// Shared by every streaming/long-poll endpoint (`stream_lines`, `create_seek`,
/// `create_challenge`): turns a successful response's body into a stream of lines.
fn response_to_lines(
    resp: reqwest::Response,
) -> std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>> {
    lines_from_chunks(resp.bytes_stream())
}

// HTTP chunks can split a UTF-8 character. Decoding each chunk corrupts it,
// while buffering the entire response never delivers a live board update.
fn lines_from_chunks<C, E>(
    chunks: impl futures_util::Stream<Item = Result<C, E>> + Send + 'static,
) -> std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>
where
    C: AsRef<[u8]> + Send,
    E: std::fmt::Display + Send,
{
    struct State<S> {
        chunks: std::pin::Pin<Box<S>>,
        carry: Vec<u8>,
        pending: std::collections::VecDeque<String>,
        chunks_exhausted: bool,
    }

    let state = State {
        chunks: Box::pin(chunks),
        carry: Vec::new(),
        pending: std::collections::VecDeque::new(),
        chunks_exhausted: false,
    };

    Box::pin(futures_util::stream::unfold(state, |mut state| async move {
        loop {
            if let Some(line) = state.pending.pop_front() {
                return Some((line, state));
            }
            if state.chunks_exhausted {
                return None;
            }
            match state.chunks.next().await {
                Some(Ok(chunk)) => {
                    for segment in chunk.as_ref().split_inclusive(|byte| *byte == b'\n') {
                        if let Some(body) = segment.strip_suffix(b"\n") {
                            state.carry.extend_from_slice(body);
                            state.pending.push_back(String::from_utf8_lossy(&state.carry).into_owned());
                            state.carry.clear();
                        } else {
                            state.carry.extend_from_slice(segment);
                        }
                    }
                }
                Some(Err(error)) => {
                    log::warn!("stream chunk read error: {error}");
                    return None;
                }
                None => {
                    // Only a clean close can complete a record without a newline.
                    if state.carry.is_empty() {
                        return None;
                    }
                    state.chunks_exhausted = true;
                    let line = String::from_utf8_lossy(&state.carry).into_owned();
                    return Some((line, state));
                }
            }
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::{TcpListener, TcpStream};
    use tokio::sync::oneshot;
    use wiremock::matchers::{body_string_contains, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    async fn accept_http_request(server: TcpListener) -> BufReader<TcpStream> {
        let (socket, _) = server.accept().await.unwrap();
        let mut socket = BufReader::new(socket);
        loop {
            let mut header = String::new();
            assert_ne!(socket.read_line(&mut header).await.unwrap(), 0);
            if header == "\r\n" {
                return socket;
            }
        }
    }

    async fn read_http_stream(response: &'static [u8]) -> Vec<String> {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", server.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let mut socket = accept_http_request(server).await;
            socket.write_all(response).await.unwrap();
            socket.shutdown().await.unwrap();
        });
        let client = LichessClient::with_base_url("test-token".into(), endpoint);
        let lines = client.stream_lines("/test").await.unwrap();
        let result = lines.collect().await;
        task.await.unwrap();
        result
    }

    async fn stalled_stream_error(response: &'static [u8], request_timeout: Duration) -> anyhow::Error {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", server.local_addr().unwrap());
        let (sent, observed) = oneshot::channel();
        let (release, hold) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut socket = accept_http_request(server).await;
            socket.write_all(response).await.unwrap();
            sent.send(()).unwrap();
            let _ = hold.await;
        });
        let mut client = LichessClient::with_base_url("test-token".into(), endpoint);
        client.request_timeout = request_timeout;
        let result = tokio::time::timeout(Duration::from_secs(2), client.stream_lines("/test")).await;
        release.send(()).unwrap();
        task.await.unwrap();
        observed.await.expect("HTTP peer must have accepted the request");
        result.expect("stream setup should finish before the observation deadline").err().unwrap()
    }

    #[tokio::test]
    async fn stalled_stream_headers_return_a_timeout() {
        let error = stalled_stream_error(b"", Duration::from_millis(200)).await;
        assert!(error.to_string().contains("timed out waiting for Lichess"), "{error}");
    }

    #[tokio::test]
    async fn stalled_stream_error_body_keeps_the_http_status() {
        let error = stalled_stream_error(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 80\r\n\r\n{\"error\":\"partial",
            Duration::from_millis(200),
        ).await;
        assert!(is_auth_rejection(&error));
        assert_eq!(board_stream_rejection(&error), Some("Lichess denied access to this board."));
    }

    #[tokio::test]
    async fn stream_unauthorized_does_not_wait_for_the_error_body() {
        let error = stalled_stream_error(
            b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 80\r\n\r\n",
            Duration::from_secs(20),
        ).await;
        assert!(is_unauthorized(&error));
    }

    #[tokio::test]
    async fn successful_response_body_survives_its_setup_deadline() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", server.local_addr().unwrap());
        let (release, hold) = oneshot::channel();
        let server = tokio::spawn(async move {
            let mut socket = accept_http_request(server).await;
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nfirst\n\r\n").await.unwrap();
            hold.await.unwrap();
            socket.write_all(b"7\r\nsecond\n\r\n0\r\n\r\n").await.unwrap();
        });

        let mut client = LichessClient::with_base_url("test-token".into(), endpoint);
        client.request_timeout = Duration::from_millis(200);
        let mut lines = client.stream_lines("/test").await.unwrap();
        assert_eq!(lines.next().await.as_deref(), Some("first"));
        assert!(tokio::time::timeout(client.request_timeout * 2, lines.next()).await.is_err());
        release.send(()).unwrap();
        assert_eq!(lines.next().await.as_deref(), Some("second"));
        assert!(lines.next().await.is_none());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn streamed_json_preserves_utf8_split_between_http_chunks() {
        let lines = read_http_stream(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\na\r\n{\"name\":\"\xc3\r\n4\r\n\xa9\"}\n\r\n0\r\n\r\n",
        ).await;
        assert_eq!(lines, [r#"{"name":"é"}"#]);
    }

    #[tokio::test]
    async fn interrupted_http_stream_keeps_complete_lines_and_discards_the_tail() {
        let lines = read_http_stream(
            b"HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\ncomplete\n{\"done\":\"accepted\"}",
        ).await;
        assert_eq!(lines, ["complete"]);
    }

    #[tokio::test]
    async fn board_stream_distinguishes_game_rejection_from_other_http_failures() {
        let server = MockServer::start().await;
        for status in [400, 401, 403, 404, 429, 503] {
            Mock::given(method("GET"))
                .and(path(format!("/api/board/game/stream/{status}")))
                .respond_with(ResponseTemplate::new(status))
                .mount(&server)
                .await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for (status, rejected) in [
            (400, true), (401, false), (403, true), (404, true), (429, false), (503, false),
        ] {
            let failure = client.stream_lines(&format!("/api/board/game/stream/{status}")).await.err().unwrap();
            assert_eq!(board_stream_rejection(&failure).is_some(), rejected, "HTTP {status}");
            assert_eq!(is_unauthorized(&failure), status == 401, "HTTP {status}");
        }
    }

    #[tokio::test]
    async fn lines_from_chunks_reassembles_a_json_line_split_across_two_chunks() {
        // The exact E1 regression scenario: an HTTP chunk boundary lands
        // mid-line. A plain per-chunk `.lines()` call would previously yield
        // two unparseable fragments here instead of one complete line.
        let chunks = vec![
            Ok::<_, reqwest::Error>(br#"{"type":"gameState","statu"#.as_slice()),
            Ok(b"s\":\"started\"}\n".as_slice()),
        ];
        let mut lines = lines_from_chunks(futures_util::stream::iter(chunks));
        let mut collected = Vec::new();
        while let Some(line) = lines.next().await {
            collected.push(line);
        }
        assert_eq!(collected, vec![r#"{"type":"gameState","status":"started"}"#.to_string()]);
    }

    #[tokio::test]
    async fn lines_from_chunks_splits_multiple_complete_lines_from_one_chunk() {
        let chunks = [Ok::<_, reqwest::Error>(b"line-one\nline-two\nline-three\n")];
        let mut lines = lines_from_chunks(futures_util::stream::iter(chunks));
        let mut collected = Vec::new();
        while let Some(line) = lines.next().await {
            collected.push(line);
        }
        assert_eq!(collected, vec!["line-one".to_string(), "line-two".to_string(), "line-three".to_string()]);
    }

    #[tokio::test]
    async fn lines_from_chunks_flushes_a_trailing_line_with_no_final_newline() {
        // The connection closing right after the last line, before a
        // trailing '\n' arrives, must still surface that line rather than
        // silently dropping it.
        let chunks = [Ok::<_, reqwest::Error>(b"complete\nincomplete-tail")];
        let mut lines = lines_from_chunks(futures_util::stream::iter(chunks));
        let mut collected = Vec::new();
        while let Some(line) = lines.next().await {
            collected.push(line);
        }
        assert_eq!(collected, vec!["complete".to_string(), "incomplete-tail".to_string()]);
    }

    #[tokio::test]
    async fn is_reachable_accepts_any_reply_including_an_error_status() {
        let server = MockServer::start().await;
        // 404 on HEAD / is still proof the host answered.
        assert!(is_reachable(&server.uri()).await);
    }

    #[tokio::test]
    async fn is_reachable_reports_false_when_nothing_is_listening() {
        // Bind a port, learn its number, then drop it so the connect refuses.
        let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let dead = format!("http://{}", taken.local_addr().unwrap());
        drop(taken);
        assert!(!is_reachable(&dead).await);
    }

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
    async fn token_metadata_reads_only_the_submitted_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/token/test"))
            .and(header("Content-Type", "text/plain"))
            .and(header("User-Agent", "remarkable-lichess"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "test-token": { "userId": "player", "scopes": "challenge:read, board:play" },
                "other-token": null
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let grant = client.get_token_grant().await.unwrap().unwrap();
        assert_eq!(grant.user_id, "player");
        assert_eq!(grant.scopes, "challenge:read, board:play");
        let requests = server.received_requests().await.unwrap();
        assert_eq!(requests[0].body, b"test-token");
        assert!(!requests[0].headers.contains_key("authorization"));
    }

    #[tokio::test]
    async fn token_metadata_preserves_neither_redirects_nor_echoed_errors() {
        let server = MockServer::start().await;
        let redirected = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/token/test"))
            .respond_with(ResponseTemplate::new(307)
                .insert_header("Location", redirected.uri().as_str())
                .set_body_string("test-token"))
            .mount(&server)
            .await;
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let error = client.get_token_grant().await.err().expect("refuse the redirect");
        assert!(error.to_string().contains("307"));
        assert!(!error.to_string().contains("test-token"));
        assert!(redirected.received_requests().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_account_check_distinguishes_rejection_from_temporary_failure() {
        for (status, rejected) in [(401, true), (403, true), (429, false), (503, false)] {
            let server = MockServer::start().await;
            Mock::given(method("GET"))
                .and(path("/api/account"))
                .respond_with(ResponseTemplate::new(status))
                .mount(&server)
                .await;
            let client = LichessClient::with_base_url("test-token".into(), server.uri());
            let error = client.get_account().await.unwrap_err();
            assert_eq!(is_auth_rejection(&error), rejected, "HTTP {status}");
        }
    }

    #[tokio::test]
    async fn account_reads_refuse_redirects_before_classifying_rejection() {
        let server = MockServer::start().await;
        let other = MockServer::start().await;
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(401)).mount(&other).await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(307).insert_header("Location", other.uri().as_str()))
            .mount(&server)
            .await;
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let errors = [
            client.get_account().await.err(),
            client.get_playing().await.err(),
            client.stream_lines("/api/stream/event").await.err(),
            client.stream_lines("/api/board/game/stream/game1234").await.err(),
        ];
        for error in errors {
            let error = error.expect("account read must refuse the redirect");
            assert_eq!(error.downcast_ref::<HttpResponseError>().unwrap().status,
                reqwest::StatusCode::TEMPORARY_REDIRECT);
        }
        assert!(other.received_requests().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_playing_parses_now_playing_list() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account/playing"))
            .and(query_param("nb", "50"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "nowPlaying": [
                    {"gameId": "g1", "isMyTurn": true, "speed": "correspondence", "secondsLeft": 90061},
                    {"gameId": "g2", "isMyTurn": true}
                ]
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_playing().await.unwrap();
        assert_eq!(games.len(), 2);
        assert_eq!(games[0].game_id, "g1");
        assert_eq!(games[0].speed.as_deref(), Some("correspondence"));
        assert_eq!(games[0].seconds_left, Some(90061));
        assert!(games[1].seconds_left.is_none());
    }

    #[tokio::test]
    async fn get_user_statuses_is_a_single_bounded_metadata_request() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/users/status"))
            .and(query_param("ids", "alice,bob"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"id": "alice", "name": "Alice", "online": true},
                {"id": "bob", "name": "Bob", "playing": true, "patronColor": 2}
            ])))
            .expect(1)
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let rows = client
            .get_user_statuses(&["alice".into(), "bob".into()])
            .await
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows[0].online);
        assert_eq!(rows[1].patron_color, Some(2));
    }

    #[tokio::test]
    async fn get_game_history_requests_opening_and_accuracy_without_moves() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        let mut analyzed = serde_json::json!({
            "id": "abcd1234", "rated": true, "variant": "standard", "speed": "rapid",
            "perf": "rapid", "createdAt": 1, "lastMoveAt": 2, "status": "mate",
            "players": {
                "white": {"user": {"id": "myuser", "name": "MyUser"}, "rating": 1600},
                "black": {"user": {"id": "bob", "name": "Bob"}, "rating": 1580}
            },
            "winner": "white"
        });
        let mut unanalyzed = analyzed.clone();
        unanalyzed["id"] = serde_json::json!("abcd1235");
        analyzed["opening"] = serde_json::json!({"eco": "C60", "name": "Ruy Lopez", "ply": 5});
        analyzed["players"]["white"]["analysis"] = serde_json::json!({
            "accuracy": 0, "inaccuracy": 1, "mistake": 2, "blunder": 0
        });
        Mock::given(method("GET"))
            .and(path("/api/games/user/myuser"))
            .and(query_param("max", "20"))
            .and(query_param("opening", "true"))
            .and(query_param("accuracy", "true"))
            .and(query_param("moves", "false"))
            .and(header("Accept", "application/x-ndjson"))
            .respond_with(ResponseTemplate::new(200).set_body_string(format!("{analyzed}\n{unanalyzed}\n")))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_game_history("myuser", 20, &GameHistoryFilters::default(), None).await.unwrap();
        assert_eq!(games.len(), 2);
        assert_eq!(games[0].id, "abcd1234");
        assert_eq!(games[0].opening.as_ref().unwrap().name, "Ruy Lopez");
        let stats = games[0].players.white.analysis.as_ref().unwrap();
        assert_eq!(stats.accuracy, Some(0));
        assert_eq!(stats.acpl, None);
        assert_eq!(games[1].id, "abcd1235");
        assert!(games[1].opening.is_none() && games[1].players.white.analysis.is_none());
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
        client.get_game_history("myuser", 20, &filters, None).await.unwrap();
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
        let games = client.get_game_history("newplayer", 20, &GameHistoryFilters::default(), None).await.unwrap();
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
        let err = client.get_game_history("myuser", 20, &GameHistoryFilters::default(), None).await.unwrap_err();
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
        let err = client.get_game_history("myuser", 20, &GameHistoryFilters::default(), None).await.unwrap_err();
        assert!(err.to_string().contains("No such user"));
    }

    #[tokio::test]
    async fn history_pages_keep_tied_games_even_when_the_server_reorders_them() {
        use std::collections::BTreeSet;
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        let cutoff = 1_765_526_400_000_i64;
        let until = (cutoff + 1).to_string();
        let body = |ids: Vec<usize>| {
            ids.into_iter().map(|number| serde_json::json!({
                "id": format!("arch{number:04}"),
                "createdAt": if number < 43 { cutoff } else { cutoff - 1 },
                "players": { "white": {}, "black": {} },
            }).to_string()).collect::<Vec<_>>().join("\n")
        };
        for (max, ids) in [
            (21, (0..21).collect()),
            (41, (0..41).rev().collect()),
            (61, (0..43).rev().chain(43..45).collect()),
        ] {
            let mut mock = Mock::given(method("GET"))
                .and(path("/api/games/user/myuser"))
                .and(query_param("max", max.to_string()))
                .and(query_param("rated", "true"))
                .and(query_param("perfType", "rapid"))
                .and(query_param("color", "black"));
            if max > 21 {
                mock = mock.and(query_param("until", until.clone()));
            }
            mock.respond_with(ResponseTemplate::new(200).set_body_string(body(ids)))
                .expect(1)
                .mount(&server)
                .await;
        }

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let filters = GameHistoryFilters {
            rated: Some(true), speed: Some("rapid".into()), color: Some("black".into()),
        };
        let mut cursor = None;
        let mut received = BTreeSet::new();
        for expected in [20, 20, 5] {
            let (games, older) = client.get_game_history_page("myuser", &filters, cursor).await.unwrap();
            assert_eq!(games.len(), expected);
            for game in games {
                assert!(received.insert(game.id));
            }
            if let Some(page) = &older {
                assert_eq!(page.until_ms, cutoff + 1);
                assert_eq!(page.seen_at_cutoff, received);
            }
            cursor = older;
        }
        assert!(cursor.is_none());
        assert_eq!(received, (0..45).map(|i| format!("arch{i:04}")).collect());
    }

    #[tokio::test]
    async fn damaged_history_lookahead_is_an_error_instead_of_the_end_of_the_archive() {
        let server = MockServer::start().await;
        let first_twenty = (0..20).map(|number| serde_json::json!({
            "id": format!("arch{number:04}"), "createdAt": 1_765_526_400_000_i64 - number,
            "players": { "white": {}, "black": {} },
        }).to_string()).collect::<Vec<_>>().join("\n");
        for (endpoint, lookahead) in [
            ("truncated", r#"{"id":"bad"#),
            ("undated", r#"{"id":"arch0020","players":{"white":{},"black":{}}}"#),
        ] {
            Mock::given(method("GET"))
                .and(path(format!("/api/games/user/{endpoint}")))
                .respond_with(ResponseTemplate::new(200)
                    .set_body_string(format!("{first_twenty}\n{lookahead}\n")))
                .mount(&server)
                .await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for (endpoint, expected) in [("truncated", "didn't parse as NDJSON"),
            ("undated", "did not provide a date")] {
            let error = client.get_game_history_page(endpoint, &GameHistoryFilters::default(), None)
                .await.unwrap_err();
            assert!(error.to_string().contains(expected), "{error}");
        }
    }

    #[tokio::test]
    async fn history_and_exports_do_not_follow_redirects() {
        let server = MockServer::start().await;
        for (route, media_type) in [
            ("/api/games/user/player", "application/x-ndjson"),
            ("/game/export/abcd1234", "application/json"),
            ("/game/export/abcd1234", "application/x-chess-pgn"),
        ] {
            Mock::given(method("GET")).and(path(route))
                .and(header("Accept", media_type))
                .and(header("Authorization", "Bearer test-token"))
                .respond_with(ResponseTemplate::new(307).insert_header("Location", "/unexpected"))
                .expect(1).mount(&server).await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let game = PgnGameId::parse("abcd1234".into()).unwrap();
        for error in [
            client.get_game_history_page("player", &GameHistoryFilters::default(), None).await.unwrap_err(),
            client.export_game("abcd1234").await.unwrap_err(),
            client.export_pgn(game).await.err().expect("a redirected PGN export must fail"),
        ] {
            assert_eq!(error.downcast_ref::<HttpResponseError>().unwrap().status,
                reqwest::StatusCode::TEMPORARY_REDIRECT);
        }
        assert_eq!(server.received_requests().await.unwrap().len(), 3);
    }

    #[tokio::test]
    async fn export_game_sends_accept_json_header_and_parses_custom_position() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/game/export/abcd1234"))
            .and(header("Accept", "application/json"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "abcd1234",
                "rated": false,
                "status": "resign",
                "variant": "fromPosition",
                "initialFen": "4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17",
                "moves": "e5 a4"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let export = client.export_game("abcd1234").await.unwrap();
        assert_eq!(export.moves, "e5 a4");
        assert_eq!(export.variant.as_deref(), Some("fromPosition"));
        assert_eq!(export.initial_fen.as_deref(), Some("4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17"));
    }

    #[tokio::test]
    async fn export_game_surfaces_lichess_error_body() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/game/export/missing"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "error": "No such game"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.export_game("missing").await.unwrap_err();
        assert!(err.to_string().contains("No such game"));
    }

    #[tokio::test]
    async fn export_game_does_not_surface_html_error_pages() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/game/export/missing"))
            .respond_with(ResponseTemplate::new(404).set_body_string(
                "<!DOCTYPE html><html><body>A very large error page</body></html>",
            ))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let err = client.export_game("missing").await.unwrap_err().to_string();
        assert_eq!(err, "export_game failed with status 404 Not Found");
    }

    #[tokio::test]
    async fn cloud_evaluation_sends_fen_and_parses_best_line() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        Mock::given(method("GET"))
            .and(path("/api/cloud-eval"))
            .and(query_param("fen", fen))
            .and(query_param("multiPv", "1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "depth": 31,
                "fen": fen,
                "knodes": 123456,
                "pvs": [{"cp": 24, "moves": "e2e4 e7e5 g1f3"}]
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let evaluation = client.get_cloud_evaluation(fen).await.unwrap().unwrap();
        assert_eq!(evaluation.depth, 31);
        assert_eq!(evaluation.pvs[0].cp, Some(24));
        assert_eq!(evaluation.pvs[0].moves, "e2e4 e7e5 g1f3");
    }

    #[tokio::test]
    async fn cloud_evaluation_returns_none_when_position_is_not_cached() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/cloud-eval"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "error": "No cloud evaluation available for that position"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        assert_eq!(client.get_cloud_evaluation("8/8/8/8/8/8/8/K6k w - - 0 1").await.unwrap(), None);
    }

    #[tokio::test]
    async fn opening_explorer_only_authenticates_the_rated_database_and_refuses_redirects() {
        use wiremock::matchers::query_param;

        let server = MockServer::start().await;
        let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        Mock::given(method("GET")).and(path("/masters"))
            .and(query_param("fen", fen)).and(query_param("play", "e2e4,e7e5"))
            .and(query_param("moves", "12")).and(query_param("topGames", "0"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "white": 5, "draws": 3, "black": 4,
                "opening": {"eco": "C20", "name": "King's Pawn Game"},
                "moves": [{"san": "Nf3", "uci": "g1f3", "white": 3, "draws": 2, "black": 2}],
            }))).expect(1).mount(&server).await;
        Mock::given(method("GET")).and(path("/lichess"))
            .and(header("Authorization", "Bearer test-token")).and(query_param("recentGames", "0"))
            .respond_with(ResponseTemplate::new(302).insert_header("Location", "/unexpected"))
            .expect(1).mount(&server).await;
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let data = client.get_opening_explorer_at(&server.uri(), OpeningDatabase::Masters, fen,
                                                &["e2e4".into(), "e7e5".into()]).await.unwrap();
        assert_eq!(data.opening.unwrap().eco, "C20");
        assert_eq!(data.moves[0].san, "Nf3");
        assert!(client.get_opening_explorer_at(&server.uri(), OpeningDatabase::Lichess, fen, &[]).await.is_err());
        let requests = server.received_requests().await.unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].headers.get("authorization").is_none());
        assert_eq!(requests[1].url.path(), "/lichess");
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
    async fn make_move_times_out_when_server_never_answers_promptly() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/move/d7d5"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_delay(std::time::Duration::from_millis(200)),
            )
            .mount(&server)
            .await;

        let mut client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.request_timeout = std::time::Duration::from_millis(20);
        let error = client.make_move("g1", "d7d5").await.unwrap_err();
        assert!(error
            .downcast_ref::<reqwest::Error>()
            .is_some_and(reqwest::Error::is_timeout));
    }

    #[tokio::test]
    async fn board_post_unauthorized_does_not_wait_for_the_error_body() {
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", server.local_addr().unwrap());
        let (release, hold) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut socket = accept_http_request(server).await;
            socket.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 80\r\n\r\n").await.unwrap();
            hold.await.unwrap();
        });

        let client = LichessClient::with_base_url("test-token".into(), endpoint);
        let result = tokio::time::timeout(Duration::from_secs(2), client.make_move("g1", "e2e4")).await;
        release.send(()).unwrap();
        task.await.unwrap();
        assert!(is_unauthorized(&result.expect("401 headers should complete the request").unwrap_err()));
    }

    #[tokio::test]
    async fn board_posts_do_not_follow_redirects() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/move/e2e4"))
            .and(header("Authorization", "Bearer test-token"))
            .respond_with(ResponseTemplate::new(307).insert_header("Location", "/unexpected"))
            .expect(1).mount(&server).await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/draw/true"))
            .and(header("Authorization", "Bearer test-token"))
            .respond_with(ResponseTemplate::new(307).insert_header("Location", "/unexpected"))
            .expect(1).mount(&server).await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for error in [
            client.make_move("g1", "e2e4").await.unwrap_err(),
            client.draw("g1", true).await.unwrap_err(),
        ] {
            assert_eq!(error.downcast_ref::<HttpResponseError>().unwrap().status,
                reqwest::StatusCode::TEMPORARY_REDIRECT);
        }
        assert_eq!(server.received_requests().await.unwrap().len(), 2);
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
    async fn berserk_posts_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/berserk"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.berserk("g1").await.unwrap();
    }

    #[tokio::test]
    async fn add_time_posts_to_round_endpoint() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/round/g1/add-time/15"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.add_time("g1", 15).await.unwrap();
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
    async fn match_creation_does_not_follow_redirects() {
        let server = MockServer::start().await;
        for route in ["/api/board/seek", "/api/challenge/opponent", "/api/challenge/ai", "/api/challenge/open"] {
            Mock::given(method("POST")).and(path(route))
                .and(header("Authorization", "Bearer test-token"))
                .respond_with(ResponseTemplate::new(307).insert_header("Location", "/unexpected"))
                .expect(1).mount(&server).await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for error in [
            client.create_seek(10, 0, false, "random").await.err(),
            client.create_challenge("opponent", 10, 0, false, "random").await.err(),
            client.challenge_ai(3, 10, 0, "random").await.err(),
            client.create_open_challenge(10, 0, false).await.err(),
        ] {
            let error = error.expect("a redirected request must fail");
            assert_eq!(error.downcast_ref::<HttpResponseError>().unwrap().status,
                reqwest::StatusCode::TEMPORARY_REDIRECT);
        }
        assert_eq!(server.received_requests().await.unwrap().len(), 4);
    }

    #[tokio::test]
    async fn create_challenge_posts_to_username_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/opponent"))
            .respond_with(ResponseTemplate::new(200).set_body_string("\n{\"id\":\"direct01\"}\n{\"done\":\"accepted\"}\n"))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let (id, mut lines) = client.create_challenge("opponent", 10, 5, false, "random").await.unwrap();
        assert_eq!(id, "direct01");
        assert_eq!(lines.next().await.as_deref(), Some(r#"{"done":"accepted"}"#));
    }

    #[tokio::test]
    async fn direct_challenge_checks_usernames_before_sending() {
        let server = MockServer::start().await;
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for username in ["", "a", "two words", "José", "chess.example", &"a".repeat(31)] {
            let result = client.create_challenge(username, 10, 0, false, "white").await;
            assert!(result.err().is_some_and(|error| error.to_string().contains("username")), "{username:?}");
        }
        assert!(server.received_requests().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn direct_challenge_names_use_the_player_route() {
        let server = MockServer::start().await;
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let longest_name = "abcdefghijklmnopqrstuvwxy12345";
        for (username, expected) in [
            ("ai", "AI"),
            ("open", "Open"),
            ("oPeN", "oPeN"),
            (" 1_Friend- ", "1_Friend-"),
            (longest_name, longest_name),
        ] {
            Mock::given(method("POST"))
                .and(path(format!("/api/challenge/{expected}")))
                .respond_with(ResponseTemplate::new(200).set_body_string("{\"id\":\"direct01\"}\n"))
                .expect(1)
                .mount(&server)
                .await;
            let (id, _) = client.create_challenge(username, 10, 0, false, "white").await.unwrap();
            assert_eq!(id, "direct01");
        }
    }

    #[tokio::test]
    async fn challenge_ai_posts_level_clock_and_color() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/challenge/ai"))
            .and(body_string_contains("level=3"))
            .and(body_string_contains("clock.limit=300"))
            .and(body_string_contains("clock.increment=2"))
            .and(body_string_contains("color=black"))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!({"id": "computer"})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        assert_eq!(client.challenge_ai(3, 5, 2, "black").await.unwrap(), "computer");
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
            .respond_with(ResponseTemplate::new(200).set_body_string("{\"id\":\"direct01\"}\n"))
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
    async fn invitation_requests_do_not_follow_redirects() {
        let server = MockServer::start().await;
        for (verb, route) in [
            ("GET", "/api/challenge"),
            ("GET", "/api/challenge/invite01/show"),
            ("POST", "/api/challenge/invite01/accept"),
            ("POST", "/api/challenge/invite01/decline"),
        ] {
            Mock::given(method(verb)).and(path(route))
                .and(header("Authorization", "Bearer test-token"))
                .respond_with(ResponseTemplate::new(307).insert_header("Location", "/unexpected"))
                .expect(1).mount(&server).await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        for error in [
            client.get_challenges().await.unwrap_err(),
            client.get_challenge_terms("invite01").await.unwrap_err(),
            client.accept_challenge("invite01").await.unwrap_err(),
            client.decline_challenge("invite01").await.unwrap_err(),
        ] {
            assert_eq!(error.downcast_ref::<HttpResponseError>().unwrap().status,
                reqwest::StatusCode::TEMPORARY_REDIRECT);
        }
        assert_eq!(server.received_requests().await.unwrap().len(), 4);
    }

    #[tokio::test]
    async fn get_challenges_parses_incoming_list() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/challenge"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "in": [
                    {"id": "c1", "challenger": {"id": "opp", "name": "Opponent"},
                     "timeControl": {"limit": 600, "increment": 0}},
                    {"id": "c2", "challenger": {"id": "opp", "name": "Opponent"},
                     "timeControl": {"type": "correspondence", "daysPerTurn": 3}},
                    {"id": "c3", "challenger": {"id": "opp", "name": "Opponent"},
                     "timeControl": {"type": "unlimited"}},
                    {"id": "c4", "challenger": {"id": "opp", "name": "Opponent"},
                     "timeControl": {"type": "future"}},
                    {"id": "c5", "challenger": {"id": "opp", "name": "Opponent"}}
                ],
                "out": []
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let challenges = client.get_challenges().await.unwrap();
        assert_eq!(challenges.len(), 5);
        assert_eq!(challenges[0].id, "c1");
        assert_eq!(challenges[0].challenger.name, "Opponent");
        let clocks = challenges.iter().filter_map(|c| c.terms.time_control.as_ref()).collect::<Vec<_>>();
        assert_eq!(clocks[0].limit, Some(600));
        assert_eq!(clocks[0].increment, Some(0));
        assert_eq!(clocks[1].kind.as_deref(), Some("correspondence"));
        assert_eq!(clocks[1].days_per_turn, Some(3));
        assert_eq!(clocks[2].kind.as_deref(), Some("unlimited"));
        assert_eq!(clocks[3].kind.as_deref(), Some("future"));
        assert_eq!(challenges[4].terms.time_control, None);
    }

    #[tokio::test]
    async fn only_a_challenge_read_scope_denial_stops_list_retries() {
        for (status, reason, denied) in [
            (403, "Missing scope: challenge:read", true),
            (403, "Missing scope: board:play", false),
            (403, "Access denied", false),
            (503, "Missing scope: challenge:read", false),
        ] {
            let server = MockServer::start().await;
            Mock::given(method("GET"))
                .and(path("/api/challenge"))
                .respond_with(ResponseTemplate::new(status).set_body_json(serde_json::json!({"error": reason})))
                .mount(&server)
                .await;
            let client = LichessClient::with_base_url("test-token".into(), server.uri());
            assert_eq!(is_challenge_read_denial(&client.get_challenges().await.unwrap_err()), denied);
        }
    }

    #[tokio::test]
    async fn get_challenge_terms_checks_the_requested_identity() {
        let server = MockServer::start().await;
        for requested in ["matching", "different"] {
            Mock::given(method("GET"))
                .and(path(format!("/api/challenge/{requested}/show")))
                .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "id": "matching", "variant": {"key": "fromPosition", "name": "From Position"},
                    "speed": "blitz", "timeControl": {"type": "clock", "limit": 180, "increment": 0}
                })))
                .mount(&server)
                .await;
        }
        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let terms = client.get_challenge_terms("matching").await.unwrap();
        assert_eq!(terms.variant.unwrap().key, "fromPosition");
        assert_eq!(terms.speed.as_deref(), Some("blitz"));
        assert_eq!(terms.time_control.unwrap().limit, Some(180));
        let error = client.get_challenge_terms("different").await.unwrap_err();
        assert!(error.to_string().contains("another challenge"));
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
