import Foundation

enum AppError: LocalizedError {
    case missingCredentials
    case microphonePermissionDenied
    case recordingFailed(String)
    case noSpeechDetected
    case geminiRequestFailed(String)
    case geminiRateLimited(retryAfterSeconds: Int?)
    case geminiOverloaded
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
        case .noSpeechDetected:
            "No speech was detected in the recording — it may have been too quiet or the mic didn't pick you up. Nothing was saved. Try speaking a bit louder or closer to the mic."
        case .geminiRequestFailed(let detail):
            "Gemini failed: \(detail)"
        case .geminiRateLimited:
            "Gemini's free-tier quota is used up right now. Your transcript is saved locally — hit Retry in a minute (or later if the daily quota ran out)."
        case .geminiOverloaded:
            "Gemini's servers are temporarily overloaded (not a quota issue). Your transcript is saved locally — hit Retry in a minute."
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
