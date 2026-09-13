import Foundation

/// Terminal failure states shared by every remote lookup client
/// (`AcoustIDClient`, and `MusicBrainzClient` after it) and their callers.
/// Every non-success HTTP status — and every transport-level failure —
/// maps to exactly one of these; none of them is silently swallowed into
/// an empty result.
public enum LookupError: Error, Equatable {
    /// 401 — the API key/credentials were rejected.
    case unauthorized
    /// 429 — rate limited, and retries were exhausted.
    case rateLimited
    /// 5xx — the server failed, and retries (where applicable) were exhausted.
    case server
    /// Anything else: a `URLSession`/`URLError` failure, an unparsable
    /// response body, a non-HTTP response, or an unexpected status code.
    /// Carries the underlying description for operator-useful context.
    case transport(String)
}
