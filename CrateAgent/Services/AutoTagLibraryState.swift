import Foundation
import GRDB

@MainActor
final class AutoTagLibraryState: ObservableObject {
    @Published private(set) var fileCount = 0
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?

    func observe(in database: LibraryDatabase) async {
        isLoading = true
        error = nil
        do {
            let observation = ValueObservation.tracking { db in try FileRecord.fetchCount(db) }.removeDuplicates()
            for try await count in observation.values(in: database.writer) {
                guard !Task.isCancelled else { return }
                fileCount = count
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}
