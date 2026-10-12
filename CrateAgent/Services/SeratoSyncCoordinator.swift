import Combine

@MainActor
final class SeratoSyncCoordinator {
    private var subscription: AnyCancellable?

    init(session: SeratoLibrarySyncSession, seratoWatchdog: SeratoWatchdog, startup: LibraryStartupCoordinator? = nil) {
        subscription = seratoWatchdog.$isSeratoRunning.dropFirst().sink { [weak session] isRunning in
            session?.seratoStateChanged(isRunning: isRunning)
            if !isRunning {
                startup?.start()
            }
        }
    }
}
