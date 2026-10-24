import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications

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

    var phase: Phase = .idle {
        didSet {
            switch phase {
            case .recording, .processing:
                acquireSleepAssertions()
            case .idle, .success, .error:
                releaseSleepAssertions()
            }
        }
    }
    var elapsedSeconds = 0
    var hasCredentials: Bool
    var isCapturingSystemAudio: Bool = true
    var isPaused: Bool = false
    var bookmarks: [Int] = []
    var micLevel: Float = 0.0
    var systemLevel: Float = 0.0

    /// A Gemini result that made it through transcription but hasn't been
    /// confirmed saved to Notion yet: either from this session's last
    /// failure, or recovered from disk after the app quit mid-flow.
    var pendingNote: PendingNote?
    /// A recording that hasn't made it to a transcript yet: either this
    /// session's last transcription failure, or recovered from disk after
    /// the app quit mid-transcription. Never deleted until its transcript
    /// is durably saved, so a WhisperKit failure can't lose the class.
    var pendingAudioURL: URL?

    private let recorder = RecordingManager()
    private var timer: Timer?
    private var meterTimer: Timer?

    private var activityToken: NSObjectProtocol?
    private var powerAssertionID: IOPMAssertionID = 0
    private var isProcessingInFlight: Bool = false
    private var shouldAutoResumeOnWake: Bool = false
    private var isStartingRecording: Bool = false
    private var networkRetryCount: Int = 0

    private static let bookmarksKey = "pending_bookmarks"
    // Safety cap for recordings left running by accident.
    private static let maxRecordingSeconds = 60 * 60

    init() {
        hasCredentials = Self.credentialsPresent()
        if let recovered = PendingNoteStore.loadOldest() {
            pendingNote = recovered
            phase = .error("Found a note from a previous session that wasn't saved to Notion yet.")
        } else if let recoveredAudio = AudioStore.loadOldest() {
            pendingAudioURL = recoveredAudio
            bookmarks = (UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Int]) ?? []
            phase = .error("Found a recording from a previous session that wasn't transcribed yet.")
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWakeNotification()
            }
        }
    }

    var menuBarIcon: String {
        switch phase {
        case .idle: "mic.circle"
        case .recording: isPaused ? "pause.circle.fill" : "record.circle.fill"
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
        shouldAutoResumeOnWake = false
        phase = .idle
    }

    func togglePause() {
        guard phase == .recording else { return }
        isPaused.toggle()
        if isPaused {
            recorder.pause()
            micLevel = 0.0
            systemLevel = 0.0
        } else {
            recorder.resume()
        }
    }

    func addBookmark() {
        guard phase == .recording else { return }
        guard !bookmarks.contains(elapsedSeconds) else { return }
        bookmarks.append(elapsedSeconds)
        bookmarks.sort()
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
        NSSound(named: "Tink")?.play()
    }

    func startRecording() {
        guard phase != .recording, !isStartingRecording else { return }
        guard hasCredentials else {
            phase = .error(AppError.missingCredentials.localizedDescription)
            return
        }
        isStartingRecording = true
        networkRetryCount = 0
        bookmarks = []
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
        isPaused = false
        micLevel = 0.0
        systemLevel = 0.0

        Task {
            defer { isStartingRecording = false }
            do {
                try await recorder.start()
                isCapturingSystemAudio = recorder.isCapturingSystemAudio
                elapsedSeconds = 0
                phase = .recording
                startTimer()
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func stopAndProcess() {
        guard phase == .recording else { return }
        phase = .processing("Finalizing audio…")
        timer?.invalidate()
        timer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        micLevel = 0.0
        systemLevel = 0.0
        isPaused = false
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)

        Task {
            guard let audioURL = await recorder.stop() else {
                phase = .error("Couldn't save the recorded audio.")
                return
            }
            await process(audioURL: audioURL)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if !self.isPaused {
                    self.elapsedSeconds += 1
                    if self.elapsedSeconds >= Self.maxRecordingSeconds {
                        self.stopAndProcess()
                    }
                }
            }
        }

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if self.isPaused {
                    self.micLevel = 0.0
                    self.systemLevel = 0.0
                } else {
                    let levels = self.recorder.currentLevels()
                    self.micLevel = levels.mic
                    self.systemLevel = levels.system
                }
            }
        }
    }

    private func process(audioURL: URL) async {
        shouldAutoResumeOnWake = true
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
        meterTimer?.invalidate()
        meterTimer = nil
        micLevel = 0.0
        systemLevel = 0.0
        isPaused = false
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
        guard let audioURL = await recorder.stop() else { return }
        pendingAudioURL = audioURL
    }

    /// Runs Whisper transcription (if needed) followed by Gemini
    /// summarization and the Notion save. Shared by a fresh recording and
    /// by `retryTranscription()` for audio recovered from a previous
    /// failure.
    private func transcribeAndSummarize(audioURL: URL) async {
        guard !isProcessingInFlight else { return }
        isProcessingInFlight = true
        defer { isProcessingInFlight = false }

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

            // The transcript is now durably saved on its own, so the raw
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

            let currentBookmarks = bookmarks.isEmpty
                ? (UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Int] ?? [])
                : bookmarks

            phase = .processing("Generating study notes with Gemini…")
            let gemini = GeminiClient(apiKey: geminiKey)
            let (title, overview, notes) = try await gemini.summarize(transcript: trimmedTranscript, bookmarks: currentBookmarks)

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
            AudioStore.delete(audioURL)
            pendingAudioURL = nil
            bookmarks = []
            UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
            shouldAutoResumeOnWake = false
            phase = .error(Self.message(for: AppError.noSpeechDetected))
        } catch {
            phase = .error(Self.message(for: error))
            if isNetworkError(error) && shouldAutoResumeOnWake && networkRetryCount < 3 {
                networkRetryCount += 1
                print("Network error detected during transcription/summarization (retry \(networkRetryCount)/3). Will retry in 3 seconds…")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, self.shouldAutoResumeOnWake, !self.isProcessingInFlight else { return }
                    if self.pendingNote != nil {
                        self.retryPendingNote()
                    } else if self.pendingAudioURL != nil {
                        self.retryTranscription()
                    }
                }
            }
        }
    }

    func retryTranscription() {
        guard let audioURL = pendingAudioURL else { return }
        shouldAutoResumeOnWake = true
        Task {
            await transcribeAndSummarize(audioURL: audioURL)
        }
    }

    func discardPendingAudio() {
        guard let audioURL = pendingAudioURL else { return }
        AudioStore.delete(audioURL)
        pendingAudioURL = nil
        bookmarks = []
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
        shouldAutoResumeOnWake = false
        phase = .idle
    }

    func retryPendingNote() {
        guard let note = pendingNote else { return }
        guard !isProcessingInFlight else { return }
        shouldAutoResumeOnWake = true
        isProcessingInFlight = true

        Task {
            defer { isProcessingInFlight = false }
            do {
                guard let geminiKey = KeychainStore.read(.geminiAPIKey) else {
                    throw AppError.missingCredentials
                }

                var updatedNote = note
                if updatedNote.result.notes == nil || updatedNote.result.notes?.isEmpty == true {
                    phase = .processing("Generating study notes with Gemini…")
                    let gemini = GeminiClient(apiKey: geminiKey)
                    let currentBookmarks = bookmarks.isEmpty
                        ? (UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Int] ?? [])
                        : bookmarks
                    let (title, overview, notes) = try await gemini.summarize(transcript: updatedNote.result.transcript, bookmarks: currentBookmarks)
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
                if isNetworkError(error) && shouldAutoResumeOnWake && networkRetryCount < 3 {
                    networkRetryCount += 1
                    print("Network error detected during note retry (retry \(networkRetryCount)/3). Will retry in 3 seconds…")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, self.shouldAutoResumeOnWake, !self.isProcessingInFlight else { return }
                        if self.pendingNote != nil {
                            self.retryPendingNote()
                        }
                    }
                }
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

                if let githubToken = KeychainStore.read(.githubToken), !githubToken.isEmpty {
                    phase = .processing("Syncing session to Obsidian vault…")
                    do {
                        let obsidian = ObsidianClient(token: githubToken)
                        try await obsidian.recordClassSession(
                            title: "Voice Note",
                            overview: "Voice note transcript (saved without Gemini notes).",
                            notesMarkdown: nil,
                            notionURL: pageURL
                        )
                    } catch {
                        print("WARN: Obsidian sync failed: \(error)")
                    }
                }

                PendingNoteStore.delete(id: note.id)
                pendingNote = nil
                bookmarks = []
                UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
                shouldAutoResumeOnWake = false
                notifySuccess(pageURL: pageURL)
            } catch {
                phase = .error(Self.message(for: error))
            }
        }
    }

    func discardPendingNote() {
        guard let note = pendingNote else { return }
        PendingNoteStore.delete(id: note.id)
        pendingNote = nil
        bookmarks = []
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
        shouldAutoResumeOnWake = false
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

        if let githubToken = KeychainStore.read(.githubToken), !githubToken.isEmpty {
            phase = .processing("Syncing session to Obsidian vault…")
            do {
                let obsidian = ObsidianClient(token: githubToken)
                try await obsidian.recordClassSession(
                    title: note.result.title,
                    overview: note.result.summary,
                    notesMarkdown: note.result.notes,
                    notionURL: pageURL
                )
            } catch {
                print("WARN: Obsidian sync failed: \(error)")
            }
        }

        PendingNoteStore.delete(id: note.id)
        pendingNote = nil
        bookmarks = []
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
        shouldAutoResumeOnWake = false
        notifySuccess(pageURL: pageURL)
    }

    private func notifySuccess(pageURL: URL?) {
        networkRetryCount = 0
        phase = .success(pageURL)
        NSSound(named: "Glass")?.play()

        let content = UNMutableNotificationContent()
        content.title = "KoeNotes: Class Notes Saved"
        content.body = "Your study notes, corrections, and quiz are ready in Notion."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Power Assertion & Sleep Management

    private func acquireSleepAssertions() {
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .userInitiated],
                reason: "Recording and transcribing Japanese class"
            )
        }
        if powerAssertionID == 0 {
            let reason = "NotesToNotion transcribing and saving class notes" as CFString
            let type = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
            _ = IOPMAssertionCreateWithName(type, level, reason, &powerAssertionID)
        }
    }

    private func releaseSleepAssertions() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
        }
    }

    private func handleWakeNotification() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !self.isProcessingInFlight else { return }
            if self.shouldAutoResumeOnWake || self.pendingAudioURL != nil || self.pendingNote != nil {
                if self.pendingNote != nil {
                    self.retryPendingNote()
                } else if self.pendingAudioURL != nil {
                    self.retryTranscription()
                }
            }
        }
    }

    private func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }
        if case AppError.geminiOverloaded = error { return true }
        return false
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
