import SwiftUI

/// Contenido de la píldora flotante que aparece arriba a la derecha
/// mientras se graba o se procesa una nota.
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            switch appState.phase {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(appState.formattedElapsed)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Button("Detener") { appState.stopAndProcess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)

            case .processing(let status):
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            default:
                // El controller oculta el panel en cualquier otro estado.
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}
