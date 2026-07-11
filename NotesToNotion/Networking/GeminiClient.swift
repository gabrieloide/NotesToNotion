import Foundation

struct GeminiClient {
    let apiKey: String

    private static let baseURL = "https://generativelanguage.googleapis.com"
    // Pro en vez de flash: más preciso con audio bilingüe/complejo (clases con
    // cambio de idioma japonés/inglés), a cambio de ser más lento — aceptable
    // para el volumen de uso (1-2 clases de 1h por semana).
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

        // Paso 1: iniciar la sesión de subida resumable.
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

        // Paso 2: subir los bytes y finalizar en una sola llamada.
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
                throw AppError.geminiRequestFailed("el archivo de audio tardó demasiado en procesarse.")
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
            throw AppError.geminiRequestFailed("Gemini no pudo procesar el audio (estado: \(current.state)).")
        }
        return current
    }

    // MARK: - generateContent

    private static let prompt = """
    El audio es de una clase online que puede alternar entre japonés e inglés en cualquier momento (code-switching), incluso dentro de la misma oración. Presta especial atención a los cambios de idioma: no asumas un solo idioma dominante ni fuerces todo el audio a uno solo.

    Devuelve un JSON con exactamente tres campos:
    - "transcript": la transcripción fiel y completa de todo lo que se dice, cada palabra en el idioma exacto en que se pronunció (japonés en japonés, inglés en inglés, tal como ocurra el cambio). No traduzcas nada. Limpia solo muletillas obvias (eh, em, あの, えっと) manteniendo el contenido íntegro. Si se menciona vocabulario o gramática japonesa, escribe el japonés con su escritura nativa (kanji/kana), no en rōmaji.
    - "summary": un resumen conciso (1 a 3 oraciones) de los puntos principales de la clase, en español.
    - "keyPoints": una lista de 3 a 7 frases breves y concretas con los puntos clave de la clase (vocabulario nuevo, gramática, correcciones, temas tratados), en español. Cada elemento debe ser una frase corta, no una oración larga.
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
        // Pro es más lento que flash y las clases pueden durar hasta 1h de audio.
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
        // Último recurso: conservar el texto crudo como transcripción para no
        // perder la nota aunque el resumen falle.
        return GeminiResult(transcript: cleaned, summary: "(No se pudo generar el resumen)", keyPoints: [])
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
