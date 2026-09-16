import AppKit

/// Intercepts app termination (Cmd+Q, Quit button, logout) while a
/// recording is in progress, so the class gets finalized to disk instead of
/// being silently dropped when the process dies.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.phase == .recording else { return .terminateNow }
        Task {
            await appState.finalizeRecordingForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
