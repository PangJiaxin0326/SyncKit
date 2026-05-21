import Foundation

public protocol JournalSyncProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func accountStatus() async -> CloudAccountStatus
    func uploadJournal(_ snapshot: JournalSyncSnapshot) async throws -> SyncResult
    func downloadJournal() async throws -> DownloadResult
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

public struct DownloadResult: Codable, Hashable, Sendable {
    public var snapshot: JournalSyncSnapshot
    public var recordsDownloaded: Int
    public var entriesDownloaded: Int
    public var blocksDownloaded: Int
    public var mediaDownloaded: Int
    public var mediaSkipped: Int
    public var completedAt: Date

    public init(
        snapshot: JournalSyncSnapshot,
        recordsDownloaded: Int,
        entriesDownloaded: Int,
        blocksDownloaded: Int,
        mediaDownloaded: Int,
        mediaSkipped: Int,
        completedAt: Date = Date()
    ) {
        self.snapshot = snapshot
        self.recordsDownloaded = recordsDownloaded
        self.entriesDownloaded = entriesDownloaded
        self.blocksDownloaded = blocksDownloaded
        self.mediaDownloaded = mediaDownloaded
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
