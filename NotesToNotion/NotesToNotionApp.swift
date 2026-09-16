import SwiftUI

@main
struct NotesToNotionApp: App {
    @State private var appState = AppState()
    @State private var indicatorController = RecordingIndicatorController()

    init() {
        // Unbuffered stdout so debug prints show up immediately when run
        // from a shell instead of sitting in a block buffer until exit.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
                .task { indicatorController.start(with: appState) }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
