# SyncKit

SyncKit is a small Swift package for cloud sync providers. The current provider
uploads and downloads journal entries with their attached media files through
the user's private CloudKit database.

The package intentionally accepts a journal snapshot instead of app-owned
storage objects. Callers decide what is eligible for cloud sync before handing
data to SyncKit, which keeps unrelated local state such as AI configuration or
assistant memory out of the cloud path.

## Record Types

- `JournalEntry`: entry metadata and user context.
- `JournalBlock`: ordered entry content blocks.
- `JournalMedia`: CloudKit assets for image and voice files referenced by
  blocks.

Records use deterministic IDs derived from local UUIDs so uploads are idempotent.
