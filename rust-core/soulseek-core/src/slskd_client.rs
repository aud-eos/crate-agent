use serde::Deserialize;

use crate::error::{Result, SoulseekError};
use crate::types::Candidate;

/// Thin typed wrapper over slskd's REST API. The ONLY unit in
/// soulseek-core that performs network I/O.
#[derive(Clone)]
pub struct SlskdClient {
    base_url: String,
    api_key: String,
    http: reqwest::Client,
}

#[derive(Debug, Deserialize)]
struct SearchCreated {
    id: String,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    username: String,
    #[serde(rename = "hasFreeUploadSlot")]
    has_free_upload_slot: bool,
    files: Vec<SearchFile>,
}

#[derive(Debug, Deserialize)]
struct SearchFile {
    filename: String,
    size: u64,
    #[serde(rename = "bitRate")]
    bit_rate: Option<u32>,
    length: Option<u64>,
    extension: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DownloadUser {
    directories: Vec<DownloadDirectory>,
}

#[derive(Debug, Deserialize)]
struct DownloadDirectory {
    files: Vec<DownloadFile>,
}

#[derive(Debug, Deserialize)]
struct DownloadFile {
    filename: String,
    state: String,
}

impl SlskdClient {
    pub fn new(base_url: impl Into<String>, api_key: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            api_key: api_key.into(),
            http: reqwest::Client::new(),
        }
    }

    /// Initiate a search and return its slskd id.
    pub async fn start_search(&self, query: &str) -> Result<String> {
        let response = self
            .http
            .post(format!("{}/api/v0/searches", self.base_url))
            .header("X-API-Key", &self.api_key)
            .json(&serde_json::json!({ "searchText": query }))
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let response = response
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let created: SearchCreated = response
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;
        Ok(created.id)
    }

    /// Fetch the current responses for a search and normalize them to
    /// `Candidate`s.
    pub async fn fetch_results(&self, search_id: &str) -> Result<Vec<Candidate>> {
        let response = self
            .http
            .get(format!(
                "{}/api/v0/searches/{}/responses",
                self.base_url, search_id
            ))
            .header("X-API-Key", &self.api_key)
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let responses: Vec<SearchResponse> = response
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;

        let mut candidates = Vec::new();
        for entry in responses {
            for file in entry.files {
                let format = file
                    .extension
                    .map(|extension| extension.trim_start_matches('.').to_lowercase())
                    .or_else(|| {
                        std::path::Path::new(&file.filename)
                            .extension()
                            .and_then(|os_str| os_str.to_str())
                            .map(|extension| extension.to_lowercase())
                    })
                    .unwrap_or_default();
                candidates.push(Candidate {
                    username: entry.username.clone(),
                    filename: file.filename,
                    size_bytes: file.size,
                    bitrate_kbps: file.bit_rate,
                    format,
                    has_free_upload_slot: entry.has_free_upload_slot,
                    length_secs: file.length,
                });
            }
        }
        Ok(candidates)
    }

    /// Filenames of downloads slskd reports as fully completed.
    pub async fn completed_downloads(&self) -> Result<Vec<String>> {
        let users: Vec<DownloadUser> = self
            .http
            .get(format!("{}/api/v0/transfers/downloads", self.base_url))
            .header("X-API-Key", &self.api_key)
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;
        let mut done = Vec::new();
        for user in users {
            for directory in user.directories {
                for file in directory.files {
                    if file.state.contains("Completed") && file.state.contains("Succeeded") {
                        let name = std::path::Path::new(&file.filename)
                            .file_name()
                            .map(|os_str| os_str.to_string_lossy().to_string())
                            .unwrap_or(file.filename);
                        done.push(name);
                    }
                }
            }
        }
        Ok(done)
    }

    /// Queue a download of one file from a user.
    pub async fn enqueue_download(
        &self,
        username: &str,
        filename: &str,
        size_bytes: u64,
    ) -> Result<()> {
        self.http
            .post(format!(
                "{}/api/v0/transfers/downloads/{}",
                self.base_url, username
            ))
            .header("X-API-Key", &self.api_key)
            .json(&serde_json::json!([{ "filename": filename, "size": size_bytes }]))
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn start_search_posts_query_and_returns_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/searches"))
            .and(header("X-API-Key", "secret"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "abc-123"
            })))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let id = client
            .start_search("daft punk around the world")
            .await
            .unwrap();
        assert_eq!(id, "abc-123");
    }

    #[tokio::test]
    async fn fetch_results_normalizes_files_to_candidates() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v0/searches/abc-123/responses"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "username": "dj_alice",
                    "hasFreeUploadSlot": true,
                    "files": [
                        { "filename": "Daft Punk - Around the World.flac",
                          "size": 41000000, "bitRate": null, "length": 429, "extension": "flac" }
                    ]
                }
            ])))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let candidates = client.fetch_results("abc-123").await.unwrap();
        assert_eq!(candidates.len(), 1);
        let only = &candidates[0];
        assert_eq!(only.username, "dj_alice");
        assert_eq!(only.format, "flac");
        assert!(only.has_free_upload_slot);
        assert_eq!(only.length_secs, Some(429));
    }

    #[tokio::test]
    async fn enqueue_download_posts_to_user_endpoint() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/transfers/downloads/dj_alice"))
            .respond_with(ResponseTemplate::new(201))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        client
            .enqueue_download("dj_alice", "Daft Punk - Around the World.flac", 41000000)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn completed_downloads_lists_finished_files() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v0/transfers/downloads"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                { "username": "dj_alice", "directories": [
                    { "files": [
                        { "filename": "Around the World.flac", "state": "Completed, Succeeded" },
                        { "filename": "Other.mp3", "state": "InProgress" }
                    ]}
                ]}
            ])))
            .mount(&server)
            .await;
        let client = SlskdClient::new(server.uri(), "secret");
        let done = client.completed_downloads().await.unwrap();
        assert_eq!(done, vec!["Around the World.flac".to_string()]);
    }

    #[tokio::test]
    async fn http_error_surfaces_loudly() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/searches"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let error = client.start_search("x").await.unwrap_err();
        assert!(matches!(error, SoulseekError::Slskd(_)));
    }
}
