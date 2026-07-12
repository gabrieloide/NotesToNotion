import Foundation

struct NotionClient {
    let token: String
    let databaseID: String

    private static let baseURL = "https://api.notion.com/v1"
    private static let apiVersion = "2022-06-28"

    // Notion limits each rich_text to 2000 characters and each request to 100 blocks.
    private static let maxBlockTextLength = 1900
    private static let maxBlocksPerRequest = 90

    func createVoiceNote(summary: String, keyPoints: [String], transcript: String) async throws -> URL? {
        let titleProperty = try await titlePropertyName()

        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        let title = "Voice Note — \(formatter.string(from: Date()))"

        var children: [[String: Any]] = [Self.heading("Summary")]
        children += Self.chunkedParagraphs(summary)
        if !keyPoints.isEmpty {
            children.append(Self.heading("Key Points"))
            children += keyPoints.map(Self.bulletedListItem)
        }
        children.append(["object": "block", "type": "divider", "divider": [String: String]()])
        children.append(Self.heading("Transcript"))
        children += Self.chunkedParagraphs(transcript)

        let firstBatch = Array(children.prefix(Self.maxBlocksPerRequest))
        let remaining = Array(children.dropFirst(Self.maxBlocksPerRequest))

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

        // Very long transcripts: append the rest in batches.
        var pending = remaining
        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.maxBlocksPerRequest))
            pending = Array(pending.dropFirst(Self.maxBlocksPerRequest))
            _ = try await send("PATCH", path: "/blocks/\(pageID)/children", json: ["children": batch])
        }

        return (page["url"] as? String).flatMap(URL.init(string:))
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
