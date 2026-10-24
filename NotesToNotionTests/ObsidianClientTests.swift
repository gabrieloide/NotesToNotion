import XCTest
@testable import NotesToNotion

final class ObsidianClientTests: XCTestCase {
    func testSanitizeForTableCellRemovesDashesPipesEmojisAndNewlines() {
        let client = ObsidianClient(token: "dummy_token")
        let input = "  **手数料** (tesūryō) — \"fee\" | Tema 1 - Genki 🎉 \n Nueva línea  "
        let sanitized = client.sanitizeForTableCell(input)

        XCTAssertFalse(sanitized.contains("|"), "Table cell must not contain pipes")
        XCTAssertFalse(sanitized.contains("-"), "Table cell must not contain hyphens")
        XCTAssertFalse(sanitized.contains("—"), "Table cell must not contain em-dashes")
        XCTAssertFalse(sanitized.contains("–"), "Table cell must not contain en-dashes")
        XCTAssertFalse(sanitized.contains("\n"), "Table cell must not contain newlines")
        XCTAssertFalse(sanitized.contains("🎉"), "Table cell must not contain emojis")
        XCTAssertEqual(sanitized, "**手数料** (tesūryō): \"fee\" , Tema 1: Genki Nueva línea")
    }

    func testExtractConciseCorrectionsFromMarkdownBullets() {
        let client = ObsidianClient(token: "dummy_token")
        let markdown = """
        ### Session Overview
        Overview text here.

        ### Corrections & Natural Phrasing:
        - **自然な表現** (shizen na hyōgen) — "Natural expression"
            - Example: Student said X -> Teacher said Y
        - **食べ物** (tabemono) — "Food"
            - Example: Another correction

        ### Active Recall Mini-Quiz:
        - Q: Something?
        """

        let result = client.extractConciseCorrections(from: markdown, overview: "Fallback overview")
        XCTAssertFalse(result.contains("-"), "Corrections must not contain hyphens")
        XCTAssertFalse(result.contains("|"), "Corrections must not contain pipes")
        XCTAssertTrue(result.contains("自然な表現"), "Should extract Japanese correction")
    }

    func testUpdatePlanContentUpdatesFrontmatterDateAndInsertsRowBeforePending() {
        let client = ObsidianClient(token: "dummy_token")
        let originalContent = """
        ---
        tipo: plan_aprendizaje
        autor: Gabriel Leandro Fuentes Salinas
        tema: japones
        actualizado: 2026-10-22
        tags: [aprendizaje, japones, genki, anki, idiomas]
        ---

        # Plan de Estudio de Japonés

        ## 1. Estado Actual

        * **Nivel**: Principiante.

        ## 6. Registro de Sesiones

        | Fecha | Tipo | Tema | Aciertos | Errores Frecuentes | Notas |
        | :--- | :--- | :--- | :--- | :--- | :--- |
        | 2026-10-22 | Producción breve | Forma て (Lección 6 Genki) | 4/5 (80%) | Uso de と para unir verbos | Resumen anterior |
        | Pendiente | Sesión Genki | Forma て | Pendiente | Pendiente | Primera sesión con el PDF de Genki |
        """

        let notionURL = URL(string: "https://www.notion.so/test-page-12345")
        let updated = client.updatePlanContent(
            originalContent: originalContent,
            title: "Práctica con Genki",
            overview: "Repaso de verbos y conjugaciones.",
            notesMarkdown: nil,
            notionURL: notionURL
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let today = dateFormatter.string(from: Date())

        XCTAssertTrue(updated.contains("actualizado: \(today)"), "Frontmatter date must be updated")
        XCTAssertFalse(updated.contains("actualizado: 2026-10-22"), "Old date must be replaced")

        // Verify row insertion
        let lines = updated.components(separatedBy: "\n")
        guard let pendingIndex = lines.firstIndex(where: { $0.contains("| Pendiente |") }) else {
            XCTFail("Missing pending line")
            return
        }

        let insertedLine = lines[pendingIndex - 1]
        XCTAssertTrue(insertedLine.contains("| \(today) | Clase particular |"), "Inserted line should be right before Pending")
        XCTAssertTrue(insertedLine.contains("| Práctica oral |"), "Fourth column must be Práctica oral")
        XCTAssertTrue(insertedLine.contains("[Apunte en Notion](\(notionURL!.absoluteString))"), "Notion link should be present")
    }

    func testSanitizeCellPreservesCompoundWordHyphens() {
        let client = ObsidianClient(token: "dummy_token")
        let input = "Práctica de role-play y full-stack — sesión 1 - nivel N4"
        let sanitized = client.sanitizeCell(input)
        XCTAssertTrue(sanitized.contains("role-play"), "Should preserve role-play")
        XCTAssertTrue(sanitized.contains("full-stack"), "Should preserve full-stack")
        XCTAssertFalse(sanitized.contains("—"), "Should remove em-dash")
        XCTAssertFalse(sanitized.contains(" - "), "Should replace spaced hyphen")
        XCTAssertEqual(sanitized, "Práctica de role-play y full-stack: sesión 1: nivel N4")
    }
}
