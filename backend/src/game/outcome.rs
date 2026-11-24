use crate::protocol::GameOutcome;

pub(crate) fn outcome(status: &str, winner: Option<&str>) -> GameOutcome {
    // Match Lichess's draw adjudications. Using the status alone hides draws
    // after clock expiry, while treating every absent winner as a draw includes aborts.
    let result = match winner {
        Some(color) => color,
        None if matches!(
            status,
            "draw" | "stalemate" | "timeout" | "outoftime" | "insufficientMaterialClaim"
        ) => "draw",
        None => status,
    };
    let reason = if status == "outoftime" && winner.is_none() {
        "Time expired".to_string()
    } else {
        termination_label(status)
    };
    GameOutcome {
        result: result.to_owned(),
        reason,
        rating_diff: None,
    }
}

/// Human-readable form of Lichess's own GameStatusName -- distinct from
/// `result` (win/loss/draw) above, since two "win"s can still differ in how
/// they actually happened (checkmate vs. an opponent resigning vs. running
/// out the clock), which win/loss/draw alone can't convey. Falls back to a
/// title-cased copy of the raw status for anything not explicitly listed here
/// (e.g. a future status Lichess adds) rather than hiding it as "unknown".
fn termination_label(status: &str) -> String {
    match status {
        "created" => "Game created".to_string(),
        "started" => "In progress".to_string(),
        "aborted" => "Aborted".to_string(),
        "mate" => "Checkmate".to_string(),
        "resign" => "Resignation".to_string(),
        "stalemate" => "Stalemate".to_string(),
        "timeout" => "Disconnection".to_string(),
        "outoftime" => "Time forfeit".to_string(),
        "draw" => "Draw".to_string(),
        "cheat" => "Cheat detected".to_string(),
        "noStart" => "First move deadline missed".to_string(),
        "unknownFinish" => "Unknown finish".to_string(),
        "insufficientMaterialClaim" => "Insufficient material".to_string(),
        "variantEnd" => "Variant ending".to_string(),
        other => humanize_identifier(other),
    }
}

fn humanize_identifier(value: &str) -> String {
    let mut spaced = String::new();
    for character in value.chars() {
        if character == '_' || character == '-' {
            if !spaced.ends_with(' ') {
                spaced.push(' ');
            }
        } else {
            if character.is_uppercase() && !spaced.is_empty() && !spaced.ends_with(' ') {
                spaced.push(' ');
            }
            spaced.push(character);
        }
    }

    let mut characters = spaced.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => "Unknown".to_string(),
    }
}

#[cfg(test)]
mod game_over_result_tests {
    use super::{outcome, termination_label, GameOutcome};

    #[test]
    fn a_real_winner_is_reported_as_their_color_regardless_of_status() {
        assert_eq!(outcome("mate", Some("white")).result, "white");
        assert_eq!(outcome("resign", Some("black")).result, "black");
        assert_eq!(outcome("outoftime", Some("white")).result, "white");
        assert_eq!(outcome("timeout", Some("black")).result, "black");
        assert_eq!(outcome("noStart", Some("white")).result, "white");
    }

    #[test]
    fn draw_adjudications_preserve_the_reason_without_a_winner() {
        for (status, reason) in [
            ("draw", "Draw"),
            ("stalemate", "Stalemate"),
            ("timeout", "Disconnection"),
            ("outoftime", "Time expired"),
            ("insufficientMaterialClaim", "Insufficient material"),
        ] {
            let settled = outcome(status, None);
            assert_eq!(settled.result, "draw", "{status}");
            assert_eq!(settled.reason, reason, "{status}");
        }
    }

    #[test]
    fn game_over_reason_is_human_readable() {
        assert_eq!(
            outcome("outoftime", Some("black")),
            GameOutcome {
                result: "black".to_string(),
                reason: "Time forfeit".to_string(),
                rating_diff: None,
            }
        );
    }

    #[test]
    fn every_official_game_status_has_a_readable_label() {
        let cases = [
            ("created", "Game created"),
            ("started", "In progress"),
            ("aborted", "Aborted"),
            ("mate", "Checkmate"),
            ("resign", "Resignation"),
            ("stalemate", "Stalemate"),
            ("timeout", "Disconnection"),
            ("draw", "Draw"),
            ("outoftime", "Time forfeit"),
            ("cheat", "Cheat detected"),
            ("noStart", "First move deadline missed"),
            ("unknownFinish", "Unknown finish"),
            ("insufficientMaterialClaim", "Insufficient material"),
            ("variantEnd", "Variant ending"),
        ];

        for (status, label) in cases {
            assert_eq!(termination_label(status), label);
        }

        assert_eq!(
            termination_label("futureFinishReason"),
            "Future Finish Reason"
        );
    }

    #[test]
    fn a_no_winner_non_draw_status_is_reported_as_itself_not_mislabeled_a_draw() {
        // The E7 regression this guards: an aborted game has no winner but
        // was never a draw either -- BoardScreen previously showed
        // "Game over: Draw (aborted)", which is simply wrong.
        assert_eq!(outcome("aborted", None).result, "aborted");
        assert_eq!(outcome("noStart", None).result, "noStart");
        assert_eq!(outcome("cheat", None).result, "cheat");
        assert_eq!(outcome("unknownFinish", None).result, "unknownFinish");
    }
}
