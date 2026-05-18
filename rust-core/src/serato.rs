// Serato library I/O.
//
// Wraps the `triseratops` crate to expose high-level operations to the
// Swift app:
//   - read_database() / read_crate(path)
//   - rewrite_path_in_database(old, new)
//   - rewrite_path_in_crate(crate_path, old, new)
//
// All writes are guarded at the Swift layer by SeratoWatchdog — this
// module assumes the caller has already verified Serato is not running.
//
// Implementations land alongside the SP-1 OperationEngine wiring.
