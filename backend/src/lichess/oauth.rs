//! Lichess OAuth2 authorization-code flow with PKCE, driven entirely from this
//! device with no server of our own.
//!
//! The reMarkable has no web browser, so the user can't complete a consent
//! screen on the tablet itself. Instead we bind a one-shot HTTP listener on the
//! tablet's own Wi-Fi address, put that address in `redirect_uri`, and show the
//! authorize URL as a QR code. The user scans it with a phone, approves on
//! lichess.org, and Lichess redirects the *phone* back to the tablet over the
//! local network, delivering the code. PKCE means the code alone is useless to
//! anyone who intercepts it -- the verifier never leaves this process.
//!
//! Lichess accepts a plain-http redirect to a non-loopback host: lila only
//! flags it (`RedirectUri.insecure` -> a "Does not use a secure connection"
//! notice on the consent screen), it does not reject it. That notice is
//! expected here and is why the sign-in screen says the hop stays on the
//! local network.
//!
//! Alternatives considered: (1) a device-code flow like `gh auth login` -- the
//! best UX by far, but Lichess implements no device authorization grant, so
//! there is nothing to talk to; (2) a hosted relay that catches the redirect
//! and shows a short code to type on the tablet -- works across networks
//! instead of requiring one Wi-Fi, and PKCE keeps the relay unable to spend the
//! code, but it means running and trusting a server for a local-only app.

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sha2::{Digest, Sha256};
use std::net::{IpAddr, Ipv4Addr, UdpSocket};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Lichess requires no app registration -- any `client_id` works and is shown
/// verbatim on the consent screen, so this is user-facing text, not a secret.
pub const CLIENT_ID: &str = "remarkable-lichess";

/// Exactly the scopes this app uses, matching what the old paste-a-token screen
/// told people to tick by hand.
pub const SCOPES: [&str; 4] = [
    "board:play",
    "challenge:read",
    "challenge:write",
    "preference:read",
];

/// How long a displayed QR stays valid before the listener gives up. Long
/// enough to find a phone and log into Lichess on it, short enough that a
/// forgotten sign-in screen doesn't hold a port open indefinitely.
pub const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

const CALLBACK_READ_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_REQUEST_BYTES: usize = 8192;

pub struct PendingLogin {
    pub authorize_url: String,
    redirect_uri: String,
    state: String,
    verifier: String,
    listener: TcpListener,
}

/// Binds the callback listener and builds the URL to display. Fails when the
/// tablet has no routable address, which is the one precondition the user has
/// to fix themselves (connect to Wi-Fi) before any of this can work.
pub async fn begin(base_url: &str) -> Result<PendingLogin> {
    let ip = lan_address()
        .ok_or_else(|| anyhow!("this reMarkable isn't on a Wi-Fi network yet"))?;
    // Port 0 lets the OS pick a free one; binding to 0.0.0.0 (not `ip`) so the
    // callback still arrives if the interface address changes between now and
    // the redirect.
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
        .await
        .context("couldn't open a local port for the sign-in callback")?;
    let port = listener
        .local_addr()
        .context("couldn't read the callback port")?
        .port();
    let verifier = random_secret()?;
    let state = random_secret()?;
    let redirect_uri = format!("http://{ip}:{port}/");
    let authorize_url = authorize_url(
        base_url,
        &redirect_uri,
        &state,
        &code_challenge(&verifier),
    );
    Ok(PendingLogin {
        authorize_url,
        redirect_uri,
        state,
        verifier,
        listener,
    })
}

impl PendingLogin {
    /// Waits for the phone's redirect, then trades the code for a token.
    pub async fn complete(&self, base_url: &str) -> Result<String> {
        let code = self.wait_for_code().await?;
        exchange_code(base_url, &self.redirect_uri, &self.verifier, &code).await
    }

    /// Loops rather than serving a single connection: browsers routinely open a
    /// speculative connection or fetch /favicon.ico alongside the real redirect,
    /// and treating the first arrival as the callback would abandon the sign-in
    /// on a request that never carried a code.
    async fn wait_for_code(&self) -> Result<String> {
        loop {
            let (mut stream, _) = self
                .listener
                .accept()
                .await
                .context("sign-in callback listener failed")?;
            let Some(target) = read_request_target(&mut stream).await else {
                respond(&mut stream, "400 Bad Request", "Bad request.").await;
                continue;
            };
            match callback_outcome(&target, &self.state) {
                CallbackOutcome::Code(code) => {
                    respond(
                        &mut stream,
                        "200 OK",
                        "You can close this tab and go back to your reMarkable to finish signing in.",
                    )
                    .await;
                    return Ok(code);
                }
                CallbackOutcome::Denied(reason) => {
                    respond(&mut stream, "200 OK", "Sign-in was cancelled.").await;
                    bail!("{reason}");
                }
                CallbackOutcome::NotTheCallback => {
                    respond(&mut stream, "404 Not Found", "Nothing here.").await;
                }
            }
        }
    }
}

