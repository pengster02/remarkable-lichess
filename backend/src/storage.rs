use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

pub(crate) fn replace(path: &Path, contents: &[u8]) -> io::Result<()> {
    // A private sibling keeps the old file intact until rename. In-place writes
    // expose partial data, and a shared temporary name races concurrent saves.
    let mut nonce = [0; 16];
    getrandom::fill(&mut nonce).map_err(|error| io::Error::other(error.to_string()))?;
    let temporary = path.with_file_name(format!(".remarkable-lichess-{:032x}.tmp", u128::from_ne_bytes(nonce)));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&temporary)?;
    let write = file.write_all(contents).and_then(|()| file.sync_all());
    drop(file);
    let result = write.and_then(|()| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
