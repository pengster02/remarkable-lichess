use appload_client::{AppLoad, AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;

#[tokio::main]
async fn main() {
    AppLoad::new(EchoBackend).unwrap().run().await.unwrap();
}

struct EchoBackend;

#[async_trait]
impl AppLoadBackend for EchoBackend {
    async fn handle_message(&mut self, functionality: &BackendReplier<EchoBackend>, message: Message) {
        match message.msg_type {
            MSG_SYSTEM_NEW_COORDINATOR => println!("A frontend has connected"),
            1 => {
                functionality
                    .send_message(2, &format!("echo: {}", message.contents))
                    .unwrap();
            }
            _ => println!("Unknown message received."),
        }
    }
}
