import Foundation

/// Two-state launcher that gates AppServices construction on whether
/// the user has chosen a music folder. First-launch users land in
/// `.needsOnboarding`; returning users (with a stored
/// `UserPreferences.watchedMusicFolder`) land in `.ready(services)`.
///
/// Why a separate type from AppServices: AppServices's init is heavy
/// — opens the SQLite database, starts FSEvents and background
/// fingerprinting, and registers Combine bridges. Doing that *before* the
/// user has picked a folder means watching/scanning the wrong path
/// and creating throwaway state. The launcher defers construction
/// until the choice exists.
@MainActor
public final class AppLauncher: ObservableObject {
    public enum State {
        case needsOnboarding
        case ready(AppServices)
    }

    @Published public private(set) var state: State

    public init() {
        if UserPreferences.watchedMusicFolder != nil {
            state = .ready(AppServices.bootstrap())
        } else {
            state = .needsOnboarding
        }
    }

    /// Persist the picked folder and bootstrap services. Transitions
    /// the launcher into `.ready`, which the view tree observes to
    /// reveal the library browser.
    public func completeOnboarding(withFolder folder: URL) {
        UserPreferences.watchedMusicFolder = folder
        state = .ready(AppServices.bootstrap())
    }
}
