import CloudKit
import Foundation

public enum CloudKitDatabaseScope: String, Codable, Hashable, Sendable {
    case `private`
    case `public`
    case shared
}

public final class CloudKitJournalSyncProvider: JournalSyncProvider {
    private static let maxManifestConflictRetries = 2

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

        let existingManifest = try await fetchManifestRecord()
        let payload = CloudKitJournalRecordFactory.records(
            from: snapshot,
            mergingManifest: existingManifest
        )
        for batch in payload.contentRecords.batches(of: maxRecordsPerBatch) {
            try await modifyRecords(
                saving: batch,
                deleting: [],
                savePolicy: .allKeys
            )
        }
        try await saveManifestRecord(
            payload.manifestRecord,
            savePolicy: .allKeys
        ) { _, serverManifest in
            CloudKitManifestConflictResolver.manifestByUploading(
                payload.currentManifestNames,
                generatedAt: snapshot.generatedAt,
                rebasedOn: serverManifest
            )
        }

        return SyncResult(
            recordsUploaded: payload.recordCount,
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

        guard let manifestRecords = try await fetchManifestRecords() else {
            let snapshot = JournalSyncSnapshot(entries: [])
            return DownloadResult(
                snapshot: snapshot,
                recordsDownloaded: 0,
                entriesDownloaded: 0,
                blocksDownloaded: 0,
                mediaDownloaded: 0,
                mediaSkipped: 0
            )
        }

        let records = manifestRecords.records
        let entryRecords = records.filter { $0.recordType == RecordType.entry }
        let blockRecords = records.filter { $0.recordType == RecordType.block }
        let mediaRecords = records.filter { $0.recordType == RecordType.media }
        let payload = CloudKitJournalRecordDecoder.snapshot(
            entryRecords: entryRecords,
            blockRecords: blockRecords,
            mediaRecords: mediaRecords,
            generatedAt: manifestRecords.generatedAt ?? Date()
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

    public func deleteEntry(_ entry: JournalSyncEntry) async throws {
        let status = await accountStatus()
        guard status.isAvailable else {
            throw SyncError.unavailableAccount(status)
        }

        let candidateRecordIDs = CloudKitJournalRecordFactory.recordIDs(forDeleting: entry)
        let candidateRecordNames = Set(candidateRecordIDs.map(\.recordName))
        let manifest = try await fetchManifestRecord()
        let updatedManifest = manifest.map { Self.removing(candidateRecordNames, from: $0) }
        let existingRecordIDs = try await fetchExistingRecordIDs(candidateRecordIDs)

        for batch in existingRecordIDs.batches(of: maxRecordsPerBatch) {
            try await modifyRecords(
                saving: [],
                deleting: batch,
                savePolicy: .changedKeys
            )
        }

        if let updatedManifest {
            try await saveDeletedEntryManifest(
                updatedManifest,
                removing: candidateRecordNames
            )
        }
    }

    private var database: CKDatabase {
        switch databaseScope {
        case .private: container.privateCloudDatabase
        case .public: container.publicCloudDatabase
        case .shared: container.sharedCloudDatabase
        }
    }

    private func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        let result = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: recordIDsToDelete,
            savePolicy: savePolicy,
            atomically: false
        )
        try CloudKitRecordModificationValidator.validate(
            result,
            saving: recordsToSave.map(\.recordID),
            deleting: recordIDsToDelete
        )
    }

    private func saveManifestRecord(
        _ manifestRecord: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        rebasing rebase: (CKRecord, CKRecord) -> CKRecord
    ) async throws {
        try await CloudKitManifestConflictRetrier.save(
            manifestRecord,
            maxRetries: Self.maxManifestConflictRetries
        ) { manifest in
            try await modifyRecords(
                saving: [manifest],
                deleting: [],
                savePolicy: savePolicy
            )
        } rebasing: { manifest, serverManifest in
            rebase(manifest, serverManifest)
        }
    }

    private func saveDeletedEntryManifest(
        _ manifestRecord: CKRecord,
        removing recordNames: Set<String>
    ) async throws {
        try await saveManifestRecord(
            manifestRecord,
            savePolicy: .changedKeys
        ) { _, serverManifest in
            CloudKitManifestConflictResolver.manifestByDeleting(
                recordNames,
                rebasedOn: serverManifest
            )
        }
    }

    private func fetchManifestRecords() async throws -> CloudKitFetchedManifestRecords? {
        guard let manifest = try await fetchManifestRecord() else {
            return nil
        }

        let recordNames = manifest.stringArrayValue(Field.entryRecordNames)
            + manifest.stringArrayValue(Field.blockRecordNames)
            + manifest.stringArrayValue(Field.mediaRecordNames)
        return CloudKitFetchedManifestRecords(
            generatedAt: manifest.dateValue(Field.generatedAt),
            records: try await fetchRecords(named: recordNames)
        )
    }

