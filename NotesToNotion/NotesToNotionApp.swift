import SwiftUI

@main
struct NotesToNotionApp: App {
    @State private var appState = AppState()
    @State private var indicatorController = RecordingIndicatorController()

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
