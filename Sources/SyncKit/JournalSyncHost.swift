import Foundation

/// Host-side adapter that bridges a `JournalSyncProvider` to the app's local
/// data store. Each method is the smallest hook the sync tools need from the
/// host:
///
/// - `makeSnapshot()` collects everything the host wants uploaded.
/// - `apply(_:)` merges a downloaded snapshot back into local storage and
///   reports how many entries it changed.
/// - `syncEntry(forID:)` resolves a writer-facing entry id to a
///   `JournalSyncEntry` so the delete tool can build the right record id set
///   without forcing the host to import the provider.
public protocol JournalSyncHost: Sendable {
    func makeSnapshot() async throws -> JournalSyncSnapshot
    func apply(_ snapshot: JournalSyncSnapshot) async throws -> Int
    func syncEntry(forID id: String) async throws -> JournalSyncEntry?
}