    private func fetchManifestRecord() async throws -> CKRecord? {
        let recordID = CloudKitJournalRecordFactory.manifestRecordID()
        let results = try await database.records(for: [recordID])
        guard let result = results[recordID] else {
            return nil
        }

        switch result {
        case .success(let record):
            return record
        case .failure(let error) where error.isMissingCloudKitRecord:
            return nil
        case .failure(let error):
            throw error
        }
    }

    private func fetchRecords(named recordNames: [String]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        let recordIDs = recordNames.map(CKRecord.ID.init(recordName:))
        for batch in recordIDs.batches(of: maxRecordsPerBatch) {
            let results = try await database.records(for: batch)
            for result in results.values {
                switch result {
                case .success(let record):
                    records.append(record)
                case .failure(let error) where error.isMissingCloudKitRecord:
                    continue
                case .failure(let error):
                    throw error
                }
            }
        }
        return records
    }

    private func fetchExistingRecordIDs(_ recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        var existingRecordIDs: [CKRecord.ID] = []
        for batch in recordIDs.batches(of: maxRecordsPerBatch) {
            let results = try await database.records(for: batch)
            for (recordID, result) in results {
                switch result {
                case .success:
                    existingRecordIDs.append(recordID)
                case .failure(let error) where error.isMissingCloudKitRecord:
                    continue
                case .failure(let error):
                    throw error
                }
            }
        }
        return existingRecordIDs
    }

    private static func removing(_ recordNames: Set<String>, from manifest: CKRecord) -> CKRecord {
        CloudKitManifestConflictResolver.manifestByDeleting(recordNames, rebasedOn: manifest)
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

private struct CloudKitFetchedManifestRecords {
    var generatedAt: Date?
    var records: [CKRecord]
}

enum CloudKitRecordModificationError: LocalizedError, Equatable, Sendable {
    case missingSaveResult(String)
    case missingDeleteResult(String)

    var errorDescription: String? {
        switch self {
        case .missingSaveResult(let recordName):
            "CloudKit did not return a save result for \(recordName)."
        case .missingDeleteResult(let recordName):
            "CloudKit did not return a delete result for \(recordName)."
        }
    }
}

enum CloudKitRecordModificationValidator {
    static func validate(
        _ results: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        ),
        saving recordIDsToSave: [CKRecord.ID],
        deleting recordIDsToDelete: [CKRecord.ID]
    ) throws {
        for result in results.saveResults.values {
            if case .failure(let error) = result {
                throw error
            }
        }
        for result in results.deleteResults.values {
            if case .failure(let error) = result {
                throw error
            }
        }

        for recordID in recordIDsToSave where results.saveResults[recordID] == nil {
            throw CloudKitRecordModificationError.missingSaveResult(recordID.recordName)
        }
        for recordID in recordIDsToDelete where results.deleteResults[recordID] == nil {
            throw CloudKitRecordModificationError.missingDeleteResult(recordID.recordName)
        }
    }
}

enum CloudKitRecordConflict {
    static func serverRecordChangedRecord(
        from error: any Error,
        for recordID: CKRecord.ID
    ) -> CKRecord? {
        if let serverRecord = directServerRecordChangedRecord(from: error, for: recordID) {
            return serverRecord
        }
        guard let partialError = partialError(from: error, for: recordID) else {
            return nil
        }
        return directServerRecordChangedRecord(from: partialError, for: recordID)
    }

    private static func directServerRecordChangedRecord(
        from error: any Error,
        for recordID: CKRecord.ID
    ) -> CKRecord? {
        if let cloudKitError = error as? CKError {
            guard cloudKitError.code == .serverRecordChanged else {
                return nil
            }
            guard let serverRecord = cloudKitError.serverRecord else {
                return nil
            }
            return serverRecord.recordID == recordID ? serverRecord : nil
        }

        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              CKError.Code(rawValue: nsError.code) == .serverRecordChanged,
              let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        else {
            return nil
        }
        return serverRecord.recordID == recordID ? serverRecord : nil
    }

    private static func partialError(
        from error: any Error,
        for recordID: CKRecord.ID
    ) -> (any Error)? {
        if let cloudKitError = error as? CKError,
           let partialError = cloudKitError.partialErrorsByItemID?[AnyHashable(recordID)] {
            return partialError
        }

        let userInfo = (error as NSError).userInfo
        if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
            return partialErrors[AnyHashable(recordID)]
        }
        if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary {
            return partialErrors[recordID] as? any Error
        }
        return nil
    }
}

