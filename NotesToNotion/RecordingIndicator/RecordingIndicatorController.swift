import AppKit
import Carbon
import Observation
import SwiftUI

/// Shows/hides the floating recording panel by observing `AppState.phase`
/// directly, without depending on any SwiftUI view staying alive, and manages
/// global keyboard shortcuts (⌘⇧R, ⌘⇧P, ⌘⇧M) via Carbon Event HotKeys.
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?
    private var appState: AppState?
    private var frameObserver: NSObjectProtocol?

    func start(with appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        observePhase()
        setupGlobalHotKeys()
    }

    private func observePhase() {
        guard let appState else { return }
        withObservationTracking {
            _ = appState.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handlePhaseChange()
                self.observePhase()
            }
        }
    }

    private func handlePhaseChange() {
        guard let appState else { return }
        switch appState.phase {
        case .recording, .processing:
            show()
        case .idle, .success, .error:
            hide()
        }
    }

    private func show() {
        guard let appState else { return }
        let panel = self.panel ?? makePanel(appState: appState)
        self.panel = panel
        panel.layoutIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(appState: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: RecordingIndicatorView().environment(appState))
        hostingView.sizingOptions = .preferredContentSize
        hostingView.postsFrameChangedNotifications = true
        panel.contentView = hostingView

        // Re-anchor to top-right whenever SwiftUI recalculates intrinsic content size
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostingView,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            MainActor.assumeIsolated {
                self.position(panel)
            }
        }

        return panel
    }

    /// Top-right corner, just below the menu bar. Recomputed every time it's
    /// shown or resized in case the display configuration or pill size changed.
    private func position(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        if let contentView = panel.contentView {
            let fitting = contentView.fittingSize
            if fitting.width > 0 && fitting.height > 0 {
                panel.setContentSize(fitting)
            }
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenFrame.maxX - size.width - 16,
            y: screenFrame.maxY - size.height - 16
        ))
    }

    // MARK: - Global Hotkeys Setup

    private func setupGlobalHotKeys() {
        GlobalHotKeyManager.shared.registerHotKeys { [weak self] hotKeyID in
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                switch hotKeyID {
                case GlobalHotKeyManager.hotKeyID_R: // ⌘⇧R
                    switch appState.phase {
                    case .idle:
                        if appState.hasCredentials {
                            appState.startRecording()
                        }
                    case .success:
                        appState.startRecording()
                    case .recording:
                        appState.stopAndProcess()
                    default:
                        break
                    }

                case GlobalHotKeyManager.hotKeyID_P: // ⌘⇧P
                    if appState.phase == .recording {
                        appState.togglePause()
                    }

                case GlobalHotKeyManager.hotKeyID_M: // ⌘⇧M
                    if appState.phase == .recording {
                        appState.addBookmark()
                    }

                default:
                    break
                }
            }
        }
    }
}

// MARK: - Carbon Global HotKey Manager

final class GlobalHotKeyManager: @unchecked Sendable {
    static let shared = GlobalHotKeyManager()

    static let hotKeyID_R: UInt32 = 1
    static let hotKeyID_P: UInt32 = 2
    static let hotKeyID_M: UInt32 = 3

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handler: (@Sendable (UInt32) -> Void)?

    func registerHotKeys(handler: @escaping @Sendable (UInt32) -> Void) {
        self.handler = handler
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, theEvent, userData) -> OSStatus in
                guard let theEvent = theEvent, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.triggerHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            print("WARN: Failed to install Carbon event handler: \(status)")
            return
        }

        let modifiers = UInt32(cmdKey | shiftKey)

        // ⌘⇧R: keyCode kVK_ANSI_R = 0x0F
        register(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, id: Self.hotKeyID_R)

        // ⌘⇧P: keyCode kVK_ANSI_P = 0x23
        register(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers, id: Self.hotKeyID_P)

        // ⌘⇧M: keyCode kVK_ANSI_M = 0x2E
        register(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers, id: Self.hotKeyID_M)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E324E00 | id), id: id)
        var hotKeyRef: EventHotKeyRef?
        let err = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if err == noErr, let hotKeyRef = hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
        } else {
            print("WARN: Failed to register hotkey \(id): \(err)")
        }
    }

    private func triggerHotKey(id: UInt32) {
        handler?(id)
    }

    deinit {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
