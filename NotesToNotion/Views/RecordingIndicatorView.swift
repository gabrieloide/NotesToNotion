import SwiftUI

/// Content of the floating pill that appears in the top-right corner
/// while recording or processing a note.
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            switch appState.phase {
            case .recording:
                // Status dot + timer
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isPaused ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appState.formattedElapsed)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }

                // Audio level meters for You & Sensei
                HStack(spacing: 8) {
                    LevelMeter(label: "You", level: appState.micLevel, color: .green)
                    LevelMeter(label: "Sensei", level: appState.systemLevel, color: .blue)
                }

                // Action buttons: Bookmark, Pause/Resume, Stop
                HStack(spacing: 6) {
                    Button {
                        appState.addBookmark()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10))
                            if !appState.bookmarks.isEmpty {
                                Text("\(appState.bookmarks.count)")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Bookmark this moment (⌘⇧M)")

                    Button {
                        appState.togglePause()
                    } label: {
                        Image(systemName: appState.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(appState.isPaused ? "Resume (⌘⇧P)" : "Pause (⌘⇧P)")

                    Button("Stop") {
                        appState.stopAndProcess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .help("Stop & Save (⌘⇧R)")
                }

            case .processing(let status):
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            default:
                // The controller hides the panel in every other state.
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float
    let color: Color

    private let barWidth: CGFloat = 26
    private let barHeight: CGFloat = 5
    private let minVisibleWidth: CGFloat = 3.5

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Capsule()
                .fill(color.opacity(0.25))
                .frame(width: barWidth, height: barHeight)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: max(minVisibleWidth, barWidth * CGFloat(min(1.0, max(0.0, level)))))
                }
                .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}
