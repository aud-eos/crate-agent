use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use rmcp::handler::server::wrapper::{Json, Parameters};
use rmcp::{tool, tool_router, ServiceExt};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use soulseek_core::adapters::text_paste::parse_text;
use soulseek_core::confirmer::confirm_download;
use soulseek_core::planner::{plan, ConfidencePolicy, Decision};
use soulseek_core::slskd_client::SlskdClient;
use soulseek_core::staging::write_manifest;
use soulseek_core::types::{AcquisitionRecord, Candidate, ListEntry, ScoredCandidate, SourceInfo};

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

/// Records an enqueued download so `acquisition_status` can recover exact
/// provenance (username, remote path) without guessing by title-substring.
/// The map key is the basename of `candidate.filename`.
struct EnqueuedDownload {
    list_entry: ListEntry,
    candidate: Candidate,
}

struct Session {
    entries: Vec<ListEntry>,
    decisions: HashMap<usize, Decision>,
    /// Keyed by the download's basename (what slskd and the staging dir both use).
    enqueued: HashMap<String, EnqueuedDownload>,
}

struct State {
    sessions: HashMap<String, Session>,
    policy: ConfidencePolicy,
    next_id: u64,
}

// ---------------------------------------------------------------------------
// Server struct
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct SoulseekMcp {
    state: Arc<Mutex<State>>,
    client: SlskdClient,
    staging_dir: PathBuf,
}

// ---------------------------------------------------------------------------
// Tool parameter / result types
// ---------------------------------------------------------------------------

#[derive(Deserialize, schemars::JsonSchema)]
struct IngestParams {
    text: String,
}

#[derive(Serialize, schemars::JsonSchema)]
struct IngestResult {
    session_id: String,
    parsed: usize,
    skipped: Vec<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct SessionParams {
    session_id: String,
}

#[derive(Serialize, schemars::JsonSchema)]
struct PlanResult {
    auto_accepted: usize,
    proposed: usize,
    parked: Vec<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ReviewParams {
    session_id: String,
    entry_index: usize,
}

#[derive(Serialize, schemars::JsonSchema)]
struct ReviewResult {
    entry: String,
    candidates: Vec<ScoredCandidate>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ConfirmParams {
    session_id: String,
    entry_index: usize,
    candidate_index: usize,
}

#[derive(Serialize, schemars::JsonSchema)]
struct ConfirmResult {
    queued: bool,
    message: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct AutoAcceptParams {
    enabled: bool,
    min_score: Option<i64>,
}

#[derive(Serialize, schemars::JsonSchema)]
struct PolicyResult {
    auto_accept: bool,
    min_score: i64,
}

#[derive(Serialize, schemars::JsonSchema)]
struct StatusResult {
    completed: Vec<String>,
    confirmed: Vec<String>,
    needs_review: Vec<String>,
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

#[tool_router(server_handler)]
impl SoulseekMcp {
    fn new(client: SlskdClient, staging_dir: PathBuf) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                sessions: HashMap::new(),
                policy: ConfidencePolicy::default(),
                next_id: 0,
            })),
            client,
            staging_dir,
        }
    }

    #[tool(description = "Parse a newline-delimited 'Artist - Title' list into a session.")]
    async fn ingest_list(
        &self,
        Parameters(params): Parameters<IngestParams>,
    ) -> Json<IngestResult> {
        let parsed = parse_text(&params.text);
        let mut state = self.state.lock().await;
        let session_id = format!("s{}", state.next_id);
        state.next_id += 1;
        let count = parsed.entries.len();
        state.sessions.insert(
            session_id.clone(),
            Session {
                entries: parsed.entries,
                decisions: HashMap::new(),
                enqueued: HashMap::new(),
            },
        );
        Json(IngestResult {
            session_id,
            parsed: count,
            skipped: parsed.skipped,
        })
    }

