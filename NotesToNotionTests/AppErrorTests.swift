import XCTest
@testable import NotesToNotion

final class AppErrorTests: XCTestCase {
    /// 2026-09-16 incident: a 503 (server overload) was reported to the
    /// user as "quota is used up," which was false and sent them chasing
    /// the wrong fix. These two cases must never share wording again.
    func testOverloadedAndRateLimitedMessagesDoNotClaimTheSameThing() {
        let overloadedMessage = AppError.geminiOverloaded.errorDescription ?? ""
        let rateLimitedMessage = AppError.geminiRateLimited(retryAfterSeconds: nil).errorDescription ?? ""

        // The 503 case may still mention "quota" to explicitly rule it out
        // (e.g. "not a quota issue"), what must never happen again is it
        // asserting quota exhaustion as the cause, the way the 429 case does.
        XCTAssertTrue(rateLimitedMessage.localizedCaseInsensitiveContains("quota is used up"))
        XCTAssertFalse(overloadedMessage.localizedCaseInsensitiveContains("quota is used up"))
        XCTAssertFalse(overloadedMessage.localizedCaseInsensitiveContains("quota ran out"))
    }

    func testRateLimitedMessageMentionsTheTranscriptIsSafe() {
        let message = AppError.geminiRateLimited(retryAfterSeconds: 30).errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("saved locally"))
    }

    func testOverloadedMessageMentionsTheTranscriptIsSafe() {
        let message = AppError.geminiOverloaded.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("saved locally"))
    }

    func testMarkdownBlocksQuizQuestionGeneratesToggleBlock() {
        let markdown = """
        ### Active Recall Mini-Quiz
        - **Q:** How do you say "thank you" in Japanese?
            - Answer: **ありがとう** (arigatou): informal thanks
        """
        let blocks = MarkdownBlocks.blocks(from: markdown)
        XCTAssertFalse(blocks.isEmpty)
        guard let headingBlock = blocks.first,
              let headingData = headingBlock["heading_3"] as? [String: Any],
              let children = headingData["children"] as? [[String: Any]],
              let toggleBlock = children.first else {
            XCTFail("Expected heading_3 with toggle child")
            return
        }
        XCTAssertEqual(toggleBlock["type"] as? String, "toggle")
        guard let toggleData = toggleBlock["toggle"] as? [String: Any],
              let nestedChildren = toggleData["children"] as? [[String: Any]],
              let answerBlock = nestedChildren.first else {
            XCTFail("Expected toggle block with answer child")
            return
        }
        XCTAssertEqual(answerBlock["type"] as? String, "paragraph")
    }

    func testObsidianClientSanitizeCellRemovesDashesPipesAndNewlines() {
        let dirty = "Vocab — reading – romaji - detail | with pipe\nnewline\r\nand arrow -> natural"
        let clean = ObsidianClient.sanitizeCell(dirty)
        XCTAssertFalse(clean.contains("—"))
        XCTAssertFalse(clean.contains("–"))
        XCTAssertFalse(clean.contains("-"))
        XCTAssertFalse(clean.contains("|"))
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertFalse(clean.contains("\r"))
    }

    func testObsidianClientInsertSessionRowPlacesRowChronologically() {
        let original = """
        ## 6. Registro de Sesiones

        | Fecha | Tipo | Tema | Aciertos | Errores Frecuentes | Notas |
        | :--- | :--- | :--- | :--- | :--- | :--- |
        | 2026-10-22 | Producción breve | Forma て | 4/5 | Uso de と | Notas |
        | Pendiente | Sesión Genki | Forma て | Pendiente | Pendiente | Primera sesión |
        """
        let newRow = "| 2026-10-24 | Clase particular | Nuevo tema | Completada | Sin errores | Notas |"
        let updated = ObsidianClient.insertSessionRow(into: original, newRow: newRow)
        let lines = updated.components(separatedBy: "\n")
        guard let newRowIndex = lines.firstIndex(of: newRow),
              let pendingIndex = lines.firstIndex(where: { $0.lowercased().starts(with: "| pendiente") }) else {
            XCTFail("Expected new row and pending row")
            return
        }
        XCTAssertLessThan(newRowIndex, pendingIndex)
    }

    func testObsidianClientExtractCorrectionsSummary() {
        let markdown = """
        ### Corrections & Natural Phrasing:
        - **自然な表現** (しぜんなひょうげん / shizen na hyougen): "Natural phrasing"
            - Example: Student said: 不自然 -> Natural phrasing: 自然な表現
        - **二つ目の表現** (ふたつめのひょうげん / futatsume no hyougen): "Second phrasing"
            - Example: Student said: 間違い -> Natural phrasing: 二つ目の表現
        """
        let summary = ObsidianClient.extractCorrectionsSummary(from: markdown)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertFalse(summary.contains("—"))
        XCTAssertFalse(summary.contains("–"))
        XCTAssertFalse(summary.contains("-"))
        XCTAssertFalse(summary.contains("|"))
        XCTAssertTrue(summary.contains("自然な表現"))
    }

    func testErrorMessagesDoNotContainEmDashOrSpacedHyphen() {
        let errors: [AppError] = [
            .missingCredentials,
            .microphonePermissionDenied,
            .recordingFailed("test failure"),
            .noSpeechDetected,
            .geminiRequestFailed("network error"),
            .geminiRateLimited(retryAfterSeconds: 60),
            .geminiOverloaded,
            .geminiMalformedResponse,
            .notionDatabaseNotShared,
            .notionUnauthorized,
            .notionRequestFailed("invalid payload")
        ]

        for error in errors {
            let desc = error.errorDescription ?? ""
            XCTAssertFalse(desc.contains("—"), "Error description must not contain em-dash: \(desc)")
            XCTAssertFalse(desc.contains(" - "), "Error description must not contain spaced hyphen: \(desc)")
        }
    }
}
