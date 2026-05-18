use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("not implemented")]
    NotImplemented,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("io error: {0}")]
    IoError(String),
}

pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
