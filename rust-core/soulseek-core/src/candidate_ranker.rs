use crate::types::{Candidate, FormatPreference, ListEntry, ScoredCandidate};

/// Score weights. Public so the planner's auto-accept gate can reason
/// about the same numbers the ranker produced.
pub const SCORE_FREE_SLOT: i64 = 40;
pub const SCORE_FLAC: i64 = 50;
pub const SCORE_LOSSY_PER_KBPS_OVER_128: i64 = 1; // 320 → +192
pub const SCORE_FILENAME_HAS_ARTIST: i64 = 25;
pub const SCORE_FILENAME_HAS_TITLE: i64 = 25;
pub const PENALTY_FORMAT_PREFERENCE_MISS: i64 = -200;
pub const PENALTY_PER_SECOND_DURATION_DRIFT: i64 = -4;
pub const DURATION_FREE_TOLERANCE_SECS: u64 = 5;

/// Rank candidates best-first for a wanted entry. Pure: same inputs →
/// same ordering, no I/O. Each candidate carries `notes` explaining the
/// score so a human or Claude can audit the ranking.
pub fn rank(entry: &ListEntry, candidates: &[Candidate]) -> Vec<ScoredCandidate> {
    let mut scored: Vec<ScoredCandidate> = candidates
        .iter()
        .map(|candidate| score_one(entry, candidate))
        .collect();
    // Best score first; ties broken by larger size (usually higher quality).
    scored.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then(right.candidate.size_bytes.cmp(&left.candidate.size_bytes))
    });
    scored
}

fn score_one(entry: &ListEntry, candidate: &Candidate) -> ScoredCandidate {
    let mut score = 0i64;
    let mut notes = Vec::new();
    let is_flac = candidate.format.eq_ignore_ascii_case("flac");

    // Determine whether this candidate misses the user's format preference
    // before awarding quality bonuses — a preference miss suppresses the
    // kbps bonus because bitrate is irrelevant when the format is wrong.
    let format_preference_miss = matches!(
        entry.format_preference,
        FormatPreference::Flac if !is_flac
    ) || matches!(
        entry.format_preference,
        FormatPreference::Lossy320Plus if !is_flac && candidate.bitrate_kbps.unwrap_or(0) < 320
    );

    if candidate.has_free_upload_slot {
        score += SCORE_FREE_SLOT;
        notes.push("free upload slot".into());
    } else {
        notes.push("no free slot (queued)".into());
    }

    if is_flac {
        score += SCORE_FLAC;
        notes.push("FLAC (lossless)".into());
    } else if !format_preference_miss {
        if let Some(bitrate) = candidate.bitrate_kbps {
            let over = (bitrate as i64 - 128).max(0);
            score += over * SCORE_LOSSY_PER_KBPS_OVER_128;
            notes.push(format!("{bitrate} kbps"));
        } else {
            notes.push("unknown bitrate".into());
        }
    }

    if format_preference_miss {
        score += PENALTY_FORMAT_PREFERENCE_MISS;
        match entry.format_preference {
            FormatPreference::Flac => notes.push("does not meet FLAC preference".into()),
            FormatPreference::Lossy320Plus => notes.push("below 320 kbps preference".into()),
            FormatPreference::Any => {}
        }
    }

    let haystack = candidate.filename.to_lowercase();
    let tokens_present = |text: &str| {
        text.to_lowercase()
            .split_whitespace()
            .all(|token| haystack.contains(token))
    };
    if tokens_present(&entry.artist) {
        score += SCORE_FILENAME_HAS_ARTIST;
        notes.push("filename contains artist".into());
    }
    if tokens_present(&entry.title) {
        score += SCORE_FILENAME_HAS_TITLE;
        notes.push("filename contains title".into());
    }

    if let (Some(want), Some(have)) = (entry.duration_secs, candidate.length_secs) {
        let drift = want.abs_diff(have);
        if drift > DURATION_FREE_TOLERANCE_SECS {
            let penalized = (drift - DURATION_FREE_TOLERANCE_SECS) as i64;
            score += penalized * PENALTY_PER_SECOND_DURATION_DRIFT;
            notes.push(format!("duration off by {drift}s"));
        }
    }

    ScoredCandidate {
        candidate: candidate.clone(),
        score,
        notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_entry() -> ListEntry {
        ListEntry {
            artist: "Daft Punk".into(),
            title: "Around the World".into(),
            album: None,
            year: None,
            duration_secs: Some(429),
            isrc: None,
            musicbrainz_recording_id: None,
            format_preference: FormatPreference::Any,
        }
    }

    fn candidate(
        filename: &str,
        format: &str,
        bitrate: Option<u32>,
        slot: bool,
        length: Option<u64>,
    ) -> Candidate {
        Candidate {
            username: "someuser".into(),
            filename: filename.into(),
            size_bytes: 10_000_000,
            bitrate_kbps: bitrate,
            format: format.into(),
            has_free_upload_slot: slot,
            length_secs: length,
        }
    }

    #[test]
    fn flac_with_free_slot_and_matching_name_outranks_low_bitrate_transcode() {
        let entry = base_entry();
        let flac = candidate(
            "Daft Punk - Around the World.flac",
            "flac",
            None,
            true,
            Some(429),
        );
        let mp3_128 = candidate(
            "around_the_world_YT_rip.mp3",
            "mp3",
            Some(128),
            true,
            Some(210),
        );
        let ranked = rank(&entry, &[mp3_128.clone(), flac.clone()]);
        assert_eq!(ranked[0].candidate, flac);
        assert!(ranked[0].score > ranked[1].score);
    }

    #[test]
    fn duration_drift_is_penalized_against_radio_edit() {
        let entry = base_entry(); // wants 429s
        let full = candidate(
            "Daft Punk - Around the World.mp3",
            "mp3",
            Some(320),
            true,
            Some(429),
        );
        let radio = candidate(
            "Daft Punk - Around the World (Radio).mp3",
            "mp3",
            Some(320),
            true,
            Some(210),
        );
        let ranked = rank(&entry, &[radio, full.clone()]);
        assert_eq!(ranked[0].candidate, full);
    }

    #[test]
    fn flac_preference_disqualifies_non_flac() {
        let mut entry = base_entry();
        entry.format_preference = FormatPreference::Flac;
        let flac = candidate("x - y.flac", "flac", None, true, Some(429));
        let mp3 = candidate("x - y.mp3", "mp3", Some(320), true, Some(429));
        let ranked = rank(&entry, &[mp3, flac.clone()]);
        assert_eq!(ranked[0].candidate, flac);
        assert!(
            ranked[1].score < 0,
            "non-flac under FLAC preference must be penalized below zero"
        );
    }

    #[test]
    fn no_free_slot_loses_the_slot_bonus() {
        let entry = base_entry();
        let with_slot = candidate(
            "Daft Punk - Around the World.mp3",
            "mp3",
            Some(320),
            true,
            Some(429),
        );
        let no_slot = candidate(
            "Daft Punk - Around the World.mp3",
            "mp3",
            Some(320),
            false,
            Some(429),
        );
        let ranked = rank(&entry, &[no_slot, with_slot.clone()]);
        assert_eq!(ranked[0].candidate, with_slot);
        assert_eq!(ranked[0].score - ranked[1].score, SCORE_FREE_SLOT);
    }
}
