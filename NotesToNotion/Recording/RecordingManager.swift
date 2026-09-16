import AVFoundation
import Foundation

final class RecordingManager {
    private var micRecorder: AVAudioRecorder?
    private var systemAudioRecorder: SystemAudioRecorder?
    private var systemAudioURL: URL?

    func start() async throws {
        try await ensureMicrophonePermission()

        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = FileManager.default.temporaryDirectory
        let micURL = tempDir.appendingPathComponent("mic-\(timestamp).m4a")

        // Mono at a low bitrate: enough for voice and keeps the file small
        // even for long recordings.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ]

        let recorder = try AVAudioRecorder(url: micURL, settings: settings)
        guard recorder.record() else {
            throw AppError.recordingFailed("the microphone didn't start recording.")
        }
        self.micRecorder = recorder

        // System audio (the other side of a video call) is best-effort: a
        // denied Screen Recording permission shouldn't block recording, it
        // just means the note ends up mic-only.
        let systemURL = tempDir.appendingPathComponent("system-\(timestamp).caf")
        let systemRecorder = SystemAudioRecorder(fileURL: systemURL)
        do {
            try await systemRecorder.start()
            self.systemAudioRecorder = systemRecorder
            self.systemAudioURL = systemURL
        } catch {
            self.systemAudioRecorder = nil
            self.systemAudioURL = nil
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    func stop() async -> URL? {
        guard let micRecorder else { return nil }
        let micURL = micRecorder.url
        micRecorder.stop()
        self.micRecorder = nil
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            print("DEBUG stop(): mic file does not exist at \(micURL.path)")
            return nil
        }
        print("DEBUG stop(): mic file size = \(fileSize(micURL)) bytes at \(micURL.path)")

        guard let systemAudioRecorder, let systemAudioURL else {
            print("DEBUG stop(): no system audio recorder, returning mic-only")
            return micURL
        }
        await systemAudioRecorder.stop()
        self.systemAudioRecorder = nil
        self.systemAudioURL = nil

        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            print("DEBUG stop(): system audio file does not exist, returning mic-only")
            return micURL
        }
        print("DEBUG stop(): system file size = \(fileSize(systemAudioURL)) bytes at \(systemAudioURL.path)")

        let mixedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-\(Int(Date().timeIntervalSince1970)).m4a")
        do {
            try AudioMixer.mix(micURL: micURL, systemURL: systemAudioURL, outputURL: mixedURL)
            print("DEBUG stop(): mixed file size = \(fileSize(mixedURL)) bytes at \(mixedURL.path)")
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemAudioURL)
            return mixedURL
        } catch {
            // Mixing failed (e.g. an empty/corrupt system track) — keep the
            // mic-only recording instead of losing the note entirely.
            print("DEBUG stop(): mixing threw \(error), falling back to mic-only")
            try? FileManager.default.removeItem(at: systemAudioURL)
            return micURL
        }
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
