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
                    Button("Empezar a grabar") { appState.startRecording() }
                } else {
                    Text("Configura tus API keys para empezar")
                }

            case .recording:
                Text("Grabando… \(appState.formattedElapsed)")
                Button("Detener y guardar") { appState.stopAndProcess() }

            case .processing(let status):
                Text(status)

            case .success(let pageURL):
                Text("Guardado en Notion ✓")
                if let pageURL {
                    Button("Abrir en Notion") { NSWorkspace.shared.open(pageURL) }
                }
                Button("Nueva grabación") { appState.startRecording() }
                Button("Listo") { appState.reset() }

            case .error(let message):
                Text(message)
                Button("Entendido") { appState.reset() }
            }
        }

        Divider()

        Button("Configuración…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Salir") { NSApplication.shared.terminate(nil) }
    }
}
