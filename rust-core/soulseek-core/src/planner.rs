use serde::{Deserialize, Serialize};

use crate::candidate_ranker::rank;
use crate::error::Result;
use crate::slskd_client::SlskdClient;
use crate::types::{FormatPreference, ListEntry, ScoredCandidate};

/// How aggressively to commit downloads without a human in the loop.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfidencePolicy {
    pub auto_accept: bool,
    pub min_score: i64,
    pub require_free_slot: bool,
    /// Number of top candidates returned in the `Propose` case.
    pub propose_top_n: usize,
}

impl Default for ConfidencePolicy {
    fn default() -> Self {
        Self {
            auto_accept: false,
            min_score: 60,
            require_free_slot: true,
            propose_top_n: 5,
        }
    }
}

/// The planner's verdict for one entry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Decision {
    AutoAccept(ScoredCandidate),
    Propose(Vec<ScoredCandidate>),
    Park { reason: String },
}

/// Pure decision over already-ranked candidates. No I/O.
pub fn decide(
    entry: &ListEntry,
    ranked: &[ScoredCandidate],
    policy: &ConfidencePolicy,
) -> Decision {
    let Some(top) = ranked.first() else {
        return Decision::Park {
            reason: "no candidates returned by slskd".into(),
        };
    };

    if top.score < policy.min_score {
        return Decision::Park {
            reason: format!(
                "best candidate score {} below floor {}",
                top.score, policy.min_score
            ),
        };
    }

    if policy.auto_accept && clears_gate(entry, top, policy) {
        return Decision::AutoAccept(top.clone());
    }

    let top_n = ranked.iter().take(policy.propose_top_n).cloned().collect();
    Decision::Propose(top_n)
}

fn clears_gate(entry: &ListEntry, top: &ScoredCandidate, policy: &ConfidencePolicy) -> bool {
    if top.score < policy.min_score {
        return false;
    }
    if policy.require_free_slot && !top.candidate.has_free_upload_slot {
        return false;
    }
    match entry.format_preference {
        FormatPreference::Flac => top.candidate.format.eq_ignore_ascii_case("flac"),
        FormatPreference::Lossy320Plus => {
            top.candidate.format.eq_ignore_ascii_case("flac")
                || top.candidate.bitrate_kbps.unwrap_or(0) >= 320
        }
        FormatPreference::Any => true,
    }
}

/// Search slskd, rank, and decide. The async orchestration; `decide`
/// holds the actual policy logic and is tested independently. `poll`
/// supplies the wait before fetching (slskd accumulates responses
/// asynchronously after a search starts).
pub async fn plan(
    entry: &ListEntry,
    client: &SlskdClient,
    policy: &ConfidencePolicy,
    poll: impl Fn(&str) -> std::time::Duration,
) -> Result<Decision> {
    use crate::query_builder::build_query;

    let search_id = client.start_search(&build_query(entry)).await?;
    tokio::time::sleep(poll(&search_id)).await;
    let candidates = client.fetch_results(&search_id).await?;
    let ranked = rank(entry, &candidates);
    Ok(decide(entry, &ranked, policy))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Candidate;

    fn entry() -> ListEntry {
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

    fn scored(score: i64, slot: bool) -> ScoredCandidate {
        ScoredCandidate {
            candidate: Candidate {
                username: "u".into(),
                filename: "Daft Punk - Around the World.flac".into(),
                size_bytes: 1,
                bitrate_kbps: None,
                format: "flac".into(),
                has_free_upload_slot: slot,
                length_secs: Some(429),
            },
            score,
            notes: vec![],
        }
    }

    #[test]
    fn empty_candidates_parks() {
        let decision = decide(&entry(), &[], &ConfidencePolicy::default());
        assert!(matches!(decision, Decision::Park { .. }));
    }

    #[test]
    fn below_min_score_parks() {
        let policy = ConfidencePolicy {
            min_score: 100,
            ..Default::default()
        };
        let decision = decide(&entry(), &[scored(50, true)], &policy);
        assert!(matches!(decision, Decision::Park { .. }));
    }

    #[test]
    fn auto_off_proposes_top_n_even_when_gate_clears() {
        let policy = ConfidencePolicy {
            auto_accept: false,
            ..Default::default()
        };
        let decision = decide(&entry(), &[scored(140, true), scored(120, true)], &policy);
        match decision {
            Decision::Propose(list) => assert_eq!(list.len(), 2),
            other => panic!("expected Propose, got {other:?}"),
        }
    }

    #[test]
    fn auto_on_and_gate_clears_auto_accepts_top() {
        let policy = ConfidencePolicy {
            auto_accept: true,
            ..Default::default()
        };
        let decision = decide(&entry(), &[scored(140, true), scored(120, true)], &policy);
        match decision {
            Decision::AutoAccept(top) => assert_eq!(top.score, 140),
            other => panic!("expected AutoAccept, got {other:?}"),
        }
    }

    #[test]
    fn auto_on_but_no_free_slot_falls_back_to_propose() {
        let policy = ConfidencePolicy {
            auto_accept: true,
            require_free_slot: true,
            ..Default::default()
        };
        let decision = decide(&entry(), &[scored(140, false)], &policy);
        assert!(matches!(decision, Decision::Propose(_)));
    }
}
