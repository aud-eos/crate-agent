use thiserror::Error;

/// Every fallible path in soulseek-core surfaces through this type.
/// No variant is a silent no-op — callers (MCP tools) map these into
/// the parked / needs-review surface rather than swallowing them.
#[derive(Debug, Error)]
pub enum SoulseekError {
    #[error("slskd request failed: {0}")]
    Slskd(String),
    #[error("slskd returned unexpected response: {0}")]
    SlskdProtocol(String),
    #[error("missing required configuration: {0}")]
    Config(String),
    #[error("download verification failed: {0}")]
    Confirm(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, SoulseekError>;
