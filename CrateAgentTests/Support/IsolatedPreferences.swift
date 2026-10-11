@testable import CrateAgent
import Foundation

final class IsolatedPreferences {
    let preferences: PreferencesStore
    private let defaults: UserDefaults
    private let suiteName = "com.crateagent.tests.\(UUID().uuidString)"

    init() throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.defaults = defaults
        preferences = PreferencesStore(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
