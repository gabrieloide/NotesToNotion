import Foundation

enum AppError: LocalizedError {
    case missingCredentials
    case microphonePermissionDenied
    case recordingFailed(String)
    case geminiRequestFailed(String)
    case geminiMalformedResponse
    case notionDatabaseNotShared
    case notionUnauthorized
    case notionRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing credentials. Open Settings and add your Gemini API key, Notion token, and database ID."
        case .microphonePermissionDenied:
            "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .recordingFailed(let detail):
            "Recording failed: \(detail)"
        case .geminiRequestFailed(let detail):
            "Gemini failed: \(detail)"
        case .geminiMalformedResponse:
            "Gemini returned a response that couldn't be parsed."
        case .notionDatabaseNotShared:
            "Notion couldn't find the database. Check the ID and make sure the database is shared with your integration (••• → Connections)."
        case .notionUnauthorized:
            "The Notion token is invalid or was revoked. Check it in Settings."
        case .notionRequestFailed(let detail):
            "Notion rejected the request: \(detail)"
        }
    }
}
