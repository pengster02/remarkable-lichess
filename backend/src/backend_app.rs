use crate::game::session::GameSession;
use crate::lichess::client::LichessClient;
use crate::protocol::{BackendMessage, FrontendMessage, MSG_TYPE_BACKEND_TO_FRONTEND};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::path::PathBuf;

pub struct LichessBackend {
    token_path: PathBuf,
    client: Option<LichessClient>,
    session: Option<GameSession>,
}

impl LichessBackend {
    pub fn new(token_path: PathBuf) -> Self {
        Self { token_path, client: None, session: None }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        let json = serde_json::to_string(msg).expect("BackendMessage always serializes");
        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
    }

    async fn handle_save_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        let client = LichessClient::new(token.clone());
        match client.get_account().await {
            Ok(account) => {
                let _ = std::fs::write(&self.token_path, &token);
                self.client = Some(client);
                self.send(replier, &BackendMessage::TokenVerified { username: account.username });
            }
            Err(e) => {
                self.send(replier, &BackendMessage::TokenInvalid { reason: e.to_string() });
            }
        }
    }

    async fn handle_request_home(&mut self, replier: &BackendReplier<Self>) {
        let Some(client) = &self.client else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        match client.get_playing().await {
            Ok(games) => {
                let resumable = games.first().map(|g| g.game_id.clone());
                self.send(replier, &BackendMessage::HomeState { resumable_game_id: resumable });
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    async fn handle_create_seek(&mut self, replier: &BackendReplier<Self>, minutes: u32, increment: u32) {
        let Some(client) = &self.client else { return };
        match client.create_seek(minutes, increment).await {
            Ok(()) => self.send(replier, &BackendMessage::SeekCreated),
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    async fn handle_make_move(&mut self, replier: &BackendReplier<Self>, from: String, to: String, promotion: Option<String>) {
        let (Some(client), Some(session)) = (&self.client, &self.session) else { return };
        match session.try_move(&from, &to, promotion.as_deref()) {
            Ok(uci) => {
                if let Err(e) = client.make_move(&session.game_id, &uci).await {
                    self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                }
                // The authoritative BoardState update arrives via the game stream
                // (wired in a follow-up task covering the streaming loop), not here.
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }
}

#[async_trait]
impl AppLoadBackend for LichessBackend {
    async fn handle_message(&mut self, replier: &BackendReplier<Self>, message: Message) {
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            return;
        }
        let Ok(frontend_msg) = serde_json::from_str::<FrontendMessage>(&message.contents) else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "malformed message from frontend".into() });
            return;
        };
        match frontend_msg {
            FrontendMessage::SaveToken { token } => self.handle_save_token(replier, token).await,
            FrontendMessage::RequestHome => self.handle_request_home(replier).await,
            FrontendMessage::CreateSeek { minutes, increment } => {
                self.handle_create_seek(replier, minutes, increment).await
            }
            FrontendMessage::CreateChallenge { username, minutes, increment } => {
                let Some(client) = &self.client else { return };
                match client.create_challenge(&username, minutes, increment).await {
                    Ok(()) => self.send(replier, &BackendMessage::ChallengeCreated),
                    Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
                }
            }
            FrontendMessage::MakeMove { from, to, promotion } => {
                self.handle_make_move(replier, from, to, promotion).await
            }
            FrontendMessage::Resign => {
                if let (Some(client), Some(session)) = (&self.client, &self.session) {
                    let _ = client.resign(&session.game_id).await;
                }
            }
        }
    }
}
