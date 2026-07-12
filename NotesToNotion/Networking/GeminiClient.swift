import Foundation

struct GeminiClient {
    let apiKey: String

    private static let baseURL = "https://generativelanguage.googleapis.com"
    // Pro instead of flash: more accurate with bilingual/complex audio
    // (classes with Japanese/English code-switching), at the cost of being
    // slower — acceptable given the usage volume (1-2 one-hour classes/week).
    private static let model = "gemini-pro-latest"
    private static let audioMIMEType = "audio/mp4"

    func transcribeAndSummarize(audioFile: URL) async throws -> GeminiResult {
        let file = try await uploadAudio(audioFile)
        let activeFile = try await waitUntilActive(file)
        return try await generateContent(fileURI: activeFile.uri)
    }

    // MARK: - Files API (subida resumable)

    private struct GeminiFile: Decodable {
        let name: String
        let uri: String
        let state: String
    }

    private struct FileEnvelope: Decodable {
        let file: GeminiFile
    }

    private func uploadAudio(_ audioFile: URL) async throws -> GeminiFile {
        let audioData = try Data(contentsOf: audioFile)

        // Step 1: start the resumable upload session.
        var startRequest = URLRequest(url: URL(string: "\(Self.baseURL)/upload/v1beta/files")!)
        startRequest.httpMethod = "POST"
        startRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue("\(audioData.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(Self.audioMIMEType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": audioFile.lastPathComponent]]
        )

        let (startBody, startResponse) = try await URLSession.shared.data(for: startRequest)
        guard let httpResponse = startResponse as? HTTPURLResponse, httpResponse.statusCode == 200,
              let uploadURLString = httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw AppError.geminiRequestFailed(Self.describeFailure(startResponse, startBody))
        }

        // Step 2: upload the bytes and finalize in a single call.
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")

        let (uploadBody, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, from: audioData)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, uploadHTTP.statusCode == 200 else {
            throw AppError.geminiRequestFailed(Self.describeFailure(uploadResponse, uploadBody))
        }
        return try JSONDecoder().decode(FileEnvelope.self, from: uploadBody).file
    }

    private func waitUntilActive(_ file: GeminiFile) async throws -> GeminiFile {
        var current = file
        var attempts = 0
        while current.state == "PROCESSING" {
            attempts += 1
            guard attempts <= 60 else {
                throw AppError.geminiRequestFailed("the audio file took too long to process.")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)

            var request = URLRequest(url: URL(string: "\(Self.baseURL)/v1beta/\(current.name)")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AppError.geminiRequestFailed(Self.describeFailure(response, body))
            }
            current = try JSONDecoder().decode(GeminiFile.self, from: body)
        }
        guard current.state == "ACTIVE" else {
            throw AppError.geminiRequestFailed("Gemini couldn't process the audio (state: \(current.state)).")
        }
        return current
    }

    // MARK: - generateContent

    private static let prompt = """
    The audio is from an online class that may switch between Japanese and English at any point (code-switching), even within the same sentence. Pay close attention to language switches: don't assume a single dominant language or force the whole audio into one.

    Return a JSON object with exactly three fields:
    - "transcript": a faithful, complete transcript of everything said, with each word in the exact language it was spoken in (Japanese in Japanese, English in English, following the switches as they happen). Do not translate anything. Only clean up obvious filler sounds (uh, um, あの, えっと) while keeping the content intact. When Japanese vocabulary or grammar is mentioned, write it in its native script (kanji/kana), not romaji.
    - "summary": a concise summary (1 to 3 sentences) of the class's main points, in English.
    - "keyPoints": a list of 3 to 7 short, concrete phrases covering the class's key points (new vocabulary, grammar, corrections, topics covered), in English. Each item should be a short phrase, not a long sentence.
    """

    private func generateContent(fileURI: String) async throws -> GeminiResult {
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": Self.prompt],
                        ["file_data": ["mime_type": Self.audioMIMEType, "file_uri": fileURI]],
                    ]
                ]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": [
                    "type": "OBJECT",
                    "properties": [
                        "transcript": ["type": "STRING"],
                        "summary": ["type": "STRING"],
                        "keyPoints": ["type": "ARRAY", "items": ["type": "STRING"]],
                    ],
                    "required": ["transcript", "summary", "keyPoints"],
                ],
            ],
        ]

        let url = URL(string: "\(Self.baseURL)/v1beta/models/\(Self.model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Pro is slower than flash and classes can run up to 1h of audio.
        request.timeoutInterval = 900
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.geminiRequestFailed(Self.describeFailure(response, body))
        }
        return try Self.parseResult(from: body)
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

    private static func parseResult(from body: Data) throws -> GeminiResult {
        let envelope = try JSONDecoder().decode(GenerateContentResponse.self, from: body)
        guard let text = envelope.candidates?.first?.content?.parts?
            .compactMap(\.text).joined(), !text.isEmpty else {
            throw AppError.geminiMalformedResponse
        }

        let cleaned = stripCodeFences(from: text)
        if let result = try? JSONDecoder().decode(GeminiResult.self, from: Data(cleaned.utf8)) {
            return result
        }
        // Last resort: keep the raw text as the transcript so the note
        // isn't lost even if the summary fails.
        return GeminiResult(transcript: cleaned, summary: "(Summary generation failed)", keyPoints: [])
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

    private static func describeFailure(_ response: URLResponse, _ body: Data) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let snippet = String(data: body.prefix(300), encoding: .utf8) ?? ""
        return "HTTP \(status). \(snippet)"
    }
}