enum CloudKitManifestConflictRetrier {
    static func save(
        _ initialManifest: CKRecord,
        maxRetries: Int,
        using save: (CKRecord) async throws -> Void,
        rebasing rebase: (CKRecord, CKRecord) -> CKRecord
    ) async throws {
        var manifest = initialManifest
        var remainingRetries = max(0, maxRetries)

        while true {
            try Task.checkCancellation()
            do {
                try await save(manifest)
                return
            } catch {
                guard remainingRetries > 0,
                      let serverManifest = CloudKitRecordConflict.serverRecordChangedRecord(
                        from: error,
                        for: manifest.recordID
                      )
                else {
                    throw error
                }

                manifest = rebase(manifest, serverManifest)
                remainingRetries -= 1
            }
        }
    }
}

enum CloudKitManifestConflictResolver {
    static func manifestByUploading(
        _ currentNames: CloudKitManifestRecordNames,
        generatedAt: Date,
        rebasedOn serverManifest: CKRecord
    ) -> CKRecord {
        currentNames
            .merging(CloudKitManifestRecordNames(record: serverManifest))
            .applying(to: serverManifest, generatedAt: generatedAt)
    }

    static func manifestByDeleting(
        _ recordNames: Set<String>,
        rebasedOn serverManifest: CKRecord
    ) -> CKRecord {
        CloudKitManifestRecordNames(record: serverManifest)
            .removing(recordNames)
            .applying(to: serverManifest)
    }
}

struct CloudKitJournalRecordPayload {
    var contentRecords: [CKRecord]
    var manifestRecord: CKRecord
    var currentManifestNames: CloudKitManifestRecordNames
    var mediaRecordCount: Int
    var skippedMediaCount: Int

    var records: [CKRecord] {
        contentRecords + [manifestRecord]
    }

    var recordCount: Int {
        contentRecords.count + 1
    }
}

struct CloudKitManifestRecordNames: Equatable, Sendable {
    var entryRecordNames: [String]
    var blockRecordNames: [String]
    var mediaRecordNames: [String]

    init(
        entryRecordNames: [String],
        blockRecordNames: [String],
        mediaRecordNames: [String]
    ) {
        self.entryRecordNames = entryRecordNames
        self.blockRecordNames = blockRecordNames
        self.mediaRecordNames = mediaRecordNames
    }

    init(record: CKRecord) {
        self.init(
            entryRecordNames: record.stringArrayValue(Field.entryRecordNames),
            blockRecordNames: record.stringArrayValue(Field.blockRecordNames),
            mediaRecordNames: record.stringArrayValue(Field.mediaRecordNames)
        )
    }

    func merging(_ existing: CloudKitManifestRecordNames?) -> CloudKitManifestRecordNames {
        guard let existing else { return self }
        return CloudKitManifestRecordNames(
            entryRecordNames: Self.merged(entryRecordNames, existing.entryRecordNames),
            blockRecordNames: Self.merged(blockRecordNames, existing.blockRecordNames),
            mediaRecordNames: Self.merged(mediaRecordNames, existing.mediaRecordNames)
        )
    }

    func removing(_ recordNames: Set<String>) -> CloudKitManifestRecordNames {
        CloudKitManifestRecordNames(
            entryRecordNames: entryRecordNames.filter { !recordNames.contains($0) },
            blockRecordNames: blockRecordNames.filter { !recordNames.contains($0) },
            mediaRecordNames: mediaRecordNames.filter { !recordNames.contains($0) }
        )
    }

    func applying(to record: CKRecord, generatedAt: Date? = nil) -> CKRecord {
        record[Field.schemaVersion] = NSNumber(value: 1)
        if let generatedAt {
            record[Field.generatedAt] = generatedAt as NSDate
        }
        record[Field.entryRecordNames] = entryRecordNames as NSArray
        record[Field.blockRecordNames] = blockRecordNames as NSArray
        record[Field.mediaRecordNames] = mediaRecordNames as NSArray
        return record
    }

    private static func merged(_ current: [String], _ existing: [String]) -> [String] {
        var seen = Set(current)
        var merged = current
        for name in existing where seen.insert(name).inserted {
            merged.append(name)
        }
        return merged
    }
}

struct CloudKitJournalDownloadPayload {
    var snapshot: JournalSyncSnapshot
    var mediaAttachmentCount: Int
    var skippedMediaCount: Int
}

private enum RecordType {
    static let manifest = "JournalManifest"
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
    static let entryRecordNames = "entryRecordNames"
    static let blockRecordNames = "blockRecordNames"
    static let mediaRecordNames = "mediaRecordNames"
}

