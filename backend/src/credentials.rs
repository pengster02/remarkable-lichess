use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub fn token_path(config_dir: Option<OsString>) -> PathBuf {
    config_dir
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/home/root/.config/remarkable-lichess"))
        .join("token")
}

pub(crate) fn save(path: &Path, token: &str) -> io::Result<()> {
    // A private sibling keeps the old token intact until rename. Truncating in place
    // risks partial writes, and a shared temporary name would collide across writers.
    let mut nonce = [0; 16];
    getrandom::fill(&mut nonce).map_err(|error| io::Error::other(error.to_string()))?;
    let temporary = path.with_file_name(format!(".token-{:032x}.tmp", u128::from_ne_bytes(nonce)));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&temporary)?;
    let write = file.write_all(token.as_bytes()).and_then(|()| file.sync_all());
    drop(file);
    let result = write.and_then(|()| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_the_configured_directory_or_the_existing_tablet_path() {
        let tablet_path = Path::new("/home/root/.config/remarkable-lichess/token");
        assert_eq!(token_path(None), tablet_path);
        assert_eq!(token_path(Some(OsString::new())), tablet_path);
        let emulator = std::env::temp_dir().join("remarkable-lichess-config");
        assert_eq!(token_path(Some(emulator.clone().into_os_string())), emulator.join("token"));
    }

    #[cfg(unix)]
    #[test]
    fn replacement_makes_an_existing_token_private() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("rm-lichess-private-token-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("token");
        fs::write(&path, "old-test-token").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        save(&path, "replacement-test-token").unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement-test-token");
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn failed_replacement_removes_its_temporary_token() {
        let dir = std::env::temp_dir().join(format!("rm-lichess-failed-token-{}", std::process::id()));
        let blocked_path = dir.join("token");
        fs::create_dir_all(&blocked_path).unwrap();

        assert!(save(&blocked_path, "test-token").is_err());

        assert!(blocked_path.is_dir());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }
}
