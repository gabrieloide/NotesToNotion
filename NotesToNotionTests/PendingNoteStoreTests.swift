import XCTest
@testable import NotesToNotion

final class PendingNoteStoreTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        // See AudioStoreTests for why this needs resolvingSymlinksInPath().
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        PendingNoteStore.baseDirectory = scratchDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        scratchDir = nil
        super.tearDown()
    }

    private func makeNote(id: UUID = UUID(), createdAt: Date = Date(), transcript: String = "hello") -> PendingNote {
        PendingNote(
            id: id,
            createdAt: createdAt,
            result: GeminiResult(transcript: transcript, summary: "", keyPoints: [], title: nil, notes: nil)
        )
    }

    func testSaveThenLoadOldestRoundTripsTheTranscript() {
        let note = makeNote(transcript: "class transcript that must survive")
        PendingNoteStore.save(note)

        let loaded = PendingNoteStore.loadOldest()

        XCTAssertEqual(loaded?.id, note.id)
        XCTAssertEqual(loaded?.result.transcript, "class transcript that must survive")
    }

    func testDeleteRemovesTheNote() {
        let note = makeNote()
        PendingNoteStore.save(note)
        XCTAssertNotNil(PendingNoteStore.loadOldest())

        PendingNoteStore.delete(id: note.id)

        XCTAssertNil(PendingNoteStore.loadOldest())
    }

    func testLoadOldestReturnsNilWhenNothingIsPending() {
        XCTAssertNil(PendingNoteStore.loadOldest())
    }

    func testLoadOldestPicksTheOldestByCreatedAt() {
        let older = makeNote(createdAt: Date(timeIntervalSince1970: 100), transcript: "older")
        let newer = makeNote(createdAt: Date(timeIntervalSince1970: 200), transcript: "newer")
        // Saved out of order on purpose: recovery must sort by createdAt,
        // not by save/file order.
        PendingNoteStore.save(newer)
        PendingNoteStore.save(older)

        XCTAssertEqual(PendingNoteStore.loadOldest()?.result.transcript, "older")
    }

    func testSaveOverwritesAnExistingNoteWithTheSameID() {
        let id = UUID()
        PendingNoteStore.save(makeNote(id: id, transcript: "transcript only"))
        PendingNoteStore.save(makeNote(id: id, transcript: "transcript plus gemini notes"))

        let loaded = PendingNoteStore.loadOldest()

        XCTAssertEqual(loaded?.result.transcript, "transcript plus gemini notes")
    }
}
