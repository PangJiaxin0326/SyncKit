import Foundation

public struct JournalSyncSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var entries: [JournalSyncEntry]

    public init(
        generatedAt: Date = Date(),
        entries: [JournalSyncEntry]
    ) {
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public var blockCount: Int {
        entries.reduce(0) { $0 + $1.blocks.count }
    }

    public var mediaAttachments: [JournalSyncMediaAttachment] {
        entries.flatMap { entry in
            entry.blocks.compactMap(\.media)
        }
    }
}

public struct JournalSyncEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var dateCreated: Date
    public var dateModified: Date
    public var iconSymbol: String
    public var iconColor: String
    public var context: String
    public var blocks: [JournalSyncBlock]

    public init(
        id: UUID,
        title: String,
        dateCreated: Date,
        dateModified: Date,
        iconSymbol: String,
        iconColor: String,
        context: String,
        blocks: [JournalSyncBlock]
    ) {
        self.id = id
        self.title = title
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.iconSymbol = iconSymbol
        self.iconColor = iconColor
        self.context = context
        self.blocks = blocks
    }
}

public struct JournalSyncBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var question: String
    public var content: String
    public var order: Int
    public var dateCreated: Date
    public var dateModified: Date
    public var mediaDuration: Double
    public var transcript: String
    public var aiTranscript: String
    public var media: JournalSyncMediaAttachment?

    public init(
        id: UUID,
        kind: String,
        question: String = "",
        content: String = "",
        order: Int,
        dateCreated: Date,
        dateModified: Date,
        mediaDuration: Double = 0,
        transcript: String = "",
        aiTranscript: String = "",
        media: JournalSyncMediaAttachment? = nil
    ) {
        self.id = id
        self.kind = kind
        self.question = question
        self.content = content
        self.order = order
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.mediaDuration = mediaDuration
        self.transcript = transcript
        self.aiTranscript = aiTranscript
        self.media = media
    }
}

public struct JournalSyncMediaAttachment: Codable, Hashable, Sendable {
    public var relativePath: String
    public var fileURL: URL

    public init(relativePath: String, fileURL: URL) {
        self.relativePath = relativePath
        self.fileURL = fileURL
    }
}
