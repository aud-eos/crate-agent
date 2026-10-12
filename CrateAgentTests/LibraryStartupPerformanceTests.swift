@testable import CrateAgent
import XCTest

@MainActor
final class LibraryStartupPerformanceTests: XCTestCase {
    func testThirtyThousandFileFullSynchronizationBaseline() async throws {
        let fixture = try await LibraryStartupPerformanceFixture()
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession()
        let start = ContinuousClock.now
        try await session.synchronize()
        let elapsed = start.duration(to: .now)
        guard case .ready = session.state else { return XCTFail("Full baseline did not become ready") }
        let metrics = "STARTUP_BASELINE files=30000 real_audio=true full_sync=\(elapsed)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
