import Foundation

/// Reduces `FingerprintWorker` progress, which arrives once per batch,
/// to the few `ActivityLog` entries a person needs: when a run starts,
/// every `fileInterval` files, when it finishes, and any error.
struct FingerprintActivityMilestones {
    static let defaultFileInterval = 500

    private let fileInterval: Int
    private var processedBeforeRun = 0
    private var failedBeforeRun = 0
    private var runIsActive = false
    private var nextMilestone = 0

    init(fileInterval: Int = defaultFileInterval) {
        precondition(fileInterval > 0, "Milestone interval must be positive")
        self.fileInterval = fileInterval
    }

    mutating func entries(for progress: FingerprintWorker.Progress) -> [String] {
        let processed = progress.totalDone + progress.totalFailed
        if let error = progress.error {
            finishRun(progress)
            return [error]
        }
        let processedInRun = processed - processedBeforeRun
        let runTotal = processedInRun + progress.totalPending
        if progress.totalPending == 0 {
            guard runIsActive || processedInRun > 0 else { return [] }
            let failedInRun = progress.totalFailed - failedBeforeRun
            finishRun(progress)
            return ["Fingerprinting finished · \(processedInRun.formatted()) files processed"
                + (failedInRun > 0 ? ", \(failedInRun.formatted()) failed" : "")]
        }
        var entries: [String] = []
        if !runIsActive {
            runIsActive = true
            nextMilestone = fileInterval
            entries.append("Fingerprinting \(runTotal.formatted()) files")
        }
        if processedInRun >= nextMilestone {
            nextMilestone = (processedInRun / fileInterval + 1) * fileInterval
            entries.append("Fingerprinting \(processedInRun.formatted()) of \(runTotal.formatted()) files")
        }
        return entries
    }

    private mutating func finishRun(_ progress: FingerprintWorker.Progress) {
        runIsActive = false
        processedBeforeRun = progress.totalDone + progress.totalFailed
        failedBeforeRun = progress.totalFailed
    }
}

/// Reduces `LibraryScanner` progress, which arrives every 50 files, to a
/// start entry, an entry every `fileInterval` files, and a summary when
/// the session clears its progress at the end of the scan.
struct ScanActivityMilestones {
    static let defaultFileInterval = 2000

    private let fileInterval: Int
    private var lastProgress: LibraryScanner.ScanProgress?
    private var nextMilestone = 0

    init(fileInterval: Int = defaultFileInterval) {
        precondition(fileInterval > 0, "Milestone interval must be positive")
        self.fileInterval = fileInterval
    }

    mutating func entries(for progress: LibraryScanner.ScanProgress?) -> [String] {
        guard let progress else {
            guard let finished = lastProgress else { return [] }
            lastProgress = nil
            let stoppedEarly = finished.completedFileCount.map { completed in completed < finished.seratoReferenceCount } ?? false
            return ["Library scan \(stoppedEarly ? "stopped" : "finished") · \(Self.checkedSummary(finished))"]
        }
        var entries: [String] = []
        if lastProgress == nil {
            nextMilestone = fileInterval
            entries.append("Scanning \(progress.seratoReferenceCount.formatted()) Serato references")
        }
        lastProgress = progress
        let checked = Self.checkedCount(progress)
        if checked >= nextMilestone, checked < progress.seratoReferenceCount {
            nextMilestone = (checked / fileInterval + 1) * fileInterval
            entries.append("Scanning \(Self.checkedSummary(progress))")
        }
        return entries
    }

    private static func checkedCount(_ progress: LibraryScanner.ScanProgress) -> Int {
        progress.completedFileCount ?? progress.filesIndexed + progress.filesMetadataUpdated + progress.filesSkipped
    }

    private static func checkedSummary(_ progress: LibraryScanner.ScanProgress) -> String {
        "\(checkedCount(progress).formatted()) of \(progress.seratoReferenceCount.formatted()) Serato references — "
            + "\(progress.filesIndexed.formatted()) new, \(progress.filesMetadataUpdated.formatted()) metadata-updated"
            + (progress.filesSkipped > 0 ? ", \(progress.filesSkipped.formatted()) skipped" : "")
    }
}
