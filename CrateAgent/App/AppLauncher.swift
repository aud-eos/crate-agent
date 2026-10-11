import Foundation

public typealias AppLauncher = ApplicationLauncher<AppServices>

@MainActor
public final class ApplicationLauncher<Services>: ObservableObject {
    public enum State {
        case inactive
        case needsOnboarding
        case ready(Services)
    }

    @Published public private(set) var state: State
    private let preferences: PreferencesStore?
    private let makeServices: ((URL) -> Services)?

    fileprivate init(inactive _: Void) {
        state = .inactive
        preferences = nil
        makeServices = nil
    }

    init(preferences: PreferencesStore, makeServices: @escaping (URL) -> Services) {
        self.preferences = preferences
        self.makeServices = makeServices
        if let folder = preferences.watchedMusicFolder {
            state = .ready(makeServices(folder))
        } else {
            state = .needsOnboarding
        }
    }

    public func completeOnboarding(withFolder folder: URL) {
        guard let preferences, let makeServices else {
            preconditionFailure("An inactive application cannot complete onboarding")
        }
        preferences.watchedMusicFolder = folder
        state = .ready(makeServices(folder))
    }
}

public extension ApplicationLauncher where Services == AppServices {
    convenience init() {
        if ApplicationRuntime.isTesting {
            self.init(inactive: ())
        } else {
            do {
                try self.init(preferences: PreferencesStore.live(), makeServices: AppServices.bootstrap)
            } catch {
                fatalError("Application startup failed: \(error)")
            }
        }
    }
}
