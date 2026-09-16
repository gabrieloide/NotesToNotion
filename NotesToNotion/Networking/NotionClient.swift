import Foundation

struct NotionClient {
    let token: String
    let databaseID: String

    private static let baseURL = "https://api.notion.com/v1"
    private static let apiVersion = "2022-06-28"

    // Notion limits each rich_text to 2000 characters and each request to 100 blocks.
    private static let maxBlockTextLength = 1900
    private static let maxBlocksPerRequest = 90

    func createVoiceNote(title: String?, overview: String, notesMarkdown: String?, keyPoints: [String], transcript: String) async throws -> URL? {
        let titleProperty = try await titlePropertyName()

        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        let dateStamp = formatter.string(from: Date())
        // Prefer Gemini's content-based title (with the date appended so
        // entries stay sortable and unique); fall back to just the date when
        // there's no usable title.
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = cleanedTitle.isEmpty
            ? "Voice Note — \(dateStamp)"
            : "\(cleanedTitle) — \(dateStamp)"

        var children: [[String: Any]] = []
        let markdown = (notesMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !markdown.isEmpty {
            children.append(Self.heading("Session Overview"))
            children += Self.chunkedParagraphs(overview)
            children += MarkdownBlocks.blocks(from: markdown)
        } else {
            // Legacy layout: raw-transcript saves and notes persisted before
            // study notes existed only carry a summary and key points.
            children.append(Self.heading("Summary"))
            children += Self.chunkedParagraphs(overview)
            if !keyPoints.isEmpty {
                children.append(Self.heading("Key Points"))
                children += keyPoints.map(Self.bulletedListItem)
            }
        }
        children.append(["object": "block", "type": "divider", "divider": [String: String]()])

        var noteBatches = Self.batches(of: children)
        let firstBatch = noteBatches.removeFirst()

        let pageBody: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": [
                titleProperty: [
                    "title": [["text": ["content": title]]]
                ]
            ],
            "children": firstBatch,
        ]

        let (body, _) = try await send("POST", path: "/pages", json: pageBody)
        guard let page = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pageID = page["id"] as? String else {
            throw AppError.notionRequestFailed("unexpected response while creating the page.")
        }

        for batch in noteBatches {
            _ = try await send("PATCH", path: "/blocks/\(pageID)/children", json: ["children": batch])
        }

        try await appendTranscript(transcript, toPage: pageID)

        return (page["url"] as? String).flatMap(URL.init(string:))
    }

    /// Appends the transcript at the end of the page, collapsed inside a
    /// toggleable heading so it doesn't get in the way when reviewing notes.
    private func appendTranscript(_ transcript: String, toPage pageID: String) async throws {
        let paragraphs = Self.chunkedParagraphs(transcript)
        let inlineCount = Self.maxBlocksPerRequest - 1  // heading itself counts
        let inline = Array(paragraphs.prefix(inlineCount))
        let overflow = Array(paragraphs.dropFirst(inlineCount))

        let toggle: [String: Any] = [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [["text": ["content": "Transcript"]]],
                "is_toggleable": true,
                "children": inline,
            ],
        ]
        let (body, _) = try await send("PATCH", path: "/blocks/\(pageID)/children", json: ["children": [toggle]])
        guard !overflow.isEmpty else { return }

        // The PATCH response echoes the created blocks; very long
        // transcripts append their remaining batches under the heading's ID.
        guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let results = envelope["results"] as? [[String: Any]],
              let headingID = results.first?["id"] as? String else {
            throw AppError.notionRequestFailed("unexpected response while adding the transcript.")
        }
        for batch in Self.batches(of: overflow) {
            _ = try await send("PATCH", path: "/blocks/\(headingID)/children", json: ["children": batch])
        }
    }

    /// Discovers the database's actual title property name (it may not be
    /// called "Name" if the user renamed it).
    private func titlePropertyName() async throws -> String {
        let (body, _) = try await send("GET", path: "/databases/\(databaseID)", json: nil)
        guard let database = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let properties = database["properties"] as? [String: [String: Any]],
              let titleEntry = properties.first(where: { ($0.value["type"] as? String) == "title" }) else {
            throw AppError.notionRequestFailed("the database has no title property.")
        }
        return titleEntry.key
    }

    // MARK: - Helpers

    /// Splits blocks into request-sized batches. Notion's per-request block
    /// limit counts nested children too, so batches are sized by the flat
    /// block count, not the top-level count.
    private static func batches(of blocks: [[String: Any]]) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        var currentCount = 0
        for block in blocks {
            let count = flatBlockCount(block)
            if !current.isEmpty, currentCount + count > maxBlocksPerRequest {
                result.append(current)
                current = []
                currentCount = 0
            }
            current.append(block)
            currentCount += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func flatBlockCount(_ block: [String: Any]) -> Int {
        var count = 1
        for value in block.values {
            guard let payload = value as? [String: Any],
                  let nested = payload["children"] as? [[String: Any]] else { continue }
            for child in nested { count += flatBlockCount(child) }
        }
        return count
    }

    private func send(_ method: String, path: String, json: [String: Any]?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.notionRequestFailed("invalid response from the server.")
        }
        switch http.statusCode {
        case 200, 201:
            return (body, http)
        case 401:
            throw AppError.notionUnauthorized
        case 404:
            throw AppError.notionDatabaseNotShared
        default:
            let snippet = String(data: body.prefix(300), encoding: .utf8) ?? ""
            throw AppError.notionRequestFailed("HTTP \(http.statusCode). \(snippet)")
        }
    }

    private static func heading(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": ["rich_text": [["text": ["content": text]]]],
        ]
    }

    private static func bulletedListItem(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": ["rich_text": [["text": ["content": text]]]],
        ]
    }

    private static func paragraph(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": [["text": ["content": text]]]],
        ]
    }

    /// Splits long text into paragraphs under 2000 characters (Notion's
    /// rich_text limit), preferring to cut at sentence boundaries.
    private static func chunkedParagraphs(_ text: String) -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [paragraph("—")] }

        var chunks: [String] = []
        var rest = Substring(trimmed)
        while rest.count > maxBlockTextLength {
            let window = rest.prefix(maxBlockTextLength)
            let cutIndex = window.lastIndex(where: { ".!?\n".contains($0) })
                ?? window.lastIndex(of: " ")
                ?? window.indices.last!
            let chunk = rest[...cutIndex]
            chunks.append(String(chunk).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[rest.index(after: cutIndex)...]
        }
        let tail = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }

        return chunks.map(paragraph)
    }
}
