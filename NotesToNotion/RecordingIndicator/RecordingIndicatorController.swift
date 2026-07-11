import AppKit
import Observation
import SwiftUI

/// Muestra/oculta el panel flotante de grabación observando `AppState.phase`
/// directamente, sin depender de ninguna vista SwiftUI viva.
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?
    private var appState: AppState?

    func start(with appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        observePhase()
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
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
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
        // La vista SwiftUI dicta el tamaño del panel (cambia entre grabando y procesando).
        hostingView.sizingOptions = .preferredContentSize
        panel.contentView = hostingView
        return panel
    }

    /// Esquina superior derecha, justo debajo de la barra de menú. Se recalcula
    /// en cada aparición por si cambió la configuración de pantallas.
    private func position(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenFrame.maxX - size.width - 16,
            y: screenFrame.maxY - size.height - 16
        ))
    }
}
