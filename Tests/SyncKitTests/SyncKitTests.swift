import CloudKit
import Foundation
import Testing
@testable import SyncKit

struct SyncKitTests {
    @Test func snapshotCountsBlocksAndMedia() {
        let media = JournalSyncMediaAttachment(
            relativePath: "img-1.jpg",
            fileURL: URL(filePath: "/tmp/img-1.jpg")
        )
        let entry = JournalSyncEntry(
            id: UUID(),
            title: "Trip",
            dateCreated: Date(timeIntervalSince1970: 1),
            dateModified: Date(timeIntervalSince1970: 2),
            iconSymbol: "book.closed.fill",
            iconColor: "accent",
            context: "",
            blocks: [
                JournalSyncBlock(
                    id: UUID(),
                    kind: "freestyle",
                    content: "First day",
                    order: 0,
                    dateCreated: Date(timeIntervalSince1970: 1),
                    dateModified: Date(timeIntervalSince1970: 1)
                ),
                JournalSyncBlock(
                    id: UUID(),
                    kind: "image",
                    order: 1,
                    dateCreated: Date(timeIntervalSince1970: 2),
                    dateModified: Date(timeIntervalSince1970: 2),
                    media: media
                ),
            ]
        )

        let snapshot = JournalSyncSnapshot(entries: [entry])

        #expect(snapshot.blockCount == 2)
        #expect(snapshot.mediaAttachments == [media])
    }

    @Test func downloadResultCarriesSnapshotCounts() {
        let snapshot = JournalSyncSnapshot(entries: [
            JournalSyncEntry(
                id: UUID(),
                title: "Restored",
                dateCreated: Date(timeIntervalSince1970: 1),
                dateModified: Date(timeIntervalSince1970: 2),
                iconSymbol: "book.pages",
                iconColor: "accent",
                context: "",
                blocks: [
                    JournalSyncBlock(
                        id: UUID(),
                        kind: "freestyle",
                        content: "Downloaded",
                        order: 0,
                        dateCreated: Date(timeIntervalSince1970: 1),
                        dateModified: Date(timeIntervalSince1970: 1)
                    ),
                ]
            ),
        ])

        let result = DownloadResult(
            snapshot: snapshot,
            recordsDownloaded: 2,
            entriesDownloaded: snapshot.entries.count,
            blocksDownloaded: snapshot.blockCount,
            mediaDownloaded: 0,
            mediaSkipped: 0,
            completedAt: Date(timeIntervalSince1970: 3)
        )

        #expect(result.entriesDownloaded == 1)
        #expect(result.blocksDownloaded == 1)
        #expect(result.snapshot.entries.first?.blocks.first?.content == "Downloaded")
    }

    @Test func manifestMergeKeepsCloudOnlyRecordsForLocalRestore() {
        let current = CloudKitManifestRecordNames(
            entryRecordNames: ["entry-local", "entry-shared"],
            blockRecordNames: ["block-local"],
            mediaRecordNames: []
        )
        let existing = CloudKitManifestRecordNames(
            entryRecordNames: ["entry-shared", "entry-cloud"],
            blockRecordNames: ["block-cloud", "block-local"],
            mediaRecordNames: ["media-cloud"]
        )

        let merged = current.merging(existing)

        #expect(merged.entryRecordNames == ["entry-local", "entry-shared", "entry-cloud"])
        #expect(merged.blockRecordNames == ["block-local", "block-cloud"])
        #expect(merged.mediaRecordNames == ["media-cloud"])
    }

