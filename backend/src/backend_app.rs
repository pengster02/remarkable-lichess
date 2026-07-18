use crate::game::session::GameSession;
use crate::lichess::client::LichessClient;
use crate::lichess::models::{EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use crate::protocol::{BackendMessage, FrontendMessage, MSG_TYPE_BACKEND_TO_FRONTEND};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

pub struct LichessBackend {
    token_path: PathBuf,
    client: Option<LichessClient>,
    session: Arc<Mutex<Option<GameSession>>>,
}

impl LichessBackend {
    pub fn new(token_path: PathBuf) -> Self {
        Self { token_path, client: None, session: Arc::new(Mutex::new(None)) }
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
                self.spawn_streams(replier.clone());
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
        let Some(client) = self.client.clone() else { return };
        let result = {
            let guard = self.session.lock().await;
            let Some(session) = guard.as_ref() else { return };
            session
                .try_move(&from, &to, promotion.as_deref())
                .map(|uci| (uci, session.game_id.clone()))
        };
        match result {
            Ok((uci, game_id)) => {
                if let Err(e) = client.make_move(&game_id, &uci).await {
                    self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                }
                // The authoritative BoardState update arrives via the game stream, not here.
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }

    pub fn spawn_streams(&self, replier: BackendReplier<Self>) {
        let Some(client) = self.client.clone() else { return };
        let session_handle = self.session.clone();
        tokio::spawn(async move {
            loop {
                match client.stream_lines("/api/stream/event").await {
                    Ok(mut lines) => {
                        use futures_util::StreamExt;
                        while let Some(line) = lines.next().await {
                            if let Some(EventStreamMessage::GameStart { game }) =
                                parse_ndjson_line::<EventStreamMessage>(&line)
                            {
                                spawn_game_stream(client.clone(), game.id, replier.clone(), session_handle.clone());
                            }
                        }
                    }
                    Err(_) => {
                        let json = serde_json::to_string(&BackendMessage::Reconnecting).unwrap();
                        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            }
        });
    }
}

fn spawn_game_stream(
    client: LichessClient,
    game_id: String,
    replier: BackendReplier<LichessBackend>,
    session_handle: Arc<Mutex<Option<GameSession>>>,
) {
    tokio::spawn(async move {
        use futures_util::StreamExt;
        if let Ok(mut lines) = client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await {
            while let Some(line) = lines.next().await {
                if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                    let mut guard = session_handle.lock().await;
                    let board_msg = match (&mut *guard, msg) {
                        (None, GameStreamMessage::Full(full)) => {
                            match GameSession::from_game_full(&full) {
                                Ok((s, board_msg)) => {
                                    *guard = Some(s);
                                    Some(board_msg)
                                }
                                Err(_) => None,
                            }
                        }
                        (Some(s), GameStreamMessage::State(state)) => {
                            let is_over = state.status != "started";
                            let result = s.apply_state_update(&state).ok();
                            if is_over {
                                Some(BackendMessage::GameOver {
                                    result: state.winner.clone().unwrap_or_else(|| "draw".into()),
                                    reason: state.status.clone(),
                                })
                            } else {
                                result
                            }
                        }
                        _ => None,
                    };
                    drop(guard);
                    if let Some(m) = board_msg {
                        let json = serde_json::to_string(&m).unwrap();
                        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                    }
                }
            }
        }
    });
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
                if let Some(client) = self.client.clone() {
                    let game_id = {
                        let guard = self.session.lock().await;
                        guard.as_ref().map(|s| s.game_id.clone())
                    };
                    if let Some(game_id) = game_id {
                        let _ = client.resign(&game_id).await;
                    }
                }
            }
        }
    }
}
