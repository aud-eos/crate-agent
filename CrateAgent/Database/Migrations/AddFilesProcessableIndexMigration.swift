import GRDB

/// Indexes `FileProcessingEligibility.processableSQL` and the fingerprint
/// status beside it (#267). Both eligibility columns sit after
/// `chromaprint_fingerprint` in each row, so without the index every
/// eligibility check on a fingerprinted file reads that row's overflow page.
enum AddFilesProcessableIndexMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("028_add_files_processable_index") { database in
            try database.create(index: "files_processable", on: "files",
                                columns: ["library_membership", "file_availability", "fingerprint_status"])
        }
    }
}
