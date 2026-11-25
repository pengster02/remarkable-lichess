use appload_client::AppLoad;
use backend::backend_app::LichessBackend;
use backend::credentials;

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
    // One directory keeps settings alongside the token across AppLoad and Docker.
    // A token-only override would split their defaults, and HOME differs by launcher.
    let token_path = credentials::token_path(std::env::var_os("REMARKABLE_LICHESS_CONFIG_DIR"));
    if let Some(parent) = token_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // A bare `.unwrap()` here used to panic with an unstructured backtrace on
    // either failure -- log a clean, greppable error through the logger this
    // file already just initialized instead, matching how every other error
    // in this backend is surfaced.
    let qr_sign_in_available = !matches!(std::env::var("REMARKABLE_LICHESS_SIGN_IN").as_deref(), Ok("token"));
    let backend = LichessBackend::new(token_path).with_qr_sign_in_available(qr_sign_in_available);
    let mut app = match AppLoad::new(backend) {
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
