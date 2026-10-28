import AppKit
import UserNotifications

/// Intercepts app termination (Cmd+Q, Quit button, logout) while a
/// recording is in progress, so the class gets finalized to disk instead of
/// being silently dropped when the process dies, and handles local
/// notification presentation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        LiveSenseiTest.runIfNeeded()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present banner and play sound even if app is frontmost
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.phase == .recording else { return .terminateNow }
        Task {
            await appState.finalizeRecordingForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
