import Foundation

/// A Gemini result that hasn't been confirmed saved to Notion yet.
/// Persisted to disk between the transcription and Notion steps so a
/// Notion-side failure (or the app quitting) doesn't lose the transcript.
struct PendingNote: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let result: GeminiResult
}
