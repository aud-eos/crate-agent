import XCTest

/// Awaitable `XCTAssertThrowsError` — the synchronous stdlib version can't
/// take an `async throws` autoclosure. Shared across lookup-client test
/// files (`AcoustIDClientTests`, `MusicBrainzClientTests`) rather than
/// duplicated per file.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
