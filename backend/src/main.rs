use appload_client::AppLoad;
use backend::backend_app::LichessBackend;
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    let token_path = PathBuf::from("/home/root/.config/remarkable-lichess/token");
    if let Some(parent) = token_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    AppLoad::new(LichessBackend::new(token_path)).unwrap().run().await.unwrap();
}