    #[tool(
        description = "Search slskd and decide (auto-accept / propose / park) for every entry in a session."
    )]
    async fn plan_acquisition(
        &self,
        Parameters(params): Parameters<SessionParams>,
    ) -> Json<PlanResult> {
        // Clone what we need under a short lock so we never hold it across
        // the async network calls below.
        let (entries, policy) = {
            let state = self.state.lock().await;
            match state.sessions.get(&params.session_id) {
                Some(session) => (session.entries.clone(), state.policy.clone()),
                None => {
                    return Json(PlanResult {
                        auto_accepted: 0,
                        proposed: 0,
                        parked: vec!["unknown session".into()],
                    });
                }
            }
        };

        let mut decisions: HashMap<usize, Decision> = HashMap::new();
        // Enqueued records built here; written back under lock after all async work.
        let mut new_enqueued: HashMap<String, EnqueuedDownload> = HashMap::new();
        let (mut auto_accepted, mut proposed, mut parked) = (0usize, 0usize, Vec::<String>::new());

        for (index, entry) in entries.iter().enumerate() {
            // Wait 4 seconds for slskd to accumulate search responses before fetching.
            let decision = match plan(entry, &self.client, &policy, |_search_id| {
                Duration::from_secs(4)
            })
            .await
            {
                Ok(decision) => decision,
                Err(error) => Decision::Park {
                    reason: error.to_string(),
                },
            };

            match &decision {
                Decision::AutoAccept(top) => {
                    // Auto-accept = enqueue immediately; the user asked for hands-off.
                    match self
                        .client
                        .enqueue_download(
                            &top.candidate.username,
                            &top.candidate.filename,
                            top.candidate.size_bytes,
                        )
                        .await
                    {
                        Ok(()) => {
                            let basename = candidate_basename(&top.candidate.filename);
                            new_enqueued.insert(
                                basename,
                                EnqueuedDownload {
                                    list_entry: entry.clone(),
                                    candidate: top.candidate.clone(),
                                },
                            );
                            auto_accepted += 1;
                        }
                        Err(error) => {
                            // Enqueue failure is not silent — surface it as parked.
                            parked.push(format!(
                                "{} - {}: auto-accept enqueue failed: {}",
                                entry.artist, entry.title, error
                            ));
                        }
                    }
                }
                Decision::Propose(_) => proposed += 1,
                Decision::Park { reason } => {
                    parked.push(format!("{} - {}: {}", entry.artist, entry.title, reason))
                }
            }
            decisions.insert(index, decision);
        }

        // Write decisions and enqueued records back under a single lock acquisition.
        let mut state = self.state.lock().await;
        if let Some(session) = state.sessions.get_mut(&params.session_id) {
            session.decisions = decisions;
            session.enqueued.extend(new_enqueued);
        }
        Json(PlanResult {
            auto_accepted,
            proposed,
            parked,
        })
    }

    #[tool(
        description = "Show the ranked candidate list for one entry so it can be judged before download."
    )]
    async fn review_candidates(
        &self,
        Parameters(params): Parameters<ReviewParams>,
    ) -> Json<ReviewResult> {
        let state = self.state.lock().await;
        let (entry_label, candidates) = state
            .sessions
            .get(&params.session_id)
            .and_then(|session| {
                let entry = session.entries.get(params.entry_index)?;
                let candidates = match session.decisions.get(&params.entry_index) {
                    Some(Decision::Propose(list)) => list.clone(),
                    Some(Decision::AutoAccept(top)) => vec![top.clone()],
                    _ => vec![],
                };
                Some((format!("{} - {}", entry.artist, entry.title), candidates))
            })
            .unwrap_or_else(|| ("unknown entry".into(), vec![]));
        Json(ReviewResult {
            entry: entry_label,
            candidates,
        })
    }

    #[tool(description = "Queue a chosen candidate for download in slskd.")]
    async fn confirm_download(
        &self,
        Parameters(params): Parameters<ConfirmParams>,
    ) -> Json<ConfirmResult> {
        // Clone out the candidate and its list entry under a short lock.
        let resolved = {
            let state = self.state.lock().await;
            state.sessions.get(&params.session_id).and_then(|session| {
                let entry = session.entries.get(params.entry_index)?.clone();
                let scored = match session.decisions.get(&params.entry_index) {
                    Some(Decision::Propose(list)) => list.get(params.candidate_index).cloned(),
                    Some(Decision::AutoAccept(top)) if params.candidate_index == 0 => {
                        Some(top.clone())
                    }
                    _ => None,
                }?;
                Some((entry, scored))
            })
        };

        let Some((list_entry, scored)) = resolved else {
            return Json(ConfirmResult {
                queued: false,
                message: "no such candidate".into(),
            });
        };

        match self
            .client
            .enqueue_download(
                &scored.candidate.username,
                &scored.candidate.filename,
                scored.candidate.size_bytes,
            )
            .await
        {
            Ok(()) => {
                let basename = candidate_basename(&scored.candidate.filename);
                let mut state = self.state.lock().await;
                if let Some(session) = state.sessions.get_mut(&params.session_id) {
                    session.enqueued.insert(
                        basename,
                        EnqueuedDownload {
                            list_entry,
                            candidate: scored.candidate.clone(),
                        },
                    );
                }
                Json(ConfirmResult {
                    queued: true,
                    message: format!("queued {}", scored.candidate.filename),
                })
            }
            Err(error) => Json(ConfirmResult {
                queued: false,
                message: error.to_string(),
            }),
        }
    }

    #[tool(
        description = "Toggle high-confidence auto-accept and optionally set the minimum score."
    )]
    async fn set_auto_accept(
        &self,
        Parameters(params): Parameters<AutoAcceptParams>,
    ) -> Json<PolicyResult> {
        let mut state = self.state.lock().await;
        state.policy.auto_accept = params.enabled;
        if let Some(min) = params.min_score {
            state.policy.min_score = min;
        }
        Json(PolicyResult {
            auto_accept: state.policy.auto_accept,
            min_score: state.policy.min_score,
        })
    }

    #[tool(
        description = "Poll download progress; confirm + manifest finished files; report the needs-review list."
    )]
    async fn acquisition_status(&self) -> Json<StatusResult> {
        let completed = match self.client.completed_downloads().await {
            Ok(list) => list,
            Err(error) => {
                return Json(StatusResult {
                    completed: vec![],
                    confirmed: vec![],
                    needs_review: vec![error.to_string()],
                })
            }
        };

        let mut confirmed = Vec::new();
        let mut needs_review = Vec::new();

        for filename in &completed {
            let file_path = self.staging_dir.join(filename);
            if self.staging_dir.join(format!("{filename}.json")).exists() {
                continue; // already confirmed on a prior poll
            }
            if !file_path.exists() {
                needs_review.push(format!(
                    "{filename}: completed in slskd but not present in staging dir"
                ));
                continue;
            }

            // Fix 4: surface metadata errors instead of silently defaulting to size 0.
            let size_bytes = match std::fs::metadata(&file_path) {
                Ok(meta) => meta.len(),
                Err(error) => {
                    needs_review.push(format!("{filename}: could not read file metadata: {error}"));
                    continue;
                }
            };

            // Fix 3 + Fix 5: prefer recorded provenance over title-substring guessing.
            // For files not enqueued through this server, fall back to title-substring
            // matching across sessions (same logic as before, but exact only when found).
            let (entry, slskd_username, original_filename) = {
                let state = self.state.lock().await;
                find_enqueued_download(&state, filename)
                    .map(|enqueued| {
                        (
                            enqueued.list_entry.clone(),
                            enqueued.candidate.username.clone(),
                            enqueued.candidate.filename.clone(),
                        )
                    })
                    .unwrap_or_else(|| {
                        let fallback_entry = best_effort_entry_for_state(&state, filename);
                        (fallback_entry, String::new(), filename.clone())
                    })
            };

            match confirm_download(&file_path, &entry) {
                Ok(verdict) => {
                    let record = AcquisitionRecord {
                        list_entry: entry,
                        file_path: file_path.to_string_lossy().to_string(),
                        fingerprint: verdict.fingerprint,
                        source: SourceInfo {
                            slskd_username,
                            original_filename,
                            // Use the confirmer's detected values for the actual file's
                            // bitrate and format (ground truth from the decoded audio).
                            bitrate_kbps: verdict.bitrate_kbps,
                            format: verdict.format,
                            size_bytes,
                        },
                        confirmed: verdict.confirmed,
                    };
                    match write_manifest(&self.staging_dir, &record) {
                        Ok(_) if verdict.confirmed => confirmed.push(filename.clone()),
                        Ok(_) => needs_review.push(format!(
                            "{filename}: {}",
                            verdict.reason.unwrap_or_default()
                        )),
                        Err(error) => {
                            needs_review.push(format!("{filename}: manifest write failed: {error}"))
                        }
                    }
                }
                Err(error) => needs_review.push(format!("{filename}: {error}")),
            }
        }

        Json(StatusResult {
            completed,
            confirmed,
            needs_review,
        })
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the basename of a remote slskd path (what the staging dir and
/// slskd's completed-downloads list both use as the key).
fn candidate_basename(remote_path: &str) -> String {
    Path::new(remote_path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| remote_path.to_string())
}

/// Search all sessions for an `EnqueuedDownload` whose basename matches
/// `filename` (the basename as reported by slskd).
fn find_enqueued_download<'state>(
    state: &'state State,
    filename: &str,
) -> Option<&'state EnqueuedDownload> {
    for session in state.sessions.values() {
        if let Some(enqueued) = session.enqueued.get(filename) {
            return Some(enqueued);
        }
    }
    None
}

/// Match a completed filename back to the list entry that requested it, using
/// title containment across all sessions. Falls back to a bare entry derived
/// from the filename when no session claims it. Used for files that completed
/// in slskd but were not enqueued through this server's tools.
fn best_effort_entry_for_state(state: &State, filename: &str) -> ListEntry {
    let lowercase = filename.to_lowercase();
    for session in state.sessions.values() {
        for entry in &session.entries {
            if !entry.title.is_empty() && lowercase.contains(&entry.title.to_lowercase()) {
                return entry.clone();
            }
        }
    }
    ListEntry {
        artist: String::new(),
        title: filename.to_string(),
        album: None,
        year: None,
        duration_secs: None,
        isrc: None,
        musicbrainz_recording_id: None,
        format_preference: Default::default(),
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn required_env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("required env var {key} is not set"))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let slskd_url = required_env("SLSKD_URL");
    let api_key = required_env("SLSKD_API_KEY");
    let staging_dir = PathBuf::from(required_env("SOULSEEK_STAGING_DIR"));

    let client = SlskdClient::new(slskd_url, api_key);
    let server = SoulseekMcp::new(client, staging_dir);

    let running = server.serve(rmcp::transport::stdio()).await?;
    running.waiting().await?;
    Ok(())
}
