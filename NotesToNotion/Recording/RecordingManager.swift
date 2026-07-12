import AVFoundation
import Foundation

final class RecordingManager {
    private var recorder: AVAudioRecorder?

    func start() async throws {
        try await ensureMicrophonePermission()

        let filename = "recording-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        // Mono at a low bitrate: enough for voice and keeps the file small
        // even for long recordings.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw AppError.recordingFailed("the microphone didn't start recording.")
        }
        self.recorder = recorder
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw AppError.microphonePermissionDenied }
        default:
            throw AppError.microphonePermissionDenied
        }
    }
}
