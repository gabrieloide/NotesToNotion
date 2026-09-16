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
    /// A recording that hasn't made it to a transcript yet — either this
    /// session's last transcription failure, or recovered from disk after
    /// the app quit mid-transcription. Never deleted until its transcript
    /// is durably saved, so a WhisperKit failure can't lose the class.
    var pendingAudioURL: URL?

    private let recorder = RecordingManager()
    private var timer: Timer?

    // Safety cap for recordings left running by accident.
    private static let maxRecordingSeconds = 60 * 60

    init() {
        hasCredentials = Self.credentialsPresent()
        if let recovered = PendingNoteStore.loadOldest() {
            pendingNote = recovered
            phase = .error("Found a note from a previous session that wasn't saved to Notion yet.")
        } else if let recoveredAudio = AudioStore.loadOldest() {
            pendingAudioURL = recoveredAudio
            phase = .error("Found a recording from a previous session that wasn't transcribed yet.")
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
        // RecordingManager already wrote this file directly into AudioStore's
        // durable location (see AudioStore.newRecordingURL), so it's safe
        // from a temp-dir sweep or a crash from the moment recording
        // started. It's only deleted once the transcript is durably
        // persisted below.
        pendingAudioURL = audioURL
        await transcribeAndSummarize(audioURL: audioURL)
    }

    /// Called when the app is quitting while a recording is in progress:
    /// finalizes the audio (stops the recorder, merges mic+system tracks)
    /// without starting transcription, so the class is safely on disk for
    /// recovery next launch instead of being silently dropped along with
    /// the terminated process.
    func finalizeRecordingForQuit() async {
        guard phase == .recording else { return }
        timer?.invalidate()
        timer = nil
        guard let audioURL = await recorder.stop() else { return }
        pendingAudioURL = audioURL
    }

    /// Runs Whisper transcription (if needed) followed by Gemini
    /// summarization and the Notion save. Shared by a fresh recording and
    /// by `retryTranscription()` for audio recovered from a previous
    /// failure.
    private func transcribeAndSummarize(audioURL: URL) async {
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

            // The transcript is now durably saved on its own — the raw
            // audio is no longer the only copy of the class, so it's safe
            // to delete.
            var note = PendingNote(
                id: UUID(),
                createdAt: Date(),
                result: GeminiResult(transcript: trimmedTranscript, summary: "", keyPoints: [], title: nil, notes: nil)
            )
            PendingNoteStore.save(note)
            pendingNote = note
            AudioStore.delete(audioURL)
            pendingAudioURL = nil

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
        } catch AppError.noSpeechDetected {
            // Genuinely no usable audio either way — nothing left worth
            // keeping around to retry.
            AudioStore.delete(audioURL)
            pendingAudioURL = nil
            phase = .error(Self.message(for: AppError.noSpeechDetected))
        } catch {
            // Deliberately NOT deleting the audio here: whatever failed
            // (missing credentials, WhisperKit itself, a crash) happened
            // before the transcript was durably saved, so pendingAudioURL
            // keeps pointing at the recording for retryTranscription().
            phase = .error(Self.message(for: error))
        }
    }

    func retryTranscription() {
        guard let audioURL = pendingAudioURL else { return }
        Task {
            await transcribeAndSummarize(audioURL: audioURL)
        }
    }

    func discardPendingAudio() {
        guard let audioURL = pendingAudioURL else { return }
        AudioStore.delete(audioURL)
        pendingAudioURL = nil
        phase = .idle
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
