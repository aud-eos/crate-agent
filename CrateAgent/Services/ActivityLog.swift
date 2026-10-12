import Foundation

/// Cross-cutting "what is the app doing right now?" log. Long-running
/// operations (hygiene runners, duplicate resolver, fingerprint
/// worker, library scanner) post entries here; the main window's
/// bottom strip renders the latest one so the user always has
/// evidence that work is happening.
///
/// This is `@MainActor` so SwiftUI can observe `@Published` properties
/// without dispatch hops. Posters from other actors call
/// `await activityLog.log(...)` — the await is cheap (single hop to
/// the main actor) and keeps every entry in a consistent order.
///
/// The rolling buffer caps at 200 entries so a runaway logger can't
/// pin memory. Subscribers that want history fetch `recent`; the
/// dominant case (the bottom strip) only needs `latest`.
@MainActor
public final class ActivityLog: ObservableObject {

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let message: String
        public let category: Category

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            message: String,
            category: Category
        ) {
            self.id = id
            self.timestamp = timestamp
            self.message = message
            self.category = category
        }
    }

    /// What kind of work generated this entry. Used for color-coding
    /// in the UI and for future filtered views.
    public enum Category: String, Sendable, CaseIterable {
        case hygiene
        case duplicate
        case rename
        case fingerprint
        case sync
        case scan
        case general

        public var displayName: String {
            switch self {
            case .hygiene:      return "Cleanup"
            case .duplicate:    return "Duplicates"
            case .rename:       return "Rename"
            case .fingerprint:  return "Fingerprint"
            case .sync:         return "Sync"
            case .scan:         return "Scan"
            case .general:      return "App"
            }
        }
    }

    /// Most recent entry; nil before anything has been logged. The
    /// bottom-strip view reads this and renders one line.
    @Published public private(set) var latest: Entry?

    /// Newest-first rolling buffer. Cap at `bufferLimit` entries so
    /// a chatty logger can't grow this unbounded. Older entries fall
    /// off the end as new ones land at index 0.
    @Published public private(set) var recent: [Entry] = []

    /// Hard cap on the rolling buffer. 200 is enough to retain a
    /// few minutes of even fairly chatty operations while staying
    /// trivially in-memory.
    public static let bufferLimit = 200

    public init() {}

    public func log(_ message: String, category: Category = .general) {
        let entry = Entry(message: message, category: category)
        latest = entry
        recent.insert(entry, at: 0)
        if recent.count > Self.bufferLimit {
            recent.removeLast(recent.count - Self.bufferLimit)
        }
    }

    /// Wipe the buffer. Used by tests and a possible future
    /// "Clear log" affordance in the popover.
    public func clear() {
        latest = nil
        recent.removeAll()
    }
}
