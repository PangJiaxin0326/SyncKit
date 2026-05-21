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

    public func downloadJournal() async throws -> DownloadResult {
        let status = await accountStatus()
        guard status.isAvailable else {
            throw SyncError.unavailableAccount(status)
        }

        let entryRecords = try await fetchRecords(recordType: RecordType.entry)
        let blockRecords = try await fetchRecords(recordType: RecordType.block)
        let mediaRecords = try await fetchRecords(recordType: RecordType.media)
        let payload = CloudKitJournalRecordDecoder.snapshot(
            entryRecords: entryRecords,
            blockRecords: blockRecords,
            mediaRecords: mediaRecords
        )

        return DownloadResult(
            snapshot: payload.snapshot,
            recordsDownloaded: entryRecords.count + blockRecords.count + mediaRecords.count,
            entriesDownloaded: payload.snapshot.entries.count,
            blocksDownloaded: payload.snapshot.blockCount,
            mediaDownloaded: payload.mediaAttachmentCount,
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

    private func fetchRecords(recordType: String) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        do {
            repeat {
                let page = try await fetchRecordPage(recordType: recordType, cursor: cursor)
                records.append(contentsOf: page.records)
                cursor = page.cursor
            } while cursor != nil
        } catch where error.isMissingCloudKitRecordType {
            return []
        }

        return records
    }

    private func fetchRecordPage(
        recordType: String,
        cursor: CKQueryOperation.Cursor?
    ) async throws -> CloudKitQueryPage {
        try await withCheckedThrowingContinuation { continuation in
            let operation = if let cursor {
                CKQueryOperation(cursor: cursor)
            } else {
                CKQueryOperation(
                    query: CKQuery(
                        recordType: recordType,
                        predicate: NSPredicate(value: true)
                    )
                )
            }

            let records = LockedCloudKitRecords()
            let errors = LockedCloudKitErrors()
            operation.resultsLimit = CKQueryOperation.maximumResults
            operation.qualityOfService = .userInitiated
            operation.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    records.append(record)
                case .failure(let error):
                    errors.append(error)
                }
            }
            operation.queryResultBlock = { result in
                if let recordError = errors.first {
                    continuation.resume(throwing: recordError)
                    return
                }

                switch result {
                case .success(let cursor):
                    continuation.resume(
                        returning: CloudKitQueryPage(
                            records: records.values,
                            cursor: cursor
                        )
                    )
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
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

private struct CloudKitJournalDownloadPayload {
    var snapshot: JournalSyncSnapshot
    var mediaAttachmentCount: Int
    var skippedMediaCount: Int
}

private struct CloudKitQueryPage {
    var records: [CKRecord]
    var cursor: CKQueryOperation.Cursor?
}

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

private enum CloudKitJournalRecordFactory {

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

private enum CloudKitJournalRecordDecoder {
    private struct DecodedBlock {
        var entryExternalID: String
        var block: JournalSyncBlock
    }

    private struct DecodedMedia {
        var blockExternalID: String
        var attachment: JournalSyncMediaAttachment
    }

    static func snapshot(
        entryRecords: [CKRecord],
        blockRecords: [CKRecord],
        mediaRecords: [CKRecord]
    ) -> CloudKitJournalDownloadPayload {
        var skippedMediaCount = 0
        let mediaByBlockID = Dictionary(
            uniqueKeysWithValues: mediaRecords.compactMap { record -> (String, JournalSyncMediaAttachment)? in
                guard let media = decodedMedia(from: record) else {
                    skippedMediaCount += 1
                    return nil
                }
                return (media.blockExternalID, media.attachment)
            }
        )

        let blocksByEntryID = Dictionary(
            grouping: blockRecords.compactMap { decodedBlock(from: $0, mediaByBlockID: mediaByBlockID) },
            by: \.entryExternalID
        )
        let entries = entryRecords.compactMap { record -> JournalSyncEntry? in
            let externalID = record.stringValue(Field.externalID)
            let blocks = (blocksByEntryID[externalID] ?? [])
                .map(\.block)
                .sorted { $0.order < $1.order }
            return decodedEntry(from: record, blocks: blocks)
        }
        .sorted { lhs, rhs in
            lhs.dateModified > rhs.dateModified
        }

        let snapshot = JournalSyncSnapshot(entries: entries)
        return CloudKitJournalDownloadPayload(
            snapshot: snapshot,
            mediaAttachmentCount: snapshot.mediaAttachments.count,
            skippedMediaCount: skippedMediaCount
        )
    }

    private static func decodedEntry(
        from record: CKRecord,
        blocks: [JournalSyncBlock]
    ) -> JournalSyncEntry? {
        guard let id = UUID(uuidString: record.stringValue(Field.externalID)) else {
            return nil
        }

        let dateCreated = record.dateValue(Field.dateCreated)
            ?? record.creationDate
            ?? Date()
        let dateModified = record.dateValue(Field.dateModified)
            ?? record.modificationDate
            ?? dateCreated

        return JournalSyncEntry(
            id: id,
            title: record.stringValue(Field.title),
            dateCreated: dateCreated,
            dateModified: dateModified,
            iconSymbol: record.stringValue(Field.iconSymbol),
            iconColor: record.stringValue(Field.iconColor),
            context: record.stringValue(Field.context),
            blocks: blocks
        )
    }

    private static func decodedBlock(
        from record: CKRecord,
        mediaByBlockID: [String: JournalSyncMediaAttachment]
    ) -> DecodedBlock? {
        let externalID = record.stringValue(Field.externalID)
        guard let id = UUID(uuidString: externalID) else {
            return nil
        }

        let entryExternalID = record.stringValue(Field.entryExternalID)
        guard !entryExternalID.isEmpty else {
            return nil
        }

        let dateCreated = record.dateValue(Field.dateCreated)
            ?? record.creationDate
            ?? Date()
        let dateModified = record.dateValue(Field.dateModified)
            ?? record.modificationDate
            ?? dateCreated

        let block = JournalSyncBlock(
            id: id,
            kind: record.stringValue(Field.kind, fallback: "freestyle"),
            question: record.stringValue(Field.question),
            content: record.stringValue(Field.content),
            order: record.intValue(Field.order),
            dateCreated: dateCreated,
            dateModified: dateModified,
            mediaDuration: record.doubleValue(Field.mediaDuration),
            transcript: record.stringValue(Field.transcript),
            aiTranscript: record.stringValue(Field.aiTranscript),
            media: mediaByBlockID[externalID]
        )

        return DecodedBlock(entryExternalID: entryExternalID, block: block)
    }

    private static func decodedMedia(from record: CKRecord) -> DecodedMedia? {
        let blockExternalID = record.stringValue(Field.blockExternalID)
        guard !blockExternalID.isEmpty else { return nil }
        guard let asset = record[Field.asset] as? CKAsset else { return nil }
        guard let fileURL = asset.fileURL else { return nil }

        let relativePath = record.stringValue(
            Field.mediaPath,
            fallback: record.stringValue(
                Field.fileName,
                fallback: fileURL.lastPathComponent
            )
        )
        guard !relativePath.isEmpty else { return nil }

        return DecodedMedia(
            blockExternalID: blockExternalID,
            attachment: JournalSyncMediaAttachment(
                relativePath: relativePath,
                fileURL: fileURL
            )
        )
    }
}

private final class LockedCloudKitRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CKRecord] = []

    var values: [CKRecord] {
        lock.withLock { storage }
    }

    func append(_ record: CKRecord) {
        lock.withLock {
            storage.append(record)
        }
    }
}

private final class LockedCloudKitErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var first: Error? {
        lock.withLock { storage.first }
    }

    func append(_ error: Error) {
        lock.withLock {
            storage.append(error)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private extension CKRecord {
    func stringValue(_ field: String, fallback: String = "") -> String {
        switch self[field] {
        case let value as String:
            value
        case let value as NSString:
            value as String
        default:
            fallback
        }
    }

    func intValue(_ field: String, fallback: Int = 0) -> Int {
        switch self[field] {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            fallback
        }
    }

    func doubleValue(_ field: String, fallback: Double = 0) -> Double {
        switch self[field] {
        case let value as Double:
            value
        case let value as NSNumber:
            value.doubleValue
        default:
            fallback
        }
    }

    func dateValue(_ field: String) -> Date? {
        switch self[field] {
        case let value as Date:
            value
        case let value as NSDate:
            value as Date
        default:
            nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Error {
    var isMissingCloudKitRecordType: Bool {
        guard let error = self as? CKError else { return false }
        if error.code == .unknownItem {
            return true
        }

        return error.localizedDescription.localizedCaseInsensitiveContains("record type")
    }
}
