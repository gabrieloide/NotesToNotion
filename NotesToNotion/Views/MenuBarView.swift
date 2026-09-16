import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch appState.phase {
            case .idle:
                if appState.hasCredentials {
                    Button("Start Recording") { appState.startRecording() }
                } else {
                    Text("Set up your API keys to get started")
                }

            case .recording:
                Text("Recording… \(appState.formattedElapsed)")
                Button("Stop & Save") { appState.stopAndProcess() }

            case .processing(let status):
                Text(status)

            case .success(let pageURL):
                Text("Saved to Notion ✓")
                if let pageURL {
                    Button("Open in Notion") { NSWorkspace.shared.open(pageURL) }
                }
                Button("New Recording") { appState.startRecording() }
                Button("Done") { appState.reset() }

            case .error(let message):
                Text(message)
                if appState.pendingNote != nil {
                    Button("Retry") { appState.retryPendingNote() }
                    Button("Save Transcript Only") { appState.saveRawTranscript() }
                    Button("Discard Note") { appState.discardPendingNote() }
                } else if appState.pendingAudioURL != nil {
                    Button("Retry Transcription") { appState.retryTranscription() }
                    Button("Discard Recording") { appState.discardPendingAudio() }
                } else {
                    Button("Got It") { appState.reset() }
                }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
