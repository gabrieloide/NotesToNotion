import Foundation

/// Renders the constrained Markdown Gemini produces for study notes —
/// "###" headings, "- " bullets with one level of nesting, and **bold** —
/// into Notion block dictionaries. Each heading becomes a collapsible
/// toggle heading containing everything up to the next heading, so a long
/// set of notes can be skimmed section by section instead of one long
/// scroll.
enum MarkdownBlocks {
    // Notion caps each rich_text element at 2000 characters.
    private static let maxTextLength = 1900

    static func blocks(from markdown: String) -> [[String: Any]] {
        var topLevel: [[String: Any]] = []
        var currentHeading: (type: String, richText: [[String: Any]])?
        var currentContentLines: [String] = []

        func flushSection() {
            defer { currentContentLines = [] }
            if let heading = currentHeading {
                var payload: [String: Any] = [
                    "rich_text": heading.richText,
                    "is_toggleable": true,
                ]
                let children = contentBlocks(from: currentContentLines)
                if !children.isEmpty {
                    payload["children"] = children
                }
                topLevel.append([
                    "object": "block",
                    "type": heading.type,
                    heading.type: payload,
                ])
            } else if !currentContentLines.isEmpty {
                // Content before any heading: nothing to attach it to, so
                // it stays flat rather than being dropped.
                topLevel += contentBlocks(from: currentContentLines)
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                flushSection()
                let hashes = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                let type = hashes <= 2 ? "heading_2" : "heading_3"
                currentHeading = (type, richText(from: text))
            } else {
                currentContentLines.append(rawLine)
            }
        }
        flushSection()
        return topLevel
    }

    /// Renders bullet/paragraph lines (no headings) into blocks, with one
    /// level of nesting for indented lines.
    ///
    /// For the Active Recall Mini-Quiz section, questions (bullets starting with
    /// `**Q:**` or followed by an `Answer:` sub-bullet) are converted into Notion
    /// `toggle` blocks, with the answer nested inside as a hidden child paragraph.
    /// In Notion, this yields:
    ///   heading_3 (is_toggleable: true) -> toggle (question) -> paragraph (answer)
    /// which adheres to Notion API's 2-level nesting limit in a single request.
    private static func contentBlocks(from lines: [String]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var lastTopBulletIndex: Int?

        for rawLine in lines {
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            let text = isBullet ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : line

            if indent >= 2, let parentIndex = lastTopBulletIndex {
                var parent = blocks[parentIndex]
                let parentType = parent["type"] as? String ?? ""

                if parentType == "toggle" {
                    // Parent is already a question toggle block; append answer as paragraph child.
                    var payload = parent["toggle"] as? [String: Any] ?? [:]
                    var nested = payload["children"] as? [[String: Any]] ?? []
                    let childBlock: [String: Any] = [
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": ["rich_text": richText(from: text)],
                    ]
                    nested.append(childBlock)
                    payload["children"] = nested
                    parent["toggle"] = payload
                    blocks[parentIndex] = parent
                } else if parentType == "bulleted_list_item", isAnswerBullet(text) {
                    // Sub-bullet is an answer; convert parent bullet into a toggle block.
                    let parentPayload = parent["bulleted_list_item"] as? [String: Any] ?? [:]
                    let parentRichText = parentPayload["rich_text"] as? [[String: Any]] ?? []
                    var nested = parentPayload["children"] as? [[String: Any]] ?? []

                    // Any preexisting nested bullets flatten to paragraphs inside the toggle.
                    nested = nested.map { child in
                        if (child["type"] as? String) == "bulleted_list_item",
                           let childPayload = child["bulleted_list_item"] as? [String: Any],
                           let childRichText = childPayload["rich_text"] as? [[String: Any]] {
                            return [
                                "object": "block",
                                "type": "paragraph",
                                "paragraph": ["rich_text": childRichText],
                            ]
                        }
                        return child
                    }

                    let answerBlock: [String: Any] = [
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": ["rich_text": richText(from: text)],
                    ]
                    nested.append(answerBlock)

                    let toggleParent: [String: Any] = [
                        "object": "block",
                        "type": "toggle",
                        "toggle": [
                            "rich_text": parentRichText,
                            "children": nested,
                        ],
                    ]
                    blocks[parentIndex] = toggleParent
                } else if parentType == "bulleted_list_item" {
                    // Nested bullet. Any depth flattens to one level: with
                    // the enclosing toggle heading that's already two
                    // levels of nested children, the most a single Notion
                    // create/append request reliably accepts.
                    var payload = parent["bulleted_list_item"] as? [String: Any] ?? [:]
                    var nested = payload["children"] as? [[String: Any]] ?? []
                    let childBlock: [String: Any] = [
                        "object": "block",
                        "type": isBullet ? "bulleted_list_item" : "paragraph",
                        isBullet ? "bulleted_list_item" : "paragraph": ["rich_text": richText(from: text)],
                    ]
                    nested.append(childBlock)
                    payload["children"] = nested
                    parent["bulleted_list_item"] = payload
                    blocks[parentIndex] = parent
                }
            } else if isBullet {
                if isQuestionBullet(text) {
                    let toggle: [String: Any] = [
                        "object": "block",
                        "type": "toggle",
                        "toggle": ["rich_text": richText(from: text)],
                    ]
                    blocks.append(toggle)
                    lastTopBulletIndex = blocks.count - 1
                } else {
                    let bullet: [String: Any] = [
                        "object": "block",
                        "type": "bulleted_list_item",
                        "bulleted_list_item": ["rich_text": richText(from: text)],
                    ]
                    blocks.append(bullet)
                    lastTopBulletIndex = blocks.count - 1
                }
            } else {
                blocks.append([
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": ["rich_text": richText(from: line)],
                ])
                lastTopBulletIndex = nil
            }
        }
        return blocks
    }

    private static func isQuestionBullet(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        return lower.hasPrefix("**q:**")
            || lower.hasPrefix("**q**:")
            || lower.hasPrefix("**q:")
            || lower.hasPrefix("q:")
            || lower.hasPrefix("**question:")
            || lower.hasPrefix("question:")
            || lower.hasPrefix("**question**:")
    }

    private static func isAnswerBullet(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        return lower.hasPrefix("answer:")
            || lower.hasPrefix("answer :")
            || lower.hasPrefix("**answer:**")
            || lower.hasPrefix("**answer**:")
            || lower.hasPrefix("**answer:")
            || lower.hasPrefix("a:")
            || lower.hasPrefix("**a:**")
    }

    /// Splits text on **bold** markers into Notion rich_text elements,
    /// keeping each element under Notion's per-element length cap.
    static func richText(from text: String) -> [[String: Any]] {
        let parts = text.components(separatedBy: "**")
        // With balanced markers the parts alternate plain/bold. An
        // unbalanced trailing "**" would make the last part look bold, so
        // it stays plain instead.
        let balanced = parts.count % 2 == 1

        var elements: [[String: Any]] = []
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { continue }
            let bold = index % 2 == 1 && (balanced || index < parts.count - 1)
            for chunk in chunked(part) {
                var element: [String: Any] = ["type": "text", "text": ["content": chunk]]
                if bold { element["annotations"] = ["bold": true] }
                elements.append(element)
            }
        }
        return elements
    }

    private static func chunked(_ text: String) -> [String] {
        guard text.count > maxTextLength else { return [text] }
        var chunks: [String] = []
        var rest = Substring(text)
        while rest.count > maxTextLength {
            let cut = rest.index(rest.startIndex, offsetBy: maxTextLength)
            chunks.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        return chunks
    }
}
