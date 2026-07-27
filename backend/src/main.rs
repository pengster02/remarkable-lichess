use appload_client::AppLoad;
use backend::backend_app::LichessBackend;
use std::path::PathBuf;

// Only the `production` build installs a logger (see Cargo.toml). Quiet by
// default -- warnings and errors -- but RUST_LOG can raise it to debug on-device
// without a rebuild. A no-op in every other build, where log calls are already
// compiled out.
fn init_logging() {
    #[cfg(feature = "production")]
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("warn"));
}

#[tokio::main]
async fn main() {
    init_logging();
    let token_path = PathBuf::from("/home/root/.config/remarkable-lichess/token");
    if let Some(parent) = token_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // A bare `.unwrap()` here used to panic with an unstructured backtrace on
    // either failure -- log a clean, greppable error through the logger this
    // file already just initialized instead, matching how every other error
    // in this backend is surfaced.
    let mut app = match AppLoad::new(LichessBackend::new(token_path)) {
        Ok(app) => app,
        Err(e) => {
            log::error!("failed to initialize AppLoad: {e}");
            std::process::exit(1);
        }
    };
    if let Err(e) = app.run().await {
        log::error!("AppLoad run loop exited with an error: {e}");
        std::process::exit(1);
    }
}
