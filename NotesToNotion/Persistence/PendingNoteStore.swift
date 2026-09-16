import Foundation

/// Durable local buffer for notes that made it through Gemini but not yet
/// through Notion. One JSON file per pending note in Application Support.
enum PendingNoteStore {
    /// The parent of `NotesToNotion/PendingNotes`. Defaults to the real
    /// Application Support directory; tests override this to a scratch
    /// directory so they don't read or write the user's actual pending
    /// notes.
    static var baseDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    private static var directory: URL {
        let dir = baseDirectory.appendingPathComponent("NotesToNotion/PendingNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func save(_ note: PendingNote) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: fileURL(for: note.id), options: .atomic)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// The oldest note left behind by a previous run — either a Notion
    /// failure that hasn't been retried, or the app quitting mid-flow.
    static func loadOldest() -> PendingNote? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let notes = files.compactMap { url -> PendingNote? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PendingNote.self, from: data)
        }
        return notes.min { $0.createdAt < $1.createdAt }
    }
}
