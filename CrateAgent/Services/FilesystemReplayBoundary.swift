import Foundation

struct FilesystemReplayReceipt: Sendable {
    let sequence: UInt64
    let observations: [FSEventsObservation]
    let eventID: UInt64
    let requiresReconciliation: Bool
}

enum FilesystemReplayError: LocalizedError {
    case deliveryActive
    case invalidBoundary
    case stopped

    var errorDescription: String? {
        switch self {
        case .deliveryActive: "Filesystem replay must complete before live delivery starts."
        case .invalidBoundary: "Filesystem replay boundary is missing or no longer valid."
        case .stopped: "Filesystem observation stopped before replay completed."
        }
    }
}
