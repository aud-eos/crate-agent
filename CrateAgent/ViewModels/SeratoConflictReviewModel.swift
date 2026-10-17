import Combine
import Foundation

struct SeratoConflictActionError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

@MainActor
final class SeratoConflictReviewModel: ObservableObject {
    @Published var selectedConflictID: String?
    @Published private(set) var actionError: String?
    @Published private(set) var conflicts: [SeratoPathConflict] = []
    @Published private(set) var isStale = false
    @Published private(set) var state: SeratoLibrarySyncSession.State = .idle
    private let copyAction: (String) throws -> Void
    private let revealAction: (String) async throws -> Void
    private let openAction: () async throws -> Void
    private let retryAction: () -> Void
    private var subscriptions = Set<AnyCancellable>()

    init(session: SeratoLibrarySyncSession, copyDetails: @escaping (String) throws -> Void,
         revealFile: @escaping (String) async throws -> Void, openSerato: @escaping () async throws -> Void,
         retrySync: @escaping () -> Void)
    {
        copyAction = copyDetails
        revealAction = revealFile
        openAction = openSerato
        retryAction = retrySync
        session.$conflicts.sink { [weak self] conflicts in
            guard let self else { return }
            self.conflicts = conflicts
            if !conflicts.contains(where: { conflict in conflict.id == self.selectedConflictID }) {
                selectedConflictID = conflicts.first?.id
            }
        }.store(in: &subscriptions)
        session.$conflictsAreStale.assign(to: &$isStale)
        session.$state.assign(to: &$state)
    }

    var selectedConflict: SeratoPathConflict? {
        conflicts.first { conflict in conflict.id == selectedConflictID }
    }

    var details: String {
        guard let conflict = selectedConflict else { return "No path conflicts in the last validated snapshot." }
        return ((isStale ? [SeratoConflictMessages.stale] : []) + [conflict.id, Self.guidance(conflict), "\(conflict.fileIDs.count) indexed files protected"]
            + conflict.occurrences.map(Self.describe) + [SeratoConflictMessages.repair]).joined(separator: "\n\n")
    }

    func copyDetails() {
        actionError = nil
        do { try copyAction(details) } catch { actionError = error.localizedDescription }
    }

    func reveal(_ occurrence: SeratoConflictOccurrence) async {
        actionError = nil
        do {
            guard case let .existing(expected) = occurrence.observation else {
                throw SeratoConflictActionError(message: "This entry has no verified accessible file to reveal. Restore access and retry sync.")
            }
            let path = occurrence.record.path.hasPrefix("/") ? occurrence.record.path : "/" + occurrence.record.path
            let current = try await Task.detached { try SeratoConflictAnalyzer.inspectPath(path) }.value
            guard current == .existing(expected) else {
                throw SeratoConflictActionError(message: "The file changed or is no longer accessible. Retry sync before revealing it.")
            }
            try await revealAction(path)
        } catch { actionError = error.localizedDescription }
    }

    func openSerato() async {
        actionError = nil
        do { try await openAction() } catch { actionError = error.localizedDescription }
    }

    func retry() {
        actionError = nil
        retryAction()
    }

    static func guidance(_ conflict: SeratoPathConflict) -> String {
        var identities = Set<ConflictPhysicalIdentity>()
        var uncertain = false
        for occurrence in conflict.occurrences {
            switch occurrence.observation {
            case let .existing(identity): identities.insert(identity)
            case .missing: break
            case .inaccessible, .offline, .unknown, .failed: uncertain = true
            }
        }
        let diagnosis = switch identities.count {
        case 0: "No live file was verified. Do not assume the audio is deleted."
        case 1: "The verified references resolve to one physical file. Preserve its audio and your preferred metadata and crate memberships."
        default: "The references resolve to distinct physical files. Inspect each file before choosing which library references to retain."
        }
        let rename = conflict.renameSource.map { source in SeratoConflictMessages.renameCollision(from: source, to: conflict.id) + " " } ?? ""
        return rename + diagnosis + (uncertain ? " Some locations could not be inspected. Restore access before deciding an entry is stale." : "")
    }

    static func describe(_ occurrence: SeratoConflictOccurrence) -> String {
        let record = occurrence.record
        let scalars = record.path.unicodeScalars.map { scalar in String(format: "U+%04X", scalar.value) }.joined(separator: " ")
        let bytes = occurrence.rawPathBytes.map { byte in String(format: "%02X", byte) }.joined(separator: " ")
        let metadata: [(String, String?)] = [("Artist", record.artist), ("Title", record.title), ("Album", record.album),
                                             ("Genre", record.genre), ("BPM", record.bpm), ("Key", record.key),
                                             ("Comment", record.comment), ("Length", record.length), ("Label", record.label)]
        return (["Saved entry \(occurrence.id + 1): \(record.path)", observationText(occurrence.observation),
                 "Unicode: \(scalars)", "UTF-8: \(bytes)"]
                + metadata.map { label, value in "\(label): \(value ?? "Not saved")" }).joined(separator: "\n")
    }

    static func observationText(_ observation: ConflictPathObservation) -> String {
        switch observation {
        case let .existing(identity): "Accessible file · volume \(identity.volumeID) · inode \(identity.inode)"
        case .missing: "File missing at this path"
        case .inaccessible: "Access denied — restore access before deciding"
        case .offline: "Volume offline — reconnect before deciding"
        case .unknown: "File availability unknown — inspect before deciding"
        case let .failed(message): "Inspection failed: \(message)"
        }
    }
}
