import Foundation

struct GeminiClient {
    let apiKey: String

    private static let baseURL = "https://generativelanguage.googleapis.com"
    // Pinned to gemini-flash-latest: the only model confirmed (live test
    // against this account's key) to have working free-tier quota.
    // gemini-2.5-pro -> 429, 0 RPD/RPM quota on this project.
    // gemini-2.5-flash (pinned) -> 404, not available to new-tier accounts.
    // gemini-3.5-flash -> live-tested 2026-09-16, returns intermittent 503
    // "high demand" — do not switch back without a fresh live test.
    private static let model = "gemini-flash-latest"

    // MARK: - Generate study notes from a transcript

    private static let studyNotesPrompt = """
    The following is a transcript of a one-on-one online Japanese class, transcribed locally on-device. It may switch between Japanese and English at any point, even mid-sentence — that's expected, not an error. The transcription may contain recognition errors; use context to recover the intended words.

    Produce study notes the student will use to review this class later. The student will NOT go back to the transcript, so the notes must be exhaustive: capture EVERY vocabulary item, phrase, expression, grammar point, and correction that appears in the transcript — do not be selective or summarize items away.

    Return a JSON object with exactly three fields:

    - "title": a short, specific title (3 to 8 words) describing what this class was actually about, in English. Base it on the real content — the topic, vocabulary, or grammar covered — so it's recognizable at a glance in a list. Do not include the date or the word "transcript". No surrounding quotes.

    - "overview": 2 to 4 sentences of session context in English: who took part, what kind of session it was (small talk, roleplay, new material, review), and what was covered at a high level.

    - "notes": the full study notes in English, formatted as Markdown. Rules for the notes:
      - Organize into sections with "###" headings named after the actual content of the class. Typical sections when they apply: Small Talk & Vocabulary in Context, Roleplay Recap, New Vocabulary & Phrases, Grammar & Language Points, Corrections, Time/Topic-specific sections — but adapt the names to what really happened.
      - Every Japanese term is bolded and formatted exactly like this, in this order: **native form** (kana reading · romaji) — "English meaning". The native form is however the word is normally written — kanji (plus okurigana) for most words, katakana for loanwords, hiragana for grammar particles/endings that have no kanji. If the native form already contains kanji, add its full reading in hiragana before the romaji, separated by " · ". If the native form is already pure kana (a katakana loanword, a hiragana-only word), do NOT repeat it — go straight to romaji. Examples:
        - Kanji word: `**手数料** (てすうりょう・tesūryō) — "transaction fee / commission fee"`
        - Katakana loanword (no separate kana reading needed): `**ポイントカード** (pointo kādo) — "point card / loyalty card"`
        - Mixed kanji+kana: `**食べてみたい** (たべてみたい・tabete mitai) — "want to try eating"`
      - In any section that lists several vocabulary items (vocabulary, phrases, grammar points), give AS MANY of them as possible an example sentence showing it used in context — pulled from the transcript when the class actually used it that way, otherwise a natural example consistent with how it was taught. Don't leave a section as a bare list of term-meaning pairs when examples are available; that's the difference between a dictionary and study notes.
      - Include any corrections the instructor made to the student's Japanese (what was said vs. the natural phrasing), each with its own example if useful.
      - Every section is a flat list of top-level term bullets. A term's example, if it has one, is its OWN bullet directly below it, indented exactly 4 spaces, starting with "- Example: " (the leading "- " is required — it is a bullet, not a plain indented line). Do not add any further nesting beyond this one level. Required shape for one term with an example, reproduced literally including both leading dashes:
        - **手数料** (てすうりょう・tesūryō) — "transaction fee / commission fee"
            - Example: 手数料がかかります (てすうりょうがかかります・tesūryō ga kakarimasu) — "There is a fee."
      - Use ONLY this Markdown: "###" headings, "- " bullets (indent example bullets with exactly 4 leading spaces, always keeping their own leading "- "), and "**bold**". No tables, links, code fences, numbered lists, italics, or other elements.
    """

    func summarize(transcript: String) async throws -> (title: String, overview: String, notes: String) {
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": Self.studyNotesPrompt],
                        ["text": "Transcript:\n\(transcript)"],
                    ]
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
                // Server overload ("high demand"), not a quota problem —
                // don't tell the user their quota ran out when it didn't.
                throw AppError.geminiOverloaded
            }
            throw AppError.geminiRequestFailed(Self.describeFailure(response, body))
        }
        return try Self.parseNotes(from: body)
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
