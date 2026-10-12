import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window must not quit the app — the FSEvents watcher,
        // operation engine, and Serato watchdog all run in the background
        // and need to keep running. The menu bar item stays present so the
        // user can reopen the window or explicitly quit.
        false
    }
}
