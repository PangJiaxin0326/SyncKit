import Foundation

public protocol JournalSyncProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func accountStatus() async -> CloudAccountStatus
    func uploadJournal(_ snapshot: JournalSyncSnapshot) async throws -> SyncResult
}

public enum CloudAccountStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case available
    case couldNotDetermine
    case noAccount
    case restricted
    case temporarilyUnavailable

    public var isAvailable: Bool {
        self == .available
    }

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .couldNotDetermine: "Unknown"
        case .noAccount: "No iCloud Account"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        }
    }
}

public struct SyncResult: Codable, Hashable, Sendable {
    public var recordsUploaded: Int
    public var entriesUploaded: Int
    public var blocksUploaded: Int
    public var mediaUploaded: Int
    public var mediaSkipped: Int
    public var completedAt: Date

    public init(
        recordsUploaded: Int,
        entriesUploaded: Int,
        blocksUploaded: Int,
        mediaUploaded: Int,
        mediaSkipped: Int,
        completedAt: Date = Date()
    ) {
        self.recordsUploaded = recordsUploaded
        self.entriesUploaded = entriesUploaded
        self.blocksUploaded = blocksUploaded
        self.mediaUploaded = mediaUploaded
        self.mediaSkipped = mediaSkipped
        self.completedAt = completedAt
    }
}

public enum SyncError: LocalizedError, Equatable, Sendable {
    case unavailableAccount(CloudAccountStatus)

    public var errorDescription: String? {
        switch self {
        case .unavailableAccount(let status):
            "iCloud is \(status.displayName.lowercased())."
        }
    }
}
