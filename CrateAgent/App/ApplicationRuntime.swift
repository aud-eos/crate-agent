import Foundation

enum ApplicationRuntime {
    #if CRATE_AGENT_TEST_HOST
        static let isTesting = true
    #else
        static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    #endif

    static func requireLiveResources() throws {
        guard !isTesting else { throw IsolationError.liveResourcesUnavailable }
    }

    private enum IsolationError: Error {
        case liveResourcesUnavailable
    }
}