    @Test func publicModelCodableKeysRemainStable() throws {
        let json = Data(
            """
            {
              "generatedAt": 0,
              "entries": [
                {
                  "id": "00000000-0000-0000-0000-000000000001",
                  "title": "Trip",
                  "dateCreated": 1,
                  "dateModified": 2,
                  "iconSymbol": "book.closed.fill",
                  "iconColor": "accent",
                  "context": "context",
                  "blocks": [
                    {
                      "id": "00000000-0000-0000-0000-000000000002",
                      "kind": "image",
                      "question": "",
                      "content": "Photo",
                      "order": 0,
                      "dateCreated": 1,
                      "dateModified": 2,
                      "mediaDuration": 3.5,
                      "transcript": "human",
                      "aiTranscript": "ai",
                      "media": {
                        "relativePath": "media/photo.jpg",
                        "fileURL": "file:///tmp/photo.jpg"
                      }
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(JournalSyncSnapshot.self, from: json)
        let entry = try #require(snapshot.entries.first)
        let block = try #require(entry.blocks.first)
        let media = try #require(block.media)

        #expect(snapshot.generatedAt == Date(timeIntervalSinceReferenceDate: 0))
        #expect(entry.id.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(entry.iconSymbol == "book.closed.fill")
        #expect(block.mediaDuration == 3.5)
        #expect(block.aiTranscript == "ai")
        #expect(media.relativePath == "media/photo.jpg")
        #expect(media.fileURL.absoluteString == "file:///tmp/photo.jpg")
    }

    @Test func cloudKitRecordRoundTripPreservesManifestGeneratedAt() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_234)
        let snapshot = try makeSnapshot(generatedAt: generatedAt)
        let payload = CloudKitJournalRecordFactory.records(from: snapshot)
        let manifestRecordName = CloudKitJournalRecordFactory.manifestRecordID().recordName
        let manifest = try #require(payload.records.first { $0.recordID.recordName == manifestRecordName })
        let manifestGeneratedAt = try #require(manifest["generatedAt"] as? Date)

        let decoded = CloudKitJournalRecordDecoder.snapshot(
            entryRecords: payload.records.filter { $0.recordType == "JournalEntry" },
            blockRecords: payload.records.filter { $0.recordType == "JournalBlock" },
            mediaRecords: payload.records.filter { $0.recordType == "JournalMedia" },
            generatedAt: manifestGeneratedAt
        )

        #expect(manifestGeneratedAt == generatedAt)
        #expect(decoded.snapshot.generatedAt == generatedAt)
        #expect(decoded.snapshot.entries.first?.blocks.first?.content == "First day")
    }

    @Test func duplicateMediaRecordsAreSkippedInsteadOfCrashing() throws {
        let mediaFileURL = FileManager.default.temporaryDirectory.appending(
            path: "SyncKitTests-\(UUID().uuidString).dat"
        )
        try Data([0x1]).write(to: mediaFileURL)
        defer { try? FileManager.default.removeItem(at: mediaFileURL) }

        let blockID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let media = JournalSyncMediaAttachment(relativePath: "media/photo.dat", fileURL: mediaFileURL)
        let snapshot = try makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_345),
            blockID: blockID,
            media: media
        )
        let payload = CloudKitJournalRecordFactory.records(from: snapshot)
        let mediaRecord = try #require(payload.records.first { $0.recordType == "JournalMedia" })
        let duplicateMediaRecord = CKRecord(
            recordType: "JournalMedia",
            recordID: CKRecord.ID(recordName: "duplicate-media-\(blockID.uuidString)")
        )
        duplicateMediaRecord["blockExternalID"] = blockID.uuidString as NSString
        duplicateMediaRecord["mediaPath"] = "media/duplicate-photo.dat" as NSString
        duplicateMediaRecord["asset"] = CKAsset(fileURL: mediaFileURL)

        let decoded = CloudKitJournalRecordDecoder.snapshot(
            entryRecords: payload.records.filter { $0.recordType == "JournalEntry" },
            blockRecords: payload.records.filter { $0.recordType == "JournalBlock" },
            mediaRecords: [mediaRecord, duplicateMediaRecord],
            generatedAt: snapshot.generatedAt
        )

        #expect(decoded.mediaAttachmentCount == 1)
        #expect(decoded.skippedMediaCount == 1)
        #expect(decoded.snapshot.mediaAttachments == [media])
    }

    @Test func modifyResultValidatorThrowsPartialSaveFailures() throws {
        let recordID = CKRecord.ID(recordName: "failed-save")
        let failure = CloudKitRecordModificationError.missingSaveResult("inner-save-failure")
        let results: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        ) = (
            saveResults: [recordID: .failure(failure)],
            deleteResults: [:]
        )

        expectModificationError(failure) {
            try CloudKitRecordModificationValidator.validate(
                results,
                saving: [recordID],
                deleting: []
            )
        }
    }

    @Test func modifyResultValidatorRejectsMissingDeleteResults() {
        let recordID = CKRecord.ID(recordName: "missing-delete")
        expectModificationError(.missingDeleteResult("missing-delete")) {
            try CloudKitRecordModificationValidator.validate(
                (saveResults: [:], deleteResults: [:]),
                saving: [],
                deleting: [recordID]
            )
        }
    }

    @Test func uploadManifestConflictRebasePreservesServerChangesAndLocalNames() {
        let generatedAt = Date(timeIntervalSince1970: 4_567)
        let localNames = CloudKitManifestRecordNames(
            entryRecordNames: ["entry-local", "entry-shared"],
            blockRecordNames: ["block-local"],
            mediaRecordNames: []
        )
        let serverManifest = makeManifestRecord(
            generatedAt: Date(timeIntervalSince1970: 3_456),
            names: CloudKitManifestRecordNames(
                entryRecordNames: ["entry-shared", "entry-server"],
                blockRecordNames: ["block-server"],
                mediaRecordNames: ["media-server"]
            )
        )

        let rebased = CloudKitManifestConflictResolver.manifestByUploading(
            localNames,
            generatedAt: generatedAt,
            rebasedOn: serverManifest
        )
        let rebasedNames = CloudKitManifestRecordNames(record: rebased)

        #expect(rebased === serverManifest)
        #expect(rebased["generatedAt"] as? Date == generatedAt)
        #expect(rebasedNames.entryRecordNames == ["entry-local", "entry-shared", "entry-server"])
        #expect(rebasedNames.blockRecordNames == ["block-local", "block-server"])
        #expect(rebasedNames.mediaRecordNames == ["media-server"])
    }

    @Test func deleteManifestConflictRebaseRemovesDeletedRecordsFromServerVersion() {
        let serverManifest = makeManifestRecord(
            generatedAt: Date(timeIntervalSince1970: 5_678),
            names: CloudKitManifestRecordNames(
                entryRecordNames: ["entry-delete", "entry-server"],
                blockRecordNames: ["block-delete", "block-server"],
                mediaRecordNames: ["media-delete", "media-server"]
            )
        )

        let rebased = CloudKitManifestConflictResolver.manifestByDeleting(
            ["entry-delete", "block-delete", "media-delete"],
            rebasedOn: serverManifest
        )
        let rebasedNames = CloudKitManifestRecordNames(record: rebased)

        #expect(rebased === serverManifest)
        #expect(rebased["generatedAt"] as? Date == Date(timeIntervalSince1970: 5_678))
        #expect(rebasedNames.entryRecordNames == ["entry-server"])
        #expect(rebasedNames.blockRecordNames == ["block-server"])
        #expect(rebasedNames.mediaRecordNames == ["media-server"])
    }

    @Test func recordConflictFindsServerRecordInsidePartialFailure() throws {
        let recordID = CloudKitJournalRecordFactory.manifestRecordID()
        let serverManifest = makeManifestRecord(
            generatedAt: Date(timeIntervalSince1970: 6_789),
            names: CloudKitManifestRecordNames(
                entryRecordNames: ["entry-server"],
                blockRecordNames: [],
                mediaRecordNames: []
            )
        )
        let innerError = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverManifest]
        )
        let partialError = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [AnyHashable(recordID): innerError]]
        )

        let extracted = try #require(
            CloudKitRecordConflict.serverRecordChangedRecord(
                from: partialError,
                for: recordID
            )
        )

        #expect(extracted === serverManifest)
    }

    @Test func manifestConflictRetrierRebasesServerRecordAndRetries() async throws {
        let generatedAt = Date(timeIntervalSince1970: 7_890)
        let initialManifest = makeManifestRecord(
            generatedAt: generatedAt,
            names: CloudKitManifestRecordNames(
                entryRecordNames: ["entry-local"],
                blockRecordNames: [],
                mediaRecordNames: []
            )
        )
        let serverManifest = makeManifestRecord(
            generatedAt: Date(timeIntervalSince1970: 7_000),
            names: CloudKitManifestRecordNames(
                entryRecordNames: ["entry-server"],
                blockRecordNames: ["block-server"],
                mediaRecordNames: []
            )
        )

        var attempts = 0
        var savedNames: [CloudKitManifestRecordNames] = []
        try await CloudKitManifestConflictRetrier.save(
            initialManifest,
            maxRetries: 1
        ) { manifest in
            attempts += 1
            savedNames.append(CloudKitManifestRecordNames(record: manifest))
            if attempts == 1 {
                throw CKError(
                    .serverRecordChanged,
                    userInfo: [CKRecordChangedErrorServerRecordKey: serverManifest]
                )
            }
        } rebasing: { _, serverManifest in
            CloudKitManifestConflictResolver.manifestByUploading(
                CloudKitManifestRecordNames(
                    entryRecordNames: ["entry-local"],
                    blockRecordNames: [],
                    mediaRecordNames: []
                ),
                generatedAt: generatedAt,
                rebasedOn: serverManifest
            )
        }

        #expect(attempts == 2)
        #expect(savedNames.first?.entryRecordNames == ["entry-local"])
        #expect(savedNames.last?.entryRecordNames == ["entry-local", "entry-server"])
        #expect(savedNames.last?.blockRecordNames == ["block-server"])
    }

    private func makeSnapshot(
        generatedAt: Date,
        blockID: UUID? = nil,
        media: JournalSyncMediaAttachment? = nil
    ) throws -> JournalSyncSnapshot {
        let entryID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let resolvedBlockID: UUID
        if let blockID {
            resolvedBlockID = blockID
        } else {
            resolvedBlockID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        }

        return JournalSyncSnapshot(
            generatedAt: generatedAt,
            entries: [
                JournalSyncEntry(
                    id: entryID,
                    title: "Trip",
                    dateCreated: Date(timeIntervalSince1970: 1),
                    dateModified: Date(timeIntervalSince1970: 2),
                    iconSymbol: "book.closed.fill",
                    iconColor: "accent",
                    context: "",
                    blocks: [
                        JournalSyncBlock(
                            id: resolvedBlockID,
                            kind: media == nil ? "freestyle" : "image",
                            content: "First day",
                            order: 0,
                            dateCreated: Date(timeIntervalSince1970: 1),
                            dateModified: Date(timeIntervalSince1970: 2),
                            media: media
                        ),
                    ]
                ),
            ]
        )
    }

    private func expectModificationError(
        _ expected: CloudKitRecordModificationError,
        performing action: () throws -> Void
    ) {
        do {
            try action()
            Issue.record("Expected \(expected), but no error was thrown.")
        } catch let error as CloudKitRecordModificationError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), but caught \(error).")
        }
    }

    private func makeManifestRecord(
        generatedAt: Date,
        names: CloudKitManifestRecordNames
    ) -> CKRecord {
        CloudKitJournalRecordFactory.manifestRecord(
            generatedAt: generatedAt,
            names: names
        )
    }
}
