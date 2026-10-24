import Foundation

struct GeminiClient {
    let apiKey: String

    private static let baseURL = "https://generativelanguage.googleapis.com"
    // Pinned to gemini-flash-latest: the only model confirmed (live test
    // against this account's key) to have working free-tier quota.
    // gemini-2.5-pro -> 429, 0 RPD/RPM quota on this project.
    // gemini-2.5-flash (pinned) -> 404, not available to new-tier accounts.
    // gemini-3.5-flash -> live-tested 2026-09-16, returns intermittent 503
    // "high demand": do not switch back without a fresh live test.
    private static let model = "gemini-flash-latest"

    // MARK: - Generate study notes from a transcript

    private static let studyNotesPrompt = """
    The following is a transcript of a one-on-one online Japanese class, transcribed locally on-device.
    The transcript includes timestamps and speaker labels:
    - `[MM:SS Sensei]: ...` indicates speech from the Japanese instructor/teacher (Sensei).
    - `[MM:SS Estudiante]: ...` indicates speech from the student/learner (Estudiante).
    It may switch between Japanese and English at any point, even mid-sentence, which is expected and not an error. The transcription may contain recognition errors; use context to recover the intended words.

    Produce study notes the student will use to review this class later. The student will NOT go back to the transcript, so the notes must be exhaustive: capture EVERY vocabulary item, phrase, expression, grammar point, and correction that appears in the transcript: do not be selective or summarize items away.

    Never use em-dashes (—), en-dashes (–), or spaced hyphens ( - ) as punctuation anywhere in title, overview, or notes. Use colons (:), commas, or parentheses instead.

    Return a JSON object with exactly three fields:

    - "title": a short, specific title (3 to 8 words) describing what this class was actually about, in English. Base it on the real content (the topic, vocabulary, or grammar covered) so it is recognizable at a glance in a list. Do not include the date or the word "transcript". No surrounding quotes.

    - "overview": 2 to 4 sentences of session context in English: who took part, what kind of session it was (small talk, roleplay, new material, review), and what was covered at a high level.

    - "notes": the full study notes in English, formatted as Markdown. Rules for the notes:

      ### Required Structure and Sections:
      Organize into sections with "###" headings in the following order:

      1. ### Bookmarked Moments (INCLUDE ONLY IF student bookmarked timestamps are provided below):
         If the student flagged bookmarked timestamps during class, this MUST be the first section. For each bookmarked timestamp, explain in detail what vocabulary, grammar, explanation, or correction occurred around that [MM:SS] moment in class. Format:
         - **[MM:SS] Key Topic / Word** (kana reading / romaji): "Concept meaning"
             - Example: Detailed explanation of what was taught or clarified around this timestamp.

      2. Themed Content Sections (named after actual content):
         Typical sections: Small Talk & Vocabulary in Context, New Vocabulary & Phrases, Grammar & Language Points, Roleplay Recap: adapt names to what really happened. Exhaustively cover all new Japanese material.

      3. ### Corrections & Natural Phrasing:
         Leverage the distinction between Estudiante and Sensei. Capture every mistake in vocabulary, particle, conjugation, or unnatural phrasing spoken by Estudiante, and how Sensei corrected or rephrased it (or the natural Japanese phrasing if Estudiante struggled). Format strictly as:
         - **Natural Japanese Form** (kana reading / romaji): "English meaning"
             - Example: Student said: [what student said or attempted] -> Natural phrasing: [natural correction + brief English explanation]

      4. ### Active Recall Mini-Quiz:
         Include 5 to 8 self-test questions strictly based on what was learned or corrected in the class (testing vocabulary, particle choices, verb conjugations, natural phrasing). Format strictly as:
         - **Q:** How do you say "..." in Japanese? (or fill-in-the-blank particle/verb form)
             - Answer: **Japanese form** (kana reading / romaji): brief explanation

      5. ### Anki Flashcards (Copy & Paste):
         The very last section must provide ready-to-copy flashcards for all new vocabulary, expressions, and grammar learned in the class. Format each bullet as:
         - Front (Japanese native form + reading) ; Back (English meaning + example sentence)
         Example:
         - 手数料 (てすうりょう / tesūryō) ; transaction fee / commission fee: 手数料がかかります。

      ### Japanese Formatting Rules (CRITICAL):
      - Every Japanese term is bolded and formatted exactly like this, in this order: **native form** (kana reading / romaji): "English meaning".
      - The native form is however the word is normally written: kanji (plus okurigana) for most words, katakana for loanwords, hiragana for grammar particles/endings that have no kanji.
      - If the native form already contains kanji, add its full reading in hiragana before the romaji, separated by " / ".
      - If the native form is already pure kana (a katakana loanword, a hiragana-only word), do NOT repeat it, go straight to romaji.
        Examples:
        - Kanji word: `**手数料** (てすうりょう / tesūryō): "transaction fee / commission fee"`
        - Katakana loanword (no separate kana reading needed): `**ポイントカード** (pointo kādo): "point card / loyalty card"`
        - Mixed kanji+kana: `**食べてみたい** (たべてみたい / tabete mitai): "want to try eating"`
        - Example: 手数料がかかります (てすうりょうがかかります / tesūryō ga kakarimasu): "There is a fee."

      ### Bullet Structure & Markdown Constraints:
      - In any section listing vocabulary items, give AS MANY of them as possible an example sentence showing it used in context: pulled from the transcript when actually used, otherwise a natural example consistent with how it was taught.
      - Every section is a flat list of top-level term bullets. A term's example, answer, or detail is its OWN bullet directly below it, indented exactly 4 spaces, starting with "- Example: " or "- Answer: " (the leading "- " is required: it is a bullet, not a plain indented line).
      - Do NOT add any further nesting beyond this one level.
      - Use ONLY this Markdown: "###" headings, "- " bullets (indent sub-bullets with exactly 4 leading spaces, always keeping their own leading "- "), and "**bold**". No tables, links, code fences, numbered lists, italics, or other elements.
    """

