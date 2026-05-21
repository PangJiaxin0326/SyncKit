import CloudKit
import Foundation

public enum CloudKitDatabaseScope: String, Codable, Hashable, Sendable {
    case `private`
    case `public`
    case shared
}

public final class CloudKitJournalSyncProvider: JournalSyncProvider {
    public let id = "cloudkit"
    public let displayName = "iCloud"

    public let containerIdentifier: String
    public let databaseScope: CloudKitDatabaseScope

    private let container: CKContainer
    private let maxRecordsPerBatch: Int

    public init(
        containerIdentifier: String,
        databaseScope: CloudKitDatabaseScope = .private,
        maxRecordsPerBatch: Int = 100
    ) {
        self.containerIdentifier = containerIdentifier
        self.databaseScope = databaseScope
        self.container = CKContainer(identifier: containerIdentifier)
        self.maxRecordsPerBatch = max(1, maxRecordsPerBatch)
    }

    public func accountStatus() async -> CloudAccountStatus {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                if error != nil {
                    continuation.resume(returning: .couldNotDetermine)
                } else {
                    continuation.resume(returning: CloudAccountStatus(cloudKitStatus: status))
                }
            }
        }
    }

    public func uploadJournal(_ snapshot: JournalSyncSnapshot) async throws -> SyncResult {
        let status = await accountStatus()
        guard status.isAvailable else {
            throw SyncError.unavailableAccount(status)
        }

        let payload = CloudKitJournalRecordFactory.records(from: snapshot)
        for batch in payload.records.chunked(into: maxRecordsPerBatch) {
            _ = try await database.modifyRecords(
                saving: batch,
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
        }

        return SyncResult(
            recordsUploaded: payload.records.count,
            entriesUploaded: snapshot.entries.count,
            blocksUploaded: snapshot.blockCount,
            mediaUploaded: payload.mediaRecordCount,
            mediaSkipped: payload.skippedMediaCount
        )
    }

    private var database: CKDatabase {
        switch databaseScope {
        case .private: container.privateCloudDatabase
        case .public: container.publicCloudDatabase
        case .shared: container.sharedCloudDatabase
        }
    }
}

private extension CloudAccountStatus {
    init(cloudKitStatus status: CKAccountStatus) {
        switch status {
        case .available:
            self = .available
        case .couldNotDetermine:
            self = .couldNotDetermine
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable
        @unknown default:
            self = .couldNotDetermine
        }
    }
}

private struct CloudKitJournalRecordPayload {
    var records: [CKRecord]
    var mediaRecordCount: Int
    var skippedMediaCount: Int
}

private enum CloudKitJournalRecordFactory {
    private enum RecordType {
        static let entry = "JournalEntry"
        static let block = "JournalBlock"
        static let media = "JournalMedia"
    }

    private enum Field {
        static let schemaVersion = "schemaVersion"
        static let externalID = "externalID"
        static let entryExternalID = "entryExternalID"
        static let blockExternalID = "blockExternalID"
        static let entryReference = "entryReference"
        static let blockReference = "blockReference"
        static let title = "title"
        static let dateCreated = "dateCreated"
        static let dateModified = "dateModified"
        static let iconSymbol = "iconSymbol"
        static let iconColor = "iconColor"
        static let context = "context"
        static let kind = "kind"
        static let question = "question"
        static let content = "content"
        static let order = "order"
        static let mediaDuration = "mediaDuration"
        static let transcript = "transcript"
        static let aiTranscript = "aiTranscript"
        static let mediaPath = "mediaPath"
        static let asset = "asset"
        static let fileName = "fileName"
        static let generatedAt = "generatedAt"
    }

    static func records(from snapshot: JournalSyncSnapshot) -> CloudKitJournalRecordPayload {
        var records: [CKRecord] = []
        var mediaRecordCount = 0
        var skippedMediaCount = 0

        for entry in snapshot.entries {
            let entryID = entryRecordID(entry.id)
            records.append(entryRecord(for: entry, recordID: entryID, generatedAt: snapshot.generatedAt))

            for block in entry.blocks {
                let blockID = blockRecordID(block.id)
                records.append(blockRecord(for: block, entryID: entryID, entryExternalID: entry.id.uuidString))

                guard let media = block.media else { continue }
                guard FileManager.default.fileExists(atPath: media.fileURL.path) else {
                    skippedMediaCount += 1
                    continue
                }

                records.append(
                    mediaRecord(
                        for: media,
                        block: block,
                        entryID: entryID,
                        blockID: blockID,
                        entryExternalID: entry.id.uuidString
                    )
                )
                mediaRecordCount += 1
            }
        }

        return CloudKitJournalRecordPayload(
            records: records,
            mediaRecordCount: mediaRecordCount,
            skippedMediaCount: skippedMediaCount
        )
    }

    private static func entryRecord(
        for entry: JournalSyncEntry,
        recordID: CKRecord.ID,
        generatedAt: Date
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.entry, recordID: recordID)
        record[Field.schemaVersion] = NSNumber(value: 1)
        record[Field.externalID] = entry.id.uuidString as NSString
        record[Field.title] = entry.title as NSString
        record[Field.dateCreated] = entry.dateCreated as NSDate
        record[Field.dateModified] = entry.dateModified as NSDate
        record[Field.iconSymbol] = entry.iconSymbol as NSString
        record[Field.iconColor] = entry.iconColor as NSString
        record[Field.context] = entry.context as NSString
        record[Field.generatedAt] = generatedAt as NSDate
        return record
    }

    private static func blockRecord(
        for block: JournalSyncBlock,
        entryID: CKRecord.ID,
        entryExternalID: String
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.block, recordID: blockRecordID(block.id))
        record[Field.schemaVersion] = NSNumber(value: 1)
        record[Field.externalID] = block.id.uuidString as NSString
        record[Field.entryExternalID] = entryExternalID as NSString
        record[Field.entryReference] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        record[Field.kind] = block.kind as NSString
        record[Field.question] = block.question as NSString
        record[Field.content] = block.content as NSString
        record[Field.order] = NSNumber(value: block.order)
        record[Field.dateCreated] = block.dateCreated as NSDate
        record[Field.dateModified] = block.dateModified as NSDate
        record[Field.mediaDuration] = NSNumber(value: block.mediaDuration)
        record[Field.transcript] = block.transcript as NSString
        record[Field.aiTranscript] = block.aiTranscript as NSString
        record[Field.mediaPath] = (block.media?.relativePath ?? "") as NSString
        return record
    }

    private static func mediaRecord(
        for media: JournalSyncMediaAttachment,
        block: JournalSyncBlock,
        entryID: CKRecord.ID,
        blockID: CKRecord.ID,
        entryExternalID: String
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.media, recordID: mediaRecordID(block.id))
        record[Field.schemaVersion] = NSNumber(value: 1)
        record[Field.externalID] = media.relativePath as NSString
        record[Field.entryExternalID] = entryExternalID as NSString
        record[Field.blockExternalID] = block.id.uuidString as NSString
        record[Field.entryReference] = CKRecord.Reference(recordID: entryID, action: .deleteSelf)
        record[Field.blockReference] = CKRecord.Reference(recordID: blockID, action: .deleteSelf)
        record[Field.mediaPath] = media.relativePath as NSString
        record[Field.fileName] = media.fileURL.lastPathComponent as NSString
        record[Field.asset] = CKAsset(fileURL: media.fileURL)
        return record
    }

    private static func entryRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "journal-entry-\(id.uuidString)")
    }

    private static func blockRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "journal-block-\(id.uuidString)")
    }

    private static func mediaRecordID(_ blockID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "journal-media-\(blockID.uuidString)")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
