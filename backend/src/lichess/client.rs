use crate::lichess::models::{Account, PlayingGame, PlayingResponse};
use anyhow::{bail, Result};

pub struct LichessClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
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
            bail!("get_account failed with status {}", resp.status());
        }
        Ok(resp.json::<Account>().await?)
    }

    pub async fn get_playing(&self) -> Result<Vec<PlayingGame>> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/account/playing", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("get_playing failed with status {}", resp.status());
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
            bail!("make_move failed with status {}", resp.status());
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
            bail!("resign failed with status {}", resp.status());
        }
        Ok(())
    }
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
}