enum CallbackOutcome {
    Code(String),
    Denied(String),
    NotTheCallback,
}

fn callback_outcome(target: &str, expected_state: &str) -> CallbackOutcome {
    let Some(("/", query)) = target.split_once('?') else {
        return CallbackOutcome::NotTheCallback;
    };
    let (mut state, mut code, mut error, mut description) = (None, None, None, None);
    for (key, value) in form_urlencoded::parse(query.as_bytes()) {
        let parameter = match key.as_ref() {
            "state" => &mut state,
            "code" => &mut code,
            "error" => &mut error,
            "error_description" => &mut description,
            _ => continue,
        };
        if parameter.replace(value).is_some() {
            return CallbackOutcome::NotTheCallback;
        }
    }
    // Both aborting on a mismatch and honoring errors before checking state let an unrelated redirect end this attempt.
    if state.as_deref() != Some(expected_state) {
        return CallbackOutcome::NotTheCallback;
    }
    match (code, error) {
        (Some(code), None) if !code.is_empty() => CallbackOutcome::Code(code.into_owned()),
        (None, Some(error)) if !error.is_empty() => {
            let reason = description.as_deref().filter(|value| !value.is_empty()).unwrap_or(&error);
            CallbackOutcome::Denied(format!("Lichess declined the sign-in: {reason}"))
        }
        _ => CallbackOutcome::NotTheCallback,
    }
}

async fn exchange_code(
    base_url: &str,
    redirect_uri: &str,
    verifier: &str,
    code: &str,
) -> Result<String> {
    // Its own client rather than LichessClient's: every method there attaches a
    // bearer token, and this is the one Lichess call made before we have one.
    let http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(20))
        .build()
        .expect("reqwest client with a timeout always builds");
    let response = http
        .post(format!("{base_url}/api/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect_uri),
            ("client_id", CLIENT_ID),
        ])
        .send()
        .await
        .context("couldn't reach Lichess to finish signing in")?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        let reason = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| {
                v.get("error_description")
                    .or_else(|| v.get("error"))
                    .and_then(|e| e.as_str())
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| format!("status {status}"));
        bail!("Lichess rejected the sign-in: {reason}");
    }
    let body: serde_json::Value = response
        .json()
        .await
        .context("Lichess sent an unreadable sign-in reply")?;
    body.get("access_token")
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("Lichess sent no access token"))
}

fn authorize_url(base_url: &str, redirect_uri: &str, state: &str, challenge: &str) -> String {
    format!(
        "{base_url}/oauth?response_type=code&client_id={}&redirect_uri={}&scope={}&code_challenge_method=S256&code_challenge={}&state={}",
        encode(CLIENT_ID),
        encode(redirect_uri),
        encode(&SCOPES.join(" ")),
        encode(challenge),
        encode(state),
    )
}

fn code_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// 32 bytes, the size RFC 7636 recommends for a code verifier; the CSRF `state`
/// reuses it since it wants the same unguessability.
fn random_secret() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| anyhow!("no system randomness available: {e}"))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

/// A connected UDP socket sends nothing -- it just makes the kernel resolve
/// which interface would carry traffic to that address, which is the only
/// portable way to learn our own LAN address without pulling in a libc
/// `getifaddrs` binding or parsing `/proc/net/route`.
fn lan_address() -> Option<IpAddr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect(("1.1.1.1", 80)).ok()?;
    let ip = socket.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

async fn read_request_target(stream: &mut TcpStream) -> Option<String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let read = tokio::time::timeout(CALLBACK_READ_TIMEOUT, stream.read(&mut chunk))
            .await
            .ok()?
            .ok()?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        // The request line is all we need, so stop at the first newline rather
        // than draining headers we'll never look at.
        if buffer.contains(&b'\n') || buffer.len() >= MAX_REQUEST_BYTES {
            break;
        }
    }
    let head = String::from_utf8_lossy(&buffer);
    let line = head.lines().next()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?;
    let target = parts.next()?;
    (method == "GET").then(|| target.to_owned())
}

