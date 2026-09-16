import XCTest
@testable import NotesToNotion

final class AudioStoreTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Two URLs can point at the identical file yet compare unequal as
    /// plain paths — macOS's FileManager.contentsOfDirectory hands back
    /// /private/var/folders/... while a path built from
    /// FileManager.default.temporaryDirectory stays /var/folders/...
    /// (the same directory; resolvingSymlinksInPath deliberately leaves
    /// /var and /tmp alone). Comparing by file identity sidesteps the
    /// spelling entirely and is what these tests actually care about.
    private func assertSameFile(_ lhs: URL?, _ rhs: URL?, file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs, let rhs else {
            XCTFail("expected two URLs, got \(String(describing: lhs)) and \(String(describing: rhs))", file: file, line: line)
            return
        }
        let lhsID = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let rhsID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        XCTAssertNotNil(lhsID, "couldn't read file identity for \(lhs)", file: file, line: line)
        XCTAssertEqual(lhsID as? NSObject, rhsID as? NSObject, "\(lhs) and \(rhs) are not the same file", file: file, line: line)
    }

    func testNewRecordingURLPointsInsideDurableDirectory() {
        let url = AudioStore.newRecordingURL(name: "mic-123.m4a")

        XCTAssertEqual(url.lastPathComponent, "mic-123.m4a")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "PendingAudio")
        assertSameFile(url.deletingLastPathComponent(), pendingAudioDir())
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

        assertSameFile(AudioStore.loadOldest(), older)
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

        assertSameFile(AudioStore.loadOldest(), mic)
    }
}
