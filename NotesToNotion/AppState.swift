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

    private let recorder = RecordingManager()
    private var timer: Timer?

    // Tope de seguridad para grabaciones olvidadas.
    private static let maxRecordingSeconds = 60 * 60

    init() {
        hasCredentials = Self.credentialsPresent()
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
        guard let audioURL = recorder.stop() else {
            phase = .error("No se pudo guardar el audio de la grabación.")
            return
        }
        Task { await process(audioURL: audioURL) }
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
            guard let geminiKey = KeychainStore.read(.geminiAPIKey),
                  let notionToken = KeychainStore.read(.notionToken),
                  let databaseID = KeychainStore.read(.notionDatabaseID) else {
                throw AppError.missingCredentials
            }

            phase = .processing("Transcribiendo con Gemini…")
            let gemini = GeminiClient(apiKey: geminiKey)
            let result = try await gemini.transcribeAndSummarize(audioFile: audioURL)

            phase = .processing("Guardando en Notion…")
            let notion = NotionClient(token: notionToken, databaseID: databaseID)
            let pageURL = try await notion.createVoiceNote(
                summary: result.summary,
                keyPoints: result.keyPoints,
                transcript: result.transcript
            )

            phase = .success(pageURL)
        } catch {
            phase = .error(Self.message(for: error))
        }
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
        return "Algo salió mal: \(error.localizedDescription)"
    }
}
