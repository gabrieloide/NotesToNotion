import XCTest
@testable import NotesToNotion

final class AudioStoreTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        // Resolved up front: /var/folders/... vs /private/var/folders/...
        // is the same directory (symlink) but compares unequal as a plain
        // URL, and FileManager.contentsOfDirectory can hand back either
        // form depending on the OS/runner — seen failing on GitHub's
        // macOS runner while passing locally.
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        AudioStore.baseDirectory = scratchDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        scratchDir = nil
        super.tearDown()
    }

    private func pendingAudioDir() -> URL {
        scratchDir.appendingPathComponent("NotesToNotion/PendingAudio", isDirectory: true)
    }

    func testNewRecordingURLPointsInsideDurableDirectory() {
        let url = AudioStore.newRecordingURL(name: "mic-123.m4a")

        XCTAssertEqual(url, pendingAudioDir().appendingPathComponent("mic-123.m4a"))
    }

    func testNewRecordingURLCreatesTheDirectoryEagerly() {
        _ = AudioStore.newRecordingURL(name: "mic-123.m4a")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: pendingAudioDir().path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDeleteRemovesTheFile() throws {
        let url = AudioStore.newRecordingURL(name: "mic-123.m4a")
        try Data("fake audio".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        AudioStore.delete(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteOfMissingFileDoesNotThrowOrCrash() {
        let url = AudioStore.newRecordingURL(name: "never-existed.m4a")
        AudioStore.delete(url) // should be a silent no-op
    }

    func testLoadOldestReturnsNilWhenNothingIsPending() {
        XCTAssertNil(AudioStore.loadOldest())
    }

    func testLoadOldestPicksTheOldestM4AFile() throws {
        let older = AudioStore.newRecordingURL(name: "mic-100.m4a")
        try Data("older".utf8).write(to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)

        let newer = AudioStore.newRecordingURL(name: "mic-200.m4a")
        try Data("newer".utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)

        XCTAssertEqual(AudioStore.loadOldest(), older)
    }

    /// A crash mid-recording (before RecordingManager.stop() merges the
    /// tracks) can leave a lone raw system-audio track (.caf) behind with
    /// no mic counterpart. It's never independently useful (see
    /// AudioStore.loadOldest's doc comment), so recovery must skip it
    /// rather than surface it as "the recording to retry."
    func testLoadOldestIgnoresOrphanedSystemAudioTrack() throws {
        let orphanedSystemTrack = AudioStore.newRecordingURL(name: "system-100.caf")
        try Data("system audio only".utf8).write(to: orphanedSystemTrack)

        XCTAssertNil(AudioStore.loadOldest())
    }

    func testLoadOldestFindsMicOnlyRecordingAlongsideOrphanedSystemTrack() throws {
        let mic = AudioStore.newRecordingURL(name: "mic-100.m4a")
        try Data("mic".utf8).write(to: mic)
        let orphanedSystemTrack = AudioStore.newRecordingURL(name: "system-100.caf")
        try Data("system audio only".utf8).write(to: orphanedSystemTrack)

        XCTAssertEqual(AudioStore.loadOldest(), mic)
    }
}
