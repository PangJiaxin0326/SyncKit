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
}
