import Foundation
import AIToolKit

/// Tool errors thrown by the sync tools. Marked retriable by default so the
/// orchestrator can surface the message to the model on the next iteration.
public struct JournalSyncToolError: ToolError, CustomStringConvertible {
    public let message: String
    public let isRetriable: Bool

    public init(_ message: String, isRetriable: Bool = false) {
        self.message = message
        self.isRetriable = isRetriable
    }

    public var description: String { message }
}

// MARK: - Account status

public struct CheckSyncAccountStatusTool: Tool {
    public struct Input: Codable, Sendable { public init() {} }
    public struct Output: Codable, Sendable {
        public var providerID: String
        public var displayName: String
        public var status: String
        public var statusDisplayName: String
        public var isAvailable: Bool
    }

    public static let name = "checkSyncAccountStatus"
    public static let description = """
    Check whether the configured sync provider (iCloud by default) is available \
    on this device. Use before calling uploadJournalSnapshot or \
    downloadJournalSnapshot to fail fast with a clear message.
    """
    public static let schema = ToolSchema.object(properties: [:])

    private let provider: any JournalSyncProvider

    public init(provider: any JournalSyncProvider) {
        self.provider = provider
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let status = await provider.accountStatus()
        return Output(
            providerID: provider.id,
            displayName: provider.displayName,
            status: status.rawValue,
            statusDisplayName: status.displayName,
            isAvailable: status.isAvailable
        )
    }
}

// MARK: - Upload

public struct UploadJournalSnapshotTool: Tool {
    public struct Input: Codable, Sendable { public init() {} }
    public struct Output: Codable, Sendable {
        public var providerID: String
        public var recordsUploaded: Int
        public var entriesUploaded: Int
        public var blocksUploaded: Int
        public var mediaUploaded: Int
        public var mediaSkipped: Int
        public var completedAt: Date
    }

    public static let name = "uploadJournalSnapshot"
    public static let description = """
    Upload the current local journal (every entry, block, and media file the \
    host marks as syncable) to the configured cloud provider. The host builds \
    the snapshot — this tool takes no arguments. Reports counts of records \
    uploaded.
    """
    public static let schema = ToolSchema.object(properties: [:])

    private let provider: any JournalSyncProvider
    private let host: any JournalSyncHost

    public init(provider: any JournalSyncProvider, host: any JournalSyncHost) {
        self.provider = provider
        self.host = host
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let snapshot: JournalSyncSnapshot
        do {
            snapshot = try await host.makeSnapshot()
        } catch {
            throw JournalSyncToolError(
                "Couldn't build a snapshot to upload: \(error.localizedDescription)"
            )
        }
        let result: SyncResult
        do {
            result = try await provider.uploadJournal(snapshot)
        } catch let syncError as SyncError {
            throw JournalSyncToolError(
                syncError.errorDescription ?? "\(syncError)",
                isRetriable: syncError == .unavailableAccount(.temporarilyUnavailable)
            )
        } catch {
            throw JournalSyncToolError(
                "Upload failed: \(error.localizedDescription)", isRetriable: true
            )
        }
        return Output(
            providerID: provider.id,
            recordsUploaded: result.recordsUploaded,
            entriesUploaded: result.entriesUploaded,
            blocksUploaded: result.blocksUploaded,
            mediaUploaded: result.mediaUploaded,
            mediaSkipped: result.mediaSkipped,
            completedAt: result.completedAt
        )
    }
}

// MARK: - Download

public struct DownloadJournalSnapshotTool: Tool {
    public struct Input: Codable, Sendable { public init() {} }
    public struct Output: Codable, Sendable {
        public var providerID: String
        public var recordsDownloaded: Int
        public var entriesDownloaded: Int
        public var blocksDownloaded: Int
        public var mediaDownloaded: Int
        public var mediaSkipped: Int
        public var entriesMerged: Int
        public var completedAt: Date
    }

    public static let name = "downloadJournalSnapshot"
    public static let description = """
    Download the latest journal snapshot from the cloud and merge it back into \
    the local store. Use to pull edits made on another device, or to restore \
    after a fresh install. Reports counts downloaded and how many entries the \
    host merged.
    """
    public static let schema = ToolSchema.object(properties: [:])