async fn respond(stream: &mut TcpStream, status: &str, message: &str) {
    let body = format!(
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\">\
         <title>Lichess for reMarkable</title>\
         <body style=\"font:16px/1.5 system-ui;margin:3rem;text-align:center\">{message}</body>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.flush().await;
}

fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_challenge_matches_rfc7636_example() {
        // The verifier/challenge pair published in RFC 7636 appendix B, so this
        // pins our S256 derivation against the spec, not against ourselves.
        assert_eq!(
            code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn random_secrets_differ_and_are_url_safe() {
        let a = random_secret().unwrap();
        let b = random_secret().unwrap();
        assert_ne!(a, b);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn authorize_url_percent_encodes_redirect_and_scopes() {
        let url = authorize_url(
            "https://lichess.org",
            "http://192.168.1.7:41234/",
            "state-value",
            "challenge-value",
        );
        assert!(url.starts_with("https://lichess.org/oauth?response_type=code"));
        assert!(url.contains("redirect_uri=http%3A%2F%2F192.168.1.7%3A41234%2F"));
        assert!(url.contains("scope=board%3Aplay%20challenge%3Aread%20challenge%3Awrite%20preference%3Aread"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("code_challenge=challenge-value"));
        assert!(url.contains("state=state-value"));
    }

    #[test]
    fn callback_accepts_a_matching_state() {
        match callback_outcome("/?code=abc123&state=expected", "expected") {
            CallbackOutcome::Code(code) => assert_eq!(code, "abc123"),
            _ => panic!("expected a code"),
        }
    }

    #[test]
    fn callback_ignores_unrelated_requests() {
        for target in [
            "/favicon.ico",
            "/favicon.ico?code=abc123&state=expected",
            "/?code=abc123",
            "/?code=abc123&state=previous-attempt",
            "/?error=access_denied",
            "/?error=access_denied&state=previous-attempt",
            "/?code=abc123&state=expected&state=previous-attempt",
            "/?code=first&code=second&state=expected",
            "/?error=first&error=second&state=expected",
            "/?code=abc123&error=access_denied&state=expected",
            "/?code=&state=expected",
            "/?error=&state=expected",
            "/?state=expected",
        ] {
            assert!(
                matches!(callback_outcome(target, "expected"), CallbackOutcome::NotTheCallback),
                "unexpected callback outcome for {target}",
            );
        }
    }

    #[test]
    fn callback_reports_a_declined_authorization() {
        match callback_outcome(
            "/?error=access_denied&error_description=Access+denied&state=expected",
            "expected",
        ) {
            CallbackOutcome::Denied(reason) => {
                assert_eq!(reason, "Lichess declined the sign-in: Access denied");
            }
            _ => panic!("expected a denial"),
        }
    }

    #[test]
    fn callback_handles_non_ascii_query_text() {
        assert!(matches!(
            callback_outcome("/?code=abc123&state=%✓", "expected"),
            CallbackOutcome::NotTheCallback
        ));
    }

    #[test]
    fn callback_decodes_form_encoding() {
        match callback_outcome("/?code=abc%2B123+suffix&state=expected", "expected") {
            CallbackOutcome::Code(code) => assert_eq!(code, "abc+123 suffix"),
            _ => panic!("expected a decoded code"),
        }
    }

    #[tokio::test]
    async fn exchange_code_returns_the_access_token() {
        use wiremock::matchers::{body_string_contains, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/token"))
            .and(body_string_contains("grant_type=authorization_code"))
            .and(body_string_contains("code_verifier=the-verifier"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "lip_granted",
                "token_type": "Bearer"
            })))
            .mount(&server)
            .await;

        let token = exchange_code(&server.uri(), "http://192.168.1.7:41234/", "the-verifier", "the-code")
            .await
            .unwrap();
        assert_eq!(token, "lip_granted");
    }

    #[tokio::test]
    async fn a_live_callback_survives_unrelated_requests_and_yields_a_token() {
        use wiremock::matchers::{body_string_contains, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/token"))
            .and(body_string_contains("code=the-code"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "lip_granted"
            })))
            .expect(1)
            .mount(&server)
            .await;

        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let pending = PendingLogin {
            authorize_url: String::new(),
            redirect_uri: format!("http://127.0.0.1:{port}/"),
            state: "current-attempt".into(),
            verifier: "the-verifier".into(),
            listener,
        };

        let browser = tokio::spawn(async move {
            for (target, status) in [
                ("/favicon.ico", "404 Not Found"),
                ("/?error=access_denied&state=previous-attempt", "404 Not Found"),
                ("/?code=old-code&state=previous-attempt", "404 Not Found"),
                ("/?code=the-code&state=current-attempt", "200 OK"),
            ] {
                let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
                stream
                    .write_all(format!("GET {target} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
                    .await
                    .unwrap();
                let mut reply = Vec::new();
                stream.read_to_end(&mut reply).await.unwrap();
                assert!(String::from_utf8_lossy(&reply).starts_with(&format!("HTTP/1.1 {status}\r\n")));
            }
        });

        let token = tokio::time::timeout(Duration::from_secs(5), pending.complete(&server.uri()))
            .await
            .expect("callback should finish")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), browser)
            .await
            .expect("browser should receive its replies")
            .unwrap();
        assert_eq!(token, "lip_granted");
    }

    #[tokio::test]
    async fn exchange_code_surfaces_a_rejection_reason() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/token"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": "invalid_grant",
                "error_description": "Authorization code expired"
            })))
            .mount(&server)
            .await;

        let error = exchange_code(&server.uri(), "http://192.168.1.7:41234/", "v", "c")
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains("Authorization code expired"), "got: {error}");
    }
}
