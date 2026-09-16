import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording
        case processing(String)
        case success(URL?)
        case error(String)
    }

    var phase: Phase = .idle
    var elapsedSeconds = 0
    var hasCredentials: Bool
    /// A Gemini result that made it through transcription but hasn't been
    /// confirmed saved to Notion yet — either from this session's last
    /// failure, or recovered from disk after the app quit mid-flow.
    var pendingNote: PendingNote?

    private let recorder = RecordingManager()
    private var timer: Timer?

    // Safety cap for recordings left running by accident.
    private static let maxRecordingSeconds = 60 * 60

    init() {
        hasCredentials = Self.credentialsPresent()
        if let recovered = PendingNoteStore.loadOldest() {
            pendingNote = recovered
            phase = .error("Found a note from a previous session that wasn't saved to Notion yet.")
        }
    }

    var menuBarIcon: String {
        switch phase {
        case .idle: "mic.circle"
        case .recording: "record.circle.fill"
        case .processing: "hourglass.circle"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.circle"
        }
    }

    var formattedElapsed: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    func refreshCredentials() {
        hasCredentials = Self.credentialsPresent()
    }

    func reset() {
        phase = .idle
    }

    func startRecording() {
        guard hasCredentials else {
            phase = .error(AppError.missingCredentials.localizedDescription)
            return
        }
        Task {
            do {
                try await recorder.start()
                elapsedSeconds = 0
                phase = .recording
                startTimer()
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func stopAndProcess() {
        timer?.invalidate()
        timer = nil
        Task {
            guard let audioURL = await recorder.stop() else {
                phase = .error("Couldn't save the recorded audio.")
                return
            }
            await process(audioURL: audioURL)
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.elapsedSeconds += 1
                if self.elapsedSeconds >= Self.maxRecordingSeconds {
                    self.stopAndProcess()
                }
            }
        }
    }

    private func process(audioURL: URL) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            guard let geminiKey = KeychainStore.read(.geminiAPIKey) else {
                throw AppError.missingCredentials
            }

            phase = .processing("Transcribing with Whisper…")
            let transcript = try await WhisperTranscriber.shared.transcribe(audioURL: audioURL)
            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                throw AppError.noSpeechDetected
            }

            // Persist the transcript right away so if Gemini or Notion fails,
            // the transcript isn't lost.
            var note = PendingNote(
                id: UUID(),
                createdAt: Date(),
                result: GeminiResult(transcript: trimmedTranscript, summary: "", keyPoints: [], title: nil, notes: nil)
            )
            PendingNoteStore.save(note)
            pendingNote = note

            phase = .processing("Generating study notes with Gemini…")
            let gemini = GeminiClient(apiKey: geminiKey)
            let (title, overview, notes) = try await gemini.summarize(transcript: trimmedTranscript)

            let fullResult = GeminiResult(
                transcript: trimmedTranscript,
                summary: overview,
                keyPoints: [],
                title: title,
                notes: notes
            )
            note = PendingNote(id: note.id, createdAt: note.createdAt, result: fullResult)
            PendingNoteStore.save(note)
            pendingNote = note

            try await saveToNotion(note)
        } catch {
            phase = .error(Self.message(for: error))
        }
    }

    func retryPendingNote() {
        guard let note = pendingNote else { return }
        Task {
            do {
                guard let geminiKey = KeychainStore.read(.geminiAPIKey) else {
                    throw AppError.missingCredentials
                }

                var updatedNote = note
                if updatedNote.result.notes == nil || updatedNote.result.notes?.isEmpty == true {
                    phase = .processing("Generating study notes with Gemini…")
                    let gemini = GeminiClient(apiKey: geminiKey)
                    let (title, overview, notes) = try await gemini.summarize(transcript: updatedNote.result.transcript)
                    let fullResult = GeminiResult(
                        transcript: updatedNote.result.transcript,
                        summary: overview,
                        keyPoints: updatedNote.result.keyPoints,
                        title: title,
                        notes: notes
                    )
                    updatedNote = PendingNote(id: note.id, createdAt: note.createdAt, result: fullResult)
                    PendingNoteStore.save(updatedNote)
                    pendingNote = updatedNote
                }

                try await saveToNotion(updatedNote)
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func saveRawTranscript() {
        guard let note = pendingNote else { return }
        Task {
            do {
                guard let notionToken = KeychainStore.read(.notionToken),
                      let databaseID = KeychainStore.read(.notionDatabaseID) else {
                    throw AppError.missingCredentials
                }

                phase = .processing("Saving transcript to Notion…")
                let notion = NotionClient(token: notionToken, databaseID: databaseID)
                let pageURL = try await notion.createVoiceNote(
                    title: "Voice Note",
                    overview: "Voice note transcript (saved without Gemini notes).",
                    notesMarkdown: nil,
                    keyPoints: [],
                    transcript: note.result.transcript
                )

                PendingNoteStore.delete(id: note.id)
                pendingNote = nil
                phase = .success(pageURL)
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func discardPendingNote() {
        guard let note = pendingNote else { return }
        PendingNoteStore.delete(id: note.id)
        pendingNote = nil
        phase = .idle
    }

    private func saveToNotion(_ note: PendingNote) async throws {
        guard let notionToken = KeychainStore.read(.notionToken),
              let databaseID = KeychainStore.read(.notionDatabaseID) else {
            throw AppError.missingCredentials
        }

        phase = .processing("Saving to Notion…")
        let notion = NotionClient(token: notionToken, databaseID: databaseID)
        let pageURL = try await notion.createVoiceNote(
            title: note.result.title,
            overview: note.result.summary.isEmpty ? "Voice Note" : note.result.summary,
            notesMarkdown: note.result.notes,
            keyPoints: note.result.keyPoints,
            transcript: note.result.transcript
        )

        PendingNoteStore.delete(id: note.id)
        pendingNote = nil
        phase = .success(pageURL)
    }

    private static func credentialsPresent() -> Bool {
        KeychainStore.read(.geminiAPIKey) != nil
            && KeychainStore.read(.notionToken) != nil
            && KeychainStore.read(.notionDatabaseID) != nil
    }

    private static func message(for error: Error) -> String {
        if let appError = error as? AppError {
            return appError.localizedDescription
        }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