    private let provider: any JournalSyncProvider
    private let host: any JournalSyncHost

    public init(provider: any JournalSyncProvider, host: any JournalSyncHost) {
        self.provider = provider
        self.host = host
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let download: DownloadResult
        do {
            download = try await provider.downloadJournal()
        } catch let syncError as SyncError {
            throw JournalSyncToolError(
                syncError.errorDescription ?? "\(syncError)"
            )
        } catch {
            throw JournalSyncToolError(
                "Download failed: \(error.localizedDescription)", isRetriable: true
            )
        }
        let merged: Int
        do {
            merged = try await host.apply(download.snapshot)
        } catch {
            throw JournalSyncToolError(
                "Couldn't merge the downloaded snapshot: \(error.localizedDescription)"
            )
        }
        return Output(
            providerID: provider.id,
            recordsDownloaded: download.recordsDownloaded,
            entriesDownloaded: download.entriesDownloaded,
            blocksDownloaded: download.blocksDownloaded,
            mediaDownloaded: download.mediaDownloaded,
            mediaSkipped: download.mediaSkipped,
            entriesMerged: merged,
            completedAt: download.completedAt
        )
    }
}

// MARK: - Remote-delete a single entry

public struct DeleteRemoteJournalEntryTool: Tool {
    public struct Input: Codable, Sendable {
        public var entryID: String
        public init(entryID: String) { self.entryID = entryID }
    }
    public struct Output: Codable, Sendable {
        public var providerID: String
        public var entryID: String
        public var deleted: Bool
    }

    public static let name = "deleteRemoteJournalEntry"
    public static let description = """
    Permanently delete one entry — and all of its blocks and media — from the \
    cloud provider. Pass the entry's local UUID. Use only when the user clearly \
    asks for an all-devices delete (e.g. "delete for all"); a local-only delete \
    is a different tool.
    """
    public static let schema = ToolSchema.object(
        properties: [
            "entryID": .string(description: "The entry's UUID."),
        ],
        required: ["entryID"]
    )

    private let provider: any JournalSyncProvider
    private let host: any JournalSyncHost

    public init(provider: any JournalSyncProvider, host: any JournalSyncHost) {
        self.provider = provider
        self.host = host
    }

    public func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        let syncEntry: JournalSyncEntry?
        do {
            syncEntry = try await host.syncEntry(forID: input.entryID)
        } catch {
            throw JournalSyncToolError(
                "Couldn't resolve entry \(input.entryID): \(error.localizedDescription)"
            )
        }
        guard let syncEntry else {
            throw JournalSyncToolError(
                "No entry with id \(input.entryID).", isRetriable: false
            )
        }
        do {
            try await provider.deleteEntry(syncEntry)
        } catch let syncError as SyncError {
            throw JournalSyncToolError(
                syncError.errorDescription ?? "\(syncError)"
            )
        } catch {
            throw JournalSyncToolError(
                "Remote delete failed: \(error.localizedDescription)", isRetriable: true
            )
        }
        return Output(
            providerID: provider.id,
            entryID: input.entryID,
            deleted: true
        )
    }
}

// MARK: - Convenience

/// One-call registration for the full sync tool set.
public enum JournalSyncTools {
    public static let toolNames: Set<String> = [
        CheckSyncAccountStatusTool.name,
        UploadJournalSnapshotTool.name,
        DownloadJournalSnapshotTool.name,
        DeleteRemoteJournalEntryTool.name,
    ]

    public static func register(
        in registry: ToolRegistry,
        provider: any JournalSyncProvider,
        host: any JournalSyncHost
    ) async {
        await registry.register(CheckSyncAccountStatusTool(provider: provider))
        await registry.register(UploadJournalSnapshotTool(provider: provider, host: host))
        await registry.register(DownloadJournalSnapshotTool(provider: provider, host: host))
        await registry.register(DeleteRemoteJournalEntryTool(provider: provider, host: host))
    }
}