    func summarize(transcript: String, bookmarks: [Int] = []) async throws -> (title: String, overview: String, notes: String) {
        var parts: [[String: String]] = [
            ["text": Self.studyNotesPrompt],
        ]
        if !bookmarks.isEmpty {
            let formatted = bookmarks.sorted().map { Self.formatTimestamp($0) }.joined(separator: ", ")
            parts.append([
                "text": "Student Bookmarked Timestamps (moments the student flagged live during class as important/difficult): \(formatted)"
            ])
        }
        parts.append(["text": "Transcript:\n\(transcript)"])

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": parts,
                ]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": [
                    "type": "OBJECT",
                    "properties": [
                        "title": ["type": "STRING"],
                        "overview": ["type": "STRING"],
                        "notes": ["type": "STRING"],
                    ],
                    "required": ["title", "overview", "notes"],
                ],
            ],
        ]

        let url = URL(string: "\(Self.baseURL)/v1beta/models/\(Self.model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Pro is slow and exhaustive notes for an hour-long class are a long
        // generation.
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                throw AppError.geminiRateLimited(retryAfterSeconds: Self.parseRetryDelay(from: body))
            }
            if status == 503 {
                // Server overload ("high demand"), not a quota problem:
                // don't tell the user their quota ran out when it didn't.
                throw AppError.geminiOverloaded
            }
            throw AppError.geminiRequestFailed(Self.describeFailure(response, body))
        }
        return try Self.parseNotes(from: body)
    }

    private static func formatTimestamp(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let m = clamped / 60
        let s = clamped % 60
        return String(format: "%02d:%02d", m, s)
    }

    private struct GenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    private struct NotesResult: Decodable {
        let title: String
        let overview: String
        let notes: String
    }

    private static func parseNotes(from body: Data) throws -> (title: String, overview: String, notes: String) {
        let envelope = try JSONDecoder().decode(GenerateContentResponse.self, from: body)
        guard let text = envelope.candidates?.first?.content?.parts?
            .compactMap(\.text).joined(), !text.isEmpty else {
            throw AppError.geminiMalformedResponse
        }

        let cleaned = stripCodeFences(from: text)
        guard let result = try? JSONDecoder().decode(NotesResult.self, from: Data(cleaned.utf8)) else {
            throw AppError.geminiMalformedResponse
        }
        return (result.title, result.overview, result.notes)
    }

    private static func stripCodeFences(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Rate-limit errors carry a RetryInfo detail like `"retryDelay": "27s"`
    /// saying when the free-tier quota window resets.
    private static func parseRetryDelay(from body: Data) -> Int? {
        guard let text = String(data: body, encoding: .utf8),
              let match = text.firstMatch(of: #/"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"/#),
              let seconds = Double(match.1) else {
            return nil
        }
        return Int(seconds.rounded(.up))
    }

    private static func describeFailure(_ response: URLResponse, _ body: Data) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let snippet = String(data: body.prefix(300), encoding: .utf8) ?? ""
        return "HTTP \(status). \(snippet)"
    }
}
