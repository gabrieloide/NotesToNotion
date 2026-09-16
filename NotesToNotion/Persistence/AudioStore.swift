import Foundation

/// Durable local storage for raw recordings that haven't been transcribed
/// yet. Recordings start in the system temp directory (which macOS can
/// clear on its own schedule) — this moves them somewhere that survives
/// until the transcript is safely on disk, so a WhisperKit failure or an
/// app crash mid-transcription can't lose an unrecoverable class recording.
enum AudioStore {
    /// The parent of `NotesToNotion/PendingAudio`. Defaults to the real
    /// Application Support directory; tests override this to a scratch
    /// directory so they don't read or write the user's actual pending
    /// recordings.
    static var baseDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    private static var directory: URL {
        let dir = baseDirectory.appendingPathComponent("NotesToNotion/PendingAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fresh durable file URL for a new recording. Mic and system-audio
    /// capture write here directly from the moment recording starts,
    /// instead of the (OS-purgeable, crash-unsafe) system temp directory —
    /// so a class survives even if the app never reaches a clean `stop()`.
    static func newRecordingURL(name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The oldest recording left behind by a previous run that never made
    /// it to a transcript — a Whisper failure, or the app quitting or
    /// crashing mid-recording/mid-transcription.
    ///
    /// Only considers `.m4a` files: both a mic-only and a mixed recording
    /// end up as `.m4a`, while the raw system-audio track (`.caf`) is an
    /// intermediate file that's only meaningful alongside its mic
    /// counterpart and is never itself the thing to recover.
    static func loadOldest() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        return files
            .filter { $0.pathExtension == "m4a" }
            .min { modificationDate($0) < modificationDate($1) }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