enum CloudKitJournalRecordFactory {
    private static let manifestRecordName = "journal-manifest-v1"

    static func records(
        from snapshot: JournalSyncSnapshot,
        mergingManifest existingManifest: CKRecord? = nil
    ) -> CloudKitJournalRecordPayload {
        var contentRecords: [CKRecord] = []
        var entryRecordNames: [String] = []
        var blockRecordNames: [String] = []
        var mediaRecordNames: [String] = []
        var mediaRecordCount = 0
        var skippedMediaCount = 0

        for entry in snapshot.entries {
            let entryID = entryRecordID(entry.id)
            entryRecordNames.append(entryID.recordName)
            contentRecords.append(entryRecord(for: entry, recordID: entryID, generatedAt: snapshot.generatedAt))

            for block in entry.blocks {
                let blockID = blockRecordID(block.id)
                blockRecordNames.append(blockID.recordName)
                contentRecords.append(blockRecord(for: block, entryID: entryID, entryExternalID: entry.id.uuidString))

                guard let media = block.media else { continue }
                guard FileManager.default.fileExists(atPath: media.fileURL.path) else {
                    skippedMediaCount += 1
                    continue
                }

                let mediaID = mediaRecordID(block.id)
                mediaRecordNames.append(mediaID.recordName)
                contentRecords.append(
                    mediaRecord(
                        for: media,
                        block: block,
                        entryID: entryID,
                        blockID: blockID,
                        recordID: mediaID,
                        entryExternalID: entry.id.uuidString
                    )
                )
                mediaRecordCount += 1
            }
        }

        let currentManifestNames = CloudKitManifestRecordNames(
            entryRecordNames: entryRecordNames,
            blockRecordNames: blockRecordNames,
            mediaRecordNames: mediaRecordNames
        )
        let manifestNames = currentManifestNames
            .merging(existingManifest.map(CloudKitManifestRecordNames.init(record:)))
        let manifest = manifestRecord(
            generatedAt: snapshot.generatedAt,
            names: manifestNames
        )

        return CloudKitJournalRecordPayload(
            contentRecords: contentRecords,
            manifestRecord: manifest,
            currentManifestNames: currentManifestNames,
            mediaRecordCount: mediaRecordCount,
            skippedMediaCount: skippedMediaCount
        )
    }

    static func manifestRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: manifestRecordName)
    }

    static func recordIDs(forDeleting entry: JournalSyncEntry) -> [CKRecord.ID] {
        [entryRecordID(entry.id)]
            + entry.blocks.map { blockRecordID($0.id) }
            + entry.blocks.map { mediaRecordID($0.id) }
    }

    static func manifestRecord(
        generatedAt: Date,
        names: CloudKitManifestRecordNames
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.manifest, recordID: manifestRecordID())
        return names.applying(to: record, generatedAt: generatedAt)
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
        recordID: CKRecord.ID,
        entryExternalID: String
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.media, recordID: recordID)
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

enum CloudKitJournalRecordDecoder {
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
        mediaRecords: [CKRecord],
        generatedAt: Date = Date()
    ) -> CloudKitJournalDownloadPayload {
        var skippedMediaCount = 0
        var mediaByBlockID: [String: JournalSyncMediaAttachment] = [:]
        for record in mediaRecords {
            guard let media = decodedMedia(from: record) else {
                skippedMediaCount += 1
                continue
            }
            guard mediaByBlockID[media.blockExternalID] == nil else {
                skippedMediaCount += 1
                continue
            }
            mediaByBlockID[media.blockExternalID] = media.attachment
        }

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

        let snapshot = JournalSyncSnapshot(generatedAt: generatedAt, entries: entries)
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

private extension Array {
    func batches(of size: Int) -> some Sequence<[Element]> {
        let batchSize = Swift.max(1, size)
        return stride(from: 0, to: count, by: batchSize).lazy.map { start in
            Array(self[start..<Swift.min(start + batchSize, count)])
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

    func stringArrayValue(_ field: String) -> [String] {
        switch self[field] {
        case let values as [String]:
            values
        case let values as [NSString]:
            values.map { $0 as String }
        case let values as NSArray:
            values.compactMap { value in
                switch value {
                case let string as String:
                    string
                case let string as NSString:
                    string as String
                default:
                    nil
                }
            }
        default:
            []
        }
    }
}

private extension Error {
    var isMissingCloudKitRecord: Bool {
        guard let error = self as? CKError else {
            return false
        }
        return error.code == .unknownItem || error.code == .zoneNotFound
    }
}
