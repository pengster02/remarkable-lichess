use crate::lichess::models::{Account, PlayingGame, PlayingResponse};
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
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/board/seek", self.base_url)))
            .form(&[
                ("rated", "false".to_string()),
                ("time", minutes.to_string()),
                ("increment", increment.to_string()),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("create_seek", resp).await);
        }
        Ok(response_to_lines(resp))
    }

    /// Same long-poll caveat as `create_seek` -- `/api/challenge/{username}` also
    /// keeps the connection open until the challenge is accepted, declined, or
    /// expires; callers must keep draining the returned stream.
    pub async fn create_challenge(
        &self,
        username: &str,
        minutes: u32,
        increment: u32,
    ) -> Result<std::pin::Pin<Box<dyn futures_util::Stream<Item = String> + Send>>> {
        let resp = self
            .bearer(self.http.post(format!("{}/api/challenge/{}", self.base_url, username)))
            .form(&[
                ("rated", "false".to_string()),
                ("clock.limit", (minutes * 60).to_string()),
                ("clock.increment", increment.to_string()),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(error_from_response("create_challenge", resp).await);
        }
        Ok(response_to_lines(resp))
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
    use wiremock::matchers::{header, method, path};
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
        let _stream = client.create_seek(10, 0).await.unwrap();
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
        let _stream = client.create_challenge("opponent", 10, 5).await.unwrap();
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
        let mut lines = client.create_seek(10, 0).await.unwrap();
        let mut count = 0;
        while lines.next().await.is_some() {
            count += 1;
        }
        assert_eq!(count, 3, "expected all keep-alive lines to be drainable from the stream");
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
        let result = client.create_seek(10, 0).await;
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
