use anyhow::{Context, Result};
use qrcode::{types::Color, QrCode};
use serde::Serialize;

// Row strings are ready for QML's charAt. Boolean arrays enlarge the payload,
// while packed bits would need decoding before the canvas can paint.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct QrMatrix {
    pub size: u32,
    pub rows: Vec<String>,
}

impl QrMatrix {
    pub(crate) fn encode(data: &str) -> Result<Self> {
        let code = QrCode::new(data.as_bytes()).context("couldn't encode the QR code")?;
        let width = code.width();
        let rows = code
            .to_colors()
            .chunks(width)
            .map(|row| row.iter().map(|c| if *c == Color::Dark { '1' } else { '0' }).collect())
            .collect();
        Ok(Self { size: width as u32, rows })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_are_square_and_match_the_reported_width() {
        let matrix = QrMatrix::encode("https://lichess.org/oauth?response_type=code").unwrap();
        assert_eq!(matrix.rows.len(), matrix.size as usize);
        assert!(matrix.rows.iter().all(|row| row.len() == matrix.size as usize));
        assert!(matrix.rows.iter().any(|row| row.contains('1')));
    }
}
