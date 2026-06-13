use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use rmcp::handler::server::wrapper::{Json, Parameters};
use rmcp::{tool, tool_router, ServiceExt};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use soulseek_core::adapters::text_paste::parse_text;
use soulseek_core::planner::{plan, ConfidencePolicy, Decision};
use soulseek_core::slskd_client::SlskdClient;
use soulseek_core::types::{ListEntry, ScoredCandidate};

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

struct Session {
    entries: Vec<ListEntry>,
    decisions: HashMap<usize, Decision>,
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
    // Used by acquisition_status (Task 9).
    _staging_dir: PathBuf,
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
            _staging_dir: staging_dir,
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
        let entries: Vec<ListEntry> = {
            let state = self.state.lock().await;
            match state.sessions.get(&params.session_id) {
                Some(session) => session.entries.clone(),
                None => {
                    return Json(PlanResult {
                        auto_accepted: 0,
                        proposed: 0,
                        parked: vec!["unknown session".into()],
                    });
                }
            }
        };

        let policy = self.state.lock().await.policy.clone();
        let mut decisions: HashMap<usize, Decision> = HashMap::new();
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
                Decision::AutoAccept(_) => auto_accepted += 1,
                Decision::Propose(_) => proposed += 1,
                Decision::Park { reason } => {
                    parked.push(format!("{} - {}: {}", entry.artist, entry.title, reason))
                }
            }
            decisions.insert(index, decision);
        }

        let mut state = self.state.lock().await;
        if let Some(session) = state.sessions.get_mut(&params.session_id) {
            session.decisions = decisions;
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
        let candidate = {
            let state = self.state.lock().await;
            state.sessions.get(&params.session_id).and_then(|session| {
                match session.decisions.get(&params.entry_index) {
                    Some(Decision::Propose(list)) => list.get(params.candidate_index).cloned(),
                    Some(Decision::AutoAccept(top)) if params.candidate_index == 0 => {
                        Some(top.clone())
                    }
                    _ => None,
                }
            })
        };

        let Some(scored) = candidate else {
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
            Ok(()) => Json(ConfirmResult {
                queued: true,
                message: format!("queued {}", scored.candidate.filename),
            }),
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
