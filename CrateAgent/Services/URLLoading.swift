import Foundation

/// Abstraction over "send an HTTP request, get back data + response" so
/// remote lookup clients (`AcoustIDClient`, and `MusicBrainzClient` after
/// it) can be tested against a stub instead of a real network call.
/// `URLSession` is the production implementation.
public protocol URLLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLLoading {}
